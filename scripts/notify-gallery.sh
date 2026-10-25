#!/usr/bin/env bash
#
# 通知 wallpaper-gallery 重新部署。
#
# ── 为什么需要这一步 ─────────────────────────────────────────────
# 图仓（nuanXinProPic / nuanXinProPic-desktop）处理完新壁纸后会发布新 tag，
# 而 gallery 部署时才把「最新 tag」写进 public/miniapp/config.json 的 cdnTag
# 字段，供小程序远程下发覆盖内置的兜底版本号。
#
# gallery 侧虽有 schedule（每天 UTC 18:00 ≈ 北京时间凌晨 02:00），但那意味着
# 「上传的新图最多要等近 24 小时才可见」——不可接受。这里用 repository_dispatch
# 让三个部署流（Cloudflare / EdgeOne 海外 / EdgeOne 国内）实时重建。
#
# 触发链：
#   Studio 上传 → 图仓 → repository_dispatch(process-wallpapers)
#     → 本流水线处理+打 tag+发布 release
#     → 【本步】repository_dispatch(wallpaper-updated) → gallery 三站重建
#     → 站点 data/ 与 miniapp/config.json 的 cdnTag 同步 → 小程序免发版生效
#
# ── 设计约束 ─────────────────────────────────────────────────────
# 1. **永不拖垮流水线**：壁纸已经处理完并发布成功，通知失败只应告警，
#    不应让整个 run 标红误导排查。任何异常都 exit 0。
# 2. client_payload 用 Node 构造 JSON（而非 heredoc 拼字符串），
#    避免 SHARD_LABEL 里的中文/特殊字符破坏 JSON 结构。
# 3. gallery 三条部署流的 concurrency 均为 cancel-in-progress: true，
#    短时间内多次通知会互相取消、只有最后一次真正跑完，天然去重。
#
# ── 环境变量 ─────────────────────────────────────────────────────
#   GH_TOKEN        必填；需对 wallpaper-gallery 有 repo 权限
#   TARGET_REPO     默认 mkmkgo/wallpaper-gallery
#   EVENT_TYPE      默认 wallpaper-updated
#   NEW_TAG         刚创建的 tag（可空，仅用于日志与 payload）
#   REPO_NAME       图仓名（可空）
#   SHARD_LABEL     分片标签，如「主仓」「桌面壁纸仓」（可空）
#   SOURCE          触发来源，用于区分 process / rollback（默认 unknown）
#
# ── 用法 ─────────────────────────────────────────────────────────
#   bash scripts/notify-gallery.sh

TARGET_REPO="${TARGET_REPO:-mkmkgo/wallpaper-gallery}"
EVENT_TYPE="${EVENT_TYPE:-wallpaper-updated}"
SOURCE="${SOURCE:-unknown}"
NEW_TAG="${NEW_TAG:-}"
REPO_NAME="${REPO_NAME:-}"
SHARD_LABEL="${SHARD_LABEL:-}"

if [ -z "${GH_TOKEN:-}" ]; then
  echo "::warning::GH_TOKEN 未设置，跳过通知 gallery（站点将依赖每日定时任务刷新）"
  exit 0
fi

PAYLOAD_FILE="$(mktemp)"
if ! NEW_TAG="$NEW_TAG" REPO_NAME="$REPO_NAME" SHARD_LABEL="$SHARD_LABEL" \
     SOURCE="$SOURCE" EVENT_TYPE="$EVENT_TYPE" node -e '
       const fs = require("node:fs")
       fs.writeFileSync(
         process.argv[1],
         JSON.stringify({
           event_type: process.env.EVENT_TYPE,
           client_payload: {
             repo: process.env.REPO_NAME,
             tag: process.env.NEW_TAG,
             shard: process.env.SHARD_LABEL,
             source: process.env.SOURCE,
           },
         }),
       )
     ' "$PAYLOAD_FILE"; then
  echo "::warning::构造 dispatch payload 失败，跳过通知 gallery"
  rm -f "$PAYLOAD_FILE"
  exit 0
fi

echo "🔄 通知 $TARGET_REPO 重新部署（source=$SOURCE repo=${REPO_NAME:-未知} tag=${NEW_TAG:-无}）..."

HTTP_CODE="$(curl -s -o /tmp/gallery-dispatch-response.txt -w '%{http_code}' \
  -X POST \
  -H "Authorization: token $GH_TOKEN" \
  -H "Accept: application/vnd.github.v3+json" \
  "https://api.github.com/repos/$TARGET_REPO/dispatches" \
  --data-binary "@$PAYLOAD_FILE" 2>/dev/null || echo '000')"

BODY="$(head -c 300 /tmp/gallery-dispatch-response.txt 2>/dev/null || true)"
rm -f "$PAYLOAD_FILE" /tmp/gallery-dispatch-response.txt

case "$HTTP_CODE" in
  204)
    echo "✅ gallery 三站部署已触发，稍后自动同步最新 CDN tag 与数据"
    ;;
  401|403)
    echo "::warning::通知 gallery 失败（HTTP $HTTP_CODE）：GH_TOKEN 对 $TARGET_REPO 无权限，$BODY"
    echo "::warning::请确认 REPO_TOKEN 具备 wallpaper-gallery 的 repo 范围；站点将回退到每日定时任务刷新"
    ;;
  404)
    echo "::warning::通知 gallery 失败（HTTP 404）：仓库不存在或 token 无权访问，$BODY"
    ;;
  *)
    echo "::warning::通知 gallery 失败（HTTP $HTTP_CODE）：${BODY:-无响应体}"
    ;;
esac

# 无论成败都 exit 0：壁纸处理与发布已完成，不能因通知环节让流水线标红
exit 0
