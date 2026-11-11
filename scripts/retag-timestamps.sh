#!/bin/bash
# ========================================
# 补图后重打 tag 脚本
# ========================================
#
# 用途：修复「缩略图补生成了，但前端仍按旧 tag 取图」的死锁。
#
# 背景（为什么必须有这一步）：
#   前端拼图 URL 用的是每条数据自带的 cdnTag（= timestamps 记录里的 first_tag）：
#       https://<cdn>/gh/mkmkgo/nuanXinProPic@<cdnTag>/thumbnail/...
#   tag 是不可变快照。历史遗漏的那批原图，first_tag 停在 v1.5.29 之类的旧 tag，
#   缩略图是本次补图才生成的、只存在于新 tag 里 —— 所以只生成图片不改 first_tag，
#   前端依旧 404。
#
#   而 verify-timestamps.sh --fix 只做两件事：补「缺记录」、删「孤立记录」，
#   **不会修改已有记录的 tag**。因此补图后必须显式把受影响条目的 tag 改成新 tag。
#
# 用法：
#   ./scripts/retag-timestamps.sh <图床仓库路径> <新tag> [清单文件]
#     - 清单文件每行格式：series|相对路径（即 process-new-images.sh 在补图模式下
#       写出的 /tmp/backfilled_images.txt）
#     - 省略清单文件时，默认读 /tmp/backfilled_images.txt
#
# 输出：
#   就地重写 <图床仓库路径>/timestamps-backup-all.txt 中被命中条目的第 4 列
#
# ========================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

main() {
    local project_root="${1:-.}"
    local new_tag="${2:-}"
    local list_file="${3:-/tmp/backfilled_images.txt}"

    if [ -z "$new_tag" ]; then
        echo -e "${RED}错误: 必须传入新 tag${NC}"
        exit 1
    fi

    local backup_file="$project_root/timestamps-backup-all.txt"
    if [ ! -f "$backup_file" ]; then
        echo -e "${RED}错误: 找不到 $backup_file${NC}"
        exit 1
    fi

    if [ ! -s "$list_file" ]; then
        echo -e "${YELLOW}清单为空（$list_file），无需重打 tag${NC}"
        exit 0
    fi

    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}补图后重打 tag → $new_tag${NC}"
    echo -e "${BLUE}========================================${NC}"
    local list_count
    list_count=$(wc -l < "$list_file" | tr -d ' ')
    echo -e "  清单: $list_file (${list_count} 条)"

    local tmp_file
    tmp_file=$(mktemp)

    # 单次 awk 扫描：清单进内存做集合，避免 1500×4500 的 O(N*M) 逐行 grep
    awk -F'|' -v OFS='|' -v tag="$new_tag" -v tmp="$tmp_file" '
        NR == FNR { want[$0] = 1; next }
        {
            key = $1 "|" $2
            if (NF >= 4 && (key in want)) {
                changed++
                if ($4 != tag) {
                    $4 = tag
                    real++
                }
                print
                next
            }
            print
        }
        END {
            printf "%d %d\n", changed + 0, real + 0 > tmp
        }
    ' "$list_file" "$backup_file" > "$tmp_file.new"

    read -r matched rewritten < "$tmp_file"
    rm -f "$tmp_file"

    mv "$tmp_file.new" "$backup_file"

    echo -e "  命中记录: ${GREEN}${matched:-0}${NC} 条，其中实际改写: ${GREEN}${rewritten:-0}${NC} 条"

    if [ "${matched:-0}" -eq 0 ]; then
        echo -e "${YELLOW}⚠️  清单里的条目在时间戳文件中一条都没匹配到 —— 请检查清单格式（应为 series|相对路径）${NC}"
        exit 1
    fi

    local diff=$(( $(wc -l < "$list_file" | tr -d ' ') - matched ))
    if [ "$diff" -gt 0 ]; then
        echo -e "${YELLOW}  注: 有 $diff 条清单项没有对应时间戳记录（可能本就缺失，由 verify-timestamps --fix 另行补齐）${NC}"
    fi

    echo -e "${GREEN}✅ 重打 tag 完成${NC}"
}

main "$@"
