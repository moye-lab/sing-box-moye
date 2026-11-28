#!/usr/bin/env bash
umask 077

# 尽量使用 UTF-8 locale，保证边框与中文对齐
if [[ "$(locale charmap 2>/dev/null)" != "UTF-8" ]]; then
    for _l in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
        if locale -a 2>/dev/null | grep -qix "$_l"; then export LC_ALL="$_l"; break; fi
    done
    unset _l
fi

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
APP_HOME="$SCRIPT_DIR"

source "${APP_HOME}/core/env.sh"
source "${APP_HOME}/core/pins.sh"
source "${APP_HOME}/core/ui.sh"
source "${APP_HOME}/core/state_manager.sh"
source "${APP_HOME}/core/json_builder.sh"
source "${APP_HOME}/core/engine.sh"
source "${APP_HOME}/utils/cert.sh"
source "${APP_HOME}/utils/sysctl.sh"
source "${APP_HOME}/utils/export.sh"
source "${APP_HOME}/utils/subscription.sh"
source "${APP_HOME}/protocols/reality.sh"
source "${APP_HOME}/protocols/hysteria2.sh"
source "${APP_HOME}/protocols/tuic.sh"
source "${APP_HOME}/protocols/argo.sh"
source "${APP_HOME}/protocols/socks5.sh"
source "${APP_HOME}/protocols/anytls.sh"
source "${APP_HOME}/protocols/warp.sh"
source "${APP_HOME}/protocols/cnblock/cnblock.sh"

get_telemetry() {
    local ver pid mem cc_algo
    ver=$(get_installed_sb_version)
    CORE_VER="$ver"
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        pid=$(systemctl show -p MainPID --value sing-box 2>/dev/null || echo "-")
        if [[ -n "$pid" && "$pid" != "0" && -d "/proc/$pid" ]]; then
            mem=$(awk '/VmRSS/ {printf "%.1fMB", $2/1024}' "/proc/$pid/status" 2>/dev/null || echo "-")
        else
            mem="-"
        fi
        CORE_STATE="running"
        CORE_PID="$pid"; CORE_MEM="$mem"
        CORE_TXT="${UI_ON} 运行中 v${ver}";  CORE_CLR="$GREEN"
        RES_TXT="PID ${pid} · ${mem}";        RES_CLR="$WHITE"
    elif [[ -x "$SB_BIN" ]]; then
        CORE_STATE="stopped"
        CORE_PID="-"; CORE_MEM="-"
        CORE_TXT="${UI_ON} 已停止 v${ver}";  CORE_CLR="$RED"
        RES_TXT="服务未启动";                 RES_CLR="$GRAY"
    else
        CORE_STATE="not_installed"
        CORE_PID="-"; CORE_MEM="-"
        CORE_TXT="${UI_OFF} 未安装内核";     CORE_CLR="$YELLOW"
        RES_TXT="-";                          RES_CLR="$GRAY"
    fi

    cc_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "cubic")
    BBR_ALGO="$cc_algo"
    if [[ "$cc_algo" == "bbr" ]]; then
        BBR_STATE="bbr"
        BBR_TXT="${UI_ON} BBR + FQ";  BBR_CLR="$GREEN"
    else
        BBR_STATE="other"
        BBR_TXT="${UI_OFF} ${cc_algo}"; BBR_CLR="$YELLOW"
    fi

    # WARP：只读本地检测（状态文件 + 配置端点 + 服务状态），不做网络请求。
    # 「已连接」是本地证据推断（已安装 + 服务运行 + 端点在配置中），真实连通性
    # 以 warp_check 的五层检测（含流量验证）为准；状态未知时显示未知，不伪装正常。
    if ! declare -F warp_installed >/dev/null 2>&1; then
        WARP_STATE="unknown"
        WARP_TXT="未知"; WARP_CLR="$GRAY"
    elif ! warp_installed 2>/dev/null; then
        WARP_STATE="not_installed"
        WARP_TXT="${UI_OFF} 未安装"; WARP_CLR="$GRAY"
    elif [[ "$CORE_STATE" == "running" ]] && jq -e '.endpoints[]? | select(.tag == "warp")' "$SB_CONFIG" >/dev/null 2>&1; then
        WARP_STATE="connected"
        WARP_TXT="${UI_ON} 已连接"; WARP_CLR="$GREEN"
    else
        WARP_STATE="disconnected"
        WARP_TXT="${UI_OFF} 未连接"; WARP_CLR="$YELLOW"
    fi
}

# 面板菜单按键读取：面板已展示，直接调 ui_menu_read_key 读键（字母立即、
# 数字需回车），不再区分 TTY/行模式（ui_menu_read_key 内部自行判定）。

# 快捷命令提示：按终端实际宽度自适应，避免窄屏下在单词中部换行
# （iPhone 竖屏 Termius 实测：完整行 92 列，在 <96 列终端下会把 export
# 截成两行）。≥104 列显示完整列表；60~103 列分三行；<60 列只显示短格式。
_sbx_cli_hint() {
    local cols="${UI_COLS:-80}"
    if (( cols >= 104 )); then
        ui_hint "快捷命令: sbx [reality|hy2|tuic|anytls|argo|socks5|warp|cnblock|all|subscription|export|rename|bbr]"
    elif (( cols >= 60 )); then
        ui_hint "快捷命令: sbx [reality|hy2|tuic|anytls|argo|socks5]"
        ui_hint "              [warp|all|subscription|export|rename|bbr]"
        ui_hint "              [cnblock]"
    else
        ui_hint "快捷命令: sbx <协议>|all|export"
    fi
}

# 协议状态摘要（供菜单的 desc 用）：已启用时带参数摘要，未安装时明示。
_sbx_proto_desc() {
    local p="$1"
    if state_has_proto "$p" 2>/dev/null; then
        ui_proto_detail "$p"
        if [[ -n "${UI_DETAIL:-}" ]]; then
            printf '已启用 · %s' "$UI_DETAIL"
        else
            printf '已启用'
        fi
    else
        printf '未安装'
    fi
}

# 内核版本展示文本：未安装时不加 v 前缀。
_sbx_ver_text() {
    if [[ -z "${CORE_VER:-}" || "${CORE_VER:-}" == "未安装" ]]; then
        printf '未安装'
    else
        printf 'v%s' "$CORE_VER"
    fi
}

menu_maintenance() {
    local m_opt m_ver m_rc
    local -a entries=()
    get_telemetry || true
    m_ver=$(_sbx_ver_text)
    # 面板只显示一次：面板含全部选项，打印后直接读键，不另画列表
    ui_clear
    ui_panel_begin
    ui_panel_add "$(ui_top)"
    ui_panel_add "$(ui_split "${BOLD}${CYAN}内核服务维护${PLAIN}" "${GRAY}SING-BOX MOYE › SERVICE${PLAIN}")"
    ui_panel_add "$(ui_kv "内核版本" "$m_ver" "$WHITE")"
    ui_panel_add "$(ui_kv "核心状态" "$CORE_TXT" "$CORE_CLR")"
    ui_panel_add "$(ui_mid)"
    ui_panel_add "$(ui_section "KERNEL" "内核")"
    ui_panel_add_menu 0 "$(ui_item "1/u" "升级内核" "校验现有配置，失败自动回滚")"
    ui_panel_add "$(ui_section "SERVICE" "服务")"
    ui_panel_add_menu 1 "$(ui_item "2/r" "重启服务" "systemctl restart + status")"
    ui_panel_add "$(ui_section "LOGS" "日志")"
    ui_panel_add_menu 2 "$(ui_item "3/l" "查看实时日志" "journalctl -u sing-box -n 30")"
    ui_panel_add "$(ui_mid)"
    ui_panel_add_menu 3 "$(ui_item "0/q" "返回主菜单" "")"
    ui_panel_add "$(ui_bot)"
    entries=(
        "1/u|升级内核|校验现有配置，失败自动回滚"
        "2/r|重启服务|systemctl restart + status"
        "3/l|查看实时日志|journalctl -u sing-box -n 30"
        "0/q|返回主菜单|"
    )
    ui_panel_print
    ui_menu_read_key "请选择" 0 "${entries[@]}"
    m_rc=$?
    case "$m_rc" in
        0) m_opt="${UI_SEL_KEY%%/*}" ;;
        *) return ;;   # Esc / q / EOF / 中断：返回主菜单
    esac
    case "$m_opt" in
        1|u|U) install_singbox_core "latest" ;;
        2|r|R) systemctl restart sing-box; systemctl status sing-box --no-pager || true ;;
        3|l|L) journalctl -u sing-box -n 30 --no-pager || true ;;
        *) return ;;
    esac
}


run_diagnostics() {
    local failures=0 item missing_deps=()
    echo ""
    ui_top
    ui_split "${BOLD}${CYAN}SBX 运行诊断${PLAIN}" "${GRAY}DOCTOR${PLAIN}"
    ui_mid
    ui_section "DEPENDENCIES" "依赖检查"
    for item in bash curl jq openssl tar systemctl; do
        if command -v "$item" >/dev/null 2>&1; then
            ui_kv "$item" "$(ui_status_pill ok "通过")"
        else
            ui_kv "$item" "$(ui_status_pill error "缺失")"
            missing_deps+=("$item")
            ((failures+=1))
        fi
    done
    if (( ${#missing_deps[@]} > 0 )); then
        ui_line "${GRAY}→ 建议：缺失依赖 ${missing_deps[*]}，请运行 install.sh 补齐${PLAIN}"
    fi
    ui_mid
    ui_section "CONFIG" "状态与配置"
    if [[ -x "$SB_BIN" ]]; then
        if "$SB_BIN" check -c "$SB_CONFIG" >/dev/null 2>&1; then
            ui_kv "配置校验" "$(ui_status_pill ok "校验通过")"
        else
            ui_kv "配置校验" "$(ui_status_pill error "校验失败")"
            "$SB_BIN" check -c "$SB_CONFIG" 2>&1 | head -n 12
            ui_line "${GRAY}→ 建议：检查 ${SB_CONFIG} 语法，或用备份恢复配置${PLAIN}"
            ((failures+=1))
        fi
    else
        ui_kv "内核状态" "$(ui_status_pill warn "未安装")"
        ui_line "${GRAY}→ 提示：内核未安装，可在主菜单 13/s 升级安装${PLAIN}"
    fi
    if [[ -f "$SB_STATE" ]] && jq -e 'type == "object" and (.protocols|type=="object") and (.installed_protocols|type=="array")' "$SB_STATE" >/dev/null 2>&1; then
        ui_kv "状态文件" "$(ui_status_pill ok "JSON / 基本结构正常")"
    else
        ui_kv "状态文件" "$(ui_status_pill error "缺失或损坏")"
        ui_line "${GRAY}→ 建议：备份 ${SB_STATE} 后删除，重新运行 sbx 重建${PLAIN}"
        ((failures+=1))
    fi
    ui_mid
    ui_section "CN-BLOCK" "CN 出站拦截"
    if declare -F _cnblock_probe >/dev/null 2>&1; then
        _cnblock_probe
        if (( CNBLOCK_P_RULES == 3 )) && [[ "$CNBLOCK_P_SETS" == "ok" ]] && [[ "$CNBLOCK_P_DBS" == "ok" ]] && [[ "$CNBLOCK_P_ORDER" == "ok" ]] && [[ "$CNBLOCK_P_OUTBOUND" == "ok" ]] && [[ "$CNBLOCK_P_EXCLUDE" == "ok" ]]; then
            ui_kv "拦截状态" "$(ui_status_pill ok "已开启 · 规则 3/3")"
        elif (( CNBLOCK_P_RULES == 0 )); then
            ui_kv "拦截状态" "$(ui_status_pill warn "未开启")"
            ui_line "${GRAY}→ 提示：拦截未开启，代理可访问国内网站；可在主菜单 12/c 开启${PLAIN}"
        else
            ui_kv "拦截状态" "$(ui_status_pill error "不一致 · 规则 ${CNBLOCK_P_RULES}/3")"
            if [[ "$CNBLOCK_P_OUTBOUND" != "ok" ]]; then
                ui_line "${GRAY}→ block 出站缺失：在主菜单 12/c 重新开启拦截，开启时自动补齐${PLAIN}"
            elif [[ "$CNBLOCK_P_EXCLUDE" != "ok" ]]; then
                ui_line "${GRAY}→ 放行规则缺失：在主菜单 12/c 重新开启拦截，开启时自动补齐${PLAIN}"
            else
                ui_line "${GRAY}→ 建议：在主菜单 12/c 关闭后重新开启拦截${PLAIN}"
            fi
            ((failures+=1))
        fi
        if [[ "$CNBLOCK_P_DBS" == "ok" ]]; then
            ui_kv "规则集" "$(ui_status_pill ok "geosite-cn.srs / geoip-cn.srs 齐全")"
        elif (( CNBLOCK_P_RULES > 0 )); then
            ui_kv "规则集" "$(ui_status_pill error "缺失或不完整")"
            ui_line "${GRAY}→ 建议：在主菜单 12/c 关闭后重新开启，重新下载规则集${PLAIN}"
            ((failures+=1))
        else
            ui_kv "规则集" "$(ui_status_pill warn "未下载（开启时自动下载）")"
        fi
    else
        ui_kv "拦截状态" "$(ui_status_pill warn "模块未加载")"
    fi
    ui_mid
    ui_section "SERVICE" "服务状态"
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        ui_kv "服务状态" "$(ui_status_pill running "运行中")"
    else
        ui_kv "服务状态" "$(ui_status_pill stopped "未运行")"
        ui_line "${GRAY}→ 提示：服务未运行，可在主菜单 13/s 重启服务${PLAIN}"
    fi
    ui_mid
    if (( failures == 0 )); then
        ui_line "${GREEN}基础诊断未发现阻断性问题。${PLAIN}"
    else
        ui_line "${RED}发现 ${failures} 项需要处理的问题。${PLAIN}"
    fi
    ui_bot
    return "$(( failures > 0 ))"
}

# ---------------------------------------------------------------------
# 紧凑主页（终端行数 <42 时自动启用，见 core/ui/compact.sh；SBM_LAYOUT 可强制）
# 目标：80 列下约 20 行，24 行 SSH 窗口 / 手机竖屏能完整显示；按键与完整版一致。
# ---------------------------------------------------------------------
_sbx_cnblock_pill() {
    if [[ -f "$SB_STATE" ]] && jq -e '.cnblock.enabled == true' "$SB_STATE" >/dev/null 2>&1; then
        ui_status_pill running "已开启"
    else
        ui_status_pill stopped "已关闭"
    fi
}

_sbx_sub_pill() {
    if systemctl is-active --quiet sbx-subscription.service 2>/dev/null; then
        ui_status_pill running "运行中"
    elif [[ -f "${SUB_ENV:-/nonexistent}" ]]; then
        ui_status_pill stopped "已停止"
    else
        ui_status_pill stopped "未启用"
    fi
}

_sbx_cli_hint_c() {   # 紧凑版快捷命令提示：始终一行
    if (( ${UI_COLS:-80} >= 72 )); then
        ui_hint "CLI: sbx <reality|hy2|tuic|anytls|argo|socks5|warp|all|export|doctor>"
    else
        ui_hint "CLI: sbx <协议>|all|export|doctor"
    fi
}

# 参数：prefix ip asn loc ver_txt proc_txt core_pill warp_pill net_pill
_sbx_panel_compact() {
    local prefix="$1" ip="$2" asn="$3" loc="$4" ver_txt="$5" proc_txt="$6"
    local core_pill="$7" warp_pill="$8" net_pill="$9"
    local l2 chips1 chips2 cn_pill sub_pill tip=""

    cn_pill=$(_sbx_cnblock_pill)
    sub_pill=$(_sbx_sub_pill)

    l2="${core_pill} ${WHITE}${ver_txt}${PLAIN}"
    if [[ "${CORE_STATE:-}" == "running" ]]; then
        l2+="${GRAY} · ${proc_txt} · ${CORE_MEM:--}${PLAIN}"
    fi
    chips1="${GRAY}网络${PLAIN} ${net_pill}   ${GRAY}WARP${PLAIN} ${warp_pill}"
    chips2="${GRAY}拦截${PLAIN} ${cn_pill}   ${GRAY}订阅${PLAIN} ${sub_pill}"

    ui_panel_add "$(ui_top)"
    ui_panel_add "$(ui_split "${BOLD}${CYAN}SING-BOX MOYE${PLAIN}" "${PURPLE}v${SBM_VERSION}${PLAIN}${GRAY} · ${prefix}${PLAIN}")"
    ui_panel_add "$(ui_line "$l2")"
    ui_panel_add "$(ui_line "${CYAN}${ip}${PLAIN}${GRAY} · ${asn} · ${loc}${PLAIN}")"
    if [[ "${UI_MODE:-}" != "plain" ]] && (( UI_IW - 4 >= 66 )); then
        ui_panel_add "$(ui_line "${chips1}   ${chips2}")"
    else
        ui_panel_add "$(ui_line "$chips1")"
        ui_panel_add "$(ui_line "$chips2")"
    fi
    # 状态驱动的下一步提示：只在需要用户动手时出现
    case "${CORE_STATE:-}" in
        not_installed) tip="→ 尚未安装内核：按 i 一键全装，或按 r 安装 Reality" ;;
        stopped)       tip="→ 服务未运行：按 s 进入内核服务维护，查看日志或重启" ;;
    esac
    [[ -n "$tip" ]] && ui_panel_add "$(ui_line "${YELLOW}${tip}${PLAIN}")"

    ui_panel_add "$(ui_mid)"
    ui_panel_add "$(ui_section_r "协议" "字母直达 · 数字+回车")"
    ui_panel_add_menu 0 "$(ui_proto_row_c "1/r" "VLESS-Reality"   reality)"
    ui_panel_add_menu 1 "$(ui_proto_row_c "2/h" "Hysteria 2"      hysteria2)"
    ui_panel_add_menu 2 "$(ui_proto_row_c "3/t" "TUIC v5"         tuic)"
    ui_panel_add_menu 3 "$(ui_proto_row_c "4/a" "AnyTLS"          anytls)"
    ui_panel_add_menu 4 "$(ui_proto_row_c "5/p" "Cloudflare Argo" argo)"
    ui_panel_add_menu 5 "$(ui_proto_row_c "6/y" "SOCKS5"          socks5)"
    ui_panel_add_menu 6 "$(ui_item_c "7/i" "一键全装" "Reality·Hy2·TUIC·AnyTLS")"
    ui_panel_add "$(ui_mid)"
    ui_panel_add "$(ui_section_r "管理")"
    ui_panel_add "$(ui_grid "8/e|节点订阅" "9/n|节点命名" "10/o|网络调优" \
        "11/w|WARP 分流" "12/c|CN 出站拦截" "13/s|内核维护" \
        "14/d|环境诊断" "x|彻底卸载|red" "0/q|退出")"
    ui_panel_add "$(ui_bot)"
    ui_panel_add_hint "$(_sbx_cli_hint_c)"
}

# ---------------------------------------------------------------------
# 无边框主页（clean 样式，默认）：状态优先、单字母键、80 列下约 20 行。
# 旧版数字编号 + 回车仍可用（entries 里保留 "1/r" 形式），只是不再在界面展示。
# 参数：prefix ip asn loc ver_txt proc_txt core_pill warp_pill net_pill
# ---------------------------------------------------------------------
_sbx_panel_clean() {
    local prefix="$1" ip="$2" asn="$3" loc="$4" ver_txt="$5" proc_txt="$6"
    local core_pill="$7" warp_pill="$8" net_pill="$9"
    local l2 chips cn_pill sub_pill tip=""

    cn_pill=$(_sbx_cnblock_pill)
    sub_pill=$(_sbx_sub_pill)

    l2="${core_pill} ${WHITE}${ver_txt}${PLAIN}"
    if [[ "${CORE_STATE:-}" == "running" ]]; then
        l2+="${GRAY} · ${proc_txt} · ${CORE_MEM:--}${PLAIN}"
    fi
    chips="${GRAY}网络${PLAIN} ${net_pill}   ${GRAY}WARP${PLAIN} ${warp_pill}   ${GRAY}拦截${PLAIN} ${cn_pill}   ${GRAY}订阅${PLAIN} ${sub_pill}"

    ui_panel_add_blank
    ui_panel_add "$(ui_split "${BOLD}${CYAN}SING-BOX MOYE${PLAIN} ${PURPLE}v${SBM_VERSION}${PLAIN}" "${GRAY}${prefix}${PLAIN}")"
    if [[ -e "$(state_err_mark)" ]]; then
        ui_panel_add "$(ui_line "${RED}✖ 状态文件异常（损坏或缺少 jq），下方状态不可信；请运行 sbx doctor${PLAIN}")"
    fi
    ui_panel_add "$(ui_line "$l2")"
    ui_panel_add "$(ui_line "${CYAN}${ip}${PLAIN}${GRAY} · ${asn} · ${loc}${PLAIN}")"
    if (( UI_IW - 4 >= 66 )) && [[ "${UI_MODE:-}" != "plain" ]]; then
        ui_panel_add "$(ui_line "$chips")"
    else
        ui_panel_add "$(ui_line "${GRAY}网络${PLAIN} ${net_pill}   ${GRAY}WARP${PLAIN} ${warp_pill}")"
        ui_panel_add "$(ui_line "${GRAY}拦截${PLAIN} ${cn_pill}   ${GRAY}订阅${PLAIN} ${sub_pill}")"
    fi
    # 状态驱动的下一步提示：只在需要用户动手时出现
    case "${CORE_STATE:-}" in
        not_installed) tip="→ 尚未安装内核：按 i 一键全装，或按 r 安装 Reality" ;;
        stopped)       tip="→ 服务未运行：按 s 进入内核服务维护，查看日志或重启" ;;
    esac
    [[ -n "$tip" ]] && ui_panel_add "$(ui_line "${YELLOW}${tip}${PLAIN}")"

    ui_panel_add_blank
    ui_panel_add "$(ui_heading "协议" "按字母键直达")"
    ui_panel_add_menu 0 "$(ui_row_clean r "VLESS-Reality"   reality)"
    ui_panel_add_menu 1 "$(ui_row_clean h "Hysteria 2"      hysteria2)"
    ui_panel_add_menu 2 "$(ui_row_clean t "TUIC v5"         tuic)"
    ui_panel_add_menu 3 "$(ui_row_clean a "AnyTLS"          anytls)"
    ui_panel_add_menu 4 "$(ui_row_clean p "Cloudflare Argo" argo)"
    ui_panel_add_menu 5 "$(ui_row_clean y "SOCKS5"          socks5)"
    ui_panel_add_menu 6 "$(ui_item_clean i "一键全装" "Reality·Hy2·TUIC·AnyTLS")"
    ui_panel_add_blank
    ui_panel_add "$(ui_heading "管理")"
    ui_panel_add "$(ui_grid_clean "e|节点订阅" "n|节点命名" "o|网络调优" \
        "w|WARP 分流" "c|CN 出站拦截" "s|内核维护" \
        "d|环境诊断" "x|彻底卸载|red" "q|退出")"
    ui_panel_add_blank
    ui_panel_add_hint "$(_sbx_cli_hint_c)"
}

main_menu() {
    local opt prefix ip asn cc city city_code host_name loc ver_txt proc_txt
    local core_pill warp_pill net_pill m_rc
    local -a entries=()
    while true; do
        # 状态异常只提示一次：每轮渲染前清标记，渲染期间子 shell 首次报错
        # 建标记、后续不再重复；下一轮渲染如状态仍异常可再次提示。
        # 注：不在循环内调用 init_state_file——它做文件 I/O 与 JSON 校验，
        # 每轮调用拖慢菜单渲染，破坏 PTY 输入时序（ui_twokey 测试回归）。
        # 状态初始化只在启动时做一次（见 main 末尾 init_state_file）。
        rm -f "$(state_err_mark)" 2>/dev/null || true
        # v1.8.2 升级重断言：旧版 2 条规则补齐为 3 条并提到 WARP 之前。
        cnblock_maybe_reassert || true
        get_telemetry || true
        prefix=$(get_node_prefix 2>/dev/null || echo "sbx-node")
        ip=$(get_public_ip 2>/dev/null || echo "-")
        asn=$(state_get_meta asn 2>/dev/null); asn=$(format_asn "${asn:-Direct}")
        cc=$(state_get_meta country 2>/dev/null); cc="${cc:-US}"
        city=$(state_get_meta city 2>/dev/null || true)
        city_code=$(map_city_code "${city:-}" 2>/dev/null || true)
        if [[ -n "${city_code:-}" ]]; then loc="${cc}·${city_code}"; else loc="$cc"; fi
        host_name=$(hostname 2>/dev/null || echo "-")
        ver_txt=$(_sbx_ver_text)
        if [[ "${CORE_PID:-}" == "-" || -z "${CORE_PID:-}" ]]; then proc_txt="-"; else proc_txt="PID ${CORE_PID}"; fi

        case "${CORE_STATE:-unknown}" in
            running)       core_pill=$(ui_status_pill running "运行中") ;;
            stopped)       core_pill=$(ui_status_pill error "已停止") ;;
            not_installed) core_pill=$(ui_status_pill warn "未安装") ;;
            *)             core_pill=$(ui_status_pill warn "未知") ;;
        esac
        case "${WARP_STATE:-unknown}" in
            connected)     warp_pill=$(ui_status_pill running "已连接") ;;
            disconnected)  warp_pill=$(ui_status_pill warn "未连接") ;;
            not_installed) warp_pill=$(ui_status_pill stopped "未安装") ;;
            *)             warp_pill=$(ui_status_pill warn "未知") ;;
        esac
        if [[ "${BBR_STATE:-}" == "bbr" ]]; then
            net_pill=$(ui_status_pill ok "BBR + FQ")
        else
            net_pill=$(ui_status_pill warn "${BBR_ALGO:-未知}")
        fi

        # 面板只显示一次：仪表盘含全部选项，打印后直接读键，不另画列表。
        # 渲染时逐行捕获进面板数组（窄屏下 ui_dash_row 会退化为两行，固定行号
        # 不可靠，必须按调用逐行记录）。
        ui_clear
        ui_panel_begin
        if [[ "${UI_STYLE:-clean}" == "clean" ]]; then
            _sbx_panel_clean "$prefix" "$ip" "$asn" "$loc" "$ver_txt" "$proc_txt" \
                "$core_pill" "$warp_pill" "$net_pill"
        elif [[ "$(ui_layout)" == "compact" ]]; then
            _sbx_panel_compact "$prefix" "$ip" "$asn" "$loc" "$ver_txt" "$proc_txt" \
                "$core_pill" "$warp_pill" "$net_pill"
        else
            ui_panel_add "$(ui_top)"
            ui_panel_add "$(ui_split "${BOLD}${CYAN}SING-BOX MOYE${PLAIN}" "${PURPLE}v${SBM_VERSION}${PLAIN}")"
            ui_panel_add "$(ui_line "${CYAN}NETWORK MANAGEMENT CONSOLE${PLAIN}")"
            ui_panel_add "$(ui_line "${GRAY}Lightweight · State-Driven · Multi-Protocol Manager${PLAIN}")"
            ui_panel_add "$(ui_line "${GRAY}HOST ${PLAIN}${WHITE}${host_name}${PLAIN}  ${GRAY}NODE ${PLAIN}${WHITE}${prefix}${PLAIN}")"
            ui_panel_add "$(ui_mid)"
            ui_panel_add "$(ui_dash_title "SYSTEM OVERVIEW" "系统状态仪表盘")"
            ui_panel_add "$(ui_dash_row "CORE STATE" "$core_pill" "$WHITE" "VERSION"  "$ver_txt"        "$WHITE")"
            ui_panel_add "$(ui_dash_row "PROCESS"    "$proc_txt"  "$WHITE" "MEMORY"   "${CORE_MEM:--}"  "$WHITE")"
            ui_panel_add "$(ui_dash_row "PUBLIC IP"  "$ip"        "$CYAN"  "LOCATION" "$loc"            "$WHITE")"
            ui_panel_add "$(ui_dash_row "ASN"        "$asn"       "$WHITE" "PREFIX"   "$prefix"         "$WHITE")"
            ui_panel_add "$(ui_dash_row "NETWORK"    "$net_pill"  "$WHITE" "WARP"     "$warp_pill"      "$WHITE")"
            ui_panel_add "$(ui_mid)"
            ui_panel_add "$(ui_section "01 PROTOCOL MANAGEMENT" "协议矩阵")"
            ui_panel_add_menu 0 "$(ui_proto_row "1/r" "VLESS-Reality"   reality)"
            ui_panel_add_menu 1 "$(ui_proto_row "2/h" "Hysteria 2"      hysteria2)"
            ui_panel_add_menu 2 "$(ui_proto_row "3/t" "TUIC v5"         tuic)"
            ui_panel_add_menu 3 "$(ui_proto_row "4/a" "AnyTLS"          anytls)"
            ui_panel_add_menu 4 "$(ui_proto_row "5/p" "Cloudflare Argo" argo)"
            ui_panel_add_menu 5 "$(ui_proto_row "6/y" "SOCKS5"          socks5)"
            ui_panel_add_menu 6 "$(ui_item "7/i" "一键全装" "Reality·Hy2·TUIC·AnyTLS（不含 SOCKS5·Argo）")"
            ui_panel_add "$(ui_mid)"
            ui_panel_add "$(ui_section "02 NODE & SUBSCRIPTION" "节点与订阅")"
            ui_panel_add_menu 7 "$(ui_item "8/e" "节点订阅中心" "分享链接 · 二维码 · Mihomo · Sing-box")"
            ui_panel_add_menu 8 "$(ui_item "9/n" "节点命名规则" "当前前缀: ${prefix}")"
            ui_panel_add "$(ui_mid)"
            ui_panel_add "$(ui_section "03 NETWORK & ROUTING" "网络与路由")"
            ui_panel_add_menu 9 "$(ui_item "10/o" "系统网络调优" "BBR · UDP 缓冲区 · 端口跳跃")"
            ui_panel_add_menu 10 "$(ui_item "11/w" "WARP 与域名分流" "解锁 AI 服务 · 域名走 WARP 出口")"
            ui_panel_add_menu 11 "$(ui_item "12/c" "CN 出站拦截" "国内域名/IP 走代理时直接拒绝")"
            ui_panel_add "$(ui_mid)"
            ui_panel_add "$(ui_section "04 SYSTEM MANAGEMENT" "系统管理")"
            ui_panel_add_menu 12 "$(ui_item "13/s" "内核服务维护" "升级内核 · 重启服务 · 实时日志")"
            ui_panel_add_menu 13 "$(ui_item "14/d" "运行环境诊断" "检查依赖、状态文件与 sing-box 配置")"
            ui_panel_add_menu 14 "$(ui_item "x" "彻底卸载清理" "销毁所有配置与系统服务" "$RED")"
            ui_panel_add_menu 15 "$(ui_item "0/q" "退出管理面板" "")"
            ui_panel_add "$(ui_mid)"
            ui_panel_add "$(ui_line "${GRAY}字母直接进入 · 数字+回车确认 · Esc 返回 · Q 退出${PLAIN}")"
            ui_panel_add "$(ui_line "${GRAY}快捷键 1-14 · r h t a p y i e n o w c s d${PLAIN}")"
            ui_panel_add "$(ui_bot)"
            ui_panel_add_hint "$(_sbx_cli_hint)"
        fi

        # entries 按面板视觉顺序排列，与数字序号一致；快捷键按 key
        # 匹配，与顺序无关（方向键已移除，顺序不再影响导航）。
        entries=(
            "1/r|VLESS-Reality|$(_sbx_proto_desc reality)"
            "2/h|Hysteria 2|$(_sbx_proto_desc hysteria2)"
            "3/t|TUIC v5|$(_sbx_proto_desc tuic)"
            "4/a|AnyTLS|$(_sbx_proto_desc anytls)"
            "5/p|Cloudflare Argo|$(_sbx_proto_desc argo)"
            "6/y|SOCKS5|$(_sbx_proto_desc socks5)"
            "7/i|一键全装|Reality·Hy2·TUIC·AnyTLS（不含 SOCKS5·Argo）"
            "8/e|节点订阅中心|分享链接 · 二维码 · Mihomo · Sing-box"
            "9/n|节点命名规则|当前前缀: ${prefix}"
            "10/o|系统网络调优|BBR · UDP 缓冲区 · 端口跳跃"
            "11/w|WARP 与域名分流|解锁 AI 服务 · 域名走 WARP 出口"
            "12/c|CN 出站拦截|国内域名/IP 走代理时直接拒绝"
            "13/s|内核服务维护|升级内核 · 重启服务 · 实时日志"
            "14/d|运行环境诊断|检查依赖、状态文件与 sing-box 配置"
            "x|彻底卸载清理|销毁所有配置与系统服务"
            "0/q|退出管理面板|"
        )
        ui_panel_print
        ui_menu_read_key "请输入选项" 0 "${entries[@]}"
        m_rc=$?
        case "$m_rc" in
            0) opt="${UI_SEL_KEY%%/*}" ;;
            *) echo ""; exit 0 ;;   # Esc / q / EOF / 中断：主菜单直接退出
        esac
        case "$opt" in
            1|r|R) menu_reality ;;
            2|h|H) menu_hysteria2 ;;
            3|t|T) menu_tuic ;;
            4|a|A) menu_anytls ;;
            5|p|P) menu_argo ;;
            6|y|Y) menu_socks5 ;;
            7|i|I) install_all_protocols ;;
            8|e|E) show_export_menu ;;
            9|n|N) menu_node_naming ;;
            10|o|O) sysctl_menu ;;
            11|w|W) menu_warp ;;
            12|c|C) menu_cnblock ;;
            13|s|S) menu_maintenance ;;
            14|d|D) run_diagnostics ;;
            x|X) uninstall_all ;;
            0|q|Q) echo ""; exit 0 ;;
            *) log_warn "无效选项，请输入对应数字或快捷字母"; sleep 1; continue ;;
        esac
        pause
    done
}

install_all_protocols() {
    ui_banner "一键安装常用节点协议（不含 SOCKS5·Argo）"
    echo " 将按默认配置依次安装：VLESS-Reality → Hysteria 2 → TUIC v5 → AnyTLS"
    echo " 已安装的协议自动跳过；SOCKS5（菜单 6/y）与 Argo（菜单 5/p，优选 IP 需手动选择）请单独安装。"
    echo ""
    local p failed=0 installed=0 skipped=0
    for p in reality hysteria2 tuic anytls; do
        if state_has_proto "$p"; then
            log_info "[$p] 已安装，跳过"
            ((skipped+=1))
            continue
        fi
        log_info "[$p] 正在安装（默认配置）..."
        if SBX_AUTO=1 "install_$p"; then
            log_ok "[$p] 安装成功"
            ((installed+=1))
        else
            log_warn "[$p] 安装失败，已跳过（可单独进入对应菜单重试）"
            ((failed+=1))
        fi
        echo ""
    done
    if (( installed > 0 )); then
        export_all_nodes >/dev/null 2>&1 || true
    fi
    log_ok "一键全装完成：新增 ${installed} 个，跳过 ${skipped} 个，失败 ${failed} 个"
    (( failed == 0 )) || return 1
}

sbx_main() {
    check_root
    init_state_file
    ensure_node_meta
    refresh_legacy_exports

    if [[ $# -gt 0 ]]; then
        case "$1" in
            reality|r)
                if [[ "${2:-}" == "del" ]]; then uninstall_reality; else install_reality; fi
                ;;
            hy2|hysteria2|h)
                if [[ "${2:-}" == "del" ]]; then uninstall_hysteria2; else install_hysteria2; fi
                ;;
            tuic|t)
                if [[ "${2:-}" == "del" ]]; then uninstall_tuic; else install_tuic; fi
                ;;
            anytls|a)
                if [[ "${2:-}" == "del" ]]; then uninstall_anytls; else install_anytls; fi
                ;;
            argo|p)
                if [[ "${2:-}" == "del" ]]; then uninstall_argo; else install_argo; fi
                ;;
            socks5|socks|y)
                if [[ "${2:-}" == "del" ]]; then uninstall_socks5; else install_socks5; fi
                ;;
            warp|w)
                if [[ "${2:-}" == "del" ]]; then uninstall_warp; else menu_warp; fi
                ;;
            cnblock|c)
                case "${2:-}" in
                    on|enable) cnblock_enable ;;
                    off|disable) cnblock_disable ;;
                    status) cnblock_status ;;
                    verify) cnblock_verify ;;
                    update) cnblock_update ;;
                    test) cnblock_test "${3:-}" ;;
                    doctor) cnblock_doctor ;;
                    *) menu_cnblock ;;
                esac
                ;;
            all)
                install_all_protocols
                ;;
            subscription|sub)
                case "${2:-}" in enable|start) subscription_enable ;; disable|stop) subscription_disable ;; rotate|reset) subscription_rotate ;; *) subscription_status ;; esac
                ;;
            rename|n)
                if [[ -n "${2:-}" ]]; then
                    set_custom_node_prefix "$2"
                    export_all_nodes
                else
                    menu_node_naming
                fi
                ;;
            export|info|e)
                export_all_nodes
                ;;
            bbr|o)
                enable_bbr_and_udp_tuning
                ;;
            doctor|check)
                run_diagnostics
                ;;
            version|-v|--version)
                echo "sing-box-moye v${SBM_VERSION}"
                ;;
            *)
                echo "用法: sbx [reality|hy2|tuic|anytls|argo|socks5|warp|cnblock|all|subscription|rename|export|bbr|doctor|version] [del|on|off|status|verify|update|test|doctor|新前缀]"
                ;;
        esac
    else
        main_menu
    fi
}

# 仅在被直接执行时运行（被 source 时不启动，便于测试）
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    sbx_main "$@"
fi
