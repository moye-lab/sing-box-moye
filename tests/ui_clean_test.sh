#!/usr/bin/env bash
# clean（无边框）主页样式测试：无需 jq / root / 网络（状态函数用桩）
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'PASS: %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$*"; }
check(){ if (eval "$2") >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

for _l in C.UTF-8 C.utf8 en_US.UTF-8; do
    locale -a 2>/dev/null | grep -qix "$_l" && { export LC_ALL="$_l"; break; }
done
if [[ "$(locale charmap 2>/dev/null)" != "UTF-8" ]]; then
    echo "SKIP: 无 UTF-8 locale"; exit 0
fi

render() {   # $1=列数 $2=样式 $3=core_state  → 输出面板文本
    COLS="$1" STYLE="$2" CS="$3" NO_COLOR=1 bash -c '
        ROOT="'"$ROOT"'"
        source "$ROOT/core/env.sh"
        export SBM_COLS="$COLS" SBX_STYLE="$STYLE"
        source "$ROOT/core/ui.sh"
        SBM_VERSION="test"; SB_STATE=/nonexistent; SUB_ENV=/nonexistent
        state_has_proto() { case "$1" in reality|hysteria2) return 0;; *) return 1;; esac; }
        state_get_field() { case "$1:$2" in reality:port) echo 443;; reality:sni) echo www.microsoft.com;; hysteria2:port) echo 8443;; esac; }
        eval "$(sed -n "/^_sbx_cnblock_pill()/,/^}/p;/^_sbx_sub_pill()/,/^}/p;/^_sbx_cli_hint_c()/,/^}/p;/^_sbx_panel_clean()/,/^}/p" "$ROOT/sbx.sh")"
        state_err_mark() { printf "%s" "${SBX_STATE_ERR_MARK:-/nonexistent-mark}"; }
        CORE_STATE="$CS"; CORE_MEM=6.6MB
        ui_init; ui_panel_begin
        _sbx_panel_clean pfx 203.0.113.9 AS1 US "v1.0" "PID 1" "$(ui_status_pill running 运行中)" "$(ui_status_pill stopped 未安装)" "$(ui_status_pill ok BBR)"
        ui_panel_print
    '
}

out80="$(render 80 clean running)"
check "80 列：不含任何边框字符" '! grep -qE "[│╭╮╰╯├┤]" <<<"$out80"'
check "80 列：七个协议键与管理键齐全" 'for k in r h t a p y i e n o w c s d x q; do grep -qE "(^|[[:space:]])$k[[:space:]]+[^[:space:]]" <<<"$out80" || exit 1; done'
check "80 列：已启用协议显示端口与 SNI" 'grep -q "443 · www.microsoft.com" <<<"$out80"'
check "80 列：主页不超过 24 行（SSH 默认窗口）" '(( $(wc -l <<<"$out80") <= 24 ))'
check "无尾随空格" '! grep -qE " +$" <<<"$out80"'

for c in 120 80 60 40; do
    o="$(render $c clean running)"
    w=$(source "$ROOT/core/env.sh"; export SBM_COLS=$c; source "$ROOT/core/ui.sh"; m=0
        while IFS= read -r line; do ui_vwidth "$line"; (( UI_VW > m )) && m=$UI_VW; done <<<"$o"; echo $m)
    check "${c} 列：最宽行 ${w} ≤ ${c}-1" "(( $w <= $c - 1 ))"
done

o_stop="$(render 80 clean stopped)"
check "内核已停止时出现下一步提示" 'grep -q "服务未运行" <<<"$o_stop"'
o_none="$(render 80 clean not_installed)"
check "未安装内核时提示一键全装" 'grep -q "尚未安装内核" <<<"$o_none"'

boxed="$(COLS=80 STYLE=boxed bash -c 'source '"$ROOT"'/core/env.sh; export SBM_COLS=80 SBX_STYLE=boxed NO_COLOR=1; source '"$ROOT"'/core/ui.sh; ui_top; ui_line x; ui_bot')"
check "SBX_STYLE=boxed 仍输出旧版边框" 'grep -q "│" <<<"$boxed" && grep -q "╭" <<<"$boxed"'

hint="$(NO_COLOR=1 SBM_COLS=80 SBX_STYLE=clean bash -c 'source '"$ROOT"'/core/env.sh; source '"$ROOT"'/core/ui.sh; ui_init; ui_hint abc')"
check "clean 下 ui_hint 为 2 格缩进" '[[ "$hint" == "  abc" ]]'
hint_b="$(NO_COLOR=1 SBM_COLS=80 SBX_STYLE=boxed bash -c 'source '"$ROOT"'/core/env.sh; source '"$ROOT"'/core/ui.sh; ui_init; ui_hint abc')"
check "boxed 下 ui_hint 仍为 1 格缩进" '[[ "$hint_b" == " abc" ]]'
_mark="$(mktemp)"
banner="$(SBX_STATE_ERR_MARK="$_mark" render 80 clean running)"
rm -f "$_mark"
check "状态异常标记存在时主页顶部出现提示" 'grep -q "状态文件异常" <<<"$banner"'
check "无标记时没有该提示" '! grep -q "状态文件异常" <<<"$out80"'

printf '\nUI CLEAN TEST SUMMARY: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
