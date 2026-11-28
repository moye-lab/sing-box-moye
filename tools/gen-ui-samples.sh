#!/usr/bin/env bash
# =====================================================================
#  tools/gen-ui-samples.sh — 渲染主页（fixture 状态，不依赖 jq / systemd / 网络）
#
#  用法：
#    tools/gen-ui-samples.sh --render COLS ROWS LAYOUT [CORE_STATE]
#        打印一次主页到 stdout。LAYOUT = full | compact | auto；
#        CORE_STATE = running（默认）| stopped | not_installed。
#        颜色/字符集沿用环境变量：SBM_FORCE_COLOR=1 / NO_COLOR=1 / SBM_ASCII=1。
#    tools/gen-ui-samples.sh
#        重新生成 docs/ui-samples/main-*.txt（改动 UI 后运行并提交结果）。
#
#  fixture：Reality / Hysteria 2 已启用，WARP 已连接，公网 IP 为 TEST-NET-3
#  的 203.0.113.9。仅用于渲染，不会读写真实的 /etc/sing-box。
# =====================================================================
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

render_once() {   # cols rows layout [core_state]
    local cols="$1" rows="$2" layout="$3" core="${4:-running}"
    (
        export LC_ALL=C.UTF-8 SBM_COLS="$cols" SBM_ROWS="$rows" SBM_LAYOUT="$layout" SBM_MENU_LINE=1
        export FX_CORE="$core"
        # shellcheck source=/dev/null
        source "$ROOT/sbx.sh"
        SB_STATE="/nonexistent/state.json"
        systemctl() { return 1; }
        hostname() { echo "demo-host"; }
        cnblock_maybe_reassert() { :; }
        get_node_prefix() { echo "US-vps01"; }
        get_public_ip() { echo "203.0.113.9"; }
        state_get_meta() { case "$1" in asn) echo "AS64500" ;; country) echo "US" ;; city) echo "Los Angeles" ;; esac; }
        state_has_proto() { [[ "$FX_CORE" != "not_installed" ]] && case "$1" in reality|hysteria2) return 0 ;; esac; return 1; }
        state_get_field() {
            case "$1.$2" in
                reality.port) echo 443 ;; reality.sni) echo "www.microsoft.com" ;;
                hysteria2.port) echo 8443 ;; hysteria2.hop_range) echo "10000-20000" ;;
            esac
        }
        get_telemetry() {
            case "$FX_CORE" in
                running)       CORE_STATE=running; CORE_VER="1.12.0"; CORE_PID=100606; CORE_MEM="6.6MB"
                               WARP_STATE=connected; BBR_STATE=bbr; BBR_ALGO=bbr ;;
                stopped)       CORE_STATE=stopped; CORE_VER="1.12.0"; CORE_PID="-"; CORE_MEM="-"
                               WARP_STATE=disconnected; BBR_STATE=bbr; BBR_ALGO=bbr ;;
                not_installed) CORE_STATE=not_installed; CORE_VER="未安装"; CORE_PID="-"; CORE_MEM="-"
                               WARP_STATE=not_installed; BBR_STATE=cubic; BBR_ALGO=cubic ;;
            esac
        }
        printf 'q\n' | main_menu
    )
}

if [[ "${1:-}" == "--render" ]]; then
    shift
    [[ $# -ge 3 ]] || { echo "用法: $0 --render COLS ROWS LAYOUT [CORE_STATE]" >&2; exit 2; }
    render_once "$@"
    exit 0
fi

OUT="$ROOT/docs/ui-samples"
mkdir -p "$OUT"
rm -f "$OUT"/main-*.txt

gen() {   # 名称 cols rows layout core [额外环境变量...]
    local name="$1" cols="$2" rows="$3" layout="$4" core="$5"; shift 5
    env "$@" bash "$0" --render "$cols" "$rows" "$layout" "$core" | sed 's/[[:space:]]*$//' > "$OUT/${name}.txt"
}
gen_ansi() {
    local name="$1" cols="$2" rows="$3" layout="$4" core="$5"
    SBM_FORCE_COLOR=1 bash "$0" --render "$cols" "$rows" "$layout" "$core" > "$OUT/${name}-ansi.txt"
}

for c in 120 80 60 40; do gen "main-full-${c}col" "$c" 60 full running; done
for c in 80 60 44 40; do gen "main-compact-${c}col" "$c" 24 compact running; done
gen "main-compact-80col-ascii"        80 24 compact running SBM_ASCII=1
gen "main-compact-80col-stopped"      80 24 compact stopped
gen "main-compact-80col-notinstalled" 80 24 compact not_installed
gen_ansi "main-full-80col"    80 60 full running
gen_ansi "main-compact-80col" 80 24 compact running
gen_ansi "main-compact-44col" 44 30 compact running
echo "已生成 $(ls "$OUT"/main-*.txt | wc -l) 个样本 → $OUT"
