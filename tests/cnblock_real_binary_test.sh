#!/usr/bin/env bash
export SBX_STYLE="${SBX_STYLE:-boxed}"   # 旧版测试断言边框样式；默认样式为 clean
# tests/cnblock_real_binary_test.sh — CN 拦截 block 出站修复的真实内核验证
#
# 背景（2026-11-28 DediOne 实测）：base.json 只有 direct 出站，旧版
# cnblock_enable 只插 3 条 outbound: "block" 的规则，开启失败，
# FATAL[0000] initialize router: rule[1]: outbound not found: block。
# v1.10.2 修复：enable 在同一事务里先补 {type: "block", tag: "block"} 出站。
#
# 注意（2026-11-28 沙箱实测）：sing-box 1.14.4 的 check 不校验路由规则
# 的出站引用，check 恒过；失败发生在流量命中规则时——无 block 出站时
# 每条命中连接报 router: outbound not found: block；DediOne 的版本则在
# 启动/校验时就 FATAL。根因相同（缺 block 出站），只是报错时机因版本而异。
# 因此本文件用真实流量验证（经 SOCKS 入站打国内 IP），而非只看 check：
#   0. 负向对照：3 条规则、无 block 出站 → 打 223.5.5.5，日志含
#      outbound not found: block（复现 DediOne 故障模式）。
#   1. 从无 block 出站的 base.json 出发跑 cnblock_enable，返回 0。
#   2. 配置里恰好 1 个 block 出站，3 条 block 规则，顺序 sniff→direct→block×3。
#   3. 真实 sing-box check 通过；真实 run 正常启动（sing-box started）。
#   4. 流量验证：打 223.5.5.5 被 block 出站拦截（blocked connection），
#      日志无 outbound not found；打 google 走 direct 出站；打
#      www.gstatic.com/generate_204 走 direct 出站（放行规则生效）。
#   5. 后加一条 direct 规则，block 规则仍在其前（sniff 之后、分流之前）。
#   6. 重复 enable 幂等：block 出站仍 1 个，规则仍 3 条；关闭后出站保留。
#   7. （v1.10.3）放行规则：enable 后恰好 1 条、在 block 规则之前；真实流量
#      www.gstatic.com/generate_204 经代理返回 204（走 direct 出站），
#      国内 IP 仍被 block 拦截；重复开启幂等；关闭后放行规则与 block 规则
#      均移除、出站保留。
#
# 沙箱限制（2026-11-28 实测）：沙箱出站只走 HTTP 代理，sing-box direct
# 出站的 TCP 能建连（日志有 outbound connection），但 TLS 会被出站代理
# 重置——经代理打 google.com 与 gstatic 均返回 000，而沙箱直连 gstatic
# 是 204。因此 gstatic 的 204 返回码断言以 google 对照站为门控：对照站
# 经代理也不通时 SKIP 该条（环境无法完成 HTTPS），只认路由日志（direct
# 出站、无 block）为放行证据；真机上对照站通时正常断言 204。
#
# 真实二进制缺失（/tmp/sb_test/sing-box-1.14.4-linux-amd64/sing-box）
# 或真实规则集文件缺失且无法下载时，整文件 SKIP（返回 0），不算失败。
# 真实规则集来源：/tmp/sb_test/*.srs（有则直接用），否则现从 SagerNet
# 官方 URL 下载；下载失败则 SKIP。
set -u
cd "$(dirname "$0")/.." || exit 1
APP_HOME="$PWD"
export APP_HOME

REAL_SB="${SB_BIN:-/tmp/sb_test/sing-box-1.14.4-linux-amd64/sing-box}"
if [[ ! -x "$REAL_SB" ]]; then
    echo "SKIP: 未找到真实 sing-box 二进制 ($REAL_SB)"
    exit 0
fi
echo "真实 sing-box：$("$REAL_SB" version 2>/dev/null | head -1)"

REAL_SRS_DIR="/tmp/sb_test"
GEOSITE_SRS="$REAL_SRS_DIR/geosite-cn.srs"
GEOIP_SRS="$REAL_SRS_DIR/geoip-cn.srs"
_srs_ok() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    [[ $(stat -c %s "$f" 2>/dev/null || echo 0) -ge 10240 ]] || return 1
    [[ "$(head -c 4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')" == "53525301" ]]
}
if ! _srs_ok "$GEOSITE_SRS" || ! _srs_ok "$GEOIP_SRS"; then
    echo "真实规则集缺失，尝试下载……"
    if ! curl -sL --max-time 30 -o "$GEOSITE_SRS" https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs; then
        echo "SKIP: 无法下载 geosite-cn.srs"
        exit 0
    fi
    if ! curl -sL --max-time 30 -o "$GEOIP_SRS" https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs; then
        echo "SKIP: 无法下载 geoip-cn.srs"
        exit 0
    fi
    if ! _srs_ok "$GEOSITE_SRS" || ! _srs_ok "$GEOIP_SRS"; then
        echo "SKIP: 下载的规则集校验失败"
        exit 0
    fi
fi
echo "真实规则集：geosite-cn $(stat -c %s "$GEOSITE_SRS") 字节，geoip-cn $(stat -c %s "$GEOIP_SRS") 字节"

# 模拟环境（真实 SB_BIN，systemctl 与下载均为桩）
TEST_ETC=$(mktemp -d)
export SB_ETC="$TEST_ETC"
export SB_CONFIG="$TEST_ETC/config.json"
export SB_STATE="$TEST_ETC/state.json"
export SB_BIN="$REAL_SB"
# 基础配置：base.json + SOCKS 入站（流量验证用）+ info 日志（run 日志可观测）。
cp templates/base.json "$SB_CONFIG"
jq '.inbounds = [{type: "socks", tag: "socks-in", listen: "127.0.0.1", listen_port: 11880}] | .log.level = "info"' \
    "$SB_CONFIG" > "$TEST_ETC/base.tmp" && mv "$TEST_ETC/base.tmp" "$SB_CONFIG"

SERVICE_ACTIVE=0
systemctl() {
    case "$1" in
        is-active) [[ $SERVICE_ACTIVE -eq 1 ]] ;;
        restart|reload|enable) SERVICE_ACTIVE=1; return 0 ;;
        *) return 0 ;;
    esac
}
export -f systemctl

# shellcheck source=/dev/null
source core/env.sh
# env.sh 硬设路径，重新覆盖
export SB_ETC="$TEST_ETC" SB_CONFIG="$TEST_ETC/config.json" SB_STATE="$TEST_ETC/state.json" SB_BIN="$REAL_SB"
# shellcheck source=/dev/null
source core/state_manager.sh
# shellcheck source=/dev/null
source core/json_builder.sh
# shellcheck source=/dev/null
source protocols/cnblock/cnblock.sh

# 真实规则集已预置在 SB_ETC，ensure_dbs 跳过下载；万一触发下载，复制真实文件。
download_file() {
    local _url="$1" dest="$2"
    case "$dest" in
        *geosite-cn.srs) cp -f "$GEOSITE_SRS" "$dest" ;;
        *geoip-cn.srs) cp -f "$GEOIP_SRS" "$dest" ;;
        *) return 1 ;;
    esac
}

PASS=0
FAIL=0
assert() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        PASS=$((PASS + 1)); echo "PASS: $desc"
    else
        FAIL=$((FAIL + 1)); echo "FAIL: $desc"
    fi
}
block_outbound_count() {
    jq '[.outbounds[]? | select(.tag == "block" and .type == "block")] | length' "$SB_CONFIG"
}
cnblock_rule_count() {
    local extra_json
    extra_json=$(_cnblock_extra_domains_json)
    jq --argjson extra "$extra_json" "$_CNBLOCK_JQ_DEF [.route.rules[]? | select(is_cnblock)] | length" "$SB_CONFIG"
}
cnblock_exclude_count() {
    local excludes_json
    excludes_json=$(_cnblock_exclude_domains_json)
    # 注意：\$excludes 必须转义——双引号内不转义会被 bash 当变量展开，
    # set -u 下直接报 unbound variable（$excludes 是 jq 变量，不是 bash 变量）。
    jq --argjson excludes "$excludes_json" "$_CNBLOCK_JQ_DEF [.route.rules[]? | select(is_cnblock_exclude(\$excludes))] | length" "$SB_CONFIG"
}
# 跑真实 sing-box run，打一次流量，返回时服务已停；日志留在 $1。
# 另测 Karing 延迟检测地址 www.gstatic.com/generate_204 与对照站 google
# 的状态码，追加到日志（GSTATIC_CODE=204 为放行生效，000 为被误拦或
# 环境不通——见文件头沙箱限制说明，对照站用于区分两者）。
run_with_traffic() {   # <logfile>
    local log="$1"
    "$REAL_SB" run -c "$SB_CONFIG" > "$log" 2>&1 &
    local pid=$!
    sleep 2
    curl -s -o /dev/null --max-time 8 -x socks5h://127.0.0.1:11880 http://223.5.5.5/ || true
    # 注意：curl 连不上时 -w 本身就打印 000，不能再 || echo 000（会变成
    # 000000，门控判断出错）；失败时以 || true 兜底，空值由调用方默认 000。
    echo "GOOGLE_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -x socks5h://127.0.0.1:11880 https://www.google.com/ 2>/dev/null || true)" >> "$log"
    echo "GSTATIC_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -x socks5h://127.0.0.1:11880 https://www.gstatic.com/generate_204 2>/dev/null || true)" >> "$log"
    kill "$pid" 2>/dev/null || true
    sleep 1
}

init_state_file
cp -f "$GEOSITE_SRS" "$TEST_ETC/geosite-cn.srs"
cp -f "$GEOIP_SRS" "$TEST_ETC/geoip-cn.srs"
chmod 600 "$TEST_ETC/geosite-cn.srs" "$TEST_ETC/geoip-cn.srs"

# ---------- 0. 负向对照：复现 DediOne 故障模式 ----------
# 手工构造 3 条 block 规则 + 规则集条目、但无 block 出站的配置。
jq --arg g "$TEST_ETC/geosite-cn.srs" --arg p "$TEST_ETC/geoip-cn.srs" \
    '.route.rules = [{action: "sniff"}, {rule_set: "geosite-cn", outbound: "block"}, {rule_set: "geoip-cn", outbound: "block"}, {domain_suffix: ["deepseek.com"], outbound: "block"}]
     | .route.rule_set = [{type: "local", tag: "geosite-cn", format: "binary", path: $g}, {type: "local", tag: "geoip-cn", format: "binary", path: $p}]' \
    "$SB_CONFIG" > "$TEST_ETC/neg.json" && mv "$TEST_ETC/neg.json" "$SB_CONFIG"
run_with_traffic "$TEST_ETC/neg-run.log"
assert "负向对照：命中规则时日志报 outbound not found: block" grep -q 'outbound not found: block' "$TEST_ETC/neg-run.log"
assert "负向对照：国内 IP 未被 block 出站拦截" bash -c "! grep -q 'outbound/block\[block\]: blocked connection to 223.5.5.5:80' $TEST_ETC/neg-run.log"
# 恢复为 base.json + SOCKS 入站（无 block 出站、无规则），跑 enable。
cp templates/base.json "$SB_CONFIG"
jq '.inbounds = [{type: "socks", tag: "socks-in", listen: "127.0.0.1", listen_port: 11880}] | .log.level = "info"' \
    "$SB_CONFIG" > "$TEST_ETC/base.tmp" && mv "$TEST_ETC/base.tmp" "$SB_CONFIG"
assert "恢复后无 block 出站" bash -c "[[ $(block_outbound_count) -eq 0 ]]"

# ---------- 1-3. enable + 结构 + 真实 check/run ----------
cnblock_enable > "$TEST_ETC/enable.out" 2>&1; enable_rc=$?
assert "enable 返回 0" bash -c "[[ $enable_rc -eq 0 ]]"
assert "enable 后恰好 1 个 block 出站" bash -c "[[ $(block_outbound_count) -eq 1 ]]"
assert "enable 后 3 条 block 规则" bash -c "[[ $(cnblock_rule_count) -eq 3 ]]"
assert "顺序为 sniff→direct→block×3" jq -e '
    (.route.rules | map(.outbound // .action)) as $o
    | $o[0] == "sniff" and $o[1] == "direct" and $o[2] == "block" and $o[3] == "block" and $o[4] == "block"' "$SB_CONFIG"
assert "放行规则恰好 1 条（gstatic.com + cp.cloudflare.com）" bash -c "[[ $(cnblock_exclude_count) -eq 1 ]]"
assert "真实 sing-box check 通过" "$REAL_SB" check -c "$SB_CONFIG"
timeout 5 "$REAL_SB" run -c "$SB_CONFIG" > "$TEST_ETC/run.log" 2>&1 || true
assert "真实 sing-box run 无 FATAL" bash -c "! grep -qi 'FATAL' $TEST_ETC/run.log"
assert "真实 sing-box run 正常启动" grep -q 'sing-box started' "$TEST_ETC/run.log"
_cnblock_probe
assert "探针 block 出站为 ok" bash -c "[[ $CNBLOCK_P_OUTBOUND == ok ]]"
assert "探针放行规则为 ok" bash -c "[[ $CNBLOCK_P_EXCLUDE == ok ]]"
assert "探针 Guard 为 ACTIVE" bash -c "[[ $CNBLOCK_P_GUARD == ACTIVE ]]"

# ---------- 4. 流量验证：国内 IP 被拦，海外走 direct，检测地址放行 ----------
run_with_traffic "$TEST_ETC/pos-run.log"
assert "国内 IP 被 block 出站拦截" grep -q 'outbound/block\[block\]: blocked connection to 223.5.5.5:80' "$TEST_ETC/pos-run.log"
assert "拦截后日志无 outbound not found" bash -c "! grep -q 'outbound not found' $TEST_ETC/pos-run.log"
assert "海外流量走 direct 出站" grep -q 'outbound/direct\[direct\]: outbound connection to www.google.com:443' "$TEST_ETC/pos-run.log"
# gstatic 返回码断言以 google 对照站为门控（见文件头沙箱限制说明）：
# 对照站经代理也返回 000 时，环境本身完不成 HTTPS，SKIP 该条；
# 真机上对照站通时正常断言 204。路由日志（下一条）始终断言。
google_code=$(grep -o 'GOOGLE_CODE=[0-9]*' "$TEST_ETC/pos-run.log" | cut -d= -f2)
google_code=${google_code:-000}
if [[ "$google_code" != "000" ]]; then
    assert "Karing 检测地址 www.gstatic.com/generate_204 经代理返回 204" grep -q 'GSTATIC_CODE=204' "$TEST_ETC/pos-run.log"
else
    echo "SKIP: 对照站 google 经代理返回 000（沙箱直连 HTTPS 被拦截），gstatic 返回码无法验证；路由日志已证明走 direct（见下条）"
fi
assert "检测地址流量走 direct 出站（未被 geosite-cn 误拦）" grep -q 'outbound/direct\[direct\]: outbound connection to www.gstatic.com:443' "$TEST_ETC/pos-run.log"

# ---------- 5. 后加 direct 规则，block 仍在前 ----------
config_transaction '.route.rules = ((.route.rules // []) + [{domain_suffix: ["example.com"], outbound: "direct"}])' >/dev/null 2>&1
assert "后加规则后顺序 sniff→direct→block×3→direct" jq -e '
    (.route.rules | map(.outbound // .action)) as $o
    | $o[0] == "sniff" and $o[1] == "direct" and $o[2] == "block" and $o[3] == "block" and $o[4] == "block"
      and $o[5] == "direct"' "$SB_CONFIG"
assert "后加规则后真实 check 仍通过" "$REAL_SB" check -c "$SB_CONFIG"

# ---------- 6. 重复 enable 幂等 + 关闭保留出站 ----------
cnblock_enable >/dev/null 2>&1
assert "重复开启后仍为 1 个 block 出站" bash -c "[[ $(block_outbound_count) -eq 1 ]]"
assert "重复开启后仍为 3 条规则" bash -c "[[ $(cnblock_rule_count) -eq 3 ]]"
assert "重复开启后仍为 1 条放行规则" bash -c "[[ $(cnblock_exclude_count) -eq 1 ]]"
assert "重复开启后真实 check 仍通过" "$REAL_SB" check -c "$SB_CONFIG"
cnblock_disable >/dev/null 2>&1
assert "关闭后 block 出站保留" bash -c "[[ $(block_outbound_count) -eq 1 ]]"
assert "关闭后放行规则移除" bash -c "[[ $(cnblock_exclude_count) -eq 0 ]]"
assert "关闭后无 block 规则" bash -c "[[ $(cnblock_rule_count) -eq 0 ]]"
assert "关闭后真实 check 仍通过" "$REAL_SB" check -c "$SB_CONFIG"

rm -rf "$TEST_ETC"
echo ""
echo "CNBLOCK REAL BINARY TEST SUMMARY: PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
