#!/usr/bin/env bash
# 端口保留 / 端口跳跃冲突 / ASN 格式化 / 状态错误去重（无需 jq、root、网络）
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS: %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$*"; }
check() { if (eval "$2") >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
source "$ROOT/core/env.sh"
source "$ROOT/core/state_manager.sh"
source "$ROOT/utils/sysctl.sh"
log_err() { :; }; log_warn() { :; }; log_info() { :; }

export SB_STATE="$T/state.json"
cat > "$SB_STATE" <<'JSON'
{"schema_version":1,"installed_protocols":["reality","hysteria2","tuic","socks5"],
 "meta":{},
 "protocols":{
  "reality":{"port":12559,"sni":"itunes.apple.com"},
  "hysteria2":{"port":15633,"hop_range":"20000:30000"},
  "tuic":{"port":17784},
  "socks5":{"port":28644,"udp":true}}}
JSON

# --- 状态端口 / 跳跃段读取 ---
ports="$(state_assigned_ports | sort -n | tr '\n' ' ')"
check "state_assigned_ports 读出全部 4 个端口" '[[ "$ports" == "12559 15633 17784 28644 " ]]'
check "state_hop_range 读出 20000:30000" '[[ "$(state_hop_range)" == "20000:30000" ]]'
check "25000 在跳跃段内" 'port_in_hop_range 25000'
check "19999 不在跳跃段内" '! port_in_hop_range 19999'
check "17784 属于已分配端口" 'port_reserved 17784'
check "40000 未保留" '! port_reserved 40000'

# --- random_port 必须跳过：已分配端口 / 跳跃段 / ss 在用端口 ---
printf '%s\n' 25000 17784 41000 42000 > "$T/seq"
shuf() {   # 命令替换里调用，计数必须落盘
    local n; n=$(head -n1 "$T/seq"); sed -i 1d "$T/seq"; echo "$n"
}
is_port_used() { [[ "$1" == 41000 ]]; }
got="$(random_port)"
check "random_port 跳过跳跃段/已分配/在用端口，返回 42000" '[[ "$got" == "42000" ]]'
unset -f shuf is_port_used

# --- 跳跃段冲突检查 ---
_hop_udp_listen_ports() { printf '%s\n' 53 22333 51820; }   # 模拟系统里正在绑定的 UDP 端口
c="$(hop_range_conflicts 10000:20000 15633 | tr '\n' ' ')"
check "10000:20000 与 TUIC 17784、22333 无关：只报 17784" '[[ "$c" == "17784 " ]]'
c="$(hop_range_conflicts 40000:50000 15633 | tr '\n' ' ')"
check "40000:50000 无冲突" '[[ -z "${c// /}" ]]'
c="$(hop_range_conflicts 20000:30000 15633 | tr '\n' ' ')"
check "20000:30000 报 22333 与 28644（socks5 UDP）" '[[ "$c" == "22333 28644 " ]]'
c="$(hop_range_conflicts 10000:20000 17784 | tr '\n' ' ')"
check "目标端口自身不算冲突" '[[ "$c" != *"17784"* ]]'

# add_port_hopping 在冲突时必须在改动系统前就失败（不依赖 iptables/systemctl）
iptables() { :; }; ip6tables() { :; }
systemctl() { echo "SYSTEMCTL-CALLED" >> "$T/sysctl.log"; }
HOP_UNIT="$T/sbx-hop.service"
add_port_hopping 10000:20000 15633; rc=$?
check "冲突时 add_port_hopping 返回非 0" '(( rc != 0 ))'
check "冲突时没有写 unit 也没有调用 systemctl" '[[ ! -e "$HOP_UNIT" && ! -e "$T/sysctl.log" ]]'

# --- ASN 格式化 ---
check "format_asn 36352 → AS36352" '[[ "$(format_asn 36352)" == "AS36352" ]]'
check "format_asn AS-Direct 原样" '[[ "$(format_asn AS-Direct)" == "AS-Direct" ]]'
check "format_asn Direct 原样" '[[ "$(format_asn Direct)" == "Direct" ]]'
check "format_asn 空值不报错" '[[ -z "$(format_asn "")" ]]'

# --- 状态错误只报一次（用文件标记跨子 shell 去重） ---
export SBX_STATE_ERR_MARK="$T/err.mark"
log_err() { echo "ERR: $1" >> "$T/err.log"; }
for _ in 1 2 3; do ( _state_report_error "x" ); done
check "同一标记下三次（子 shell）只记录一次错误" '[[ "$(wc -l < "$T/err.log")" == 1 ]]'
rm -f "$SBX_STATE_ERR_MARK"; ( _state_report_error "y" )
check "清标记后可再次报告" '[[ "$(wc -l < "$T/err.log")" == 2 ]]'

# --- install.sh 加固 ---
check "install.sh 下载带 https-only / 超时 / 重试" 'grep -q -- "--https-only" "$ROOT/install.sh" && grep -q -- "--proto .=https" "$ROOT/install.sh"'
check "install.sh 支持 SBX_SHA256 校验" 'grep -q "SBX_SHA256" "$ROOT/install.sh"'

printf '\nPORT GUARD TEST SUMMARY: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
