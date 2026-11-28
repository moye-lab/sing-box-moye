#!/usr/bin/env bash
# 固定版本 / sha256 校验的单元测试（无需 jq、无需网络、无需 root）
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

source "$ROOT/core/env.sh"
export SB_ETC="$tmp/etc"
export CF_BIN="$tmp/cloudflared-not-installed"
log_err() { :; }
log_warn() { :; }
log_info() { :; }
source "$ROOT/protocols/argo.sh"

printf 'hello' > "$tmp/f"
good="$(sha256sum "$tmp/f" | awk '{print $1}')"
bad="$(printf '0%.0s' {1..64})"

verify_sha256 "$tmp/f" "$good" || fail "correct sha256 rejected"
! verify_sha256 "$tmp/f" "$bad" || fail "wrong sha256 accepted"
rc=0; verify_sha256 "$tmp/f" "abc" || rc=$?
[[ "$rc" == 2 ]] || fail "malformed sha256 should return 2, got $rc"

# 未配置版本/哈希时必须拒绝下载
unset CF_VERSION CF_SHA256_amd64 CF_SHA256_arm64 CF_SHA256_armhf SBX_ALLOW_UNVERIFIED || true
! ensure_cloudflared || fail "ensure_cloudflared must refuse when pins are empty"

# 只配了版本、没配哈希，同样必须拒绝
CF_VERSION="0.0.0"
! ensure_cloudflared || fail "ensure_cloudflared must refuse when sha256 is empty"

# 仓库内的 pins.sh 不得带有看起来像真实值的伪造哈希（必须由作者自己填写并核对）
grep -qE '^CF_SHA256_[a-z0-9]+="[0-9a-f]{64}"' "$ROOT/core/pins.sh" \
    && echo "NOTE: core/pins.sh 已填写哈希（请确认已与官方 Release 核对）"

echo "pins_test OK"
