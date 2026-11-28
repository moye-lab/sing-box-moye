#!/usr/bin/env bash
# 订阅令牌重置：保留端口/监听地址、换新令牌、权限 600、服务被重启（无需 root / 网络）
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS: %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$*"; }
check() { if (eval "$2") >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
source "$ROOT/core/env.sh"
export SBX_STYLE=boxed
source "$ROOT/core/ui.sh"
source "$ROOT/utils/subscription.sh"
log_ok() { :; }; log_warn() { echo "WARN: $*" >> "$T/log"; }; log_err() { echo "ERR: $*" >> "$T/log"; }

SUB_ENV="$T/sub.env"
systemctl() { echo "$*" >> "$T/systemctl.log"; return 0; }
subscription_status() { :; }

subscription_rotate; rc=$?
check "未启用时拒绝重置" '(( rc != 0 )) && grep -q "尚未启用" "$T/log"'

old="$(printf 'a%.0s' {1..64})"
printf 'SUB_TOKEN=%s\nSUB_PORT=8765\nSUB_BIND=0.0.0.0\n' "$old" > "$SUB_ENV"; chmod 600 "$SUB_ENV"
subscription_rotate; rc=$?
new="$(sed -n 's/^SUB_TOKEN=//p' "$SUB_ENV")"
check "返回 0" '(( rc == 0 ))'
check "令牌已更换且为 64 位十六进制" '[[ "$new" != "$old" && "$new" =~ ^[0-9a-f]{64}$ ]]'
check "端口与监听地址保持不变" 'grep -qx "SUB_PORT=8765" "$SUB_ENV" && grep -qx "SUB_BIND=0.0.0.0" "$SUB_ENV"'
check "文件权限为 600" '[[ "$(stat -c %a "$SUB_ENV")" == "600" ]]'
check "重启了订阅服务" 'grep -qx "restart sbx-subscription.service" "$T/systemctl.log"'
check "不残留临时文件" '[[ "$(ls "$T" | grep -c "^sub.env\.")" == 0 ]]'

printf '\nSUBSCRIPTION ROTATE TEST SUMMARY: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
