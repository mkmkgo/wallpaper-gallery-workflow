#!/bin/bash
# ========================================
# 创建 Tag 脚本（第一步）
# ========================================
#
# 功能：提交更改，创建并推送新 tag
#       不包含 stats.json 更新和 release 发布
#
# 用法：
#   ./scripts/create-tag.sh <图床仓库路径> [提交信息]
#
# 输出：
#   /tmp/new_tag.txt - 新创建的 tag
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
    local commit_msg="${2:-chore: update wallpapers [$(TZ='Asia/Shanghai' date +'%Y-%m-%d')]}"

    cd "$project_root"

    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}创建 Tag${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    # 配置 git
    git config user.name "github-actions[bot]"
    git config user.email "github-actions[bot]@users.noreply.github.com"

    # 获取最新 tag
    git fetch --tags --quiet 2>/dev/null || true
    local latest_tag=$(git tag -l 'v*' --sort=-version:refname | head -1)

    # ==========================================
    # P0 修复：中断恢复机制
    # ==========================================

    # 1. 检查是否有未提交的更改
    local has_changes=false
    if [ -n "$(git status --porcelain)" ]; then
        has_changes=true
    fi

    # ---------------------------------------------------------
    # [LOCAL] 图片版本号只在图片文件真变时才递增
    #
    # 背景：图片 URL 形如 .../nuanXinProPic@<tag>/...，tag 一变，
    # 全站每一个图片 URL 都变，整个 CDN 缓存随之作废，所有图片
    # 回到冷启动（实测 MISS≈3s / HIT≈0.04s，差 70~90 倍）。
    # 而 stats.json / data / metadata 每天都在变，导致 tag 一天一个。
    #
    # 修法：只有当 wallpaper/ thumbnail/ preview/ 下有改动时才创建新
    # v* tag；仅数据类文件变化时复用现有 tag，图片 URL 保持不变。
    # ---------------------------------------------------------
    local changed_files
    changed_files=$(
        {
            git -c core.quotePath=false diff HEAD --name-only
            git -c core.quotePath=false ls-files --others --exclude-standard
        } 2>/dev/null | sort -u
    )
    local has_image_changes=false
    if printf '%s\n' "${changed_files}" | grep -qE '^(wallpaper|thumbnail|preview)/'; then
        has_image_changes=true
    fi

    echo -e "${BLUE}本次改动是否含图片文件: ${has_image_changes}${NC}"
    if [ "$has_changes" = true ] && [ "$has_image_changes" = false ]; then
        echo -e "${BLUE}改动明细（前 10 条）:${NC}"
        printf '%s\n' "${changed_files}" | head -10 | sed 's/^/    /'
    fi

    # 2. 检查当前 HEAD commit 是否已有 tag（工作流中断恢复场景）
    local existing_tag=$(git tag --points-at HEAD | grep '^v' | head -1)

    if [ -n "$existing_tag" ]; then
        echo -e "${YELLOW}🔄 发现当前 commit 已有 tag: ${existing_tag}${NC}"
        echo -e "${YELLOW}   这可能是上次工作流中断后恢复的情况${NC}"

        if [ "$has_changes" = true ]; then
            # 有新的更改需要提交，创建新 tag
            echo -e "${BLUE}   检测到新更改，将创建新 tag...${NC}"
        else
            # 没有新更改，复用现有 tag
            echo -e "${GREEN}   没有新更改，复用现有 tag: ${existing_tag}${NC}"
            echo "$existing_tag" > /tmp/new_tag.txt
            return 0
        fi
    fi

    # 3. 检查 /tmp/new_tag.txt 是否存在未完成的 tag（同一工作流内的恢复）
    if [ -f /tmp/new_tag.txt ]; then
        local pending_tag=$(cat /tmp/new_tag.txt)
        # 检查这个 tag 是否已经在远程存在
        if git ls-remote --tags origin | grep -q "refs/tags/${pending_tag}$"; then
            echo -e "${YELLOW}🔄 发现未完成的 tag: ${pending_tag}（已推送到远程）${NC}"
            if [ "$has_changes" = false ]; then
                echo -e "${GREEN}   没有新更改，继续使用此 tag${NC}"
                return 0
            fi
        fi
    fi

    # ==========================================
    # 正常流程：创建新 tag
    # ==========================================

    # 检查是否有更改需要提交
    if [ "$has_changes" = false ]; then
        echo -e "${YELLOW}没有检测到更改，无需创建 tag${NC}"
        exit 0
    fi

    # ---------------------------------------------------------
    # [LOCAL] 仅数据类改动：照常提交推送，但不递增图片版本号
    #
    # 不创建新 v* tag，而是复用 latest_tag 写回 /tmp/new_tag.txt，
    # 保证下游步骤（update-timestamps / verify-timestamps /
    # process-metadata / publish-release）拿到的仍是有效 tag。
    # ---------------------------------------------------------
    if [ "$has_image_changes" = false ] && [ -n "$latest_tag" ]; then
        echo ""
        echo -e "${YELLOW}本次仅为数据类改动（不含 wallpaper/thumbnail/preview），复用现有 tag: ${latest_tag}${NC}"
        echo -e "${YELLOW}图片 URL 保持不变，CDN 缓存不会因本次发版整体失效${NC}"
        echo ""

        echo -e "${BLUE}📥 提交更改（不创建新 tag）...${NC}"
        git add .
        git commit -m "$commit_msg"

        echo -e "${BLUE}🚀 推送到远程...${NC}"
        git push

        echo ""
        echo -e "${GREEN}✅ 数据更新已提交，图片版本保持: ${latest_tag}${NC}"

        echo "$latest_tag" > /tmp/new_tag.txt
        return 0
    fi

    # 计算新版本号（patch 满 100 进位 minor，minor 满 10 进位 major）
    # [LOCAL] 支持 TAG_MAJOR 环境变量：分仓仓库（如 desktop）从 v2.0.0 起独立编号，
    # 避免与主仓 v1.x 冲突。未设置时沿用主仓逻辑（v1.x）。
    local new_tag=""
    local tag_major="${TAG_MAJOR:-}"
    if [ -z "$latest_tag" ]; then
        if [ -n "$tag_major" ]; then
            new_tag="v${tag_major}.0.0"
        else
            new_tag="v1.0.1"
        fi
    else
        local version=${latest_tag#v}
        IFS='.' read -r major minor patch <<< "$version"
        if [ -n "$tag_major" ]; then
            major="$tag_major"
        fi
        local new_patch=$((patch + 1))
        if [ "$new_patch" -ge 100 ]; then
            new_patch=0
            minor=$((minor + 1))
        fi
        if [ "$minor" -ge 10 ]; then
            minor=0
            major=$((major + 1))
        fi
        new_tag="v${major}.${minor}.${new_patch}"
    fi

    echo -e "📦 版本号: ${latest_tag:-无} → ${GREEN}${new_tag}${NC}"
    echo ""

    local today=$(TZ='Asia/Shanghai' date +'%Y-%m-%d')

    # 提交更改（缩略图、预览图等）
    echo -e "${BLUE}📥 提交更改...${NC}"
    git add .
    git commit -m "$commit_msg"

    # 创建 tag
    echo -e "${BLUE}🏷️  创建 tag: ${new_tag}${NC}"
    git tag -a "$new_tag" -m "Release $new_tag - $today"

    # 推送 commit 和 tag
    echo -e "${BLUE}🚀 推送到远程...${NC}"
    git push
    git push origin "$new_tag"

    echo ""
    echo -e "${GREEN}✅ Tag 创建成功: ${new_tag}${NC}"

    # 输出新 tag 供后续脚本使用
    echo "$new_tag" > /tmp/new_tag.txt
}

main "$@"
