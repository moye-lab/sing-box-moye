#!/usr/bin/env bash
export SBX_STYLE="${SBX_STYLE:-boxed}"   # 旧版测试断言边框样式；默认样式为 clean
# tests/cnguard_test.sh — CN Egress Guard（v1.10.0）单元测试
# 用法：bash tests/cnguard_test.sh
# 覆盖：补漏域名 conf 加载与 fallback、规则集 update 成功/失败保留旧规则、
#       Guard 四态（ACTIVE/DEGRADED/FAILED/DISABLED）、doctor、test
#       （无参与单目标）、IPv6 探针。
# 注意：sing-box / systemctl / curl / ip / getent 均为桩；真实内核与
# 真实网络验证见 RN 真机测试，不在本文件。
set -u
cd "$(dirname "$0")/.." || exit 1
APP_HOME="$PWD"
export APP_HOME

# 模拟环境
TEST_ETC=$(mktemp -d)
export SB_ETC="$TEST_ETC"
export SB_CONFIG="$TEST_ETC/config.json"
export SB_STATE="$TEST_ETC/state.json"
export SB_BIN="$TEST_ETC/fake_singbox.sh"
cat > "$SB_BIN" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$SB_BIN"
cp templates/base.json "$SB_CONFIG"

SERVICE_ACTIVE=0
RELOAD_CALLS=0
systemctl() {
    case "$1" in
        is-active) [[ $SERVICE_ACTIVE -eq 1 ]] ;;
        reload|restart) RELOAD_CALLS=$((RELOAD_CALLS + 1)); SERVICE_ACTIVE=1; return 0 ;;
        enable) return 0 ;;
        *) return 0 ;;
    esac
}
export -f systemctl

# shellcheck source=/dev/null
source core/env.sh
# env.sh 硬设路径，重新覆盖
export SB_ETC="$TEST_ETC" SB_CONFIG="$TEST_ETC/config.json" SB_STATE="$TEST_ETC/state.json" SB_BIN="$TEST_ETC/fake_singbox.sh"
# shellcheck source=/dev/null
source core/state_manager.sh
# shellcheck source=/dev/null
source core/json_builder.sh
# shellcheck source=/dev/null
source protocols/cnblock/cnblock.sh

# 写一个“合格”的假规则集文件：SRS 魔数 + 指定大小填充（默认 20KB）。
write_fake_srs() { local size="${2:-20000}"; printf 'SRS\001' > "$1"; head -c "$size" /dev/zero >> "$1"; chmod 600 "$1"; }

# 模拟规则集下载：ok 写合格假文件，fail 返回失败，bad 写无魔数文件。
DOWNLOAD_MODE="ok"
DOWNLOAD_CALLS=0
download_file() {
    local _url="$1" dest="$2"
    DOWNLOAD_CALLS=$((DOWNLOAD_CALLS + 1))
    if [[ "$DOWNLOAD_MODE" == "fail" ]]; then
        return 1
    fi
    if [[ "$DOWNLOAD_MODE" == "bad" ]]; then
        head -c 20000 /dev/zero > "$dest"
        chmod 600 "$dest"
        return 0
    fi
    write_fake_srs "$dest"
}

# 桩 curl / ip / getent（经 PATH 找到）。
mkdir -p "$TEST_ETC/bin"
cat > "$TEST_ETC/bin/curl" <<'CURLEOF'
#!/usr/bin/env bash
url="${@: -1}"
if [[ "${FAKE_CURL_MODE:-block}" == "open" ]]; then echo 200; exit 0; fi
case "$url" in
  *google.com*|*cloudflare.com*|*github.com*|*8.8.8.8*) echo 200 ;;
  *) echo 000 ;;
esac
CURLEOF
chmod +x "$TEST_ETC/bin/curl"
cat > "$TEST_ETC/bin/ip" <<'IPEOF'
#!/usr/bin/env bash
if [[ "$*" == *"-6 addr show scope global"* ]] && [[ "${FAKE_IP6:-0}" == "1" ]]; then
    echo "    inet6 2400:3200::1/64 scope global"
fi
exit 0
IPEOF
chmod +x "$TEST_ETC/bin/ip"
cat > "$TEST_ETC/bin/getent" <<'GETEOF'
#!/usr/bin/env bash
# 桩 getent：hosts 查询返回固定 IP（国内域名→1.2.3.4，海外→8.8.8.8）。
if [[ "$1" == "hosts" ]]; then
    case "$2" in
        www.google.com|github.com|www.cloudflare.com) echo "8.8.8.8 $2" ;;
        *) echo "1.2.3.4 $2" ;;
    esac
fi
exit 0
GETEOF
chmod +x "$TEST_ETC/bin/getent"
export PATH="$TEST_ETC/bin:$PATH"

fail=0
assert() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "PASS: $desc"
    else
        echo "FAIL: $desc"
        fail=1
    fi
}

reset_env() {
    cp templates/base.json "$SB_CONFIG"
    rm -f "$SB_STATE" "$SB_ETC/geosite-cn.srs" "$SB_ETC/geoip-cn.srs" "$SB_ETC"/*.bak
    DOWNLOAD_MODE="ok"
    unset CNBLOCK_DOMAINS_CONF
    SERVICE_ACTIVE=0
    RELOAD_CALLS=0
}

setup_socks5() {
    jq '.protocols.socks5 = {port: 12345, username: "u", password: "p"}' "$SB_STATE" > "$TEST_ETC/state.tmp" && mv "$TEST_ETC/state.tmp" "$SB_STATE"
    SERVICE_ACTIVE=1
}

init_state_file

# ---------- 1. conf 文件加载与 fallback ----------
extra_n=$(_cnblock_extra_domains_json | jq 'length')
assert "默认 conf 加载出 45 个域名" bash -c "[[ $extra_n -eq 45 ]]"
# conf 与内嵌 fallback 内容一致（排序后逐行比对）。
grep -v '^[[:space:]]*#' protocols/cnblock/rules/high-risk-domains.conf | grep -v '^[[:space:]]*$' | tr -d '\r' | sort > "$TEST_ETC/conf-list.txt"
printf '%s' "$CNBLOCK_EXTRA_DOMAINS" | tr ' ' '\n' | grep -v '^$' | sort > "$TEST_ETC/embedded-list.txt"
assert "conf 清单与内嵌 fallback 内容一致" cmp -s "$TEST_ETC/conf-list.txt" "$TEST_ETC/embedded-list.txt"
# 自定义 conf 生效（CNBLOCK_DOMAINS_CONF 覆盖）。
printf '# 注释行\n\nexample-a.com\n\n# 另一个注释\nexample-b.com\n' > "$TEST_ETC/custom.conf"
CNBLOCK_DOMAINS_CONF="$TEST_ETC/custom.conf" _cnblock_extra_domains_json > "$TEST_ETC/custom.json"
assert "自定义 conf 加载（注释与空行忽略）" jq -e 'length == 2 and index("example-a.com") != null and index("example-b.com") != null' "$TEST_ETC/custom.json"
# conf 不存在 → fallback 45 个。
CNBLOCK_DOMAINS_CONF="$TEST_ETC/nonexistent.conf" _cnblock_extra_domains_json > "$TEST_ETC/fb1.json"
assert "conf 不存在时回落到内嵌 45 个" jq -e 'length == 45' "$TEST_ETC/fb1.json"
# conf 只有注释 → fallback 45 个。
printf '# 只有注释\n# 没有域名\n' > "$TEST_ETC/empty.conf"
CNBLOCK_DOMAINS_CONF="$TEST_ETC/empty.conf" _cnblock_extra_domains_json > "$TEST_ETC/fb2.json"
assert "conf 为空时回落到内嵌 45 个" jq -e 'length == 45' "$TEST_ETC/fb2.json"
# fallback 端到端：conf 不存在时开启拦截，规则仍为 45 个域名。
reset_env
CNBLOCK_DOMAINS_CONF="$TEST_ETC/nonexistent.conf" cnblock_enable >/dev/null 2>&1
assert "conf 不存在时开启拦截仍写 45 个域名" jq -e '.route.rules[4].domain_suffix | length == 45' "$SB_CONFIG"
unset CNBLOCK_DOMAINS_CONF
reset_env
# conf 变更检测：新增域名后重跑 enable 必须重写规则（幂等检查需比对域名集合）。
reset_env
cnblock_enable >/dev/null 2>&1
cp protocols/cnblock/rules/high-risk-domains.conf "$TEST_ETC/changed.conf"
printf 'newdomain-test.com\n' >> "$TEST_ETC/changed.conf"
CNBLOCK_DOMAINS_CONF="$TEST_ETC/changed.conf" cnblock_enable >/dev/null 2>&1
assert "conf 新增域名后重跑 enable 写 46 个域名" jq -e '.route.rules[4].domain_suffix | length == 46' "$SB_CONFIG"
assert "conf 新增域名后重跑 enable 包含新域名" jq -e '.route.rules[4].domain_suffix | index("newdomain-test.com") != null' "$SB_CONFIG"
unset CNBLOCK_DOMAINS_CONF
reset_env

# ---------- 2. update 成功 ----------
# 旧规则集（15KB，40 天前）+ 已开启（DEGRADED）→ 更新后变新文件 + ACTIVE。
write_fake_srs "$TEST_ETC/geosite-cn.srs" 15000
write_fake_srs "$TEST_ETC/geoip-cn.srs" 15000
touch -d "40 days ago" "$TEST_ETC/geosite-cn.srs" "$TEST_ETC/geoip-cn.srs"
cnblock_enable >/dev/null 2>&1
cnblock_status > "$TEST_ETC/status-stale.out" 2>&1; st=$?
assert "旧规则集开启后 status 为 DEGRADED" grep -q 'Guard：DEGRADED' "$TEST_ETC/status-stale.out"
SERVICE_ACTIVE=1
RELOAD_CALLS=0
cnblock_update > "$TEST_ETC/update.out" 2>&1; upd_rc=$?
assert "update 成功返回 0" bash -c "[[ $upd_rc -eq 0 ]]"
assert "update 后 geosite 文件被替换（新大小）" bash -c "[[ $(stat -c %s $TEST_ETC/geosite-cn.srs) -eq 20004 ]]"
assert "update 后 geoip 文件被替换（新大小）" bash -c "[[ $(stat -c %s $TEST_ETC/geoip-cn.srs) -eq 20004 ]]"
assert "update 后无 .bak 残留" bash -c "[[ ! -f $TEST_ETC/geosite-cn.srs.bak && ! -f $TEST_ETC/geoip-cn.srs.bak ]]"
assert "update 后无临时目录残留" bash -c "[[ -z \"\$(ls -d $TEST_ETC/.cnblock-update.* 2>/dev/null)\" ]]"
assert "update 成功时重载了服务" bash -c "[[ $RELOAD_CALLS -ge 1 ]]"
assert "update 后状态记录 ok" jq -e '.cnblock.rules.last_update_status == "ok"' "$SB_STATE"
assert "update 后失败原因已清空" jq -e '.cnblock.rules.last_update_error == ""' "$SB_STATE"
assert "update 后 geosite.updated_at 已写" jq -e '.cnblock.rules.geosite.updated_at | type == "number"' "$SB_STATE"
assert "update 后 geoip.updated_at 已写" jq -e '.cnblock.rules.geoip.updated_at | type == "number"' "$SB_STATE"
cnblock_status > "$TEST_ETC/status-fresh.out" 2>&1; st=$?
assert "update 后 status 变为 ACTIVE" grep -q 'Guard：ACTIVE' "$TEST_ETC/status-fresh.out"
assert "update 后 status 返回 0" bash -c "[[ $st -eq 0 ]]"
assert "status 显示上次更新 ok" grep -q '上次更新：.*（ok）' "$TEST_ETC/status-fresh.out"
# 服务未运行时 update 不启动服务，但文件照样更新。
reset_env
write_fake_srs "$TEST_ETC/geosite-cn.srs" 15000
write_fake_srs "$TEST_ETC/geoip-cn.srs" 15000
SERVICE_ACTIVE=0
RELOAD_CALLS=0
cnblock_update > "$TEST_ETC/update-down.out" 2>&1; upd_rc=$?
assert "服务未运行时 update 仍成功" bash -c "[[ $upd_rc -eq 0 ]]"
assert "服务未运行时 update 不重载/不启动服务" bash -c "[[ $RELOAD_CALLS -eq 0 && $SERVICE_ACTIVE -eq 0 ]]"
assert "服务未运行时 update 提示下次启动生效" grep -q '下次启动时生效' "$TEST_ETC/update-down.out"

# ---------- 3. update 失败保留旧规则 ----------
reset_env
write_fake_srs "$TEST_ETC/geosite-cn.srs" 15000
write_fake_srs "$TEST_ETC/geoip-cn.srs" 15000
touch -d "40 days ago" "$TEST_ETC/geosite-cn.srs" "$TEST_ETC/geoip-cn.srs"
cnblock_enable >/dev/null 2>&1
DOWNLOAD_MODE="fail"
cnblock_update > "$TEST_ETC/update-fail.out" 2>&1; upd_rc=$?
DOWNLOAD_MODE="ok"
assert "下载失败时 update 返回非 0" bash -c "[[ $upd_rc -ne 0 ]]"
assert "下载失败时旧 geosite 文件还在" bash -c "[[ $(stat -c %s $TEST_ETC/geosite-cn.srs) -eq 15004 ]]"
assert "下载失败时旧 geoip 文件还在" bash -c "[[ $(stat -c %s $TEST_ETC/geoip-cn.srs) -eq 15004 ]]"
assert "下载失败时无 .bak 残留" bash -c "[[ ! -f $TEST_ETC/geosite-cn.srs.bak && ! -f $TEST_ETC/geoip-cn.srs.bak ]]"
assert "下载失败时状态记录 failed" jq -e '.cnblock.rules.last_update_status == "failed"' "$SB_STATE"
assert "下载失败时记录了失败原因" bash -c "[[ -n \"$(jq -r '.cnblock.rules.last_update_error' $SB_STATE)\" ]]"
assert "下载失败时拦截规则仍在（3 条）" bash -c "[[ $(jq '[.route.rules[]? | select(.outbound == "block")] | length' $SB_CONFIG) -eq 3 ]]"
assert "下载失败时不静默（有报错输出）" grep -q '下载失败' "$TEST_ETC/update-fail.out"
# 校验失败（下载到无魔数文件）同样保留旧规则。
DOWNLOAD_MODE="bad"
cnblock_update > "$TEST_ETC/update-bad.out" 2>&1; upd_rc=$?
DOWNLOAD_MODE="ok"
assert "校验失败时 update 返回非 0" bash -c "[[ $upd_rc -ne 0 ]]"
assert "校验失败时旧文件还在" bash -c "[[ $(stat -c %s $TEST_ETC/geosite-cn.srs) -eq 15004 ]]"
assert "校验失败时状态记录 failed" jq -e '.cnblock.rules.last_update_status == "failed"' "$SB_STATE"
# 失败一次后成功：失败原因清空，状态恢复 ok。
cnblock_update >/dev/null 2>&1; upd_rc=$?
assert "失败后重试 update 成功" bash -c "[[ $upd_rc -eq 0 ]]"
assert "重试成功后失败原因清空" jq -e '.cnblock.rules.last_update_error == ""' "$SB_STATE"
reset_env

# ---------- 4. Guard 四态 ----------
# DISABLED
cnblock_status > "$TEST_ETC/st-disabled.out" 2>&1; st=$?
assert "DISABLED 时 status 返回 1" bash -c "[[ $st -eq 1 ]]"
assert "DISABLED 时输出 Guard：DISABLED" grep -q 'Guard：DISABLED' "$TEST_ETC/st-disabled.out"
_cnblock_probe
assert "DISABLED 时探针 Guard 为 DISABLED" bash -c "[[ $CNBLOCK_P_GUARD == DISABLED ]]"
# ACTIVE
cnblock_enable >/dev/null 2>&1
cnblock_status > "$TEST_ETC/st-active.out" 2>&1; st=$?
assert "ACTIVE 时 status 返回 0" bash -c "[[ $st -eq 0 ]]"
assert "ACTIVE 时输出 Guard：ACTIVE" grep -q 'Guard：ACTIVE' "$TEST_ETC/st-active.out"
assert "ACTIVE 时显示域名层 OK" grep -q '域名层 geosite-cn：OK' "$TEST_ETC/st-active.out"
assert "ACTIVE 时显示 IP 层含 IPv4+IPv6" grep -q 'IP 层 geoip-cn：OK.*含 IPv4+IPv6' "$TEST_ETC/st-active.out"
assert "ACTIVE 时显示补漏域名 45 个" grep -q '补漏域名：45 个' "$TEST_ETC/st-active.out"
assert "ACTIVE 时显示文件大小与日期" grep -q 'KB · 20' "$TEST_ETC/st-active.out"
# DEGRADED（陈旧）
touch -d "40 days ago" "$TEST_ETC/geosite-cn.srs" "$TEST_ETC/geoip-cn.srs"
cnblock_status > "$TEST_ETC/st-degraded.out" 2>&1; st=$?
assert "陈旧时 status 返回 0（拦截仍生效）" bash -c "[[ $st -eq 0 ]]"
assert "陈旧时输出 Guard：DEGRADED" grep -q 'Guard：DEGRADED' "$TEST_ETC/st-degraded.out"
assert "陈旧时显示 STALE" grep -q 'STALE' "$TEST_ETC/st-degraded.out"
assert "陈旧时建议 update" grep -q '建议 sbx cnblock update' "$TEST_ETC/st-degraded.out"
_cnblock_probe
assert "陈旧时探针 Guard 为 DEGRADED" bash -c "[[ $CNBLOCK_P_GUARD == DEGRADED ]]"
assert "陈旧时探针 STALE_DAYS 为 40" bash -c "[[ $CNBLOCK_P_STALE_DAYS -eq 40 ]]"
# DEGRADED（上次更新失败，文件新鲜）
reset_env
cnblock_enable >/dev/null 2>&1
jq '.cnblock.rules = {last_update_at: 1700000000, last_update_status: "failed", last_update_error: "测试失败"}' "$SB_STATE" > "$TEST_ETC/state.tmp" && mv "$TEST_ETC/state.tmp" "$SB_STATE"
cnblock_status > "$TEST_ETC/st-deg2.out" 2>&1; st=$?
assert "更新失败时 status 为 DEGRADED" grep -q 'Guard：DEGRADED' "$TEST_ETC/st-deg2.out"
assert "更新失败时 status 返回 0" bash -c "[[ $st -eq 0 ]]"
assert "更新失败时显示失败原因" grep -q 'failed：测试失败' "$TEST_ETC/st-deg2.out"
# FAILED（规则不完整）
reset_env
cnblock_enable >/dev/null 2>&1
config_transaction '.route.rules = ([{action: "sniff"}, {rule_set: "geosite-cn", outbound: "block"}] + (.route.rules // [] | map(select(. != {action: "sniff"}))))' >/dev/null 2>&1
cnblock_status > "$TEST_ETC/st-failed.out" 2>&1; st=$?
assert "规则不完整时 status 返回 2" bash -c "[[ $st -eq 2 ]]"
assert "规则不完整时输出 Guard：FAILED" grep -q 'Guard：FAILED' "$TEST_ETC/st-failed.out"
# FAILED（规则集文件缺失）
reset_env
cnblock_enable >/dev/null 2>&1
rm -f "$TEST_ETC/geoip-cn.srs"
cnblock_status > "$TEST_ETC/st-failed2.out" 2>&1; st=$?
assert "规则集缺失时 status 返回 2" bash -c "[[ $st -eq 2 ]]"
assert "规则集缺失时输出 Guard：FAILED" grep -q 'Guard：FAILED' "$TEST_ETC/st-failed2.out"
reset_env

# ---------- 5. doctor ----------
# ACTIVE + 实测通过 → 0
cnblock_enable >/dev/null 2>&1
setup_socks5
cnblock_doctor > "$TEST_ETC/doctor-ok.out" 2>&1; dr=$?
assert "ACTIVE 时 doctor 返回 0" bash -c "[[ $dr -eq 0 ]]"
assert "doctor 输出 Guard 状态 ACTIVE" grep -q 'Guard 状态：ACTIVE' "$TEST_ETC/doctor-ok.out"
assert "doctor 输出实测百度被拒" grep -q 'www.baidu.com 被拒 OK' "$TEST_ETC/doctor-ok.out"
assert "doctor 输出实测谷歌正常" grep -q 'www.google.com 正常 OK' "$TEST_ETC/doctor-ok.out"
assert "doctor 无问题时报未发现问题" grep -q '未发现问题' "$TEST_ETC/doctor-ok.out"
# DEGRADED（陈旧）→ 1 + 建议
touch -d "40 days ago" "$TEST_ETC/geosite-cn.srs" "$TEST_ETC/geoip-cn.srs"
cnblock_doctor > "$TEST_ETC/doctor-deg.out" 2>&1; dr=$?
assert "陈旧时 doctor 返回 1" bash -c "[[ $dr -eq 1 ]]"
assert "陈旧时 doctor 建议 update" grep -q '规则集已过期 40 天，建议 sbx cnblock update' "$TEST_ETC/doctor-deg.out"
# DISABLED → 0（用户选择，不计问题）
reset_env
cnblock_doctor > "$TEST_ETC/doctor-off.out" 2>&1; dr=$?
assert "DISABLED 时 doctor 返回 0" bash -c "[[ $dr -eq 0 ]]"
assert "DISABLED 时 doctor 提示未开启" grep -q '拦截未开启' "$TEST_ETC/doctor-off.out"
# FAILED → 1
reset_env
cnblock_enable >/dev/null 2>&1
config_transaction '.route.rules = ([{action: "sniff"}, {rule_set: "geosite-cn", outbound: "block"}] + (.route.rules // [] | map(select(. != {action: "sniff"}))))' >/dev/null 2>&1
cnblock_doctor > "$TEST_ETC/doctor-fail.out" 2>&1; dr=$?
assert "FAILED 时 doctor 返回 1" bash -c "[[ $dr -eq 1 ]]"
assert "FAILED 时 doctor 输出 Guard 状态 FAILED" grep -q 'Guard 状态：FAILED' "$TEST_ETC/doctor-fail.out"
reset_env

# ---------- 6. cnblock_test 无参 ----------
cnblock_enable >/dev/null 2>&1
setup_socks5
cnblock_test > "$TEST_ETC/test.out" 2>&1; trc=$?
assert "无参 test 全过时返回 0" bash -c "[[ $trc -eq 0 ]]"
assert "无参 test 汇总国内 6/6 被拒、海外 3/3 正常" grep -q '国内 6/6 被拒，海外 3/3 正常' "$TEST_ETC/test.out"
assert "无 IPv6 时 test 跳过 IPv6 探针" grep -q 'SKIP 本机无全局 IPv6' "$TEST_ETC/test.out"
FAKE_IP6=1 cnblock_test > "$TEST_ETC/test-v6.out" 2>&1; trc=$?
assert "有 IPv6 时 test 返回 0" bash -c "[[ $trc -eq 0 ]]"
assert "有 IPv6 时 test 汇总国内 7/7 被拒" grep -q '国内 7/7 被拒，海外 3/3 正常' "$TEST_ETC/test-v6.out"
assert "有 IPv6 时 test 列出 IPv6 探针 PASS" grep -q 'PASS 2400:3200::1（国内 IPv6）被拒' "$TEST_ETC/test-v6.out"
FAKE_CURL_MODE=open cnblock_test > "$TEST_ETC/test-open.out" 2>&1; trc=$?
assert "拦截失效时 test 返回非 0" bash -c "[[ $trc -ne 0 ]]"
assert "拦截失效时 test 有 FAIL 行" grep -q 'FAIL www.baidu.com' "$TEST_ETC/test-open.out"
# 未装 SOCKS5 时无法实测
reset_env
cnblock_enable >/dev/null 2>&1
SERVICE_ACTIVE=1
cnblock_test > "$TEST_ETC/test-nosocks.out" 2>&1; trc=$?
assert "未装 SOCKS5 时 test 返回非 0" bash -c "[[ $trc -ne 0 ]]"
assert "未装 SOCKS5 时 test 提示原因" grep -q '未安装 SOCKS5' "$TEST_ETC/test-nosocks.out"
# 拦截未开启时 test 提示
reset_env
setup_socks5
cnblock_test > "$TEST_ETC/test-off.out" 2>&1; trc=$?
assert "拦截未开启时 test 提示" grep -q '拦截未开启' "$TEST_ETC/test-off.out"
reset_env

# ---------- 7. cnblock_test 单目标 ----------
cnblock_enable >/dev/null 2>&1
setup_socks5
cnblock_test www.baidu.com > "$TEST_ETC/tgt-baidu.out" 2>&1; trc=$?
assert "单目标 baidu 返回 0" bash -c "[[ $trc -eq 0 ]]"
assert "单目标 baidu 输出 Target" grep -q 'Target: www.baidu.com' "$TEST_ETC/tgt-baidu.out"
assert "单目标 baidu 输出解析 IP" grep -q 'Resolved IP: 1.2.3.4' "$TEST_ETC/tgt-baidu.out"
assert "单目标 baidu 动作为 BLOCK" grep -q 'Action: BLOCK' "$TEST_ETC/tgt-baidu.out"
assert "单目标 baidu 推断 IP 层命中" grep -q '推断：解析出的 IP 也被拒，推断 IP 层命中' "$TEST_ETC/tgt-baidu.out"
cnblock_test www.deepseek.com > "$TEST_ETC/tgt-ds.out" 2>&1
assert "单目标 deepseek 推断在补漏名单里" grep -q '推断：在 45 个补漏域名名单里' "$TEST_ETC/tgt-ds.out"
cnblock_test notdeepseek.com > "$TEST_ETC/tgt-notds.out" 2>&1
assert "单目标 notdeepseek.com 不误判为补漏名单" bash -c "! grep -q '推断：在 45 个补漏域名名单里' \"$TEST_ETC/tgt-notds.out\""
cnblock_test www.gov.cn > "$TEST_ETC/tgt-gov.out" 2>&1
assert "单目标 gov.cn 推断 .cn 域名" grep -q '推断：.cn 域名' "$TEST_ETC/tgt-gov.out"
cnblock_test 223.5.5.5 > "$TEST_ETC/tgt-ip.out" 2>&1
assert "单目标 IP 字面量动作为 BLOCK" grep -q 'Action: BLOCK' "$TEST_ETC/tgt-ip.out"
assert "单目标 IP 字面量解析 IP 即自身" grep -q 'Resolved IP: 223.5.5.5' "$TEST_ETC/tgt-ip.out"
assert "单目标 IP 字面量推断 IP 层命中" grep -q '推断：IP 字面量被拒，推断 IP 层命中' "$TEST_ETC/tgt-ip.out"
cnblock_test www.google.com > "$TEST_ETC/tgt-gg.out" 2>&1
assert "单目标 google 动作为 ALLOW" grep -q 'Action: ALLOW' "$TEST_ETC/tgt-gg.out"
assert "单目标 google 推断未命中规则" grep -q '推断：未命中任何拦截规则' "$TEST_ETC/tgt-gg.out"
# 单目标：无 SOCKS5 时返回非 0
reset_env
cnblock_enable >/dev/null 2>&1
SERVICE_ACTIVE=1
cnblock_test www.baidu.com >/dev/null 2>&1; trc=$?
assert "单目标无 SOCKS5 时返回非 0" bash -c "[[ $trc -ne 0 ]]"
reset_env

# ---------- 8. TUI 与 CLI 接线静态检查 ----------
assert "菜单有更新规则集入口" bash -c "grep -q '更新规则集' protocols/cnblock/cnblock.sh"
assert "菜单有快速测试入口" bash -c "grep -q '快速测试' protocols/cnblock/cnblock.sh"
assert "菜单有诊断入口" bash -c "grep -q '诊断|健康检查与建议' protocols/cnblock/cnblock.sh"
assert "菜单 DEGRADED pill 文案" bash -c "grep -q '已开启·规则集过期' protocols/cnblock/cnblock.sh"
assert "菜单分发 update" bash -c "grep -q '3/u) cnblock_update' protocols/cnblock/cnblock.sh"
assert "菜单分发 test" bash -c "grep -q '4/t) cnblock_test' protocols/cnblock/cnblock.sh"
assert "菜单分发 doctor" bash -c "grep -q '5/o) cnblock_doctor' protocols/cnblock/cnblock.sh"
assert "主菜单 12/c 标签仍为CN 出站拦截" bash -c "grep -q '12/c|CN 出站拦截' sbx.sh"
assert "cnblock_update 函数存在" declare -F cnblock_update
assert "cnblock_test 函数存在" declare -F cnblock_test
assert "cnblock_doctor 函数存在" declare -F cnblock_doctor

rm -rf "$TEST_ETC"
if [[ $fail -eq 0 ]]; then
    echo "PASS: CN Egress Guard 更新、状态分级、诊断、实测、IPv6 探针"
else
    echo "FAIL: CN Egress Guard 测试有失败项"
    exit 1
fi
