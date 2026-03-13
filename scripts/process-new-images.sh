#!/bin/bash
# ========================================
# 处理新增图片脚本（优化版）
# ========================================
#
# 功能：基于 Git diff 快速检测新增图片，生成缩略图和预览图
#       时间复杂度 O(新增文件数)，与总图片数无关
#
# 用法：
#   ./scripts/process-new-images.sh <图床仓库路径>
#
# ========================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 配置（与 local-process.sh 保持一致）
THUMBNAIL_WIDTH=350
THUMBNAIL_QUALITY=75
PREVIEW_WIDTH=1920
PREVIEW_QUALITY=78
MOBILE_PREVIEW_WIDTH=1080
MOBILE_PREVIEW_QUALITY=75

WATERMARK_ENABLED=true
WATERMARK_TEXT="暖心"
WATERMARK_OPACITY=40

# 检测 ImageMagick 命令
detect_imagemagick_cmd() {
    if command -v magick &>/dev/null; then
        echo "magick"
    elif command -v convert &>/dev/null; then
        if convert --version 2>&1 | grep -q "ImageMagick"; then
            echo "convert"
        else
            echo ""
        fi
    else
        echo ""
    fi
}

# 检测中文字体
detect_chinese_font() {
    local cmd="$1"
    for f in "Noto-Sans-CJK-SC" "Heiti-SC-Medium" "PingFang-SC-Medium" "Microsoft-YaHei" "SimHei"; do
        $cmd -list font 2>/dev/null | grep -q "$f" && echo "$f" && return
    done
    echo ""
}

# 基于 Git 获取新增图片（包括未暂存的文件）
get_new_images_by_git() {
    local project_root="$1"
    cd "$project_root"
    
    # 获取最新 tag
    git fetch --tags --quiet 2>/dev/null || true
    local latest_tag=$(git tag -l 'v*' --sort=-version:refname | head -1)
    
    echo -e "${GREEN}  ⚡ 基于 Git 检测新增图片${NC}" >&2
    echo -e "${GREEN}     Latest tag: ${latest_tag:-无}${NC}" >&2
    
    # 方法1: 检测已 commit 但在最新 tag 之后的文件（新增的图片）
    if [ -n "$latest_tag" ]; then
        echo -e "${GREEN}     检测 $latest_tag..HEAD 之间的新增文件...${NC}" >&2
        git diff --name-only --diff-filter=A "$latest_tag"..HEAD -- 'wallpaper/' 2>/dev/null | \
            grep -iE '\.(jpg|jpeg|png)$' || true
    fi
    
    # 方法2: 检测未跟踪的新文件（工作目录中但未 commit 的）
    git ls-files --others --exclude-standard -- 'wallpaper/' 2>/dev/null | \
        grep -iE '\.(jpg|jpeg|png)$' || true
    
    # 方法3: 检测已暂存但未 commit 的新文件
    git diff --cached --name-only --diff-filter=A -- 'wallpaper/' 2>/dev/null | \
        grep -iE '\.(jpg|jpeg|png)$' || true
    
    cd - > /dev/null
}

# 回退方案：遍历检查（首次或无 tag 时使用）
get_new_images_by_scan() {
    local project_root="$1"
    
    for series in desktop mobile avatar; do
        local wallpaper_dir="$project_root/wallpaper/$series"
        local thumbnail_dir="$project_root/thumbnail/$series"
        
        [ ! -d "$wallpaper_dir" ] && continue
        
        while IFS= read -r -d '' img; do
            local rel_path="${img#$wallpaper_dir/}"
            local filename=$(basename "$img")
            local name="${filename%.*}"
            local dir_path=$(dirname "$rel_path")
            
            # 检查缩略图是否存在
            if [ "$dir_path" = "." ]; then
                local thumb_path="$thumbnail_dir/${name}.webp"
            else
                local thumb_path="$thumbnail_dir/$dir_path/${name}.webp"
            fi
            
            if [ ! -f "$thumb_path" ]; then
                echo "wallpaper/$series/$rel_path"
            fi
        done < <(find "$wallpaper_dir" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.webp" \) -print0)
    done
}

# 处理单张图片
# 返回值：0=成功，1=失败
process_image() {
    local src_file="$1"
    local project_root="$2"
    local im_cmd="$3"
    local font="$4"
    local failed_file="$5"

    # 解析路径: wallpaper/desktop/动漫/原神/xxx.jpg
    local rel_to_wallpaper="${src_file#wallpaper/}"  # desktop/动漫/原神/xxx.jpg
    local series="${rel_to_wallpaper%%/*}"            # desktop
    local rest="${rel_to_wallpaper#*/}"               # 动漫/原神/xxx.jpg

    local filename=$(basename "$src_file")
    local name="${filename%.*}"
    local dir_path=$(dirname "$rest")  # 动漫/原神

    local full_src="$project_root/$src_file"

    [ ! -f "$full_src" ] && return 1

    # 目标路径
    if [ "$dir_path" = "." ]; then
        local thumbnail_dir="$project_root/thumbnail/$series"
        local preview_dir="$project_root/preview/$series"
    else
        local thumbnail_dir="$project_root/thumbnail/$series/$dir_path"
        local preview_dir="$project_root/preview/$series/$dir_path"
    fi

    mkdir -p "$thumbnail_dir"
    [ "$series" != "avatar" ] && mkdir -p "$preview_dir"

    # 生成缩略图（带水印）
    local dest_thumbnail="$thumbnail_dir/${name}.webp"
    if [ ! -f "$dest_thumbnail" ]; then
        local thumb_font_size=$((THUMBNAIL_WIDTH * 2 / 100))
        local watermark_alpha=$(awk "BEGIN {printf \"%.2f\", $WATERMARK_OPACITY / 100}")
        local watermark_color="rgba(255,255,255,$watermark_alpha)"

        local thumb_success=false
        if [ "$WATERMARK_ENABLED" = true ] && [ -n "$font" ]; then
            if $im_cmd "$full_src" \
                -resize "${THUMBNAIL_WIDTH}x>" \
                -font "$font" \
                -pointsize "$thumb_font_size" \
                -fill "$watermark_color" \
                -gravity southeast \
                -annotate -25x-25+20+40 "$WATERMARK_TEXT" \
                -gravity southwest \
                -annotate 0x0+20+40 "$WATERMARK_TEXT" \
                -quality "$THUMBNAIL_QUALITY" \
                -strip \
                "$dest_thumbnail" 2>/dev/null; then
                thumb_success=true
            elif $im_cmd "$full_src" \
                -resize "${THUMBNAIL_WIDTH}x>" \
                -quality "$THUMBNAIL_QUALITY" \
                -strip \
                "$dest_thumbnail" 2>/dev/null; then
                thumb_success=true
            fi
        else
            if $im_cmd "$full_src" \
                -resize "${THUMBNAIL_WIDTH}x>" \
                -quality "$THUMBNAIL_QUALITY" \
                -strip \
                "$dest_thumbnail" 2>/dev/null; then
                thumb_success=true
            fi
        fi

        if [ "$thumb_success" = false ]; then
            echo -e "    ${RED}✗${NC} 缩略图生成失败"
            echo "$src_file" >> "$failed_file"
            return 1
        fi
        echo -e "    ${GREEN}✓${NC} 缩略图"
    fi

    # 生成预览图（无水印，avatar 不需要）
    if [ "$series" != "avatar" ]; then
        local preview_width=$PREVIEW_WIDTH
        local preview_quality=$PREVIEW_QUALITY
        if [ "$series" = "mobile" ]; then
            preview_width=$MOBILE_PREVIEW_WIDTH
            preview_quality=$MOBILE_PREVIEW_QUALITY
        fi

        local dest_preview="$preview_dir/${name}.webp"
        if [ ! -f "$dest_preview" ]; then
            if ! $im_cmd "$full_src" \
                -resize "${preview_width}x>" \
                -quality "$preview_quality" \
                -strip \
                "$dest_preview" 2>/dev/null; then
                echo -e "    ${RED}✗${NC} 预览图生成失败"
                # 清理已生成的缩略图
                rm -f "$dest_thumbnail"
                echo "$src_file" >> "$failed_file"
                return 1
            fi
            echo -e "    ${GREEN}✓${NC} 预览图"
        fi
    fi

    return 0
}

main() {
    local project_root="${1:-.}"

    [ ! -d "$project_root/wallpaper" ] && {
        echo -e "${RED}错误: 找不到 wallpaper 目录${NC}"
        exit 1
    }

    # 检测 ImageMagick
    local im_cmd=$(detect_imagemagick_cmd)
    [ -z "$im_cmd" ] && {
        echo -e "${RED}错误: 未找到 ImageMagick${NC}"
        exit 1
    }

    # 检测字体
    local font=""
    [ "$WATERMARK_ENABLED" = true ] && font=$(detect_chinese_font "$im_cmd")

    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}检测并处理新增图片（Git diff 优化版）${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    # P0 修复：失败图片追踪文件
    local failed_file="/tmp/failed_images.txt"
    rm -f "$failed_file"
    touch "$failed_file"

    # 获取新增图片列表（去重）
    local new_files=()
    local seen_files=()

    while IFS= read -r file; do
        # 去重：检查是否已经添加过
        if [ -n "$file" ] && [[ ! " ${seen_files[*]} " =~ " ${file} " ]]; then
            new_files+=("$file")
            seen_files+=("$file")
        fi
    done < <(get_new_images_by_git "$project_root")

    # 如果 Git 方法没有结果，回退到全量扫描
    if [ ${#new_files[@]} -eq 0 ]; then
        echo -e "${YELLOW}  Git 检测无结果，回退到全量扫描${NC}"
        while IFS= read -r file; do
            [ -n "$file" ] && new_files+=("$file")
        done < <(get_new_images_by_scan "$project_root")
    fi

    local count=${#new_files[@]}

    echo ""
    echo -e "发现 ${GREEN}${count}${NC} 张新图片"
    echo ""

    if [ "$count" -eq 0 ]; then
        echo -e "${YELLOW}没有新图片需要处理${NC}"
        echo "0" > /tmp/processed_count.txt
        exit 0
    fi

    # 处理每张图片
    local processed=0
    local success_count=0
    for file in "${new_files[@]}"; do
        processed=$((processed + 1))
        echo -e "${BLUE}[$processed/$count]${NC} $file"
        if process_image "$file" "$project_root" "$im_cmd" "$font" "$failed_file"; then
            success_count=$((success_count + 1))
        fi
        echo ""
    done

    # P0 修复：处理失败的图片
    local failed_count=0
    if [ -f "$failed_file" ] && [ -s "$failed_file" ]; then
        failed_count=$(wc -l < "$failed_file" | tr -d ' ')

        echo -e "${RED}========================================${NC}"
        echo -e "${RED}⚠️  以下 ${failed_count} 张图片处理失败：${NC}"
        echo -e "${RED}========================================${NC}"

        while IFS= read -r failed_img; do
            echo -e "  ${RED}✗${NC} $failed_img"
        done < "$failed_file"

        echo ""
        echo -e "${YELLOW}这些图片将不会被添加到 metadata${NC}"
        echo -e "${YELLOW}请检查图片格式是否正确，或手动重新处理${NC}"
        echo ""

        # 将失败列表保存供后续脚本使用
        cp "$failed_file" /tmp/failed_images_list.txt
    fi

    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}处理完成!${NC}"
    echo -e "${GREEN}  成功: ${success_count} 张${NC}"
    if [ $failed_count -gt 0 ]; then
        echo -e "${RED}  失败: ${failed_count} 张${NC}"
    fi
    echo -e "${GREEN}========================================${NC}"

    # 输出成功处理数量供工作流使用（只统计成功的）
    echo "$success_count" > /tmp/processed_count.txt
}

main "$@"
