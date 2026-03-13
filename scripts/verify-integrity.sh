#!/bin/bash
# ========================================
# 数据完整性验证脚本 (P0 修复)
# ========================================
#
# 功能：检查壁纸系统数据一致性
#   - 孤儿原图（有原图但无缩略图）
#   - 孤儿缩略图（有缩略图但无原图）
#   - metadata 一致性（有记录但文件不存在）
#   - timestamps 一致性
#
# 用法：
#   ./scripts/verify-integrity.sh <图床仓库路径> [--fix]
#
# 参数：
#   --fix  自动修复发现的问题（删除孤儿文件）
#
# ========================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 计数器
ORPHAN_ORIGINALS=0
ORPHAN_THUMBNAILS=0
ORPHAN_PREVIEWS=0
MISSING_FILES=0
TIMESTAMP_ISSUES=0
FIXED_COUNT=0

main() {
    local project_root="${1:-.}"
    local fix_mode=false

    # 解析参数
    for arg in "$@"; do
        case $arg in
            --fix)
                fix_mode=true
                shift
                ;;
        esac
    done

    cd "$project_root"

    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}数据完整性验证${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    if [ "$fix_mode" = true ]; then
        echo -e "${YELLOW}⚠️  修复模式已启用${NC}"
        echo ""
    fi

    # 1. 检查孤儿原图（有原图但无缩略图）
    echo -e "${BLUE}=== 检查孤儿原图（有原图但无缩略图）===${NC}"
    check_orphan_originals "$project_root" "$fix_mode"
    echo ""

    # 2. 检查孤儿缩略图（有缩略图但无原图）
    echo -e "${BLUE}=== 检查孤儿缩略图（有缩略图但无原图）===${NC}"
    check_orphan_thumbnails "$project_root" "$fix_mode"
    echo ""

    # 3. 检查孤儿预览图（有预览图但无原图）
    echo -e "${BLUE}=== 检查孤儿预览图（有预览图但无原图）===${NC}"
    check_orphan_previews "$project_root" "$fix_mode"
    echo ""

    # 4. 检查 metadata 一致性
    echo -e "${BLUE}=== 检查 metadata 一致性 ===${NC}"
    check_metadata_consistency "$project_root" "$fix_mode"
    echo ""

    # 5. 检查 timestamps 一致性
    echo -e "${BLUE}=== 检查 timestamps 一致性 ===${NC}"
    check_timestamps_consistency "$project_root" "$fix_mode"
    echo ""

    # 汇总报告
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}验证报告${NC}"
    echo -e "${BLUE}========================================${NC}"

    local total_issues=$((ORPHAN_ORIGINALS + ORPHAN_THUMBNAILS + ORPHAN_PREVIEWS + MISSING_FILES + TIMESTAMP_ISSUES))

    if [ $total_issues -eq 0 ]; then
        echo -e "${GREEN}✅ 数据完整性验证通过，未发现问题${NC}"
    else
        echo -e "${RED}❌ 发现 ${total_issues} 个问题：${NC}"
        [ $ORPHAN_ORIGINALS -gt 0 ] && echo -e "   - 孤儿原图: ${ORPHAN_ORIGINALS}"
        [ $ORPHAN_THUMBNAILS -gt 0 ] && echo -e "   - 孤儿缩略图: ${ORPHAN_THUMBNAILS}"
        [ $ORPHAN_PREVIEWS -gt 0 ] && echo -e "   - 孤儿预览图: ${ORPHAN_PREVIEWS}"
        [ $MISSING_FILES -gt 0 ] && echo -e "   - metadata 引用缺失: ${MISSING_FILES}"
        [ $TIMESTAMP_ISSUES -gt 0 ] && echo -e "   - timestamps 问题: ${TIMESTAMP_ISSUES}"

        if [ "$fix_mode" = true ]; then
            echo ""
            echo -e "${GREEN}✅ 已修复 ${FIXED_COUNT} 个问题${NC}"
        fi
    fi

    # 输出结果供工作流使用
    echo "$total_issues" > /tmp/integrity_issues.txt

    # 如果有问题且不是修复模式，返回非零退出码
    if [ $total_issues -gt 0 ] && [ "$fix_mode" = false ]; then
        exit 1
    fi
}

# 检查孤儿原图
check_orphan_originals() {
    local project_root="$1"
    local fix_mode="$2"
    local count=0

    for series in desktop mobile avatar; do
        local wallpaper_dir="$project_root/wallpaper/$series"
        local thumbnail_dir="$project_root/thumbnail/$series"

        [ ! -d "$wallpaper_dir" ] && continue

        while IFS= read -r -d '' img; do
            local rel_path="${img#$wallpaper_dir/}"
            local filename=$(basename "$img")
            local name="${filename%.*}"
            local dir_path=$(dirname "$rel_path")

            # 构建缩略图路径
            if [ "$dir_path" = "." ]; then
                local thumb_path="$thumbnail_dir/${name}.webp"
            else
                local thumb_path="$thumbnail_dir/$dir_path/${name}.webp"
            fi

            if [ ! -f "$thumb_path" ]; then
                count=$((count + 1))
                echo -e "${RED}❌ 缺少缩略图: $img${NC}"
                echo -e "   期望路径: $thumb_path"

                if [ "$fix_mode" = true ]; then
                    # 修复方案：重新生成缩略图或删除原图
                    echo -e "   ${YELLOW}⚠️  需要手动处理或重新运行工作流${NC}"
                fi
            fi
        done < <(find "$wallpaper_dir" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.webp" \) -print0)
    done

    ORPHAN_ORIGINALS=$count
    [ $count -eq 0 ] && echo -e "${GREEN}✅ 未发现孤儿原图${NC}"
}

# 检查孤儿缩略图
check_orphan_thumbnails() {
    local project_root="$1"
    local fix_mode="$2"
    local count=0

    for series in desktop mobile avatar; do
        local wallpaper_dir="$project_root/wallpaper/$series"
        local thumbnail_dir="$project_root/thumbnail/$series"

        [ ! -d "$thumbnail_dir" ] && continue

        while IFS= read -r -d '' thumb; do
            local rel_path="${thumb#$thumbnail_dir/}"
            local filename=$(basename "$thumb")
            local name="${filename%.*}"
            local dir_path=$(dirname "$rel_path")

            # 反向查找原图（支持 jpg/jpeg/png）
            local found=false
            for ext in jpg jpeg png JPG JPEG PNG; do
                if [ "$dir_path" = "." ]; then
                    local orig_path="$wallpaper_dir/${name}.${ext}"
                else
                    local orig_path="$wallpaper_dir/$dir_path/${name}.${ext}"
                fi

                if [ -f "$orig_path" ]; then
                    found=true
                    break
                fi
            done

            if [ "$found" = false ]; then
                count=$((count + 1))
                echo -e "${RED}❌ 孤儿缩略图: $thumb${NC}"

                if [ "$fix_mode" = true ]; then
                    echo -e "   ${YELLOW}正在删除...${NC}"
                    rm -f "$thumb"
                    FIXED_COUNT=$((FIXED_COUNT + 1))
                fi
            fi
        done < <(find "$thumbnail_dir" -type f -iname "*.webp" -print0)
    done

    ORPHAN_THUMBNAILS=$count
    [ $count -eq 0 ] && echo -e "${GREEN}✅ 未发现孤儿缩略图${NC}"
}

# 检查孤儿预览图
check_orphan_previews() {
    local project_root="$1"
    local fix_mode="$2"
    local count=0

    for series in desktop mobile; do  # avatar 没有预览图
        local wallpaper_dir="$project_root/wallpaper/$series"
        local preview_dir="$project_root/preview/$series"

        [ ! -d "$preview_dir" ] && continue

        while IFS= read -r -d '' preview; do
            local rel_path="${preview#$preview_dir/}"
            local filename=$(basename "$preview")
            local name="${filename%.*}"
            local dir_path=$(dirname "$rel_path")

            # 反向查找原图
            local found=false
            for ext in jpg jpeg png JPG JPEG PNG; do
                if [ "$dir_path" = "." ]; then
                    local orig_path="$wallpaper_dir/${name}.${ext}"
                else
                    local orig_path="$wallpaper_dir/$dir_path/${name}.${ext}"
                fi

                if [ -f "$orig_path" ]; then
                    found=true
                    break
                fi
            done

            if [ "$found" = false ]; then
                count=$((count + 1))
                echo -e "${RED}❌ 孤儿预览图: $preview${NC}"

                if [ "$fix_mode" = true ]; then
                    echo -e "   ${YELLOW}正在删除...${NC}"
                    rm -f "$preview"
                    FIXED_COUNT=$((FIXED_COUNT + 1))
                fi
            fi
        done < <(find "$preview_dir" -type f -iname "*.webp" -print0)
    done

    ORPHAN_PREVIEWS=$count
    [ $count -eq 0 ] && echo -e "${GREEN}✅ 未发现孤儿预览图${NC}"
}

# 检查 metadata 一致性
check_metadata_consistency() {
    local project_root="$1"
    local fix_mode="$2"
    local count=0

    # 检查是否有 jq
    if ! command -v jq &>/dev/null; then
        echo -e "${YELLOW}⚠️  跳过 metadata 检查（未安装 jq）${NC}"
        return
    fi

    for series in desktop mobile avatar; do
        local metadata_file="$project_root/metadata/${series}.json"

        [ ! -f "$metadata_file" ] && continue

        # 遍历 metadata 中的所有图片路径
        while IFS= read -r path; do
            if [ ! -f "$project_root/$path" ]; then
                count=$((count + 1))
                echo -e "${RED}❌ metadata 记录但文件不存在: $path${NC}"

                if [ "$fix_mode" = true ]; then
                    echo -e "   ${YELLOW}⚠️  需要手动从 metadata 中移除此记录${NC}"
                fi
            fi
        done < <(jq -r '.images | keys[]' "$metadata_file" 2>/dev/null)
    done

    MISSING_FILES=$count
    [ $count -eq 0 ] && echo -e "${GREEN}✅ metadata 一致性验证通过${NC}"
}

# 检查 timestamps 一致性
check_timestamps_consistency() {
    local project_root="$1"
    local fix_mode="$2"
    local count=0
    local timestamp_file="$project_root/timestamps-backup-all.txt"

    [ ! -f "$timestamp_file" ] && {
        echo -e "${YELLOW}⚠️  timestamps 文件不存在${NC}"
        return
    }

    # 检查 timestamps 中的文件是否存在
    while IFS='|' read -r series rel_path timestamp tag; do
        [ -z "$series" ] && continue

        local full_path="$project_root/wallpaper/$series/$rel_path"

        if [ ! -f "$full_path" ]; then
            count=$((count + 1))
            echo -e "${RED}❌ timestamps 记录但文件不存在: wallpaper/$series/$rel_path${NC}"

            if [ "$fix_mode" = true ]; then
                echo -e "   ${YELLOW}⚠️  需要手动从 timestamps 中移除此记录${NC}"
            fi
        fi
    done < "$timestamp_file"

    TIMESTAMP_ISSUES=$count
    [ $count -eq 0 ] && echo -e "${GREEN}✅ timestamps 一致性验证通过${NC}"
}

main "$@"
