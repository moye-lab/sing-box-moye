#!/usr/bin/env bash
# =====================================================================
#  core/ui/clean.sh — 无边框（clean）样式的主页组件
#  职责：状态优先的主页行组件。不画边框、不依赖右边框对齐，所以：
#        · CJK / 宽度不明字符在 Xshell、PuTTY、Termius 里不会再"右边框错位"；
#        · 复制 IP、链接时不会带上 │；
#        · 80 列下主页约 20 行，24 行 SSH 窗口 / 手机竖屏一屏看完。
#  只显示字母键；旧版数字编号（数字 + 回车）仍然可用，不在界面上展示。
#  依赖：terminal.sh（ui_fit）、layout.sh（ui_line / ui_split）、
#        components.sh（ui_proto_detail）、业务层 state_has_proto。
# =====================================================================

ui_panel_add_blank() {   # 面板里加一个空行（$(...) 会吞掉空输出，必须直接写数组）
    _UI_PANEL_LINES+=("")
    _UI_PANEL_MENU+=(-1)
}

ui_heading() {          # 分区标题  [右侧灰色提示]
    local r="${2:-}"
    if [[ -n "$r" && "${UI_MODE:-}" != "plain" ]] && (( UI_IW - 4 >= 44 )); then
        ui_split "${PURPLE}${BOLD}${1}${PLAIN}" "${GRAY}${r}${PLAIN}"
    else
        ui_line "${PURPLE}${BOLD}${1}${PLAIN}"
    fi
}

# 协议行：键 名称 [● 参数摘要 | ○ 未安装]
ui_row_clean() {         # 键  名称  协议标识
    local key="$1" title="$2" p="$3" T D dw tw=15
    if [[ "${UI_MODE:-}" == "plain" ]]; then ui_proto_row "$key" "$title" "$p"; return; fi
    (( UI_IW >= 56 )) && tw=16
    ui_fit "$title" "$tw"; T="$UI_FIT"
    dw=$(( UI_IW - 4 - 2 - tw - 2 ))
    if state_has_proto "$p"; then
        ui_proto_detail "$p"
        D="$UI_DETAIL"
        # 放不下时丢掉第一段（TCP/UDP），保住端口与 SNI
        if (( dw < ${#D} )); then D="${D#*· }"; fi
        ui_fit "$D" "$dw"; D="$UI_FIT"
        ui_line "${CYAN}${BOLD}${key}${PLAIN}  ${WHITE}${BOLD}${T}${PLAIN} ${GREEN}${UI_ON}${PLAIN} ${WHITE}${D}${PLAIN}"
    else
        ui_fit "未安装" "$dw"; D="$UI_FIT"
        ui_line "${CYAN}${BOLD}${key}${PLAIN}  ${GRAY}${T} ${UI_OFF} ${D}${PLAIN}"
    fi
}

ui_item_clean() {        # 键  名称  说明
    local key="$1" label="$2" desc="${3:-}" T D dw tw=15
    if [[ "${UI_MODE:-}" == "plain" ]]; then ui_item "$key" "$label" "$desc"; return; fi
    (( UI_IW >= 56 )) && tw=16
    ui_fit "$label" "$tw"; T="$UI_FIT"
    dw=$(( UI_IW - 4 - 2 - tw - 1 ))
    (( dw < 6 )) && desc=""
    ui_fit "$desc" "$dw"; D="$UI_FIT"
    ui_line "${CYAN}${BOLD}${key}${PLAIN}  ${WHITE}${BOLD}${T}${PLAIN} ${GRAY}${D}${PLAIN}"
}

# 网格：单元 "键|名称[|red]"，按宽度自动分 1~3 列，行优先
ui_grid_clean() {
    local avail=$(( UI_IW - 4 )) lw=12 gap=3 ncols cw cell rest key label flag L clr line="" n=0
    cw=$(( 2 + lw ))
    ncols=$(( (avail + gap) / (cw + gap) ))
    (( ncols > 3 )) && ncols=3
    (( ncols < 1 )) && ncols=1
    [[ "${UI_MODE:-}" == "plain" ]] && ncols=1
    for cell in "$@"; do
        key="${cell%%|*}"; rest="${cell#*|}"; label="${rest%%|*}"; flag=""
        [[ "$rest" == *"|"* ]] && flag="${rest#*|}"
        clr="$WHITE"; [[ "$flag" == "red" ]] && clr="$RED"
        if (( ncols == 1 )); then L="$label"; else ui_fit "$label" "$lw"; L="$UI_FIT"; fi
        line+="${line:+   }${CYAN}${BOLD}${key}${PLAIN} ${clr}${L}${PLAIN}"
        n=$(( n + 1 ))
        if (( n == ncols )); then ui_line "$line"; line=""; n=0; fi
    done
    [[ -n "$line" ]] && ui_line "$line"
    return 0
}
