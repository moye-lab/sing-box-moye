#!/usr/bin/env bash
export SBX_STYLE="${SBX_STYLE:-boxed}"   # 旧版测试断言边框样式；默认样式为 clean
# tests/cnblock_test.sh — CN 出站拦截单元测试
# 用法：bash tests/cnblock_test.sh
# 覆盖：开关幂等、WARP/自定义规则保留、状态与配置一致、规则集下载失败
#       干净 abort、锁不泄漏（含并发）、菜单/CLI 接线静态检查、拦截优先
#       于 WARP、补漏域名清单、升级重断言钩子、顺序错误检测。
# 注意：sing-box 与 systemctl 均为桩（fake_singbox 总是 check 通过）；
# 真实内核验证见 P2 手动验证（真 sing-box 1.14.4 + 真实 .srs 规则集），不在本文件。
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
export SB_ETC="$TEST_ETC" SB_CONFIG="$TEST_ETC/config.json" SB_STATE="$TEST_ETC/state.json" SB_BIN="$TEST_ETC/fake_singbox.sh"
# shellcheck source=/dev/null
source core/state_manager.sh
# shellcheck source=/dev/null
source core/json_builder.sh
# shellcheck source=/dev/null
source protocols/warp.sh
# shellcheck source=/dev/null
source protocols/cnblock/cnblock.sh

# 写一个“合格”的假规则集文件：SRS 魔数 + 20KB 填充（≥10KB 下限）。
write_fake_srs() { printf 'SRS\001' > "$1"; head -c 20000 /dev/zero >> "$1"; chmod 600 "$1"; }

# 模拟规则集下载：DOWNLOAD_MODE=ok 时写合格假文件，fail 时返回失败。
# DOWNLOAD_CALLS 记录调用次数（供“跳过已存在规则集”断言）。
DOWNLOAD_MODE="ok"
DOWNLOAD_CALLS=0
download_file() {
    local _url="$1" dest="$2"
    DOWNLOAD_CALLS=$((DOWNLOAD_CALLS + 1))
    if [[ "$DOWNLOAD_MODE" == "fail" ]]; then
        return 1
    fi
    write_fake_srs "$dest"
}

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

cnblock_rule_count() {
    local extra_json
    extra_json=$(_cnblock_extra_domains_json)
    jq --argjson extra "$extra_json" "$_CNBLOCK_JQ_DEF [.route.rules[]? | select(is_cnblock)] | length" "$SB_CONFIG"
}
cnblock_set_count() {
    jq '[.route.rule_set[]? | select(.tag == "geosite-cn" or .tag == "geoip-cn")] | length' "$SB_CONFIG"
}
bare_sniff_count() {
    jq '[.route.rules[]? | select(. == {action: "sniff"})] | length' "$SB_CONFIG"
}

init_state_file

# ---------- 1. 全新配置上开启 ----------
cnblock_enable >/dev/null 2>&1
assert "开启后有 3 条拦截规则" bash -c "[[ $(cnblock_rule_count) -eq 3 ]]"
assert "开启后有 2 条规则集条目" bash -c "[[ $(cnblock_set_count) -eq 2 ]]"
assert "开启后头部补裸 sniff" bash -c "[[ $(bare_sniff_count) -eq 1 ]]"
assert "sniff 在规则头部" jq -e '.route.rules[0] == {action: "sniff"}' "$SB_CONFIG"
assert "放行规则紧跟 sniff（gstatic.com、cp.cloudflare.com 走 direct）" jq -e '.route.rules[1] == {domain_suffix: ["gstatic.com", "cp.cloudflare.com"], outbound: "direct"}' "$SB_CONFIG"
assert "geosite 规则第三位" jq -e '.route.rules[2] == {rule_set: "geosite-cn", outbound: "block"}' "$SB_CONFIG"
assert "geoip 规则第四位" jq -e '.route.rules[3] == {rule_set: "geoip-cn", outbound: "block"}' "$SB_CONFIG"
assert "补漏域名规则第五位（45 个域名，含 deepseek.com）" jq -e '.route.rules[4].outbound == "block" and (.route.rules[4].domain_suffix | length == 45) and (.route.rules[4].domain_suffix | index("deepseek.com") != null) and (.route.rules[4].domain_suffix | index("svw-volkswagen.com") != null) and (.route.rules[4].domain_suffix | index("hongguoduanju.com") != null)' "$SB_CONFIG"
assert "geosite-cn 规则集条目正确（本地/二进制/绝对路径）" jq -e --arg p "$TEST_ETC/geosite-cn.srs" '.route.rule_set[] | select(.tag == "geosite-cn" and .type == "local" and .format == "binary" and .path == $p)' "$SB_CONFIG"
assert "geoip-cn 规则集条目正确（本地/二进制/绝对路径）" jq -e --arg p "$TEST_ETC/geoip-cn.srs" '.route.rule_set[] | select(.tag == "geoip-cn" and .type == "local" and .format == "binary" and .path == $p)' "$SB_CONFIG"
assert "状态记录 enabled=true" jq -e '.cnblock.enabled == true' "$SB_STATE"
assert "规则集文件已下载" bash -c "[[ -f $TEST_ETC/geoip-cn.srs && -f $TEST_ETC/geosite-cn.srs ]]"
cnblock_status >/dev/null 2>&1; st=$?
assert "开启后 status 返回 0" bash -c "[[ $st -eq 0 ]]"

# ---------- 2. 重复开启幂等 ----------
cnblock_enable >/dev/null 2>&1
assert "重复开启仍为 3 条规则" bash -c "[[ $(cnblock_rule_count) -eq 3 ]]"
assert "重复开启仍为 2 条规则集条目" bash -c "[[ $(cnblock_set_count) -eq 2 ]]"
assert "重复开启仍为 1 条裸 sniff" bash -c "[[ $(bare_sniff_count) -eq 1 ]]"

# ---------- 3. WARP 规则不受影响，且拦截规则插在 sniff 之后、WARP 之前 ----------
cnblock_disable >/dev/null 2>&1
apply_route_rules '["openai.com","google.com"]' "warp" >/dev/null 2>&1
assert "WARP 规则写入成功" jq -e '.route.rules[] | select(.outbound == "warp")' "$SB_CONFIG"
cnblock_enable >/dev/null 2>&1
assert "WARP 出站规则保留" jq -e '.route.rules[] | select(.outbound == "warp" and (.domain_suffix | length == 2))' "$SB_CONFIG"
assert "WARP resolve 规则保留" jq -e '.route.rules[] | select(.action == "resolve" and (.domain_suffix | length == 2))' "$SB_CONFIG"
assert "开启后顺序 sniff→direct→block→block→block→resolve→warp" jq -e '
    (.route.rules | map(.outbound // .action)) as $o
    | $o[0] == "sniff" and $o[1] == "direct" and $o[2] == "block" and $o[3] == "block" and $o[4] == "block"
      and $o[5] == "resolve" and $o[6] == "warp"' "$SB_CONFIG"

# ---------- 4. 用户自定义规则与自定义规则集保留 ----------
config_transaction '.route.rules = ((.route.rules // []) + [{domain_suffix: ["example.com"], outbound: "direct"}, {rule_set: "my-ads", outbound: "block"}]) | .route.rule_set = ((.route.rule_set // []) + [{type: "local", tag: "my-ads", format: "binary", path: $p}])' --arg p "$TEST_ETC/my-ads.srs" >/dev/null 2>&1
custom_before=$(jq -c '[.route.rules[]? | select(.domain_suffix == ["example.com"] or .rule_set == "my-ads")] + [.route.rule_set[]? | select(.tag == "my-ads")]' "$SB_CONFIG")
cnblock_disable >/dev/null 2>&1
cnblock_enable >/dev/null 2>&1
cnblock_disable >/dev/null 2>&1
custom_after=$(jq -c '[.route.rules[]? | select(.domain_suffix == ["example.com"] or .rule_set == "my-ads")] + [.route.rule_set[]? | select(.tag == "my-ads")]' "$SB_CONFIG")
assert "开关两次后自定义规则与规则集原样保留" test "$custom_before" = "$custom_after"
assert "自定义的 my-ads block 规则未被误删" jq -e '.route.rules[] | select(.rule_set == "my-ads" and .outbound == "block")' "$SB_CONFIG"
assert "自定义的 my-ads 规则集条目未被误删" jq -e '.route.rule_set[] | select(.tag == "my-ads")' "$SB_CONFIG"
assert "WARP 规则在开关后仍保留" jq -e '.route.rules[] | select(.outbound == "warp")' "$SB_CONFIG"

# ---------- 5. 关闭：规则与本功能规则集条目移除，.srs 文件保留 ----------
cnblock_enable >/dev/null 2>&1
cnblock_disable >/dev/null 2>&1
assert "关闭后无拦截规则" bash -c "[[ $(cnblock_rule_count) -eq 0 ]]"
assert "关闭后无本功能规则集条目" bash -c "[[ $(cnblock_set_count) -eq 0 ]]"
assert "关闭后自定义规则集条目仍保留" jq -e '.route.rule_set[] | select(.tag == "my-ads")' "$SB_CONFIG"
assert "关闭后 .srs 文件保留在磁盘" bash -c "[[ -f $TEST_ETC/geoip-cn.srs && -f $TEST_ETC/geosite-cn.srs ]]"
assert "状态记录 enabled=false" jq -e '.cnblock.enabled == false' "$SB_STATE"
cnblock_status >/dev/null 2>&1; st=$?
assert "关闭后 status 返回 1" bash -c "[[ $st -eq 1 ]]"

# ---------- 6. 重复关闭幂等 ----------
cnblock_disable >/dev/null 2>&1
assert "重复关闭仍无拦截规则" bash -c "[[ $(cnblock_rule_count) -eq 0 ]]"

# ---------- 7. 无自定义规则集时关闭后 rule_set 为空 ----------
config_transaction '.route.rules = ((.route.rules // []) | map(select(.rule_set != "my-ads"))) | .route.rule_set = ((.route.rule_set // []) | map(select(.tag != "my-ads")))' >/dev/null 2>&1
cnblock_enable >/dev/null 2>&1
cnblock_disable >/dev/null 2>&1
assert "无自定义规则集时关闭后 rule_set 为空" jq -e '[.route.rule_set[]?] | length == 0' "$SB_CONFIG"

# ---------- 8. 规则集下载失败：干净 abort，配置与状态不动 ----------
rm -f "$TEST_ETC/geoip-cn.srs" "$TEST_ETC/geosite-cn.srs"
cfg_before=$(md5sum "$SB_CONFIG" | cut -d' ' -f1)
state_before=$(md5sum "$SB_STATE" | cut -d' ' -f1)
DOWNLOAD_MODE="fail"
cnblock_enable >/dev/null 2>&1
enable_rc=$?
DOWNLOAD_MODE="ok"
cfg_after=$(md5sum "$SB_CONFIG" | cut -d' ' -f1)
state_after=$(md5sum "$SB_STATE" | cut -d' ' -f1)
assert "下载失败时 enable 返回非 0" bash -c "[[ $enable_rc -ne 0 ]]"
assert "下载失败时配置未改动" bash -c "[[ \"$cfg_before\" == \"$cfg_after\" ]]"
assert "下载失败时状态未改动" bash -c "[[ \"$state_before\" == \"$state_after\" ]]"
assert "下载失败时无拦截规则" bash -c "[[ $(cnblock_rule_count) -eq 0 ]]"

# ---------- 9. 已存在合格规则集时跳过下载；不合格文件触发重下 ----------
write_fake_srs "$TEST_ETC/geoip-cn.srs"
write_fake_srs "$TEST_ETC/geosite-cn.srs"
DOWNLOAD_MODE="fail"
DOWNLOAD_CALLS=0
cnblock_enable >/dev/null 2>&1
enable_rc=$?
DOWNLOAD_MODE="ok"
assert "规则集已存在时下载失败也不影响开启" bash -c "[[ $enable_rc -eq 0 ]]"
assert "规则集已存在时未调用下载" bash -c "[[ $DOWNLOAD_CALLS -eq 0 ]]"
assert "跳过下载后规则正常写入" bash -c "[[ $(cnblock_rule_count) -eq 3 ]]"
cnblock_disable >/dev/null 2>&1
# 不合格文件（无 SRS 魔数）不被当作已存在：开启时必须重下，重下失败则 abort
head -c 1048576 /dev/zero > "$TEST_ETC/geosite-cn.srs"
DOWNLOAD_MODE="fail"
DOWNLOAD_CALLS=0
cnblock_enable >/dev/null 2>&1
enable_rc=$?
DOWNLOAD_MODE="ok"
assert "无魔数文件触发重新下载" bash -c "[[ $DOWNLOAD_CALLS -gt 0 ]]"
assert "重下载失败时 enable 返回非 0" bash -c "[[ $enable_rc -ne 0 ]]"
assert "重下载失败时无拦截规则" bash -c "[[ $(cnblock_rule_count) -eq 0 ]]"

# ---------- 10. 部分规则 / 规则集缺失时 status 返回 2 ----------
config_transaction '.route.rules = ([{action: "sniff"}, {rule_set: "geosite-cn", outbound: "block"}] + (.route.rules // [] | map(select(. != {action: "sniff"})))) | .route.rule_set = [{type: "local", tag: "geosite-cn", format: "binary", path: $g}]' --arg g "$TEST_ETC/geosite-cn.srs" >/dev/null 2>&1
cnblock_status >/dev/null 2>&1; st=$?
assert "只有 1 条规则时 status 返回 2" bash -c "[[ $st -eq 2 ]]"
cnblock_disable >/dev/null 2>&1
cnblock_enable >/dev/null 2>&1
rm -f "$TEST_ETC/geoip-cn.srs"
cnblock_status >/dev/null 2>&1; st=$?
assert "规则齐全但规则集缺失时 status 返回 2" bash -c "[[ $st -eq 2 ]]"
cnblock_disable >/dev/null 2>&1

# ---------- 11. 锁不泄漏：同进程内 enable 后锁已释放 ----------
cnblock_enable >/dev/null 2>&1
assert "enable 返回后状态锁已释放（子进程可立即获取）" flock -n "${SB_STATE}.lock" true
assert "enable 返回后配置锁已释放（子进程可立即获取）" flock -n "${SB_CONFIG}.lock" true
cnblock_disable >/dev/null 2>&1
assert "disable 返回后状态锁已释放" flock -n "${SB_STATE}.lock" true

# ---------- 12. 并发调用：两个进程交替开关，均成功且无 10 秒阻塞 ----------
cat > "$TEST_ETC/driver.sh" <<'DRIVEREOF'
#!/usr/bin/env bash
set -u
TETC="$1"; ROOT="$2"
export SB_ETC="$TETC" SB_CONFIG="$TETC/config.json" SB_STATE="$TETC/state.json" SB_BIN="$TETC/fake_singbox.sh"
export APP_HOME="$ROOT"
export SB_CERT_DIR="$TETC/certs" SB_EXPORT_DIR="$TETC/export"
# shellcheck source=/dev/null
source "$ROOT/core/env.sh"
export SB_ETC="$TETC" SB_CONFIG="$TETC/config.json" SB_STATE="$TETC/state.json" SB_BIN="$TETC/fake_singbox.sh"
export SB_CERT_DIR="$TETC/certs" SB_EXPORT_DIR="$TETC/export"
# shellcheck source=/dev/null
source "$ROOT/core/state_manager.sh"
# shellcheck source=/dev/null
source "$ROOT/core/json_builder.sh"
# shellcheck source=/dev/null
source "$ROOT/protocols/cnblock/cnblock.sh"
systemctl() {
    case "$1" in
        is-active) return 0 ;;
        *) return 0 ;;
    esac
}
download_file() {
    printf 'SRS\001' > "$2"; head -c 20000 /dev/zero >> "$2"; chmod 600 "$2"
}
rc=0
cnblock_enable >/dev/null 2>&1 || rc=1
cnblock_disable >/dev/null 2>&1 || rc=1
cnblock_enable >/dev/null 2>&1 || rc=1
exit "$rc"
DRIVEREOF
chmod +x "$TEST_ETC/driver.sh"
conc_start=$(date +%s)
bash "$TEST_ETC/driver.sh" "$TEST_ETC" "$APP_HOME" > "$TEST_ETC/driver1.log" 2>&1 &
d1=$!
bash "$TEST_ETC/driver.sh" "$TEST_ETC" "$APP_HOME" > "$TEST_ETC/driver2.log" 2>&1 &
d2=$!
wait "$d1"; rc1=$?
wait "$d2"; rc2=$?
conc_elapsed=$(( $(date +%s) - conc_start ))
assert "并发进程 1 开关成功" bash -c "[[ $rc1 -eq 0 ]]"
assert "并发进程 2 开关成功" bash -c "[[ $rc2 -eq 0 ]]"
assert "并发总耗时 < 30 秒（无锁泄漏导致的 10 秒阻塞）" bash -c "[[ $conc_elapsed -lt 30 ]]"
assert "并发后无锁超时报错" bash -c "! grep -q '获取.*锁超时' $TEST_ETC/driver1.log $TEST_ETC/driver2.log"
assert "并发后配置仍为合法 JSON" jq -e . "$SB_CONFIG"
assert "并发后拦截规则不多于 3 条" bash -c "[[ $(cnblock_rule_count) -le 3 ]]"
assert "并发后规则集条目不多于 2 条" bash -c "[[ $(cnblock_set_count) -le 2 ]]"
assert "并发后裸 sniff 不多于 1 条" bash -c "[[ $(bare_sniff_count) -le 1 ]]"
# 并发后最终状态应为开启（两个进程都以 enable 收尾）
cnblock_disable >/dev/null 2>&1

# ---------- 13. 配置中无自定义标记字段 ----------
cnblock_enable >/dev/null 2>&1
assert "规则中无 sbx_/cnblock_ 自定义字段" jq -e '[.route.rules[]? | keys[] | select(test("^(sbx|cnblock)_"))] | length == 0' "$SB_CONFIG"
assert "规则集条目中无 sbx_/cnblock_ 自定义字段" jq -e '[.route.rule_set[]? | keys[] | select(test("^(sbx|cnblock)_"))] | length == 0' "$SB_CONFIG"
cnblock_disable >/dev/null 2>&1

# ---------- 14. 菜单 / CLI 接线静态检查 ----------
assert "sbx.sh 加载 cnblock.sh" bash -c "grep -q 'protocols/cnblock/cnblock.sh' sbx.sh"
assert "主菜单有 12/c 入口" bash -c "grep -q '\"12/c\"' sbx.sh"
assert "主菜单 dispatch 有 12/c 分发" bash -c "grep -q '12|c|C) menu_cnblock' sbx.sh"
assert "CLI 有 cnblock 分发" bash -c "grep -q 'cnblock|c)' sbx.sh"
assert "CLI 有 cnblock update 分发" bash -c "grep -q 'update) cnblock_update' sbx.sh"
assert "CLI 有 cnblock test 分发" bash -c "grep -q 'test) cnblock_test' sbx.sh"
assert "CLI 有 cnblock doctor 分发" bash -c "grep -q 'doctor) cnblock_doctor' sbx.sh"
assert "诊断含 CN-BLOCK 检查" bash -c "grep -q 'CN-BLOCK' sbx.sh"
assert "menu_cnblock 函数存在" declare -F menu_cnblock

# ---------- 15. 默认关闭（v1.8.2 起 D1 移除，开源项目只提供选择） ----------
# reset_cnblock_env 被 16 节及之后复用：重置配置/状态/规则集，不留任何标记。
pause() { :; }  # 重断言钩子里的 pause 在测试中为空操作
reset_cnblock_env() {
    cp templates/base.json "$SB_CONFIG"
    rm -f "$SB_STATE" "$SB_ETC/geosite-cn.srs" "$SB_ETC/geoip-cn.srs"
    DOWNLOAD_MODE="ok"
}

# 静态检查：默认开启机制已彻底移除
assert "install.sh 不写默认开启标记" bash -c "! grep -q 'cnblock-default-on' install.sh"
assert "主菜单不调用默认开启钩子" bash -c "! grep -q 'cnblock_maybe_enable_default' sbx.sh"
assert "cnblock.sh 不定义默认开启钩子" bash -c "! grep -q 'cnblock_maybe_enable_default' protocols/cnblock/cnblock.sh"
assert "重断言钩子仍在（别把该留的也删了）" bash -c "grep -q 'cnblock_maybe_reassert' sbx.sh && grep -q 'cnblock_maybe_reassert' protocols/cnblock/cnblock.sh"

# 行为检查：全新安装状态下没有任何自动开启
reset_cnblock_env
assert "全新安装后拦截规则为 0 条" bash -c "[[ $(cnblock_rule_count) -eq 0 ]]"
assert "全新安装后无默认开启标记残留" bash -c "[[ ! -f $SB_ETC/.cnblock-default-on ]]"

# ---------- 16. verify 第 3 层：高风险国内站点逐个实测 ----------
# 桩 curl：拦截生效时国内站返回 000、对照站返回 200；FAKE_CURL_MODE=open
# 时全部返回 200（模拟拦截失效）。timeout 走真实命令，经 PATH 找到桩 curl。
mkdir -p "$TEST_ETC/bin"
cat > "$TEST_ETC/bin/curl" <<'CURLEOF'
#!/usr/bin/env bash
url="${@: -1}"
if [[ "${FAKE_CURL_MODE:-block}" == "open" ]]; then echo 200; exit 0; fi
case "$url" in
  *google.com*|*cloudflare.com*) echo 200 ;;
  *) echo 000 ;;
esac
CURLEOF
chmod +x "$TEST_ETC/bin/curl"
# 桩 ip：默认无全局 IPv6（FAKE_IP6=1 时输出一个全局地址），让 verify 的
# IPv6 探针是否运行不依赖测试机真实网络，汇总计数确定。
cat > "$TEST_ETC/bin/ip" <<'IPEOF'
#!/usr/bin/env bash
if [[ "$*" == *"-6 addr show scope global"* ]] && [[ "${FAKE_IP6:-0}" == "1" ]]; then
    echo "    inet6 2400:3200::1/64 scope global"
fi
exit 0
IPEOF
chmod +x "$TEST_ETC/bin/ip"
export PATH="$TEST_ETC/bin:$PATH"
DOWNLOAD_MODE="ok"
cnblock_enable >/dev/null 2>&1
jq '.protocols.socks5 = {port: 12345, username: "u", password: "p"}' "$SB_STATE" > "$TEST_ETC/state.tmp" && mv "$TEST_ETC/state.tmp" "$SB_STATE"
SERVICE_ACTIVE=1
cnblock_verify > "$TEST_ETC/verify.out" 2>&1; verify_rc=$?
assert "verify 全过时返回 0" bash -c "[[ $verify_rc -eq 0 ]]"
assert "verify 逐个列出 gov.cn 被拒" grep -q 'www.gov.cn 被拒绝' "$TEST_ETC/verify.out"
assert "verify 逐个列出 miit.gov.cn 被拒" grep -q 'www.miit.gov.cn 被拒绝' "$TEST_ETC/verify.out"
assert "verify 逐个列出 12306 被拒" grep -q 'kyfw.12306.cn 被拒绝' "$TEST_ETC/verify.out"
assert "verify 逐个列出支付宝被拒" grep -q 'www.alipay.com 被拒绝' "$TEST_ETC/verify.out"
assert "verify 逐个列出微信域名被拒" grep -q 'weixin.qq.com 被拒绝' "$TEST_ETC/verify.out"
assert "verify 逐个列出公安部域名被拒" grep -q 'www.mps.gov.cn 被拒绝' "$TEST_ETC/verify.out"
assert "verify 逐个列出央行域名被拒" grep -q 'www.pbc.gov.cn 被拒绝' "$TEST_ETC/verify.out"
assert "verify 列出国内 IP 字面量被拒" grep -q '223.5.5.5（国内 IP）被拒绝' "$TEST_ETC/verify.out"
assert "verify 逐个列出 DeepSeek 被拒" grep -q 'www.deepseek.com 被拒绝' "$TEST_ETC/verify.out"
assert "verify 逐个列出上汽大众被拒" grep -q 'www.svw-volkswagen.com 被拒绝' "$TEST_ETC/verify.out"
assert "verify 逐个列出红果短剧被拒" grep -q 'www.hongguoduanju.com 被拒绝' "$TEST_ETC/verify.out"
assert "verify 列出对照站正常" grep -q 'www.cloudflare.com 正常' "$TEST_ETC/verify.out"
assert "verify 汇总国内 25/25 被拒、对照 2/2 正常" grep -q '国内 25/25 被拒，对照 2/2 正常' "$TEST_ETC/verify.out"
assert "无 IPv6 时 verify 提示跳过 IPv6 探针" grep -q '无全局 IPv6' "$TEST_ETC/verify.out"
# 有全局 IPv6 时 verify 测 IPv6 探针，国内目标 25 → 26 个。
FAKE_IP6=1 cnblock_verify > "$TEST_ETC/verify-v6.out" 2>&1; verify_rc=$?
assert "有 IPv6 时 verify 返回 0" bash -c "[[ $verify_rc -eq 0 ]]"
assert "有 IPv6 时 verify 列出 IPv6 探针被拒" grep -q '2400:3200::1（国内 IPv6）被拒绝' "$TEST_ETC/verify-v6.out"
assert "有 IPv6 时 verify 汇总国内 26/26 被拒" grep -q '国内 26/26 被拒，对照 2/2 正常' "$TEST_ETC/verify-v6.out"
# 拦截失效（全部 200）时 verify 必须失败，并点名未被拦截的域名。
FAKE_CURL_MODE=open cnblock_verify > "$TEST_ETC/verify-open.out" 2>&1; verify_rc=$?
assert "拦截失效时 verify 返回非 0" bash -c "[[ $verify_rc -ne 0 ]]"
assert "拦截失效时点名 gov.cn 未被拦截" grep -q 'www.gov.cn 返回 200' "$TEST_ETC/verify-open.out"
# 服务未运行时第 3 层跳过、不记失败（既有语义：只做前两层判定）。
SERVICE_ACTIVE=0
cnblock_verify > "$TEST_ETC/verify-down.out" 2>&1; verify_rc=$?
assert "服务未运行时 verify 仍返回 0（跳过实测）" bash -c "[[ $verify_rc -eq 0 ]]"
assert "服务未运行时提示无法验证实际流量" grep -q '服务未运行' "$TEST_ETC/verify-down.out"
SERVICE_ACTIVE=1

# ---------- 17. 状态记录探针：false 不得误报为 unset ----------
# （2026-11-22 RN 实测 bug：'.cnblock.enabled // empty' 把 false 当缺失，
# 关闭后状态记录显示 unset 而非 disabled。）
reset_cnblock_env
cnblock_enable >/dev/null 2>&1
_cnblock_probe
assert "开启后探针状态为 enabled" bash -c "[[ $CNBLOCK_P_STATE == enabled ]]"
cnblock_disable >/dev/null 2>&1
_cnblock_probe
assert "关闭后探针状态为 disabled（非 unset）" bash -c "[[ $CNBLOCK_P_STATE == disabled ]]"
cnblock_status > "$TEST_ETC/status.out" 2>&1
assert "关闭后 status 显示状态记录 disabled" grep -q "状态记录：disabled" "$TEST_ETC/status.out"
reset_cnblock_env
_cnblock_probe
assert "全新状态探针为 unset" bash -c "[[ $CNBLOCK_P_STATE == unset ]]"
# 过期记录告警：规则已无但记录为 enabled → status 返回 2
reset_cnblock_env
cnblock_enable >/dev/null 2>&1
jq '.route.rules = [] | .route.rule_set = []' "$SB_CONFIG" > "$TEST_ETC/cfg.tmp" && mv "$TEST_ETC/cfg.tmp" "$SB_CONFIG"
cnblock_status >/dev/null 2>&1; _rc=$?
assert "规则已无但记录 enabled 时 status 返回 2" bash -c "[[ $_rc -eq 2 ]]"
# 过期记录告警：规则在但记录为 disabled → status 返回 2
reset_cnblock_env
cnblock_enable >/dev/null 2>&1
_cnblock_write_state false
cnblock_status >/dev/null 2>&1; _rc=$?
assert "规则在但记录 disabled 时 status 返回 2" bash -c "[[ $_rc -eq 2 ]]"
# ---------- 18. WARP 写入后拦截仍在前（v1.8.2 拦截优先） ----------
# 2026-11-22 RN 实测：WARP 规则写在拦截之前导致 deepseek.com 漏网。
reset_cnblock_env
cnblock_enable >/dev/null 2>&1
apply_route_rules '["openai.com","google.com"]' "warp" >/dev/null 2>&1
assert "WARP 后写时顺序仍为 sniff→direct→block×3→resolve→warp" jq -e '
    (.route.rules | map(.outbound // .action)) as $o
    | $o[0] == "sniff" and $o[1] == "direct" and $o[2] == "block" and $o[3] == "block" and $o[4] == "block"
      and $o[5] == "resolve" and $o[6] == "warp"' "$SB_CONFIG"
_cnblock_probe
assert "WARP 后写时探针顺序为 ok" bash -c "[[ $CNBLOCK_P_ORDER == ok ]]"
apply_route_rules '["claude.ai"]' "warp" >/dev/null 2>&1
assert "WARP 更新域名后拦截仍在前" jq -e '
    (.route.rules | map(.outbound // .action)) as $o
    | $o[1] == "direct" and $o[2] == "block" and $o[3] == "block" and $o[4] == "block"
      and $o[5] == "resolve" and $o[6] == "warp"' "$SB_CONFIG"
cnblock_disable >/dev/null 2>&1
apply_route_rules '["openai.com"]' "warp" >/dev/null 2>&1
assert "无拦截时 WARP 规则保持旧行为（头部三条）" jq -e '
    (.route.rules | map(.outbound // .action)) as $o
    | $o[0] == "sniff" and $o[1] == "resolve" and $o[2] == "warp"' "$SB_CONFIG"

# ---------- 19. 升级重断言钩子（v1.8.2） ----------
# 模拟旧版配置：2 条规则（无补漏规则），且 WARP 规则在拦截之前。
reset_cnblock_env
: > "$SB_ETC/.cnblock-reassert"
CNBLOCK_REASSERT_TRIED=0
apply_route_rules '["openai.com"]' "warp" >/dev/null 2>&1
config_transaction '.route.rules = (.route.rules + [{rule_set: "geosite-cn", outbound: "block"}, {rule_set: "geoip-cn", outbound: "block"}]) | .route.rule_set = [{type: "local", tag: "geosite-cn", format: "binary", path: $g}, {type: "local", tag: "geoip-cn", format: "binary", path: $p}]' --arg g "$TEST_ETC/geosite-cn.srs" --arg p "$TEST_ETC/geoip-cn.srs" >/dev/null 2>&1
write_fake_srs "$TEST_ETC/geoip-cn.srs"
write_fake_srs "$TEST_ETC/geosite-cn.srs"
_cnblock_probe
assert "旧版模拟：探针顺序为 wrong" bash -c "[[ $CNBLOCK_P_ORDER == wrong ]]"
assert "旧版模拟：规则为 2 条" bash -c "[[ $(cnblock_rule_count) -eq 2 ]]"
cnblock_maybe_reassert >/dev/null 2>&1
assert "重断言后规则为 3 条" bash -c "[[ $(cnblock_rule_count) -eq 3 ]]"
_cnblock_probe
assert "重断言后顺序修正" bash -c "[[ $CNBLOCK_P_ORDER == ok ]]"
assert "重断言后标记被删除" bash -c "[[ ! -f $SB_ETC/.cnblock-reassert ]]"
assert "重断言后顺序 sniff→direct→block×3→resolve→warp" jq -e '
    (.route.rules | map(.outbound // .action)) as $o
    | $o[0] == "sniff" and $o[1] == "direct" and $o[2] == "block" and $o[3] == "block" and $o[4] == "block"
      and $o[5] == "resolve" and $o[6] == "warp"' "$SB_CONFIG"
CNBLOCK_REASSERT_TRIED=0
cnblock_maybe_reassert >/dev/null 2>&1
assert "无标记时重断言钩子不改配置" bash -c "[[ $(cnblock_rule_count) -eq 3 ]]"
assert "install.sh 在升级且拦截开启时写重断言标记" bash -c "grep -q 'cnblock-reassert' install.sh"
assert "主菜单循环调用重断言钩子" bash -c "grep -q 'cnblock_maybe_reassert' sbx.sh"

# 成功时静默（v1.8.3）：不输出、不 pause（拦截是辅助功能，不挡菜单入口）
# 此时规则已是新版 3 条（上一段刚修好），重建标记再触发一次即 RN 实测场景。
: > "$SB_ETC/.cnblock-reassert"
CNBLOCK_REASSERT_TRIED=0
PAUSE_CALLED=0
pause() { PAUSE_CALLED=1; }
cnblock_maybe_reassert >"$TEST_ETC/reassert.out" 2>&1
assert "重断言成功时无输出" bash -c "[[ ! -s $TEST_ETC/reassert.out ]]"
assert "重断言成功时不 pause" bash -c "[[ $PAUSE_CALLED -eq 0 ]]"
assert "静默重断言后标记被删除" bash -c "[[ ! -f $SB_ETC/.cnblock-reassert ]]"
pause() { :; }

# 失败时只警告、不 pause，标记保留
reset_cnblock_env
: > "$SB_ETC/.cnblock-reassert"
CNBLOCK_REASSERT_TRIED=0
DOWNLOAD_MODE="fail"
PAUSE_CALLED=0
pause() { PAUSE_CALLED=1; }
cnblock_maybe_reassert >"$TEST_ETC/reassert.out" 2>&1
assert "重断言失败时有警告" bash -c "grep -q '拦截规则更新失败' $TEST_ETC/reassert.out"
assert "重断言失败时不 pause" bash -c "[[ $PAUSE_CALLED -eq 0 ]]"
assert "重断言失败时标记保留" bash -c "[[ -f $SB_ETC/.cnblock-reassert ]]"
pause() { :; }
DOWNLOAD_MODE="ok"

# ---------- 20. 补漏域名清单自检 ----------
extra_count=$(printf '%s' "$CNBLOCK_EXTRA_DOMAINS" | wc -w)
extra_dupes=$(printf '%s\n' $CNBLOCK_EXTRA_DOMAINS | sort | uniq -d | wc -l)
extra_cn=$(printf '%s\n' $CNBLOCK_EXTRA_DOMAINS | grep -c '\.cn$' || true)
assert "补漏域名共 45 个" bash -c "[[ $extra_count -eq 45 ]]"
assert "补漏域名无重复" bash -c "[[ $extra_dupes -eq 0 ]]"
assert "补漏域名不含 .cn（已由规则集覆盖）" bash -c "[[ $extra_cn -eq 0 ]]"
_extra_has() { printf '%s' "$CNBLOCK_EXTRA_DOMAINS" | grep -q "$1"; }
assert "补漏域名含 deepseek.com" _extra_has deepseek.com
assert "补漏域名含 svw-volkswagen.com" _extra_has svw-volkswagen.com
assert "补漏域名含 hongguoduanju.com" _extra_has hongguoduanju.com
assert "补漏域名含 zj96596.com" _extra_has zj96596.com

# ---------- 21. 顺序错误时 status 返回 2，重新开启可修正 ----------
reset_cnblock_env
cnblock_enable >/dev/null 2>&1
config_transaction '.route.rules = ([{action: "sniff"}, {action: "resolve", domain_suffix: ["openai.com"], strategy: "prefer_ipv4"}, {domain_suffix: ["openai.com"], outbound: "warp"}] + (.route.rules // [] | map(select(. != {action: "sniff"}))))' >/dev/null 2>&1
cnblock_status >/dev/null 2>&1; _rc=$?
assert "顺序错误时 status 返回 2" bash -c "[[ $_rc -eq 2 ]]"
cnblock_enable >/dev/null 2>&1
_cnblock_probe
assert "重新开启后顺序修正" bash -c "[[ $CNBLOCK_P_ORDER == ok ]]"
cnblock_status >/dev/null 2>&1; _rc=$?
assert "顺序修正后 status 返回 0" bash -c "[[ $_rc -eq 0 ]]"
cnblock_disable >/dev/null 2>&1

# ---------- 22. block 出站自动补齐（v1.10.2，2026-11-28 DediOne 实测） ----------
# 根因：base.json 只有 direct 出站，旧版 enable 只插 3 条 block 规则，
# sing-box check 报 outbound not found: block，开启失败。修后 enable 在
# 同一事务里先补 block 出站；探针新增 CNBLOCK_P_OUTBOUND 检查。
reset_cnblock_env
block_outbound_count() {
    jq '[.outbounds[]? | select(.tag == "block" and .type == "block")] | length' "$SB_CONFIG"
}
assert "全新配置无 block 出站（DediOne 场景）" bash -c "[[ $(block_outbound_count) -eq 0 ]]"
cnblock_enable >/dev/null 2>&1; enable_rc=$?
assert "无 block 出站时 enable 返回 0" bash -c "[[ $enable_rc -eq 0 ]]"
assert "enable 后补齐 1 个 block 出站" bash -c "[[ $(block_outbound_count) -eq 1 ]]"
assert "enable 后 block 出站内容正确" jq -e '.outbounds[] | select(.tag == "block" and .type == "block")' "$SB_CONFIG"
assert "enable 后仍为 3 条 block 规则" bash -c "[[ $(cnblock_rule_count) -eq 3 ]]"
assert "enable 后 direct 出站保留" jq -e '.outbounds[] | select(.tag == "direct" and .type == "direct")' "$SB_CONFIG"
_cnblock_probe
assert "enable 后探针 block 出站为 ok" bash -c "[[ $CNBLOCK_P_OUTBOUND == ok ]]"
assert "enable 后探针 Guard 为 ACTIVE" bash -c "[[ $CNBLOCK_P_GUARD == ACTIVE ]]"
cnblock_status > "$TEST_ETC/status-block-out.out" 2>&1
assert "status 显示 block 出站已就绪" grep -q 'block 出站：已就绪' "$TEST_ETC/status-block-out.out"
# 重复开启幂等：block 出站不重复，规则仍 3 条。
cnblock_enable >/dev/null 2>&1
assert "重复开启后仍为 1 个 block 出站" bash -c "[[ $(block_outbound_count) -eq 1 ]]"
assert "重复开启后仍为 3 条规则" bash -c "[[ $(cnblock_rule_count) -eq 3 ]]"
# 手动删掉 block 出站（保留 3 条规则）：探针报 missing，Guard 为 FAILED。
jq 'del(.outbounds[] | select(.tag == "block"))' "$SB_CONFIG" > "$TEST_ETC/cfg.tmp" && mv "$TEST_ETC/cfg.tmp" "$SB_CONFIG"
_cnblock_probe
assert "删 block 出站后探针报 missing" bash -c "[[ $CNBLOCK_P_OUTBOUND == missing ]]"
assert "删 block 出站后 Guard 为 FAILED（非 ACTIVE）" bash -c "[[ $CNBLOCK_P_GUARD == FAILED ]]"
cnblock_status >/dev/null 2>&1; _rc=$?
assert "缺 block 出站时 status 返回 2" bash -c "[[ $_rc -eq 2 ]]"
cnblock_verify > "$TEST_ETC/verify-no-outbound.out" 2>&1; _rc=$?
assert "缺 block 出站时 verify 返回非 0" bash -c "[[ $_rc -ne 0 ]]"
assert "缺 block 出站时 verify 点名出站缺失" grep -q 'block 出站 missing' "$TEST_ETC/verify-no-outbound.out"
cnblock_doctor > "$TEST_ETC/doctor-no-outbound.out" 2>&1; _rc=$?
assert "缺 block 出站时 doctor 返回非 0" bash -c "[[ $_rc -ne 0 ]]"
assert "缺 block 出站时 doctor 提示重新开启补齐" grep -q 'block 出站缺失' "$TEST_ETC/doctor-no-outbound.out"
# 重新开启应自动补回出站，恢复 ACTIVE。
cnblock_enable >/dev/null 2>&1; enable_rc=$?
assert "缺出站时重跑 enable 返回 0" bash -c "[[ $enable_rc -eq 0 ]]"
assert "重跑 enable 后 block 出站补回 1 个" bash -c "[[ $(block_outbound_count) -eq 1 ]]"
_cnblock_probe
assert "补回后 Guard 恢复 ACTIVE" bash -c "[[ $CNBLOCK_P_GUARD == ACTIVE ]]"
# 关闭拦截：block 出站保留（留着无害，下次开启直接复用）。
cnblock_disable >/dev/null 2>&1
assert "关闭后 block 出站保留" bash -c "[[ $(block_outbound_count) -eq 1 ]]"
assert "关闭后无拦截规则" bash -c "[[ $(cnblock_rule_count) -eq 0 ]]"
_cnblock_probe
assert "关闭后探针 block 出站仍为 ok" bash -c "[[ $CNBLOCK_P_OUTBOUND == ok ]]"
assert "关闭后 Guard 为 DISABLED" bash -c "[[ $CNBLOCK_P_GUARD == DISABLED ]]"
# 关闭后再次开启：复用已有的 block 出站，不重复加。
cnblock_enable >/dev/null 2>&1
assert "复用已有出站时仍为 1 个 block 出站" bash -c "[[ $(block_outbound_count) -eq 1 ]]"
cnblock_disable >/dev/null 2>&1

# ---------- 23. 连通性检测放行规则（v1.10.3，2026-11-28 DediOne 实测） ----------
# 根因：geosite-cn 误含 www.gstatic.com（上游 v2fly @cn 标签问题），Karing
# 默认用 https://www.gstatic.com/generate_204 测延迟，拦截一开全员超时。
# 修后 enable 在 sniff 之后、3 条 block 规则之前插 1 条放行规则
# {domain_suffix: [gstatic.com, cp.cloudflare.com], outbound: "direct"}。
reset_cnblock_env
cnblock_exclude_count() {
    local excludes_json
    excludes_json=$(_cnblock_exclude_domains_json)
    # 注意：\$excludes 必须转义——双引号内不转义会被 bash 当变量展开，
    # set -u 下直接报 unbound variable（$excludes 是 jq 变量，不是 bash 变量）。
    jq --argjson excludes "$excludes_json" "$_CNBLOCK_JQ_DEF [.route.rules[]? | select(is_cnblock_exclude(\$excludes))] | length" "$SB_CONFIG"
}
assert "全新配置无放行规则" bash -c "[[ $(cnblock_exclude_count) -eq 0 ]]"
cnblock_enable >/dev/null 2>&1; enable_rc=$?
assert "干净配置上 enable 返回 0" bash -c "[[ $enable_rc -eq 0 ]]"
assert "enable 后恰好 1 条放行规则" bash -c "[[ $(cnblock_exclude_count) -eq 1 ]]"
assert "放行规则在 3 条 block 规则之前（下标 1，在 sniff 之后）" jq -e '
    (.route.rules | map(.outbound // .action)) as $o
    | $o[0] == "sniff" and $o[1] == "direct" and $o[2] == "block" and $o[3] == "block" and $o[4] == "block"' "$SB_CONFIG"
assert "放行规则内容为 gstatic.com + cp.cloudflare.com" jq -e '.route.rules[1] == {domain_suffix: ["gstatic.com", "cp.cloudflare.com"], outbound: "direct"}' "$SB_CONFIG"
assert "enable 后仍为 3 条 block 规则" bash -c "[[ $(cnblock_rule_count) -eq 3 ]]"
assert "放行规则不计入 3 条 block 规则" bash -c "[[ $(cnblock_rule_count) -eq 3 && $(cnblock_exclude_count) -eq 1 ]]"
_cnblock_probe
assert "enable 后探针放行规则为 ok" bash -c "[[ $CNBLOCK_P_EXCLUDE == ok ]]"
assert "enable 后探针 Guard 为 ACTIVE" bash -c "[[ $CNBLOCK_P_GUARD == ACTIVE ]]"
cnblock_status > "$TEST_ETC/status-exclude.out" 2>&1
assert "status 显示放行规则已就绪" grep -q '放行规则：已就绪' "$TEST_ETC/status-exclude.out"
assert "status 显示放行规则域名" grep -q 'gstatic.com、cp.cloudflare.com 走 direct' "$TEST_ETC/status-exclude.out"
_cnblock_menu_status
assert "菜单探针放行规则为已就绪" bash -c "[[ $CNBLOCK_M_EXCLUDE_TXT == 已就绪 ]]"
# WARP 写入后放行规则仍在 block 之前，顺序探针仍为 ok。
apply_route_rules '["openai.com","google.com"]' "warp" >/dev/null 2>&1
assert "WARP 写入后放行规则仍在 block 之前" jq -e '
    (.route.rules | map(.outbound // .action)) as $o
    | $o[0] == "sniff" and $o[1] == "direct" and $o[2] == "block" and $o[3] == "block" and $o[4] == "block"
      and $o[5] == "resolve" and $o[6] == "warp"' "$SB_CONFIG"
_cnblock_probe
assert "WARP 写入后探针顺序仍为 ok" bash -c "[[ $CNBLOCK_P_ORDER == ok ]]"
assert "WARP 写入后探针 Guard 仍为 ACTIVE" bash -c "[[ $CNBLOCK_P_GUARD == ACTIVE ]]"
cnblock_disable >/dev/null 2>&1
# v1.10.2 升级场景：3 条 block 规则齐全、block 出站齐全，但无放行规则。
# （DediOne 从 v1.10.2 升级后即此状态。）探针应判 FAILED，重新开启补回。
reset_cnblock_env
cnblock_enable >/dev/null 2>&1
jq 'del(.route.rules[] | select(.outbound == "direct" and (.domain_suffix | type) == "array"))' "$SB_CONFIG" > "$TEST_ETC/cfg.tmp" && mv "$TEST_ETC/cfg.tmp" "$SB_CONFIG"
assert "模拟 v1.10.2 配置：放行规则为 0 条" bash -c "[[ $(cnblock_exclude_count) -eq 0 ]]"
assert "模拟 v1.10.2 配置：block 规则仍为 3 条" bash -c "[[ $(cnblock_rule_count) -eq 3 ]]"
_cnblock_probe
assert "缺放行规则时探针报 missing" bash -c "[[ $CNBLOCK_P_EXCLUDE == missing ]]"
assert "缺放行规则时 Guard 为 FAILED（非 ACTIVE）" bash -c "[[ $CNBLOCK_P_GUARD == FAILED ]]"
cnblock_status >/dev/null 2>&1; _rc=$?
assert "缺放行规则时 status 返回 2" bash -c "[[ $_rc -eq 2 ]]"
cnblock_verify > "$TEST_ETC/verify-no-exclude.out" 2>&1; _rc=$?
assert "缺放行规则时 verify 返回非 0" bash -c "[[ $_rc -ne 0 ]]"
assert "缺放行规则时 verify 点名放行规则缺失" grep -q '放行规则 missing' "$TEST_ETC/verify-no-exclude.out"
cnblock_doctor > "$TEST_ETC/doctor-no-exclude.out" 2>&1; _rc=$?
assert "缺放行规则时 doctor 返回非 0" bash -c "[[ $_rc -ne 0 ]]"
assert "缺放行规则时 doctor 提示重新开启补齐" grep -q '放行规则缺失' "$TEST_ETC/doctor-no-exclude.out"
_cnblock_menu_status
assert "缺放行规则时菜单探针显示缺失" bash -c "[[ $CNBLOCK_M_EXCLUDE_TXT == 缺失 ]]"
# 重新开启应自动补回放行规则，恢复 ACTIVE（不依赖重断言标记）。
cnblock_enable >/dev/null 2>&1; enable_rc=$?
assert "缺放行规则时重跑 enable 返回 0" bash -c "[[ $enable_rc -eq 0 ]]"
assert "重跑 enable 后放行规则补回 1 条" bash -c "[[ $(cnblock_exclude_count) -eq 1 ]]"
assert "重跑 enable 后仍为 3 条 block 规则" bash -c "[[ $(cnblock_rule_count) -eq 3 ]]"
_cnblock_probe
assert "补回后 Guard 恢复 ACTIVE" bash -c "[[ $CNBLOCK_P_GUARD == ACTIVE ]]"
# 重复开启幂等：放行规则不重复，block 规则仍 3 条。
cnblock_enable >/dev/null 2>&1
assert "重复开启后仍为 1 条放行规则" bash -c "[[ $(cnblock_exclude_count) -eq 1 ]]"
assert "重复开启后仍为 3 条 block 规则" bash -c "[[ $(cnblock_rule_count) -eq 3 ]]"
# 放行规则域名集合过期（只剩 gstatic.com，子集判定仍认作放行规则）：
# 重跑 enable 应按当前清单重写回 2 个域名（与补漏域名清单同款逻辑）。
jq '.route.rules[1].domain_suffix = ["gstatic.com"]' "$SB_CONFIG" > "$TEST_ETC/cfg.tmp" && mv "$TEST_ETC/cfg.tmp" "$SB_CONFIG"
cnblock_enable >/dev/null 2>&1
assert "域名集合过期时重跑 enable 补齐 2 个域名" jq -e '.route.rules[1].domain_suffix == ["gstatic.com", "cp.cloudflare.com"]' "$SB_CONFIG"
assert "补齐后仍为 1 条放行规则" bash -c "[[ $(cnblock_exclude_count) -eq 1 ]]"
# 关闭拦截：放行规则与 block 规则均移除，block 出站保留。
cnblock_disable >/dev/null 2>&1
assert "关闭后放行规则移除" bash -c "[[ $(cnblock_exclude_count) -eq 0 ]]"
assert "关闭后无拦截规则" bash -c "[[ $(cnblock_rule_count) -eq 0 ]]"
assert "关闭后 block 出站保留" bash -c "[[ $(block_outbound_count) -eq 1 ]]"
_cnblock_probe
assert "关闭后 Guard 为 DISABLED" bash -c "[[ $CNBLOCK_P_GUARD == DISABLED ]]"
_cnblock_menu_status
assert "关闭后菜单探针放行规则为未启用" bash -c "[[ $CNBLOCK_M_EXCLUDE_TXT == 未启用 ]]"
cnblock_status > "$TEST_ETC/status-exclude-off.out" 2>&1
assert "关闭后 status 显示放行规则未启用" grep -q '放行规则：未启用' "$TEST_ETC/status-exclude-off.out"
cnblock_disable >/dev/null 2>&1
assert "重复关闭后仍无放行规则" bash -c "[[ $(cnblock_exclude_count) -eq 0 ]]"

rm -rf "$TEST_ETC"
if [[ $fail -eq 0 ]]; then
    echo "PASS: CN 拦截开关、幂等、规则保留、状态一致、锁安全"
else
    echo "FAIL: CN 拦截测试有失败项"
    exit 1
fi
