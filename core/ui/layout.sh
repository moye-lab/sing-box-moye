#!/usr/bin/env bash
# =====================================================================
#  core/ui/layout.sh — 面板 / 分区 / 排版
#  职责：边框线、内容行、左右对齐行、分区标题。plain 模式（<40 列）下
#  边框函数退化为空操作，行函数输出去色截断的纯文本。
#  所有行输出都经 ui_line 的 _ui_truncate_ansi 兜底，永不越界。
# =====================================================================

_ui_plain_line() {   # 纯文本行：去色、截断到 UI_W（plain 模式专用）
    ui_strip "$1"
    _ui_truncate_ansi "$UI_STRIPPED" "$UI_W"
    printf '%s\n' "$UI_TRUNC"
}

# ---------- 边框与行 ----------
ui_rule() {
    [[ "${UI_MODE:-}" == "plain" ]] && return 0
    if [[ "${UI_STYLE:-clean}" == "clean" ]]; then
        # 无边框样式：仅 ui_mid 走到这里，画一条淡色细线（top/bot 已在调用处空操作）
        local _w=$(( UI_W - 2 )) _bar
        (( _w < 1 )) && return 0
        printf -v _bar '%*s' "$_w" ''
        printf '  %s%s%s\n' "${GRAY:-}" "${_bar// /$UI_H}" "$PLAIN"
        return 0
    fi
    local l="$1" r="$2" bar
    printf -v bar '%*s' "$UI_IW" ''
    printf '%s%s%s%s%s\n' "$UI_BC" "$l" "${bar// /$UI_H}" "$r" "$PLAIN"
}
ui_top() { [[ "${UI_STYLE:-clean}" == "clean" ]] && return 0; ui_rule "$UI_TL" "$UI_TR"; }
ui_mid() { ui_rule "$UI_ML" "$UI_MR"; }
ui_bot() { [[ "${UI_STYLE:-clean}" == "clean" ]] && return 0; ui_rule "$UI_BL" "$UI_BR"; }

ui_line() {    # 一行内容（两侧各留 2 格边距），自动补齐并闭合右边框
    local content="  ${1:-}" pad
    if [[ "${UI_MODE:-}" == "plain" ]]; then
        _ui_plain_line "$content"
        return
    fi
    if [[ "${UI_STYLE:-clean}" == "clean" ]]; then
        # 无边框：只截断防止折行，不补齐、不画右边框（复制 IP / 链接时不再带 │）
        _ui_truncate_ansi "$content" "$(( UI_W - 1 ))"
        local _t="$UI_TRUNC"
        while :; do          # 去掉行尾的补齐空格与颜色复位，复制整行时不带尾随空白
            case "$_t" in
                *' ')          _t="${_t% }" ;;
                *$'\033[0m')   _t="${_t%$'\033[0m'}" ;;
                *) break ;;
            esac
        done
        printf '%s%s\n' "$_t" "$PLAIN"
        return
    fi
    _ui_truncate_ansi "$content" "$UI_IW"
    content="$UI_TRUNC"
    ui_vwidth "$content"
    pad=$(( UI_IW - UI_VW )); (( pad < 0 )) && pad=0
    printf '%s%s%s%s%s%*s%s%s%s\n' "$UI_BC" "$UI_V" "$PLAIN" "$content" "$PLAIN" "$pad" "" "$UI_BC" "$UI_V" "$PLAIN"
}

ui_split() {   # 左右两端对齐的一行
    local l="$1" r="${2:-}" lw rw gap sp
    if [[ "${UI_MODE:-}" == "plain" ]]; then
        if [[ -n "$r" ]]; then _ui_plain_line "${l}  ${r}"; else _ui_plain_line "$l"; fi
        return
    fi
    ui_vwidth "$l"; lw=$UI_VW
    ui_vwidth "$r"; rw=$UI_VW
    gap=$(( UI_IW - 4 - lw - rw )); (( gap < 1 )) && gap=1
    printf -v sp '%*s' "$gap" ''
    ui_line "${l}${sp}${r}"
}

ui_section() { ui_line "${PURPLE}${BOLD}${UI_DIA} ${1}${PLAIN}  ${GRAY}${2:-}${PLAIN}"; }
