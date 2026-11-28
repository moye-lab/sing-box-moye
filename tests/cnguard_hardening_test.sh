#!/usr/bin/env bash
# CN 出站拦截加固测试：凭据不进命令行、实测目标校验、对照站判定、补漏清单过滤。
# 无需 jq / root / 网络（curl、systemctl、getent 均为桩）。
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS: %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$*"; }
check() { if (eval "$2") >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
source "$ROOT/core/env.sh"
source "$ROOT/protocols/cnblock/cnblock.sh"
log_err() { echo "ERR: $*" >> "$T/log"; }; log_warn() { :; }; log_info() { :; }

# ---- 桩 curl：记录 argv 与 ALL_PROXY；对照站（google）是否可达由 CTL_MODE 决定 ----
cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
{ printf 'ARGV:%s\n' "$*"; printf 'ALL_PROXY:%s\n' "${ALL_PROXY:-}"; } >> "$T_LOG"
url="${@: -1}"
case "$url" in
  *google.com*) [[ "${CTL_MODE:-up}" == "up" ]] && echo 200 || echo 000 ;;
  *) echo "${TARGET_CODE:-000}" ;;
esac
STUB
chmod +x "$T/bin/curl"
export PATH="$T/bin:$PATH" T_LOG="$T/curl.log"

# ---- 1. 凭据不进命令行 ----
: > "$T_LOG"
code="$(TARGET_CODE=200 _cnblock_curl_code "https://example.com" "alice" "s3cretpw" 1080)"
check "返回目标的状态码 200" '[[ "$code" == "200" ]]'
check "命令行里没有密码" '! grep -q "^ARGV:.*s3cretpw" "$T_LOG"'
check "命令行里没有 socks5h://" '! grep -q "^ARGV:.*socks5" "$T_LOG"'
check "凭据通过 ALL_PROXY 传递（socks5h，本机端口）" 'grep -qx "ALL_PROXY:socks5h://alice:s3cretpw@127.0.0.1:1080" "$T_LOG"'
check "URL 仍是最后一个参数" 'grep -q "^ARGV:.* https://example.com$" "$T_LOG"'
check "curl 无输出时返回 000" '[[ "$(PATH=/nonexistent:/usr/bin:/bin _cnblock_curl_code http://x 1 2 3)" =~ ^[0-9]{3}$ ]]'
check "源码里不再有把 socks5h 凭据放进 -x 的调用" '! grep -qE -- "-x \"socks5h?://\\$\\{socks_user\\}" "$ROOT/protocols/cnblock/cnblock.sh" "$ROOT/protocols/warp.sh"'

# ---- 2. 实测目标校验 ----
for good in example.com www.baidu.com a-b.c-d.co.uk 223.5.5.5 2400:3200::1 ::1; do
    check "合法目标: $good" '_cnblock_valid_target "$good"'
done
for badt in "example.com:8080" "http://example.com" "example.com/path" "exa mple.com" "localhost" "999.1.1.1" "-o/etc/x" "a..b.com" "" "1.2.3"; do
    check "非法目标被拒: '$badt'" '! _cnblock_valid_target "$badt"'
done

# ---- 3. 对照站判定：000 不等于被拦截 ----
state_get_field() { case "$2" in port) echo 1080;; username) echo u;; password) echo p;; esac; }
systemctl() { return 0; }
getent() { :; }
out="$(TARGET_CODE=000 CTL_MODE=up _cnblock_test_target 223.5.5.5)"
check "目标 000 且对照站正常 → BLOCK" '[[ "$out" == *"Action: BLOCK"* ]]'
out="$(TARGET_CODE=000 CTL_MODE=down _cnblock_test_target 223.5.5.5)"; rc=$?
check "目标 000 且对照站也 000 → UNKNOWN，不下结论" '[[ "$out" == *"Action: UNKNOWN"* && "$out" != *"Action: BLOCK"* ]]'
out="$(TARGET_CODE=200 CTL_MODE=down _cnblock_test_target 223.5.5.5)"
check "目标可达 → ALLOW（不受对照站影响）" '[[ "$out" == *"Action: ALLOW"* ]]'
: > "$T/log"; _cnblock_test_target "example.com:8080" >/dev/null 2>&1; rc=$?
check "带端口的目标被拒并提示" '(( rc != 0 )) && grep -q "目标无效" "$T/log"'

# ---- 4. 补漏清单过滤 ----
printf '# 注释行\r\nAbcChina.com\r\n  pingbank.com   # 行内注释 bank\r\n\r\nexample.com:8080 http://x.com 农业银行 abc 1.2.3.4\r\nZHONGAN.com  a_b.com\r\n' > "$T/conf"
got="$(_cnblock_conf_tokens "$T/conf" | tr '\n' ' ')"
check "只保留合法域名并转小写" '[[ "$got" == "abcchina.com pingbank.com zhongan.com " ]]'
: > "$T/empty"
check "空文件不输出" '[[ -z "$(_cnblock_conf_tokens "$T/empty")" ]]'
check "仓库自带清单 45 个全部通过过滤" '[[ "$(_cnblock_conf_tokens "$ROOT/protocols/cnblock/rules/high-risk-domains.conf" | wc -l)" == 45 ]]'

# ---- 5. 安装引导加固 ----
check "install.sh 下载强制 https 并有超时/重试" 'grep -q -- "--https-only" "$ROOT/install.sh" && grep -q -- "--proto .=https" "$ROOT/install.sh"'
check "install.sh 支持 SBX_SHA256 并校验包结构" 'grep -q "SBX_SHA256" "$ROOT/install.sh" && grep -q "发布包结构异常" "$ROOT/install.sh"'

printf '\nCNGUARD HARDENING TEST SUMMARY: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
