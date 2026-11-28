#!/usr/bin/env bash
# protocols/cnblock/cnblock.sh — CN 出站拦截（CN Egress Guard）
#
# 用途：VPS 端最后一道防线。客户端（Shadowrocket / v2rayN 等）分流规则
# 一旦漏网（全局模式、规则不全），微信/支付宝等国内流量会经代理以境外 IP
# 登录，等于把实名身份与这台服务器绑定。本功能在 sing-box 服务端拦截
# 所有目标为国内域名/IP 的代理请求：漏网流量直接拒绝，变成打不开、看得见，
# 而不是悄悄登录成功。
#
# 实现：sing-box rule-set（规则集）+ 显式域名规则 + block 出站。
#   route.rule_set 挂两个本地二进制规则集（geosite-cn.srs / geoip-cn.srs，
#   SagerNet sing-geosite / sing-geoip 仓库的 rule-set 分支），
#   route.rules 里三条规则指向 block：两条分别引用规则集，一条是
#   CNBLOCK_EXTRA_DOMAINS 的 domain_suffix 规则（见下）。
#   另外一条放行规则在 3 条 block 规则之前（见 CNBLOCK_EXCLUDE_DOMAINS）：
#   geosite-cn 误含 www.gstatic.com 等 Google 域名（上游 @cn 标签问题），
#   Karing 默认用 https://www.gstatic.com/generate_204 测延迟，拦截一开
#   就全员超时。放行规则 first-match 优先，只放行连通性检测域名。
#   三条规则引用 tag 为 block 的出站：cnblock_enable 在同一个事务里
#   先确保 .outbounds 含 {type: "block", tag: "block"}（没有就追加，
#   已有不重复），否则 sing-box check 报 outbound not found: block
#   （2026-11-28 DediOne 实测：base.json 只有 direct 出站，开启失败）。
#   cnblock_disable 关闭时不删 block 出站（留着无害，下次开启直接复用），
#   但放行规则随拦截一起移除（它只在拦截开启时有意义）。
#   四条规则永远在 sniff 之后、所有分流规则（WARP 等）之前：
#   sing-box 按顺序匹配，先命中先出站，拦截被压在分流之后等于没拦
#   （2026-11-22 RN 实测：deepseek.com 同时在 WARP AI 预设里，WARP 规则
#   在前导致漏网）。apply_route_rules 写 WARP 规则时也会主动避让到
#   拦截规则之后（见 core/json_builder.sh），双保险。
#
# 补漏域名（CNBLOCK_EXTRA_DOMAINS）：geosite-cn 覆盖了 8972 个域名后缀，
# 但仍有高风险国内域名不在其中。2026-11-22 对照 domain-list-community
# 源码逐个核对 240 个候选域名，44 个确认漏网（如农业银行 abcchina.com、
# 上汽大众 svw-volkswagen.com、红果短剧 hongguoduanju.com、中信证券
# citics.com、招商证券 cmschina.com、上汽集团 saicmotor.com），另加
# deepseek.com——它在源码里有，但 RN 实测经 WARP 漏网，写死兜底。
# 合计 45 个域名，用一条 domain_suffix 规则直接拦，不依赖规则集文件。
# 清单只收“登录即实名”的国内服务（银行/支付/政务/电信/出行/电商/
# 社交/AI/游戏/汽车等）；.cn 域名由 geosite-cn 的 tld-cn 自动覆盖，
# 不必列入；境外服务（哪怕是中资出海品牌）一律不列。
# 清单主源是 rules/high-risk-domains.conf（每行一个域名，见该文件）；
# 下面的 CNBLOCK_EXTRA_DOMAINS 是内嵌 fallback：conf 缺失/不可读/为空
# 时回落到它，拦截不失效。两处清单内容必须一致（测试校验）。
#
# 注意（2026-11-22 真机验证教训）：不要用 route.geoip / route.geosite
# 数据库 + geosite / geoip 规则字段——sing-box 1.8.0 已废弃、1.12.0 已
# 移除，1.14.4 上 sing-box check 直接报 FATAL（initialize router:
# parse rule: geosite database is deprecated ... removed in 1.12.0）。
# 规则集是唯一可用的机制，P2 已用真实 1.14.4 验证通过。
#
# 规则归属（结构识别，不写自定义字段到配置）：
#   本功能的规则是 outbound=="block" 且满足以下任一条件：
#     (a) rule_set 为 geosite-cn 或 geoip-cn（字符串或数组形式）；
#     (b) domain_suffix 为非空数组且全部元素都在 CNBLOCK_EXTRA_DOMAINS 里
#         （子集判定：用户自定义的 block 规则域名不在此表，不会误删；
#         清单扩充后旧规则的域名仍是子集，升级时能正确识别并替换）。
#   放行规则是 outbound=="direct" 且 domain_suffix 为非空数组、全部元素
#   都在 CNBLOCK_EXCLUDE_DOMAINS 里（子集判定，同上）；enable 写死精确
#   的两域名，升级扩充清单后旧规则仍被识别、重写时自动补齐。
#   规则集条目按 tag 识别。sing-box 配置 schema 不认自定义字段，任何标识
#   绝不能写入 config.json（2026-11-15 实测：unknown field 致分流失败）。
#
# 锁纪律（D5）：状态写与 config_transaction 绝不嵌套持锁。
#   warp_set_domains 的已知 bug 是持状态锁期间调 config_transaction，后者
#   覆盖 RETURN trap 导致 _state_unlock 不触发，多进程并发时互相阻塞 10 秒。
#   本文件所有函数都是：先做配置事务（内部自带配置锁），事务完成返回后
#   再单独写状态（单独加锁解锁），两者绝不重叠。
#
# 状态与配置的关系：配置是唯一事实来源，state.json 的 .cnblock.enabled
# 只是用户意图的记录。状态写失败时不回滚已生效的配置（与 install_warp
# 不同：那里 state 存着不可再生的私钥，必须回滚；这里的布尔值完全可由
# 配置推导，回滚反而会把已生效的拦截悄悄撤掉）。
#
# v1.10.0 CN Egress Guard：规则集更新（cnblock_update：下载到临时文件 →
# 校验 → 备份旧文件 → 原子替换 → 重载，失败保留旧规则）、Guard 四态
# （ACTIVE/DEGRADED/FAILED/DISABLED，见探针头注释）、快速实测
# （cnblock_test，含 IPv6 探针）与诊断（cnblock_doctor）。geoip-cn 规则
# 集含 IPv4 与 IPv6 段（已核实生成器不分版本全量写入），IPv6 国内目标
# 同样被拦；verify 与 test 的 IPv6 探针只在本机有全局 IPv6 时跑。

CNBLOCK_GEOIP_URL="https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs"
CNBLOCK_GEOSITE_URL="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs"
# 规则集文件最小体积（实测 geosite-cn.srs 约 58KB、geoip-cn.srs 约 34KB；
# 小于 10KB 视为下载不完整或错误页面，拒绝使用；另校验 SRS 魔数）。
CNBLOCK_SRS_MIN_BYTES=10240
# 二进制规则集魔数：ASCII "SRS" + 版本字节 0x01
CNBLOCK_SRS_MAGIC="53525301"
# 规则集陈旧阈值（天）：.srs 文件 mtime 超过该天数即 STALE。拦截仍生效，
# 只是数据旧了；status 报 DEGRADED，doctor 建议更新。用文件 mtime 判，
# 不依赖 state.json（状态文件损坏/丢失时陈旧判定依然有效）。
CNBLOCK_SRS_STALE_DAYS=30
# 国内 IPv6 探针目标（阿里云公共 DNS v6，应被 geoip-cn 拦截）。
# geoip-cn.srs 含 IPv6 段（2026-11-23 已核实 sing-geoip 生成器把
# MaxMind 数据库里中国全部网段不分 v4/v6 都写进规则集）。
CNBLOCK_V6_PROBE_IP="2400:3200::1"

# 规则集漏网的高风险国内域名（45 个，见文件头说明）。
# 内嵌 fallback 清单：主源是 rules/high-risk-domains.conf，本变量只在
# conf 缺失/不可读/为空时启用。两处清单内容必须一致。
# 按类别分组；改动后 is_cnblock 的子集判定与 verify 自动适配。
# 注意：不要加 .cn 域名（geosite-cn 已覆盖），不要加境外服务。
CNBLOCK_EXTRA_DOMAINS="
abcchina.com pingbank.com bankofshanghai.com zj96596.com lakala.com
99bill.com allinpay.com cqrcb.com hkbchina.com qdccb.com tzbank.com
zjtlcb.com beike.com 5i5j.com qfang.com momo.com guahao.com
hongguoduanju.com moonshot.ai stepfun.com 01.ai deepseek.com
svw-volkswagen.com luckair.com 9air.com okair.com mia.com
ztgame.com kunlun.com 2144.com 51wan.com 9377.com 8090.com
sinosig.com zhongan.com shuidi.com leapmotor.com netaauto.com
aito.com zeekr.com im-motors.com avatr.com citics.com
cmschina.com saicmotor.com
"

# 连通性检测放行域名（v1.10.3，2026-11-28 DediOne 实测）：
# 上游 v2fly domain-list-community 把 www.gstatic.com、ssl.gstatic.com、
# fonts.googleapis.com 等打了 @cn 标签，SagerNet sing-geosite 生成
# geosite-cn.srs 时原样并入，导致 geosite-cn 误含这些 Google 域名
# （GitHub v2fly/domain-list-community#3378、throneproj/Throne#977
# 同款问题）。Karing 默认用 https://www.gstatic.com/generate_204 测延迟，
# 拦截一开全部节点超时、显示感叹号——节点本身是通的，只是检测流量被误拦。
# 修法：enable 时在 3 条 block 规则之前先插一条放行规则
# {domain_suffix: [gstatic.com, cp.cloudflare.com], outbound: "direct"}，
# first-match 优先放行检测流量。cp.cloudflare.com 是 Karing 另一常用
# 检测地址（测速 URL 默认值），一并放行。domain_suffix 按后缀匹配，
# 覆盖全部子域名（www.gstatic.com、ssl.gstatic.com 等）。
# 只放行连通性检测域名，不碰 Apple 相关域名（脚本不为 Apple 改白名单，
# 用户早先已定；Apple 问题是客户端分流的事，与本规则无关）。
CNBLOCK_EXCLUDE_DOMAINS="
gstatic.com
cp.cloudflare.com
"

# 补漏域名清单文件路径：与本文件同目录下的 rules/high-risk-domains.conf。
# CNBLOCK_DOMAINS_CONF 可覆盖（供测试指向临时清单或不存在的路径）。
_cnblock_conf_path() {
    if [[ -n "${CNBLOCK_DOMAINS_CONF:-}" ]]; then
        printf '%s' "$CNBLOCK_DOMAINS_CONF"
    else
        printf '%s' "${BASH_SOURCE[0]%/*}/rules/high-risk-domains.conf"
    fi
}

# 补漏域名转 JSON 数组（供 jq --argjson 传入）。
# 优先读 conf 文件（# 注释与空行忽略）；conf 缺失/不可读/无有效域名时
# 回落到内嵌的 CNBLOCK_EXTRA_DOMAINS，绝不因数据文件问题导致拦截失效。
# 注意：不能用 read -ra（read 只读第一行，变量是多行的）；
# 用 jq splits 按空白切分，自动去掉首尾空串。
_cnblock_extra_domains_json() {
    local conf json n
    conf=$(_cnblock_conf_path)
    if [[ -r "$conf" ]]; then
        json=$(_cnblock_conf_tokens "$conf" | jq -R -s '[splits("\\s+") | select(length > 0)]' 2>/dev/null)
        n=$(printf '%s' "${json:-}" | jq 'length' 2>/dev/null || echo 0)
        if [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )); then
            printf '%s' "$json"
            return 0
        fi
    fi
    printf '%s' "$CNBLOCK_EXTRA_DOMAINS" | jq -R -s '[splits("\\s+") | select(length > 0)]'
}

# 放行域名转 JSON 数组（供 jq --argjson 传入）。
_cnblock_exclude_domains_json() {
    printf '%s' "$CNBLOCK_EXCLUDE_DOMAINS" | jq -R -s '[splits("\\s+") | select(length > 0)]'
}

# 本功能规则的 jq 判定（探针/enable/disable 三处共用一个定义，避免口径漂移）。
# $extra 为补漏域名数组（调用方以 --argjson 传入）。
# is_cnblock_exclude($ex)：放行规则判定，$ex 为放行域名数组（调用方以
# --argjson excludes 传入；写成带参 def 是因为 _cnblock_domains_in_sync
# 等调用方不传 excludes，全局 $excludes 未定义时 jq 会直接报错）。
# is_cnblock_guard($ex)：拦截规则或放行规则——探针顺序检查用：四条规则
# 必须整体在所有分流规则之前，放行规则本身是 direct 出站，不能把它当成
# “其他出站规则”去比顺序（否则顺序永远报 wrong）。
_CNBLOCK_JQ_DEF='def is_cnblock: .outbound == "block" and (((.rule_set == "geosite-cn") or (.rule_set == "geoip-cn") or (((.rule_set | type) == "array") and (((.rule_set | index("geosite-cn")) != null) or ((.rule_set | index("geoip-cn")) != null)))) or (((.domain_suffix | type) == "array") and ((.domain_suffix | length) > 0) and (((.domain_suffix - $extra) | length) == 0)));
def is_cnblock_exclude($ex): .outbound == "direct" and (((.domain_suffix | type) == "array") and ((.domain_suffix | length) > 0) and (((.domain_suffix - $ex) | length) == 0));
def is_cnblock_guard($ex): is_cnblock or is_cnblock_exclude($ex);'

# 规则集文件路径（动态计算：测试会覆盖 SB_ETC，绝不能在 source 时定死）。
_cnblock_geoip_path() { printf '%s' "$SB_ETC/geoip-cn.srs"; }
_cnblock_geosite_path() { printf '%s' "$SB_ETC/geosite-cn.srs"; }

# 经本机 SOCKS5 取 HTTP 状态码（失败为 000）。
# 凭据走环境变量 ALL_PROXY，不出现在 curl 命令行：/proc/<pid>/cmdline 对本机任何
# 用户可读，而 verify/test 要连续发起二十多次请求，每次约 8 秒窗口都会暴露 SOCKS5 密码；
# 环境变量只有同用户/root 可读。
_cnblock_curl_code() {   # <url> <user> <pass> <port>
    local url="$1" user="$2" pass="$3" port="$4" code
    code=$(ALL_PROXY="socks5h://${user}:${pass}@127.0.0.1:${port}" timeout 8 curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || true)
    printf '%s' "${code:-000}"
}

# 实测目标合法性：域名（至少一个点）、IPv4 或 IPv6 字面量。
# 带端口（example.com:8080）、路径、协议头或空白的输入一律拒绝——否则 host:port 会被
# 误判成 IPv6 字面量，curl 失败后被当成"被拦截"，给出错误结论。
_cnblock_valid_target() {
    local t="$1"
    [[ -n "$t" && ${#t} -le 253 ]] || return 1
    if [[ "$t" == *:* || "$t" =~ ^[0-9.]+$ ]]; then
        command -v python3 >/dev/null 2>&1 || return 1
        python3 -c 'import ipaddress,sys; ipaddress.ip_address(sys.argv[1])' "$t" >/dev/null 2>&1
        return $?
    fi
    [[ "$t" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]
}

# 从补漏清单文件取出合法域名（每行一个，小写）。纯 bash/grep，不依赖 jq：
# 跳过整行注释，按空白切分，丢弃不是域名的记号（行内注释、全角标点、误填的
# 协议头/端口等），避免一个手误让整条 domain_suffix 规则被 sing-box check 拒绝。
_cnblock_conf_tokens() {   # <conf 文件>
    tr -d '\r' < "$1" 2>/dev/null \
        | grep -v '^[[:space:]]*#' \
        | tr -s '[:space:]' '\n' \
        | grep -E '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$' \
        | grep -vE '^[0-9.]+$' \
        | tr 'A-Z' 'a-z'
}

# 单个规则集文件是否可用：存在、体积达标、魔数为 SRS\x01。
_cnblock_srs_ok() {
    local f="$1" sz magic
    [[ -f "$f" ]] || return 1
    sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
    [[ "$sz" =~ ^[0-9]+$ ]] && (( sz >= CNBLOCK_SRS_MIN_BYTES )) || return 1
    magic=$(head -c 4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')
    [[ "$magic" == "$CNBLOCK_SRS_MAGIC" ]]
}

# 预下载 geosite-cn.srs / geoip-cn.srs（已存在且校验通过时跳过，不重复下载）。
# 失败时干净 abort（返回 1，调用方不得继续改配置）。
# 复用 download_file（仅 HTTPS、原子替换、600 权限、重试 2 次）。
cnblock_ensure_dbs() {
    local geoip_srs geosite_srs
    geoip_srs=$(_cnblock_geoip_path)
    geosite_srs=$(_cnblock_geosite_path)
    mkdir -p "$SB_ETC" || { log_err "无法创建配置目录：$SB_ETC"; return 1; }

    if _cnblock_srs_ok "$geosite_srs"; then
        log_info "geosite-cn.srs 已存在，跳过下载。"
    else
        log_info "正在下载 geosite-cn.srs ..."
        if ! download_file "$CNBLOCK_GEOSITE_URL" "$geosite_srs"; then
            log_err "geosite-cn.srs 下载失败（URL：$CNBLOCK_GEOSITE_URL），拦截未开启，配置未改动。"
            return 1
        fi
        if ! _cnblock_srs_ok "$geosite_srs"; then
            log_err "geosite-cn.srs 校验失败（体积过小或不是规则集文件），已删除，拦截未开启，配置未改动。"
            rm -f "$geosite_srs"
            return 1
        fi
    fi

    if _cnblock_srs_ok "$geoip_srs"; then
        log_info "geoip-cn.srs 已存在，跳过下载。"
    else
        log_info "正在下载 geoip-cn.srs ..."
        if ! download_file "$CNBLOCK_GEOIP_URL" "$geoip_srs"; then
            log_err "geoip-cn.srs 下载失败（URL：$CNBLOCK_GEOIP_URL），拦截未开启，配置未改动。"
            return 1
        fi
        if ! _cnblock_srs_ok "$geoip_srs"; then
            log_err "geoip-cn.srs 校验失败（体积过小或不是规则集文件），已删除，拦截未开启，配置未改动。"
            rm -f "$geoip_srs"
            return 1
        fi
    fi
    return 0
}

# ---------- 状态探针（只读，不写状态、不做网络请求） ----------
# 结果写入 CNBLOCK_P_* 全局变量，供 status / 菜单 / 诊断共用。
#   CNBLOCK_P_RULES：配置中本功能的 block 规则条数（0~3）
#   CNBLOCK_P_ORDER：拦截规则是否在所有分流规则之前（ok/wrong）
#   CNBLOCK_P_SETS：route.rule_set 中本功能的两个条目是否齐全（ok/missing）
#   CNBLOCK_P_DBS：磁盘规则集文件是否齐全可用（ok/missing）
#   CNBLOCK_P_OUTBOUND：配置的 outbounds 里是否有 {type: "block", tag: "block"}（ok/missing）
#   CNBLOCK_P_EXCLUDE：配置中本功能的放行规则条数是否为 1（ok/missing；
#     0 条或多条都算 missing——多条是重复写入的 bug，重跑 enable 会去重）
#   CNBLOCK_P_STATE：状态记录（enabled/disabled/unset）
#   CNBLOCK_P_STALE：任一 .srs 文件 mtime 超 30 天（ok/stale）
#   CNBLOCK_P_STALE_DAYS：最旧 .srs 文件的年龄（天）
#   CNBLOCK_P_LAST_UPDATE：上次更新状态（ok/failed/none）
#   CNBLOCK_P_GUARD：四态 ACTIVE/DEGRADED/FAILED/DISABLED
#     ACTIVE：规则/条目/文件/顺序/block 出站/放行规则全对，且无 STALE 且上次更新未失败
#     DEGRADED：规则全对但某层 STALE 或上次更新失败（拦截仍生效）
#     FAILED：规则不完整/条目缺/文件缺/顺序错/block 出站缺/放行规则缺且规则 > 0
#     DISABLED：规则 0 条
CNBLOCK_P_RULES=0
CNBLOCK_P_ORDER="ok"
CNBLOCK_P_SETS="missing"
CNBLOCK_P_DBS="missing"
CNBLOCK_P_OUTBOUND="missing"
CNBLOCK_P_EXCLUDE="missing"
CNBLOCK_P_STATE="unset"
CNBLOCK_P_STALE="ok"
CNBLOCK_P_STALE_DAYS=0
CNBLOCK_P_LAST_UPDATE="none"
CNBLOCK_P_GUARD="DISABLED"

_cnblock_probe() {
    CNBLOCK_P_RULES=0
    CNBLOCK_P_ORDER="ok"
    CNBLOCK_P_SETS="missing"
    CNBLOCK_P_DBS="missing"
    CNBLOCK_P_OUTBOUND="missing"
    CNBLOCK_P_EXCLUDE="missing"
    CNBLOCK_P_STATE="unset"
    CNBLOCK_P_STALE="ok"
    CNBLOCK_P_STALE_DAYS=0
    CNBLOCK_P_LAST_UPDATE="none"
    CNBLOCK_P_GUARD="DISABLED"
    local geoip_srs geosite_srs extra_json excludes_json probe_json
    geoip_srs=$(_cnblock_geoip_path)
    geosite_srs=$(_cnblock_geosite_path)

    if [[ -f "$SB_CONFIG" ]]; then
        extra_json=$(_cnblock_extra_domains_json)
        excludes_json=$(_cnblock_exclude_domains_json)
        # 一次 jq 同时算规则条数、放行规则条数与顺序：顺序正确 = 每条拦截
        # 或放行规则的下标都小于每条其他出站规则的下标（无拦截规则或无
        # 其他出站规则时恒真）。放行规则是 direct 出站，必须算在“拦截侧”，
        # 否则它下标最小、顺序永远报 wrong。
        probe_json=$(jq -c --argjson extra "$extra_json" --argjson excludes "$excludes_json" "$_CNBLOCK_JQ_DEF"'
            (.route.rules // []) as $r
            | {rules: ([$r[] | select(is_cnblock)] | length),
               exclude: ([$r[] | select(is_cnblock_exclude($excludes))] | length),
               order_ok: (([$r | to_entries[] | select(.value | is_cnblock_guard($excludes)) | .key] | max // -1) < ([$r | to_entries[] | select((.value | is_cnblock_guard($excludes) | not) and (.value.outbound != null)) | .key] | min // 999999))}' \
            "$SB_CONFIG" 2>/dev/null || echo '{"rules":0,"exclude":0,"order_ok":true}')
        CNBLOCK_P_RULES=$(echo "$probe_json" | jq -r '.rules // 0' 2>/dev/null || echo 0)
        [[ "$CNBLOCK_P_RULES" =~ ^[0-9]+$ ]] || CNBLOCK_P_RULES=0
        if [[ "$(echo "$probe_json" | jq -r '.exclude // 0' 2>/dev/null || echo 0)" == "1" ]]; then
            CNBLOCK_P_EXCLUDE="ok"
        fi
        # 注意：不能写 '.order_ok // true'——jq 里 // 把 false 也当缺失，
        # 顺序错误时 order_ok=false 会被当成缺失而返回 true，探针永远报 ok
        # （与 v1.8.0 状态探针 false 变 unset 是同一个坑）。用 tostring 显式区分。
        if [[ "$(echo "$probe_json" | jq -r '.order_ok | tostring' 2>/dev/null)" != "true" ]]; then
            CNBLOCK_P_ORDER="wrong"
        fi
        # 注意：jq 里 and 的优先级高于 |，不能写 "[...] | length == 1 and [...] | length == 1"
        # （会错解析成中间段），用 any() 两边各判一次。
        if jq -e --arg gp "$geoip_srs" --arg gs "$geosite_srs" \
            'any(.route.rule_set[]?; .tag == "geosite-cn" and .format == "binary" and .path == $gs)
             and any(.route.rule_set[]?; .tag == "geoip-cn" and .format == "binary" and .path == $gp)' \
            "$SB_CONFIG" >/dev/null 2>&1; then
            CNBLOCK_P_SETS="ok"
        fi
        # block 出站：三条规则引用 tag "block"，出站缺失时 sing-box check
        # 直接报 outbound not found: block（2026-11-28 DediOne 实测）。
        if jq -e '.outbounds[]? | select(.tag == "block" and .type == "block")' \
            "$SB_CONFIG" >/dev/null 2>&1; then
            CNBLOCK_P_OUTBOUND="ok"
        fi
    fi
    if _cnblock_srs_ok "$geoip_srs" && _cnblock_srs_ok "$geosite_srs"; then
        CNBLOCK_P_DBS="ok"
    fi
    # 陈旧检查：用文件 mtime 判（不依赖 state.json）。任一文件超 30 天即 STALE。
    local now mtime age f
    now=$(date +%s)
    for f in "$geoip_srs" "$geosite_srs"; do
        if [[ -f "$f" ]]; then
            mtime=$(stat -c %Y "$f" 2>/dev/null || echo 0)
            if [[ "$mtime" =~ ^[0-9]+$ ]] && (( mtime > 0 )) && (( now >= mtime )); then
                age=$(( (now - mtime) / 86400 ))
                if (( age > CNBLOCK_P_STALE_DAYS )); then
                    CNBLOCK_P_STALE_DAYS=$age
                fi
            fi
        fi
    done
    if (( CNBLOCK_P_STALE_DAYS > CNBLOCK_SRS_STALE_DAYS )); then
        CNBLOCK_P_STALE="stale"
    fi
    if [[ -f "$SB_STATE" ]]; then
        local en lu
        # 注意：不能写 '.cnblock.enabled // empty'——jq 里 // 把 false 也当缺失，
        # enabled=false 时会返回空，导致状态永远报 unset 而非 disabled
        # （2026-11-22 RN 实测：关闭后状态记录显示 unset）。用 has() 显式区分。
        en=$(jq -r '.cnblock | if type == "object" and has("enabled") then .enabled | tostring else empty end' "$SB_STATE" 2>/dev/null || true)
        case "$en" in
            true) CNBLOCK_P_STATE="enabled" ;;
            false) CNBLOCK_P_STATE="disabled" ;;
            *) CNBLOCK_P_STATE="unset" ;;
        esac
        lu=$(jq -r '.cnblock.rules.last_update_status // empty' "$SB_STATE" 2>/dev/null || true)
        case "$lu" in
            ok|failed) CNBLOCK_P_LAST_UPDATE="$lu" ;;
        esac
    fi
    # Guard 四态（见探针头注释）。
    if (( CNBLOCK_P_RULES == 0 )); then
        CNBLOCK_P_GUARD="DISABLED"
    elif (( CNBLOCK_P_RULES == 3 )) && [[ "$CNBLOCK_P_SETS" == "ok" ]] && [[ "$CNBLOCK_P_DBS" == "ok" ]] && [[ "$CNBLOCK_P_ORDER" == "ok" ]] && [[ "$CNBLOCK_P_OUTBOUND" == "ok" ]] && [[ "$CNBLOCK_P_EXCLUDE" == "ok" ]]; then
        if [[ "$CNBLOCK_P_STALE" == "stale" ]] || [[ "$CNBLOCK_P_LAST_UPDATE" == "failed" ]]; then
            CNBLOCK_P_GUARD="DEGRADED"
        else
            CNBLOCK_P_GUARD="ACTIVE"
        fi
    else
        CNBLOCK_P_GUARD="FAILED"
    fi
}

# 规则集文件年龄（天，基于 mtime）；文件缺失返回 -1。
_cnblock_srs_age_days() {
    local f="$1" mtime now
    if [[ ! -f "$f" ]]; then
        echo -1
        return 1
    fi
    mtime=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    now=$(date +%s)
    if [[ "$mtime" =~ ^[0-9]+$ ]] && (( mtime > 0 )) && (( now >= mtime )); then
        echo $(( (now - mtime) / 86400 ))
    else
        echo 0
    fi
}

# 规则集文件信息：存在时打印 "58 KB · 2026-11-22"，缺失时打印 "缺失"。
# 注意：只报大小与日期，不报条目数——.srs 是二进制格式，数不出条目。
_cnblock_srs_info() {
    local f="$1" sz mtime when
    if [[ ! -f "$f" ]]; then
        printf '缺失'
        return 1
    fi
    sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
    mtime=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    if [[ "$mtime" =~ ^[0-9]+$ ]] && (( mtime > 0 )); then
        when=$(date -d "@$mtime" +%Y-%m-%d 2>/dev/null || echo '?')
    else
        when='?'
    fi
    printf '%s KB · %s' "$(( (sz + 512) / 1024 ))" "$when"
}

# 单层规则集状态（一行文本，供 status / doctor 共用）：
# 未下载 / 无效（校验失败）/ OK（大小 · 日期）/ STALE（大小 · 日期，N 天前）。
_cnblock_layer_state() {
    local f="$1" age info
    if [[ ! -f "$f" ]]; then
        printf '未下载'
        return 0
    fi
    if ! _cnblock_srs_ok "$f"; then
        printf '无效（校验失败）'
        return 0
    fi
    info=$(_cnblock_srs_info "$f")
    age=$(_cnblock_srs_age_days "$f")
    if (( age > CNBLOCK_SRS_STALE_DAYS )); then
        printf 'STALE（%s，%s 天前）' "$info" "$age"
    else
        printf 'OK（%s）' "$info"
    fi
}

# 上次更新文本：无更新记录 / 2026-11-23 10:00（ok）/ 2026-11-23 10:00（failed：原因）。
_cnblock_last_update_text() {
    local ts st err when
    if [[ ! -f "$SB_STATE" ]]; then
        printf '无更新记录'
        return 0
    fi
    ts=$(jq -r '.cnblock.rules.last_update_at // empty' "$SB_STATE" 2>/dev/null || true)
    st=$(jq -r '.cnblock.rules.last_update_status // empty' "$SB_STATE" 2>/dev/null || true)
    if [[ -z "$ts" || -z "$st" ]]; then
        printf '无更新记录'
        return 0
    fi
    when=$(date -d "@$ts" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$ts")
    if [[ "$st" == "failed" ]]; then
        err=$(jq -r '.cnblock.rules.last_update_error // empty' "$SB_STATE" 2>/dev/null || true)
        printf '%s（failed：%s）' "$when" "${err:-未知错误}"
    else
        printf '%s（ok）' "$when"
    fi
}

# 写状态记录（单独加锁，与配置事务绝不嵌套；见文件头 D5 说明）。
# 参数：true|false。成功返回 0，失败返回 1（调用方只报错，不回滚配置）。
_cnblock_write_state() {
    local enabled="$1"
    init_state_file || return 1
    _state_lock || return 1
    trap '_state_unlock' RETURN
    local tmp
    tmp=$(mktemp "${SB_STATE}.XXXXXX") || return 1
    jq --argjson en "$enabled" --argjson ts "$(date +%s)" \
        '.cnblock = (.cnblock // {}) | .cnblock.enabled = $en | .cnblock.updated_at = $ts' \
        "$SB_STATE" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$SB_STATE" || { rm -f "$tmp"; return 1; }
}

# 写规则集更新记录（单独加锁，与配置事务绝不嵌套；见文件头 D5 说明）。
# 参数：状态(ok/failed) [失败原因] [geosite 更新时间戳] [geoip 更新时间戳]。
# 时间戳为空时不改动对应字段（失败时保留旧的下载时间）。
# 成功返回 0，失败返回 1。
_cnblock_write_rules_state() {
    local status="$1" error="${2:-}" g_ts="${3:-}" p_ts="${4:-}"
    init_state_file || return 1
    _state_lock || return 1
    trap '_state_unlock' RETURN
    local tmp now
    tmp=$(mktemp "${SB_STATE}.XXXXXX") || return 1
    now=$(date +%s)
    jq --arg st "$status" --arg err "$error" --argjson now "$now" \
        --argjson gts "${g_ts:-null}" --argjson pts "${p_ts:-null}" \
        '.cnblock = (.cnblock // {})
         | .cnblock.rules = (.cnblock.rules // {})
         | .cnblock.rules.last_update_at = $now
         | .cnblock.rules.last_update_status = $st
         | .cnblock.rules.last_update_error = $err
         | if $gts != null then .cnblock.rules.geosite = ((.cnblock.rules.geosite // {}) | .updated_at = $gts) else . end
         | if $pts != null then .cnblock.rules.geoip = ((.cnblock.rules.geoip // {}) | .updated_at = $pts) else . end' \
        "$SB_STATE" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$SB_STATE" || { rm -f "$tmp"; return 1; }
}

# CN Egress Guard 状态总览（CLI 与诊断用）。
# 打印状态行。返回：0=ACTIVE 或 DEGRADED（拦截生效；DEGRADED 只提示更新），
# 1=DISABLED（已关闭，干净），2=FAILED 或状态记录不一致。
cnblock_status() {
    _cnblock_probe
    local rc=1
    local geoip_srs geosite_srs extra_n
    geoip_srs=$(_cnblock_geoip_path)
    geosite_srs=$(_cnblock_geosite_path)
    extra_n=$(_cnblock_extra_domains_json | jq 'length' 2>/dev/null || echo 45)
    echo "  CN Egress Guard 状态："
    case "$CNBLOCK_P_GUARD" in
        ACTIVE|DEGRADED)
            if [[ "$CNBLOCK_P_GUARD" == "ACTIVE" ]]; then
                echo "    · Guard：ACTIVE（已开启）"
            else
                echo "    · Guard：DEGRADED（已开启，规则集需更新）"
            fi
            echo "    · 域名层 geosite-cn：$(_cnblock_layer_state "$geosite_srs")"
            echo "    · IP 层 geoip-cn：$(_cnblock_layer_state "$geoip_srs")（含 IPv4+IPv6）"
            echo "    · 补漏域名：${extra_n} 个（内嵌规则，不依赖文件）"
            echo "    · 放行规则：已就绪（gstatic.com、cp.cloudflare.com 走 direct，Karing 延迟检测可用）"
            echo "    · block 出站：已就绪"
            echo "    · 上次更新：$(_cnblock_last_update_text)"
            echo "    · 状态记录：${CNBLOCK_P_STATE}"
            if [[ "$CNBLOCK_P_STATE" == "disabled" ]]; then
                log_warn "配置已开启但状态记录为关闭（记录过期，以配置为准）。"
                rc=2
            elif [[ "$CNBLOCK_P_GUARD" == "DEGRADED" ]]; then
                if [[ "$CNBLOCK_P_STALE" == "stale" ]]; then
                    log_warn "规则集已过期 ${CNBLOCK_P_STALE_DAYS} 天，拦截仍生效，建议 sbx cnblock update 更新。"
                else
                    log_warn "上次规则集更新失败，拦截仍生效，建议 sbx cnblock update 重试。"
                fi
                rc=0
            else
                log_ok "拦截已开启：国内域名/IP 走代理时将被拒绝。"
                rc=0
            fi
            ;;
        DISABLED)
            echo "    · Guard：DISABLED（未开启）"
            echo "    · 域名层 geosite-cn：$(_cnblock_layer_state "$geosite_srs")"
            echo "    · IP 层 geoip-cn：$(_cnblock_layer_state "$geoip_srs")（含 IPv4+IPv6）"
            echo "    · 补漏域名：${extra_n} 个（开启时生效）"
            echo "    · 放行规则：未启用（开启时自动添加）"
            if [[ "$CNBLOCK_P_OUTBOUND" == "ok" ]]; then
                echo "    · block 出站：已存在（开启时直接复用）"
            else
                echo "    · block 出站：缺失（开启时自动补齐）"
            fi
            echo "    · 上次更新：$(_cnblock_last_update_text)"
            echo "    · 状态记录：${CNBLOCK_P_STATE}"
            if [[ "$CNBLOCK_P_STATE" == "enabled" ]]; then
                log_warn "状态记录为开启但配置中无规则（记录过期，以配置为准）。"
                rc=2
            else
                log_info "拦截未开启：代理可正常访问国内网站。"
                rc=1
            fi
            ;;
        *)
            # FAILED
            echo "    · Guard：FAILED（规则不完整）"
            echo "    · 拦截规则：${CNBLOCK_P_RULES}/3 条"
            echo "    · 规则集条目：${CNBLOCK_P_SETS}，规则集文件：${CNBLOCK_P_DBS}，顺序：${CNBLOCK_P_ORDER}，block 出站：${CNBLOCK_P_OUTBOUND}，放行规则：${CNBLOCK_P_EXCLUDE}"
            echo "    · 状态记录：${CNBLOCK_P_STATE}"
            log_err "拦截处于不一致状态：规则不完整，建议关闭后重新开启。"
            rc=2
            ;;
    esac
    return "$rc"
}

# 配置中的补漏域名集合是否与当前 conf 一致（集合相等）。
# 供 cnblock_enable 幂等检查：conf 新增域名后重跑 on 必须重写规则，
# 否则新域名不生效——探针只数"3 条规则"，不比对域名集合，旧规则的
# 域名仍是新 conf 的子集时会被误判为"已开启"。配置缺失或 jq 失败时
# 返回 1（不同步，走重写路径，安全方向）。
_cnblock_domains_in_sync() {
    local extra_json
    extra_json=$(_cnblock_extra_domains_json)
    [[ -f "$SB_CONFIG" ]] || return 1
    jq -e --argjson extra "$extra_json" "$_CNBLOCK_JQ_DEF"'
        ([.route.rules[]? | select(is_cnblock and ((.domain_suffix | type) == "array")) | .domain_suffix] | add // [] | sort)
        == ($extra | sort)
    ' "$SB_CONFIG" >/dev/null 2>&1
}

# 配置中的放行域名集合是否与当前 CNBLOCK_EXCLUDE_DOMAINS 一致（集合相等）。
# 与 _cnblock_domains_in_sync 同理：探针用子集判定数“1 条放行规则”，
# 清单扩充后旧规则仍是子集、会被误判为已就绪；幂等检查必须比对集合，
# 不一致时重写规则。配置缺失或 jq 失败时返回 1（走重写路径）。
_cnblock_excludes_in_sync() {
    local excludes_json
    excludes_json=$(_cnblock_exclude_domains_json)
    [[ -f "$SB_CONFIG" ]] || return 1
    jq -e --argjson excludes "$excludes_json" "$_CNBLOCK_JQ_DEF"'
        ([.route.rules[]? | select(is_cnblock_exclude($excludes)) | .domain_suffix] | add // [] | sort)
        == ($excludes | sort)
    ' "$SB_CONFIG" >/dev/null 2>&1
}

# 开启拦截：预下载规则集 → 写规则集条目与 block 规则 → 写状态记录。
# 幂等：已开启且域名集合一致时直接返回，不重复写规则、不重载服务。
cnblock_enable() {
    if [[ ! -x "$SB_BIN" ]]; then
        log_err "sing-box 内核未安装，请先在主菜单 13/s 安装内核。"
        return 1
    fi
    _cnblock_probe
    if (( CNBLOCK_P_RULES == 3 )) && [[ "$CNBLOCK_P_SETS" == "ok" ]] && [[ "$CNBLOCK_P_DBS" == "ok" ]] && [[ "$CNBLOCK_P_ORDER" == "ok" ]] && [[ "$CNBLOCK_P_OUTBOUND" == "ok" ]] && [[ "$CNBLOCK_P_EXCLUDE" == "ok" ]]; then
        if _cnblock_domains_in_sync && _cnblock_excludes_in_sync; then
            log_info "拦截已开启，无需重复操作。"
            [[ "$CNBLOCK_P_STATE" != "enabled" ]] && _cnblock_write_state true 2>/dev/null || true
            return 0
        fi
        log_info "拦截规则清单有变化，正在更新拦截规则。"
    fi
    # 先下载规则集：失败则干净 abort，配置不动（D3）。
    cnblock_ensure_dbs || return 1

    local geoip_srs geosite_srs extra_json extra_n excludes_json
    geoip_srs=$(_cnblock_geoip_path)
    geosite_srs=$(_cnblock_geosite_path)
    extra_json=$(_cnblock_extra_domains_json)
    extra_n=$(echo "$extra_json" | jq 'length')
    excludes_json=$(_cnblock_exclude_domains_json)
    # 写入：先删旧的拦截规则、旧的放行规则与规则集条目（幂等去重），再把
    # 规则集条目追加到 route.rule_set，把放行规则与三条 block 规则插到
    # 第一个裸 sniff 之后（sniff 之后、WARP 等分流规则之前）；无裸 sniff
    # 时在头部补一条。放行规则在 3 条 block 规则之前，first-match 优先：
    # geosite-cn 误含 gstatic.com 等检测域名，放行规则先命中 direct，
    # Karing 延迟检测才不会被误拦（v1.10.3）。
    # 同一事务里先确保 .outbounds 含 block 出站（没有就追加，已有不重复；
    # 缺它时 sing-box check 报 outbound not found: block）。
    # 注意：只认精确的 {action:"sniff"} 为裸 sniff，与 apply_route_rules
    # 同口径；用户自定义的 sniff（带额外字段）一律保留不动。
    if ! config_transaction \
        "$_CNBLOCK_JQ_DEF"'
         def is_bare_sniff: . == {action: "sniff"};
         def is_cnblock_set: (.tag == "geosite-cn") or (.tag == "geoip-cn");
         (.outbounds |= ((. // []) | if any(.[]; .tag == "block" and .type == "block") then . else . + [{type: "block", tag: "block"}] end))
         | (.route.rules // []) as $r
         | ([$r[] | select((is_cnblock | not) and (is_cnblock_exclude($excludes) | not))]) as $clean
         | ([$clean | to_entries[] | select(.value | is_bare_sniff) | .key] | first // -1) as $si
         | .route.rule_set = (((.route.rule_set // []) | map(select(is_cnblock_set | not))) + [{type: "local", tag: "geosite-cn", format: "binary", path: $geosite_path}, {type: "local", tag: "geoip-cn", format: "binary", path: $geoip_path}])
         | .route.rules = (
             if $si >= 0 then
               ($clean[0:($si + 1)] + [{domain_suffix: $excludes, outbound: "direct"}, {rule_set: "geosite-cn", outbound: "block"}, {rule_set: "geoip-cn", outbound: "block"}, {domain_suffix: $extra, outbound: "block"}] + $clean[($si + 1):])
             else
               ([{action: "sniff"}, {domain_suffix: $excludes, outbound: "direct"}, {rule_set: "geosite-cn", outbound: "block"}, {rule_set: "geoip-cn", outbound: "block"}, {domain_suffix: $extra, outbound: "block"}] + $clean)
             end
           )' \
        --argjson extra "$extra_json" --argjson excludes "$excludes_json" --arg geoip_path "$geoip_srs" --arg geosite_path "$geosite_srs"; then
        log_err "拦截开启失败，配置已回滚。"
        return 1
    fi
    # 配置事务已完成返回（锁已释放），再单独写状态，绝不嵌套（D5）。
    if ! _cnblock_write_state true; then
        log_err "拦截已生效，但状态记录写入失败（状态显示可能过期，以实际配置为准）。"
    fi
    log_ok "拦截已开启：国内域名/IP 走代理时将被直接拒绝（另含 ${extra_n} 个规则集漏网的高风险域名；gstatic.com、cp.cloudflare.com 已放行 direct，Karing 延迟检测可用）。"
    log_info "提示：微信/支付宝等国内服务请走直连，不要走代理；回国需求请在菜单里关闭拦截。"
    return 0
}

# 关闭拦截：移除规则（含放行规则）与本功能的规则集条目（.srs 文件保留在磁盘，
# 下次开启可直接用；用户自定义的规则集条目一律保留）。
# 幂等：已关闭时直接返回。block 出站保留（留着无害，下次开启直接复用）。
cnblock_disable() {
    _cnblock_probe
    if (( CNBLOCK_P_RULES == 0 )) && [[ "$CNBLOCK_P_EXCLUDE" != "ok" ]]; then
        log_info "拦截已关闭，无需重复操作。"
        [[ "$CNBLOCK_P_STATE" == "enabled" ]] && _cnblock_write_state false 2>/dev/null || true
        return 0
    fi
    if ! config_transaction \
        "$_CNBLOCK_JQ_DEF"'
         def is_cnblock_set: (.tag == "geosite-cn") or (.tag == "geoip-cn");
         (.route.rules // []) as $r
         | .route.rules = [$r[] | select((is_cnblock | not) and (is_cnblock_exclude($excludes) | not))]
         | .route.rule_set = ((.route.rule_set // []) | map(select(is_cnblock_set | not)))' \
        --argjson extra "$(_cnblock_extra_domains_json)" --argjson excludes "$(_cnblock_exclude_domains_json)"; then
        log_err "拦截关闭失败，配置已回滚。"
        return 1
    fi
    # 配置事务已完成返回（锁已释放），再单独写状态，绝不嵌套（D5）。
    if ! _cnblock_write_state false; then
        log_err "拦截已关闭，但状态记录写入失败（状态显示可能过期，以实际配置为准）。"
    fi
    log_ok "拦截已关闭：代理可正常访问国内网站（规则集文件已保留，下次开启无需重新下载）。"
    return 0
}

# 从 .bak 恢复规则集文件（有一个恢复一个；无备份的保持现状）。
# 只动文件，不重载服务（调用方决定是否重载）。
# 注意：只有恢复成功才删备份；mv/cp 都失败时保留 .bak 供手动恢复。
_cnblock_restore_srs_bak() {
    local f
    for f in "$@"; do
        if [[ -f "$f.bak" ]]; then
            if mv -f "$f.bak" "$f" 2>/dev/null || cp -f "$f.bak" "$f" 2>/dev/null; then
                rm -f "$f.bak"
            fi
        fi
    done
}

# 更新规则集（v1.10.0）：下载最新 geosite-cn.srs / geoip-cn.srs。
# 流程：两者都下载到临时文件并校验（体积 + SRS 魔数）→ 都通过后备份
# 旧文件（.bak）→ 原子替换 → 服务运行时重载并检查存活 → 成功删 .bak
# 并写更新记录。任一步失败：旧文件不动（或从 .bak 恢复并重载），写失败
# 记录，不静默。不改配置（config.json 不动），只换 .srs 文件；拦截未开
# 启时也可更新（下次开启直接用新规则集）。
# 返回 0=更新成功，1=失败。
cnblock_update() {
    local geoip_srs geosite_srs tmpdir
    geoip_srs=$(_cnblock_geoip_path)
    geosite_srs=$(_cnblock_geosite_path)
    mkdir -p "$SB_ETC" || { log_err "无法创建配置目录：$SB_ETC"; return 1; }
    tmpdir=$(mktemp -d "${SB_ETC}/.cnblock-update.XXXXXX") || { log_err "无法创建临时目录"; return 1; }

    local err=""
    log_info "正在下载最新规则集 ..."
    if ! download_file "$CNBLOCK_GEOSITE_URL" "$tmpdir/geosite-cn.srs"; then
        err="geosite-cn.srs 下载失败"
    elif ! _cnblock_srs_ok "$tmpdir/geosite-cn.srs"; then
        err="geosite-cn.srs 校验失败（体积过小或不是规则集文件）"
    elif ! download_file "$CNBLOCK_GEOIP_URL" "$tmpdir/geoip-cn.srs"; then
        err="geoip-cn.srs 下载失败"
    elif ! _cnblock_srs_ok "$tmpdir/geoip-cn.srs"; then
        err="geoip-cn.srs 校验失败（体积过小或不是规则集文件）"
    fi
    if [[ -n "$err" ]]; then
        rm -rf "$tmpdir"
        log_err "${err}，旧规则集未改动，拦截继续用旧规则集生效。"
        _cnblock_write_rules_state "failed" "$err" || log_err "更新失败记录写入失败。"
        return 1
    fi

    # 两者都校验通过：备份旧文件并原子替换。
    # 备份失败必须 abort（备份是回滚的前提；静默失败会让后续回滚无文件可恢复）。
    if [[ -f "$geosite_srs" ]] && ! cp -f "$geosite_srs" "$geosite_srs.bak" 2>/dev/null; then
        err="geosite-cn.srs 备份失败"
    elif [[ -f "$geoip_srs" ]] && ! cp -f "$geoip_srs" "$geoip_srs.bak" 2>/dev/null; then
        err="geoip-cn.srs 备份失败"
    fi
    if [[ -n "$err" ]]; then
        rm -rf "$tmpdir"
        log_err "${err}，旧规则集未改动，拦截继续用旧规则集生效。"
        _cnblock_write_rules_state "failed" "$err" || log_err "更新失败记录写入失败。"
        return 1
    fi
    chmod 600 "$tmpdir/geosite-cn.srs" "$tmpdir/geoip-cn.srs"
    mv -f "$tmpdir/geosite-cn.srs" "$geosite_srs" || err="geosite-cn.srs 替换失败"
    if [[ -z "$err" ]]; then
        mv -f "$tmpdir/geoip-cn.srs" "$geoip_srs" || err="geoip-cn.srs 替换失败"
    fi
    rm -rf "$tmpdir"
    if [[ -n "$err" ]]; then
        # 替换中途失败：从备份恢复（服务尚未重载，磁盘恢复即一致）。
        _cnblock_restore_srs_bak "$geosite_srs" "$geoip_srs"
        log_err "${err}，已从备份恢复旧规则集。"
        _cnblock_write_rules_state "failed" "$err" || log_err "更新失败记录写入失败。"
        return 1
    fi

    # 服务运行时重载并检查存活（config_transaction 同款 reload 方式）。
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        if ! reload_singbox_service; then
            log_err "服务重载失败，正在从备份恢复旧规则集 ..."
            _cnblock_restore_srs_bak "$geosite_srs" "$geoip_srs"
            reload_singbox_service || log_err "服务恢复重载也失败，请手动检查 sing-box 服务状态。"
            _cnblock_write_rules_state "failed" "服务重载失败，已恢复旧规则集" || log_err "更新失败记录写入失败。"
            return 1
        fi
    else
        log_info "sing-box 服务未运行，新规则集将在下次启动时生效。"
    fi

    rm -f "$geosite_srs.bak" "$geoip_srs.bak"
    local now
    now=$(date +%s)
    _cnblock_write_rules_state "ok" "" "$now" "$now" || log_err "更新成功记录写入失败（规则集已更新）。"
    log_ok "规则集已更新：geosite-cn.srs / geoip-cn.srs 均为最新。"
    return 0
}

# 本机是否有全局 IPv6 地址（决定是否跑 IPv6 探针）。
_cnblock_has_global_ipv6() {
    command -v ip >/dev/null 2>&1 || return 1
    ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'
}

# 验证拦截效果（分层检查，不改配置、不改状态）。
#   第 1 层：sing-box check 配置校验。
#   第 2 层：规则 + 规则集条目 + 规则集文件探针 + 规则顺序。
#   第 3 层：SOCKS5 可用且服务运行时，实测流量——16 个国内高风险域名
#     （百度、国家单位 gov.cn/miit.gov.cn、12306、支付宝、淘宝、京东、
#     10086、QQ、微信 + 公安部、税务、央行、122 交管、外交部、市监总局
#     6 个国家单位域名）+ 8 个补漏域名（DeepSeek、上汽大众、红果短剧、
#     丰收互联、农业银行、平安银行、月之暗面、贝壳找房）+ 1 个国内 IP
#     字面量（223.5.5.5）应全部被拒（000），谷歌与 Cloudflare 两个对照站
#     应正常（非 000）。合计 25 个国内目标；本机有全局 IPv6 时另测 1 个
#     国内 IPv6 字面量（2400:3200::1，应被拒），合计 26 个。
#     注意：用 socks5h（域名直通 sing-box）而非 socks5（本地解析后按 IP
#     走）——真实客户端（Shadowrocket/v2rayN）就是把域名交给代理，域名
#     规则只有在 socks5h 下才会被测到；2026-11-22 的漏网问题正是 socks5
#     测不出来的（本地解析后走 geoip 规则，掩盖了域名规则失效）。
# 返回 0=全部通过，1=有失败项。
cnblock_verify() {
    local failures=0
    _cnblock_probe

    echo "  [1/3] 配置校验 ..."
    if [[ -x "$SB_BIN" ]]; then
        if "$SB_BIN" check -c "$SB_CONFIG" >/dev/null 2>&1; then
            echo "        ✓ sing-box check 通过"
        else
            echo "        ✗ sing-box check 失败"
            ((failures+=1))
        fi
    else
        echo "        ? 内核未安装，跳过校验"
        ((failures+=1))
    fi

    echo "  [2/3] 拦截规则与规则集 ..."
    if (( CNBLOCK_P_RULES == 3 )) && [[ "$CNBLOCK_P_SETS" == "ok" ]] && [[ "$CNBLOCK_P_DBS" == "ok" ]] && [[ "$CNBLOCK_P_ORDER" == "ok" ]] && [[ "$CNBLOCK_P_OUTBOUND" == "ok" ]] && [[ "$CNBLOCK_P_EXCLUDE" == "ok" ]]; then
        echo "        ✓ 规则 3/3 条，规则集条目与文件齐全，block 出站就绪，放行规则就绪，拦截在分流之前"
    else
        echo "        ✗ 规则 ${CNBLOCK_P_RULES}/3 条，规则集条目 ${CNBLOCK_P_SETS}，规则集文件 ${CNBLOCK_P_DBS}，顺序 ${CNBLOCK_P_ORDER}，block 出站 ${CNBLOCK_P_OUTBOUND}，放行规则 ${CNBLOCK_P_EXCLUDE}"
        ((failures+=1))
    fi

    echo "  [3/3] 实际流量测试 ..."
    local socks_port socks_user socks_pass
    socks_port=$(state_get_field "socks5" "port" 2>/dev/null)
    if [[ -z "$socks_port" ]]; then
        echo "        ? 未安装 SOCKS5，无法验证实际流量（安装 SOCKS5 后可实测）"
    elif ! systemctl is-active --quiet sing-box 2>/dev/null; then
        echo "        ? sing-box 服务未运行，无法验证实际流量"
    else
        socks_user=$(state_get_field "socks5" "username" 2>/dev/null)
        socks_pass=$(state_get_field "socks5" "password" 2>/dev/null)
        # 高风险国内站点（2026-11-22 用户点名加测 + 同日 RN 扩展实测的
        # 6 个国家单位域名 + 8 个补漏域名代表）：经代理必须全部被拒（000）。
        # 另测一个国内 IP 字面量（223.5.5.5），走 geoip-cn 规则；对照站应正常。
        # socks5h：域名直通 sing-box，测的是真实客户端走的域名规则路径。
        local cn_domains=(www.baidu.com www.gov.cn www.miit.gov.cn kyfw.12306.cn www.alipay.com www.taobao.com www.jd.com www.10086.cn www.qq.com weixin.qq.com www.mps.gov.cn www.chinatax.gov.cn www.pbc.gov.cn www.122.gov.cn www.mfa.gov.cn www.samr.gov.cn www.deepseek.com www.svw-volkswagen.com www.hongguoduanju.com www.zj96596.com www.abcchina.com www.pingbank.com moonshot.ai www.beike.com)
        local foreign_domains=(www.google.com www.cloudflare.com)
        local d code cn_blocked=0 cn_total=0 foreign_ok=0 foreign_total=0
        for d in "${cn_domains[@]}"; do
            cn_total=$((cn_total + 1))
            code=$(_cnblock_curl_code "https://${d}" "$socks_user" "$socks_pass" "$socks_port")
            code=${code:-000}
            if [[ "$code" == "000" ]]; then
                cn_blocked=$((cn_blocked + 1))
                echo "        ✓ ${d} 被拒绝（${code}）"
            else
                echo "        ✗ ${d} 返回 ${code}（应被拒绝）"
                ((failures+=1))
            fi
        done
        # 国内 IP 字面量：http（无证书），应被 geoip-cn 规则拦住。
        cn_total=$((cn_total + 1))
        code=$(_cnblock_curl_code "http://223.5.5.5/" "$socks_user" "$socks_pass" "$socks_port")
        code=${code:-000}
        if [[ "$code" == "000" ]]; then
            cn_blocked=$((cn_blocked + 1))
            echo "        ✓ 223.5.5.5（国内 IP）被拒绝（${code}）"
        else
            echo "        ✗ 223.5.5.5（国内 IP）返回 ${code}（应被拒绝）"
            ((failures+=1))
        fi
        # 国内 IPv6 字面量：仅本机有全局 IPv6 时测（geoip-cn 含 IPv6 段）。
        if _cnblock_has_global_ipv6; then
            cn_total=$((cn_total + 1))
            code=$(_cnblock_curl_code "http://[${CNBLOCK_V6_PROBE_IP}]/" "$socks_user" "$socks_pass" "$socks_port")
            code=${code:-000}
            if [[ "$code" == "000" ]]; then
                cn_blocked=$((cn_blocked + 1))
                echo "        ✓ ${CNBLOCK_V6_PROBE_IP}（国内 IPv6）被拒绝（${code}）"
            else
                echo "        ✗ ${CNBLOCK_V6_PROBE_IP}（国内 IPv6）返回 ${code}（应被拒绝）"
                ((failures+=1))
            fi
        else
            echo "        ? 本机无全局 IPv6，跳过 IPv6 探针"
        fi
        for d in "${foreign_domains[@]}"; do
            foreign_total=$((foreign_total + 1))
            code=$(_cnblock_curl_code "https://${d}" "$socks_user" "$socks_pass" "$socks_port")
            code=${code:-000}
            if [[ "$code" != "000" ]]; then
                foreign_ok=$((foreign_ok + 1))
                echo "        ✓ ${d} 正常（${code}，对照）"
            else
                echo "        ✗ ${d} 无响应（${code}，对照应正常）"
                ((failures+=1))
            fi
        done
        if (( cn_blocked == cn_total && foreign_ok == foreign_total )); then
            echo "        ✓ 国内 ${cn_blocked}/${cn_total} 被拒，对照 ${foreign_ok}/${foreign_total} 正常：拦截生效"
        elif (( foreign_ok == 0 )); then
            # 对照站全部无响应时，国内站的 000 无法与断网区分，上面对照循环
            # 已记 failures，这里只提示，不再重复计数。
            echo "        ? 对照网站全部无响应，无法判断（可能是网络问题）"
        fi
    fi

    if (( failures == 0 )); then
        echo ""
        log_ok "拦截验证全部通过。"
        return 0
    fi
    echo ""
    log_warn "拦截验证发现 ${failures} 项问题。"
    return 1
}

# 快速实测（v1.10.0）：无参时紧凑测试拦截是否按预期工作（5 个国内域名 +
# 1 个国内 IPv4 + 有 IPv6 时 1 个国内 IPv6 应被拒，3 个海外对照应正常）；
# 带参时实测单个目标（域名或 IP），报告动作与推断。
# 无参返回：0=全部符合预期，1=有不符或无法实测。
# 带参返回：0=实测完成（动作见输出），1=无法实测。
cnblock_test() {
    local target="${1:-}"
    if [[ -n "$target" ]]; then
        _cnblock_test_target "$target"
        return $?
    fi
    _cnblock_test_suite
}

# 无参紧凑测试（自写循环，不重构 verify 第三层的循环，免得动已验证代码）。
_cnblock_test_suite() {
    local socks_port socks_user socks_pass
    _cnblock_probe
    if (( CNBLOCK_P_RULES == 0 )); then
        log_info "提示：拦截未开启，国内目标预期可达，下面的 BLOCK 断言将全部 FAIL。"
    fi
    socks_port=$(state_get_field "socks5" "port" 2>/dev/null)
    if [[ -z "$socks_port" ]]; then
        log_err "未安装 SOCKS5，无法实测（安装 SOCKS5 后可用）。"
        return 1
    fi
    if ! systemctl is-active --quiet sing-box 2>/dev/null; then
        log_err "sing-box 服务未运行，无法实测。"
        return 1
    fi
    socks_user=$(state_get_field "socks5" "username" 2>/dev/null)
    socks_pass=$(state_get_field "socks5" "password" 2>/dev/null)
    local cn_domains=(www.baidu.com www.gov.cn www.alipay.com www.taobao.com www.deepseek.com)
    local foreign_domains=(www.google.com www.cloudflare.com github.com)
    local d code cn_blocked=0 cn_total=0 foreign_ok=0 foreign_total=0
    echo "  CN Egress Guard 快速测试："
    for d in "${cn_domains[@]}"; do
        cn_total=$((cn_total + 1))
        code=$(_cnblock_curl_code "https://${d}" "$socks_user" "$socks_pass" "$socks_port")
        code=${code:-000}
        if [[ "$code" == "000" ]]; then
            cn_blocked=$((cn_blocked + 1))
            echo "    PASS ${d} 被拒"
        else
            echo "    FAIL ${d} 返回 ${code}（应被拒）"
        fi
    done
    cn_total=$((cn_total + 1))
    code=$(_cnblock_curl_code "http://223.5.5.5/" "$socks_user" "$socks_pass" "$socks_port")
    code=${code:-000}
    if [[ "$code" == "000" ]]; then
        cn_blocked=$((cn_blocked + 1))
        echo "    PASS 223.5.5.5（国内 IPv4）被拒"
    else
        echo "    FAIL 223.5.5.5（国内 IPv4）返回 ${code}（应被拒）"
    fi
    if _cnblock_has_global_ipv6; then
        cn_total=$((cn_total + 1))
        code=$(_cnblock_curl_code "http://[${CNBLOCK_V6_PROBE_IP}]/" "$socks_user" "$socks_pass" "$socks_port")
        code=${code:-000}
        if [[ "$code" == "000" ]]; then
            cn_blocked=$((cn_blocked + 1))
            echo "    PASS ${CNBLOCK_V6_PROBE_IP}（国内 IPv6）被拒"
        else
            echo "    FAIL ${CNBLOCK_V6_PROBE_IP}（国内 IPv6）返回 ${code}（应被拒）"
        fi
    else
        echo "    SKIP 本机无全局 IPv6，跳过 IPv6 探针"
    fi
    for d in "${foreign_domains[@]}"; do
        foreign_total=$((foreign_total + 1))
        code=$(_cnblock_curl_code "https://${d}" "$socks_user" "$socks_pass" "$socks_port")
        code=${code:-000}
        if [[ "$code" != "000" ]]; then
            foreign_ok=$((foreign_ok + 1))
            echo "    PASS ${d} 正常（对照）"
        else
            echo "    FAIL ${d} 无响应（对照应正常）"
        fi
    done
    echo "    国内 ${cn_blocked}/${cn_total} 被拒，海外 ${foreign_ok}/${foreign_total} 正常"
    if (( cn_blocked == cn_total && foreign_ok == foreign_total )); then
        log_ok "快速测试全部通过。"
        return 0
    fi
    log_warn "快速测试发现不符项。"
    return 1
}

# 单目标实测：报告 Target / Resolved IP / Action / 推断。
# 注意：sing-box 不提供“哪条规则命中”的信息，所有“命中哪层”均为推断，
# 依据是可验证的事实（是否在 45 名单里、是否 .cn、解析出的 IP 字面量
# 再测一次的结果），一律标“推断”，绝不硬说。
_cnblock_test_target() {
    local target="$1"
    local socks_port socks_user socks_pass
    if ! _cnblock_valid_target "$target"; then
        log_err "目标无效：请输入域名（如 example.com）、IPv4 或 IPv6 地址，不要带端口、路径或 http://。"
        return 1
    fi
    socks_port=$(state_get_field "socks5" "port" 2>/dev/null)
    if [[ -z "$socks_port" ]]; then
        log_err "未安装 SOCKS5，无法实测（安装 SOCKS5 后可用）。"
        return 1
    fi
    if ! systemctl is-active --quiet sing-box 2>/dev/null; then
        log_err "sing-box 服务未运行，无法实测。"
        return 1
    fi
    socks_user=$(state_get_field "socks5" "username" 2>/dev/null)
    socks_pass=$(state_get_field "socks5" "password" 2>/dev/null)

    local is_ip=0 resolved=""
    if [[ "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$target" == *:* ]]; then
        is_ip=1
        resolved="$target"
    else
        resolved=$(getent hosts "$target" 2>/dev/null | head -1 | awk '{print $1}')
        resolved=${resolved:-}
    fi

    local url code
    if (( is_ip == 1 )); then
        if [[ "$target" == *:* ]]; then
            url="http://[${target}]/"
        else
            url="http://${target}/"
        fi
    else
        url="https://${target}"
    fi
    code=$(_cnblock_curl_code "$url" "$socks_user" "$socks_pass" "$socks_port")
    code=${code:-000}

    local action="ALLOW"
    [[ "$code" == "000" ]] && action="BLOCK"
    if [[ "$action" == "BLOCK" ]]; then
        # 000 既可能是被拦截，也可能是代理链路/网络本身不通。先用海外对照站排除后者：
        # 对照站也连不上时不下"被拦截"的结论。
        local ctl
        ctl=$(_cnblock_curl_code "https://www.google.com" "$socks_user" "$socks_pass" "$socks_port")
        if [[ "$ctl" == "000" ]]; then
            echo "  Target: ${target}"
            echo "  Action: UNKNOWN（海外对照站也无法连通：代理链路或网络异常，无法判断是否被拦截）"
            return 1
        fi
    fi

    echo "  Target: ${target}"
    echo "  Resolved IP: ${resolved:--}"
    echo "  Action: ${action}（${code}）"

    local notes=()
    local extra_json
    extra_json=$(_cnblock_extra_domains_json)
    if (( is_ip == 0 )); then
        # 后缀判定：domain_suffix 规则按后缀匹配，www.deepseek.com 命中
        # deepseek.com 条目，不能只用精确相等查；用 bash 循环做后缀比对
        # （jq 里 $t | endswith 会把 . 重绑为 $t，写起来易错）。
        local in_extra=0 d
        while IFS= read -r d; do
            if [[ "$target" == "$d" || "$target" == *".$d" ]]; then
                in_extra=1
                break
            fi
        done < <(echo "$extra_json" | jq -r '.[]' 2>/dev/null)
        if (( in_extra == 1 )); then
            notes+=("在 45 个补漏域名名单里")
        fi
        if [[ "$target" == *.cn ]]; then
            notes+=(".cn 域名（geosite-cn 覆盖）")
        fi
        # 再测一次解析出的 IP 字面量，区分域名层与 IP 层。
        if [[ -n "$resolved" ]]; then
            local ip_url ip_code
            if [[ "$resolved" == *:* ]]; then
                ip_url="http://[${resolved}]/"
            else
                ip_url="http://${resolved}/"
            fi
            ip_code=$(_cnblock_curl_code "$ip_url" "$socks_user" "$socks_pass" "$socks_port")
            ip_code=${ip_code:-000}
            if [[ "$action" == "BLOCK" && "$ip_code" == "000" ]]; then
                notes+=("解析出的 IP 也被拒，推断 IP 层命中（geoip-cn）")
            elif [[ "$action" == "BLOCK" && "$ip_code" != "000" ]]; then
                notes+=("解析出的 IP 可达而域名被拒，推断域名层命中（geosite-cn）")
            elif [[ "$action" == "ALLOW" && "$ip_code" == "000" ]]; then
                notes+=("域名可达但 IP 被拒（域名与 IP 判定不一致，以实测动作为准）")
            fi
        fi
    else
        if [[ "$action" == "BLOCK" ]]; then
            notes+=("IP 字面量被拒，推断 IP 层命中（geoip-cn）")
        fi
    fi
    if (( ${#notes[@]} == 0 )); then
        if [[ "$action" == "BLOCK" ]]; then
            notes+=("被拒，但无法从域名/IP 特征推断命中层（可能为 geosite-cn 规则集命中）")
        else
            notes+=("未命中任何拦截规则")
        fi
    fi
    local n
    for n in "${notes[@]}"; do
        echo "  推断：${n}"
    done
    return 0
}

# 诊断（v1.10.0）：Guard 状态 + 配置校验 + 陈旧检查 + 快速实测。
# 输出健康汇总与可操作建议。返回 0=无问题，1=发现问题。
# 注意：拦截未开启是用户选择，只提示、不计为问题（与全局诊断一致）。
cnblock_doctor() {
    local problems=0
    _cnblock_probe
    echo "  CN Egress Guard 诊断："
    echo "    · Guard 状态：${CNBLOCK_P_GUARD}"
    if [[ -x "$SB_BIN" ]]; then
        if "$SB_BIN" check -c "$SB_CONFIG" >/dev/null 2>&1; then
            echo "    · 配置校验：OK"
        else
            echo "    · 配置校验：FAIL（sing-box check 未通过）"
            problems=$((problems + 1))
        fi
    else
        echo "    · 配置校验：跳过（内核未安装）"
    fi
    echo "    · 拦截规则：${CNBLOCK_P_RULES}/3 条，顺序 ${CNBLOCK_P_ORDER}，block 出站：${CNBLOCK_P_OUTBOUND}，放行规则：${CNBLOCK_P_EXCLUDE}"
    echo "    · 规则集条目：${CNBLOCK_P_SETS}，规则集文件：${CNBLOCK_P_DBS}"
    local geoip_srs geosite_srs
    geoip_srs=$(_cnblock_geoip_path)
    geosite_srs=$(_cnblock_geosite_path)
    echo "    · geosite-cn.srs：$(_cnblock_layer_state "$geosite_srs")"
    echo "    · geoip-cn.srs：$(_cnblock_layer_state "$geoip_srs")"
    echo "    · 上次更新：$(_cnblock_last_update_text)"
    local socks_port
    socks_port=$(state_get_field "socks5" "port" 2>/dev/null)
    if [[ -z "$socks_port" ]]; then
        echo "    · 实测：跳过（未安装 SOCKS5）"
    elif ! systemctl is-active --quiet sing-box 2>/dev/null; then
        echo "    · 实测：跳过（服务未运行）"
    else
        local socks_user socks_pass code
        socks_user=$(state_get_field "socks5" "username" 2>/dev/null)
        socks_pass=$(state_get_field "socks5" "password" 2>/dev/null)
        code=$(_cnblock_curl_code "https://www.baidu.com" "$socks_user" "$socks_pass" "$socks_port")
        code=${code:-000}
        if (( CNBLOCK_P_RULES == 3 )); then
            if [[ "$code" == "000" ]]; then
                echo "    · 实测：www.baidu.com 被拒 OK"
            else
                echo "    · 实测：www.baidu.com 返回 ${code}（应被拒）"
                problems=$((problems + 1))
            fi
        else
            echo "    · 实测：www.baidu.com 返回 ${code}（拦截未开启，仅作连通参考）"
        fi
        code=$(_cnblock_curl_code "https://www.google.com" "$socks_user" "$socks_pass" "$socks_port")
        code=${code:-000}
        if [[ "$code" != "000" ]]; then
            echo "    · 实测：www.google.com 正常 OK"
        else
            echo "    · 实测：www.google.com 无响应（对照应正常）"
            problems=$((problems + 1))
        fi
    fi
    local suggestions=()
    case "$CNBLOCK_P_GUARD" in
        FAILED)
            suggestions+=("拦截规则不完整，建议在主菜单 12/c 关闭后重新开启")
            if [[ "$CNBLOCK_P_OUTBOUND" != "ok" ]]; then
                suggestions+=("block 出站缺失（sing-box check 会报 outbound not found: block），重新开启时自动补齐")
            fi
            if [[ "$CNBLOCK_P_EXCLUDE" != "ok" ]]; then
                suggestions+=("放行规则缺失（gstatic.com 等连通性检测域名会被误拦），重新开启时自动补齐")
            fi
            problems=$((problems + 1))
            ;;
        DEGRADED)
            if [[ "$CNBLOCK_P_STALE" == "stale" ]]; then
                suggestions+=("规则集已过期 ${CNBLOCK_P_STALE_DAYS} 天，建议 sbx cnblock update")
            fi
            if [[ "$CNBLOCK_P_LAST_UPDATE" == "failed" ]]; then
                suggestions+=("上次规则集更新失败，建议 sbx cnblock update 重试")
            fi
            problems=$((problems + 1))
            ;;
        DISABLED)
            suggestions+=("拦截未开启：代理可访问国内网站，如需防护请在主菜单 12/c 开启")
            ;;
    esac
    if (( ${#suggestions[@]} > 0 )); then
        echo "  建议："
        local s
        for s in "${suggestions[@]}"; do
            echo "    · ${s}"
        done
    fi
    if (( problems == 0 )); then
        log_ok "诊断完成：未发现问题。"
        return 0
    fi
    log_warn "诊断完成：发现 ${problems} 项问题。"
    return 1
}

# 升级重断言钩子（v1.8.2 起，仅主菜单调用，CLI 不触发）：
# install.sh 在升级安装且拦截已开启时留 $SB_ETC/.cnblock-reassert 标记。
# 旧版只写 2 条规则（无补漏域名规则），且可能被 WARP 规则压在后面；
# 标记存在 + 内核已装 + 配置存在 → 执行一次 cnblock_enable（幂等重写：
# 删旧规则、按新版插 3 条规则到 sniff 之后、WARP 之前），成功后删标记。
# 失败时保留标记（下次启动 sbx 再试），同一进程内只试一次；内核/配置
# 未就绪时不消耗尝试次数。
# 拦截只是辅助功能：钩子成功时静默（不输出、不 pause、不挡菜单入口）；
# 失败时只留一行警告（不 pause），用户可在 12/c 手动处理。
CNBLOCK_REASSERT_TRIED=0
cnblock_maybe_reassert() {
    local marker
    marker="$SB_ETC/.cnblock-reassert"
    [[ -f "$marker" ]] || return 0
    [[ -x "$SB_BIN" && -f "$SB_CONFIG" ]] || return 0
    (( CNBLOCK_REASSERT_TRIED == 0 )) || return 0
    CNBLOCK_REASSERT_TRIED=1
    if cnblock_enable >/dev/null 2>&1; then
        rm -f "$marker"
    else
        log_warn "拦截规则更新失败，可在主菜单 12/c 手动重新开启拦截。"
    fi
    return 0
}

# ---------- CN 拦截菜单状态探针（只读，不做网络请求、不写状态） ----------
CNBLOCK_M_STATE="disabled"
CNBLOCK_M_RULES_TXT="0/3 条"
CNBLOCK_M_DBS_TXT="未下载"
CNBLOCK_M_STATE_REC="unset"
CNBLOCK_M_OUTBOUND_TXT="缺失"
CNBLOCK_M_EXCLUDE_TXT="未启用"

_cnblock_menu_status() {
    CNBLOCK_M_STATE="disabled"
    CNBLOCK_M_RULES_TXT="0/3 条"
    CNBLOCK_M_DBS_TXT="未下载"
    CNBLOCK_M_STATE_REC="unset"
    CNBLOCK_M_OUTBOUND_TXT="缺失"
    CNBLOCK_M_EXCLUDE_TXT="未启用"
    _cnblock_probe
    CNBLOCK_M_RULES_TXT="${CNBLOCK_P_RULES}/3 条"
    if [[ "$CNBLOCK_P_DBS" == "ok" ]]; then
        CNBLOCK_M_DBS_TXT="齐全"
    fi
    if [[ "$CNBLOCK_P_OUTBOUND" == "ok" ]]; then
        CNBLOCK_M_OUTBOUND_TXT="已就绪"
    fi
    if [[ "$CNBLOCK_P_EXCLUDE" == "ok" ]]; then
        CNBLOCK_M_EXCLUDE_TXT="已就绪"
    elif (( CNBLOCK_P_RULES > 0 )); then
        CNBLOCK_M_EXCLUDE_TXT="缺失"
    fi
    CNBLOCK_M_STATE_REC="$CNBLOCK_P_STATE"
    case "$CNBLOCK_P_GUARD" in
        ACTIVE) CNBLOCK_M_STATE="enabled" ;;
        DEGRADED) CNBLOCK_M_STATE="degraded" ;;
        DISABLED) CNBLOCK_M_STATE="disabled" ;;
        *) CNBLOCK_M_STATE="partial" ;;
    esac
}

menu_cnblock() {
    local c state_pill db_pill ex_pill
    while true; do
        _cnblock_menu_status
        ui_menu_head "CN 出站拦截" "CN-GUARD"
        case "$CNBLOCK_M_STATE" in
            enabled) state_pill="$(ui_status_pill ok "已开启")" ;;
            degraded) state_pill="$(ui_status_pill degraded "已开启·规则集过期")" ;;
            disabled) state_pill="$(ui_status_pill stopped "未开启")" ;;
            *) state_pill="$(ui_status_pill error "不一致")" ;;
        esac
        if [[ "$CNBLOCK_M_DBS_TXT" == "齐全" ]]; then
            db_pill="$(ui_status_pill ok "齐全")"
        else
            db_pill="$(ui_status_pill warn "未下载")"
        fi
        case "$CNBLOCK_M_EXCLUDE_TXT" in
            已就绪) ex_pill="$(ui_status_pill ok "已就绪")" ;;
            缺失) ex_pill="$(ui_status_pill warn "缺失")" ;;
            *) ex_pill="$(ui_status_pill stopped "未启用")" ;;
        esac
        ui_kv "拦截状态" "$state_pill" "$WHITE"
        ui_kv "拦截规则" "$CNBLOCK_M_RULES_TXT" "$WHITE"
        ui_kv "规则集" "$db_pill" "$WHITE"
        ui_kv "block 出站" "$CNBLOCK_M_OUTBOUND_TXT" "$WHITE"
        ui_kv "放行规则" "$ex_pill" "$WHITE"
        ui_kv "状态记录" "$CNBLOCK_M_STATE_REC" "$WHITE"
        if [[ "$CNBLOCK_M_STATE" == "partial" ]]; then
            ui_line "${GRAY}规则不完整：建议关闭后重新开启${PLAIN}"
        fi
        if [[ "$CNBLOCK_M_STATE" == "degraded" ]]; then
            if [[ "$CNBLOCK_P_STALE" == "stale" ]]; then
                ui_line "${GRAY}规则集已过期 ${CNBLOCK_P_STALE_DAYS} 天：拦截仍生效，建议更新规则集${PLAIN}"
            else
                ui_line "${GRAY}上次规则集更新失败：拦截仍生效，建议重试更新${PLAIN}"
            fi
        fi
        ui_line "${GRAY}开启后，国内域名/IP 走代理时将被直接拒绝，微信/支付宝等请走直连${PLAIN}"
        ui_line "${GRAY}放行规则：gstatic.com、cp.cloudflare.com 走直连（Karing 等客户端的延迟检测用）${PLAIN}"
        ui_line "${GRAY}回国需求（境外访问国内网站）请关闭本功能${PLAIN}"
        ui_bot
        if [[ "$CNBLOCK_M_STATE" == "disabled" ]]; then
            ui_menu_select "请选择" 0 \
                "1/e|开启拦截|国内域名与 IP 走代理时直接拒绝" \
                "2/v|验证拦截效果|检查配置、规则集与实测流量" \
                "3/u|更新规则集|下载最新 geosite-cn/geoip-cn" \
                "4/t|快速测试|实测国内/海外目标是否按预期" \
                "5/o|诊断|健康检查与建议" \
                "0/q|返回主菜单|" || return 0
        else
            ui_menu_select "请选择" 0 \
                "1/d|关闭拦截|恢复代理访问国内网站" \
                "2/v|验证拦截效果|检查配置、规则集与实测流量" \
                "3/u|更新规则集|下载最新 geosite-cn/geoip-cn" \
                "4/t|快速测试|实测国内/海外目标是否按预期" \
                "5/o|诊断|健康检查与建议" \
                "0/q|返回主菜单|" || return 0
        fi
        c="$UI_SEL_KEY"
        case "$c" in
            1/e) cnblock_enable ;;
            1/d)
                if ui_dialog_confirm "确定关闭拦截？关闭后代理可访问国内网站，存在境外 IP 登录国内账号的风险。"; then
                    cnblock_disable
                fi
                ;;
            2/v) cnblock_verify ;;
            3/u) cnblock_update ;;
            4/t) cnblock_test ;;
            5/o) cnblock_doctor ;;
            0/q) return ;;
            *) log_warn "无效选项"; sleep 1; continue ;;
        esac
        pause
    done
}
