#!/usr/bin/env bash
# 统一测试入口：bash tests/run_all.sh
# 依赖：jq、python3、python3-yaml（与 CI 一致）。单个测试可直接 bash tests/<名称>.sh 运行。
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

pass=0; fail=0; failed=()
log="$(mktemp)"; trap 'rm -f "$log"' EXIT

run() {
    local name="$1"; shift
    if "$@" >"$log" 2>&1; then
        printf 'PASS  %s\n' "$name"; pass=$((pass+1))
    else
        printf 'FAIL  %s\n' "$name"; tail -n 20 "$log" | sed 's/^/      /'
        fail=$((fail+1)); failed+=("$name")
    fi
}

run smoke bash tests/smoke.sh
run version_check bash tests/version_check.sh
run round2_regression bash tests/round2_regression.sh
for t in tests/*_test.sh; do run "$(basename "$t")" bash "$t"; done
run subscription_test.py python3 tests/subscription_test.py

printf '\n通过 %d，失败 %d\n' "$pass" "$fail"
(( fail == 0 )) || { printf '失败项: %s\n' "${failed[*]}"; exit 1; }
