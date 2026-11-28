#!/usr/bin/env bash
# =====================================================================
#  core/ui/compact.sh — 紧凑布局（按终端高度自适应）
#  职责：检测终端行数、决定主页用 full 还是 compact 布局，并提供紧凑
#        布局专用的行组件（单行协议状态、分栏菜单网格、带右侧提示的分区标题）。
#  背景：完整主页约 38 行（窄屏 46 行），手机竖屏 / 24 行 SSH 窗口放不下，
#        顶部状态会滚出屏幕。紧凑主页在 80 列下约 20 行，24 行终端可完整显示。
#  行数来源：只读 bash 自带的 LINES 变量（无需 stty/tput，不碰终端状态；
#        尺寸未知的伪终端 / 管道里 LINES 为空 → 视为未知 → 用 full，行为不变）。
#  环境变量：SBM_LAYOUT=full|compact|auto（默认 auto）
#            SBM_ROWS=N 覆盖检测到的终端行数
#  依赖：terminal.sh（ui_fit）、layout.sh（ui_line/ui_split）、
#        components.sh（ui_item/ui_proto_row/ui_proto_detail）、业务层 state_has_proto。
# =====================================================================

shopt -s checkwinsize 2>/dev/null || true   # 窗口缩放后下次重绘能拿到新行数

UI_ROWS=0       # 检测到的终端行数（0 = 未知）

ui_detect_rows() {   # → UI_ROWS
    local r="${SBM_ROWS:-}"
    [[ -n "$r" ]] || r="${LINES:-}"
    [[ "$r" =~ ^[0-9]+$ ]] || r=0
    UI_ROWS=$r
}

ui_layout() {        # 输出 full 或 compact
    case "${SBM_LAYOUT:-auto}" in
        full)    printf 'full\n';    return 0 ;;
        compact) printf 'compact\n'; return 0 ;;
    esac
    ui_detect_rows
    # full 主页高度：80 列以上约 38 行 + 提示/输入行；窄屏仪表盘退化单列约 46 行。
    local need=42
    case "${UI_MODE:-normal}" in narrow|plain) need=52 ;; esac
    if (( UI_ROWS > 0 && UI_ROWS < need )); then
        printf 'compact\n'
    else
        printf 'full\n'
    fi
}

ui_section_r() {     # 分区标题  [右侧灰色提示]（宽度不够时省略提示）
    local l="${PURPLE}${BOLD}${UI_DIA} ${1}${PLAIN}" r="${2:-}"
    if [[ -n "$r" && "${UI_MODE:-}" != "plain" ]] && (( UI_IW - 4 >= 44 )); then
        ui_split "$l" "${GRAY}${r}${PLAIN}"
    else
        ui_line "$l"
    fi
}

ui_item_c() {        # 键位  名称  说明  [名称颜色]
    local key="$1" label="$2" desc="${3:-}" lclr="${4:-$WHITE}" K L D dw tw=15
    if [[ "${UI_MODE:-}" == "plain" ]]; then ui_item "$key" "$label" "$desc"; return; fi
    (( UI_IW >= 56 )) && tw=16
    ui_fit "[${key}]" 6;    K="$UI_FIT"
    ui_fit "$label" "$tw";  L="$UI_FIT"
    dw=$(( UI_IW - 4 - 6 - 1 - tw - 1 ))
    (( dw < 6 )) && desc=""
    ui_fit "$desc" "$dw";   D="$UI_FIT"
    ui_line "${CYAN}${BOLD}${K}${PLAIN} ${lclr}${BOLD}${L}${PLAIN} ${GRAY}${D}${PLAIN}"
}

# 协议一行状态：已启用 → 亮色 ● + 参数摘要；未安装 → 灰色 ○ + 文字（形状+文字双通道）
ui_proto_row_c() {   # 键位  名称  协议标识
    local key="$1" title="$2" p="$3" K T D dw tw=15
    if [[ "${UI_MODE:-}" == "plain" ]]; then ui_proto_row "$key" "$title" "$p"; return; fi
    (( UI_IW >= 56 )) && tw=16
    ui_fit "[${key}]" 6;    K="$UI_FIT"
    ui_fit "$title" "$tw";  T="$UI_FIT"
    dw=$(( UI_IW - 4 - 6 - 1 - tw - 1 - 2 ))
    if state_has_proto "$p"; then
        ui_proto_detail "$p"
        D="$UI_DETAIL"
        # 窄屏放不下时丢掉第一段（传输层 TCP/UDP），保住端口与 SNI
        if (( dw < ${#D} )); then D="${D#*· }"; fi
        ui_fit "$D" "$dw"; D="$UI_FIT"
        ui_line "${CYAN}${BOLD}${K}${PLAIN} ${WHITE}${BOLD}${T}${PLAIN} ${GREEN}${UI_ON}${PLAIN} ${WHITE}${D}${PLAIN}"
    else
        ui_fit "未安装" "$dw"; D="$UI_FIT"
        ui_line "${CYAN}${BOLD}${K}${PLAIN} ${GRAY}${T} ${UI_OFF} ${D}${PLAIN}"
    fi
}

# 菜单网格：每个单元 "键|名称[|red]"，按宽度自动分 1~3 列，行优先排列。
ui_grid() {
    local avail=$(( UI_IW - 4 )) lw=10 gap=2 ncols cw cell rest key label flag K L clr line="" n=0
    (( avail >= 80 )) && lw=16
    cw=$(( 6 + 1 + lw ))
    ncols=$(( (avail + gap) / (cw + gap) ))
    (( ncols > 3 )) && ncols=3
    (( ncols < 1 )) && ncols=1
    [[ "${UI_MODE:-}" == "plain" ]] && ncols=1
    for cell in "$@"; do
        key="${cell%%|*}"; rest="${cell#*|}"; label="${rest%%|*}"; flag=""
        [[ "$rest" == *"|"* ]] && flag="${rest#*|}"
        clr="$WHITE"; [[ "$flag" == "red" ]] && clr="$RED"
        ui_fit "[${key}]" 6; K="$UI_FIT"
        if (( ncols == 1 )); then L="$label"; else ui_fit "$label" "$lw"; L="$UI_FIT"; fi
        line+="${line:+  }${CYAN}${BOLD}${K}${PLAIN} ${clr}${L}${PLAIN}"
        n=$(( n + 1 ))
        if (( n == ncols )); then ui_line "$line"; line=""; n=0; fi
    done
    [[ -n "$line" ]] && ui_line "$line"
    return 0
}
