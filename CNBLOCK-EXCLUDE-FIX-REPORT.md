# CN 拦截误拦 Karing 延迟检测修复报告（放行规则）

**日期**：2026-11-28
**版本**：v1.10.2 → v1.10.3（本地工作目录，**未推送**）
**工作目录**：`~/workspace/cnblock_fix`

## 一、根因

Karing 默认延迟检测用 `https://www.gstatic.com/generate_204`。DediOne 实测：
走 SOCKS5 代理 `www.gstatic.com/generate_204` 返回 000（被拦），
`cp.cloudflare.com/generate_204` 返回 204（通）。

原因是上游 v2fly domain-list-community 把 `www.gstatic.com`、
`ssl.gstatic.com`、`fonts.googleapis.com` 等打了 `@cn` 标签，SagerNet
sing-geosite 生成 geosite-cn.srs 时原样并入，导致 geosite-cn 误含这些
Google 域名（GitHub v2fly/domain-list-community#3378、
throneproj/Throne#977 同款问题）。CN 拦截的 geosite-cn 规则因此误拦
连通性检测流量：节点本身是通的，但 Karing 里全部节点延迟测不出来、
显示感叹号；小火箭默认测 `gstatic.com` 以外的地址（或本地解析），
所以不受影响。

## 二、修复方案

`cnblock_enable()` 在同一 config_transaction 里，先插一条放行规则
`{domain_suffix: [gstatic.com, cp.cloudflare.com], outbound: "direct"}`，
位置在 sniff 规则之后、3 条 block 规则之前，first-match 优先放行检测流量。
`domain_suffix` 按后缀匹配，覆盖全部子域名（www.gstatic.com、
ssl.gstatic.com 等）。`cp.cloudflare.com` 是 Karing 另一常用检测地址
（测速 URL 默认值），一并放行。

只放行连通性检测域名，不碰 Apple 相关域名（脚本不为 Apple 改白名单，
用户早先已定；Apple 问题是客户端分流的事，与本规则无关）。

规则数显示仍为 3（仅指 3 条 block 规则），放行规则单独显示、不计入 3/3。

## 三、改动文件

### `protocols/cnblock/cnblock.sh`（+158/-68 行，核心改动）

- 新增常量 `CNBLOCK_EXCLUDE_DOMAINS`（`gstatic.com`、`cp.cloudflare.com`）
  及 `_cnblock_exclude_domains_json()` helper。
- `_CNBLOCK_JQ_DEF` 新增两个带参 def（与 `is_cnblock` 同口径，结构识别，
  不写自定义字段到配置）：
  - `is_cnblock_exclude($ex)`：outbound=="direct" 且 domain_suffix
    为非空数组、全部元素都在排除清单里（子集判定；清单扩充后旧规则仍被
    识别、重写时自动补齐）。写成带参 def 是因为 `_cnblock_domains_in_sync`
    等调用方不传 excludes，全局 `$excludes` 未定义时 jq 会直接报错。
  - `is_cnblock_guard($ex)`：拦截规则或放行规则——探针顺序检查用：
    四条规则必须整体在所有分流规则之前，放行规则本身是 direct 出站，
    不能把它当成“其他出站规则”去比顺序（否则顺序永远报 wrong）。
- `_cnblock_probe()` 新增 `CNBLOCK_P_EXCLUDE`（ok/missing；恰好 1 条为
  ok，0 条或多条都算 missing——多条是重复写入的 bug，重跑 enable 会去重）；
  顺序检查改用 `is_cnblock_guard`；Guard 的 ACTIVE 判定加上放行规则
  （拦截已开但缺放行规则 → FAILED）。
- `cnblock_enable()`：
  - 幂等早返条件加上放行规则 ok，并新增 `_cnblock_excludes_in_sync`
    （放行域名集合精确比对，与补漏域名清单同款逻辑；v1.10.2 老配置
    无放行规则时不会误判“已开启”，重跑自动补回）。
  - 同一事务里先删旧拦截规则与旧放行规则（幂等去重），再把放行规则插到
    sniff 之后、3 条 block 规则之前（无裸 sniff 时头部补 sniff、放行、
    block×3）。
  - 成功日志注明放行域名与 Karing 延迟检测可用。
- `cnblock_disable()`：关闭时同时移除放行规则（block 出站仍保留）；
  早返条件改为“规则 0 条且无放行规则”（残留的放行规则也会被清理）。
- `cnblock_status()` / `cnblock_verify()`（第 2 层）/ `cnblock_doctor()` /
  菜单（`_cnblock_menu_status` 新增 `CNBLOCK_M_EXCLUDE_TXT`，菜单加
  “放行规则”行与灰色说明）：同步显示放行规则状态，缺失时提示重新开启
  自动补齐。

### `sbx.sh`（+4/-1 行）

- 主菜单诊断（`run_diagnostics`）CN-BLOCK 段：ACTIVE 判定加上
  `CNBLOCK_P_EXCLUDE == "ok"`；不一致分支加放行规则缺失的针对性提示。

### 版本与文档

- `core/env.sh`：`SBM_VERSION` 1.10.2 → 1.10.3。
- `install.sh`：`SBX_VERSION` v1.10.2 → v1.10.3；**另将 `SBX_TAG`
  v1.10.2 → v1.10.3**（bootstrap 下载 tarball 用的 tag，不跟升的话
  一键安装会拉到旧版包；v1.10.2 发布时两者就是一起升的）。
- `README.md`：3 处安装链接 v1.10.2 → v1.10.3。
- `CHANGELOG.md`：顶部新增 v1.10.3 条目。

## 四、测试

### 单元测试（fake sing-box / fake curl / fake systemctl）

| 套件 | 结果 |
|---|---|
| bash -n 全项目（全部 .sh） | 通过 |
| `tests/cnblock_test.sh` | **196 PASS / 0 FAIL**（原 155；§1 新增 1 条放行规则位置断言，§23 新增 40 条） |
| `tests/cnguard_test.sh` | **108 PASS / 0 FAIL** |
| `tests/cnguard_hardening_test.sh` | **32 PASS / 0 FAIL** |
| `tests/version_check.sh` | 通过（1.10.3 四处一致） |

`tests/cnblock_test.sh` 新增 **§23 连通性检测放行规则**（40 个断言）：
干净配置 enable 返回 0、放行规则恰好 1 条且在 3 条 block 规则之前
（sniff→direct→block×3）、内容为 gstatic.com + cp.cloudflare.com、
3 条 block 规则仍在、放行规则不计入 3 条、探针 EXCLUDE ok 且 Guard
ACTIVE、status/菜单显示已就绪；WARP 写入后放行规则仍在 block 之前、
顺序探针仍 ok、Guard 仍 ACTIVE；**v1.10.2 升级场景**（3 条 block 规则
齐全、无放行规则）探针报 missing、Guard 为 FAILED、status/verify/
doctor 均返回非 0 并点名放行规则缺失、重跑 enable 自动补回并恢复
ACTIVE；重复开启幂等（放行 1 条、block 3 条）；放行域名集合过期
（只剩 gstatic.com）时重跑 enable 按当前清单重写回 2 个域名；关闭后
放行与 block 规则均移除、block 出站保留、Guard 为 DISABLED。

随新顺序同步更新的旧断言：§1（geosite/geoip/补漏规则下标 1/2/3 →
2/3/4）、§3/§18/§19（顺序 sniff→direct→block×3→resolve→warp）、
`cnguard_test.sh` §1（补漏规则下标 3 → 4，两处）。

测试修 bug 记录：测试 helper `cnblock_exclude_count()` 里双引号内的
`$excludes` 会被 bash 当变量展开，`set -u` 下报 unbound variable
（$excludes 是 jq 变量，不是 bash 变量）；修为 `\$excludes` 转义
（产品代码里相关 jq 程序均为单引号，不受影响）。

### 真实二进制测试（sing-box 1.14.4 + 真实 .srs 规则集）

`tests/cnblock_real_binary_test.sh`：**28 PASS / 0 FAIL**（原 22；+6：
放行规则计数、探针 EXCLUDE、检测地址走 direct 日志、重复开启放行
幂等、关闭移除放行规则、关闭后无 block 规则）。

真实流量验证（经 SOCKS 入站，`run_with_traffic`）：
- 负向对照复现 DediOne 故障模式：3 条规则、无 block 出站时日志报
  `outbound not found: block`，国内 IP 未被 block 出站拦截。
- enable 后真实 `sing-box check` 通过，`run` 正常启动（sing-box
  started），无 FATAL。
- 打 223.5.5.5 被 block 出站真实拦截（`blocked connection`），日志无
  `outbound not found`；打 google 走 direct 出站。
- **打 `www.gstatic.com/generate_204` 走 direct 出站**
  （日志 `outbound/direct[direct]: outbound connection to
  www.gstatic.com:443`），未被 geosite-cn 误拦——放行规则生效的路由
  证据。
- 顺序 sniff→direct→block×3；后加 direct 规则后顺序
  sniff→direct→block×3→direct；重复开启幂等；关闭后放行与 block
  规则均移除、出站保留、check 仍通过。

**SKIP 1 项（沙箱环境限制，非产品问题）**：gstatic 的 204 返回码断言
以 google 对照站为门控——沙箱出站只走 HTTP 代理，sing-box direct
出站的 TCP 能建连（日志有 outbound connection），但 TLS 会被出站代理
重置：经代理打 google.com 与 gstatic 均返回 000，而沙箱直连 gstatic
是 204（已实测确认）。因此对照站经代理也不通时 SKIP 该条，只认路由
日志为放行证据；真机上对照站通时正常断言 204。断言实现与
`cnblock_verify` 的对照站判定同款逻辑。SKIP 行打印：
`SKIP: 对照站 google 经代理返回 000（沙箱直连 HTTPS 被拦截），gstatic
返回码无法验证；路由日志已证明走 direct`。

### 全量回归

`tests/run_all.sh`：**通过 24，失败 1**，失败项仅
`ui_twokey_test.sh`（12/13）。

- warp 相关 5 套件全过：`warp_test.sh`、`warp_healthcheck_fix_test.sh`、
  `warp_sbx_owner_fix_test.sh`、`warp_temp_cleanup_test.sh`、
  `warp_verify_persist_test.sh`。
- 其余全过：smoke、version_check、round2_regression、anytls、
  cnblock、cnblock_real_binary、cnguard、cnguard_hardening、export、
  install_all、panel_nav、pins、port_guard、submenu_nav、
  subscription_rotate、termius_fix、ui_clean、ui_test、
  subscription_test.py。

### ui_twokey_test.sh 12/13 说明（与本次改动无关）

失败项是第 9 条 PTY 时序断言：“输入 12 不回车、停顿 1.0 秒后不执行
（q 退出 RC=2）”——测主菜单数字键读取的时序行为。证据：

- `git diff` 确认本次改动 9 个文件，未动 `core/ui/`（按键读取逻辑
  所在），`sbx.sh` 只改了诊断页 `run_diagnostics` 的 4 行（该测试
  用例不调用诊断页）；`core/env.sh` 只改了版本号字符串；
  `tests/ui_twokey_test.sh` 本身未改动。失败用例执行的代码路径与
  v1.10.2 HEAD 字节一致。
- v1.10.2 修复报告已记录同一套件为 PTY 时序抖动（run_all 24/25，
  当时单独跑两次均为 13/13）；本次在服务重启后的沙箱环境里连续
  5 次均为 12/13、同一条失败，属环境时序波动，非回归。
- 未在基线 worktree 上重跑对照：执行基线 worktree 的 exec 结果
  触发了执行风险检查，按检查要求未继续在该 worktree 里跑测试；
  worktree 留在 `~/workspace/baseline_twokey`（v1.10.2 HEAD
  2b3b232），可由父代理决定是否删除或用于对照。
- 建议：真机或负载较低时重跑一次确认；不阻塞 v1.10.3 发布（v1.10.2
  发布时同一套件也是 12/13 的已知抖动状态）。

## 五、升级影响

- v1.10.2 老用户升级到 v1.10.3 后：配置里有 3 条 block 规则但无放行
  规则，探针判 Guard 为 FAILED（非 ACTIVE），status/verify/doctor
  均提示放行规则缺失；重跑一次 `cnblock_enable`（或主菜单重断言
  钩子触发）即自动补回放行规则，恢复 ACTIVE。无需手动改配置。
- DediOne 上验证过的临时 workaround（手动补 block 出站）不受影响；
  v1.10.3 重装后 enable 全自动。
- 拦截语义不变：国内域名/IP 仍被拒（223.5.5.5 真实流量验证通过）；
  只多放行 gstatic.com 与 cp.cloudflare.com 两个检测域名。

## 六、待办（父代理）

- 推送 GitHub 主线 v1.10.3（born-final 单 commit + tag，流程同 v1.10.2；
  本地只改未推）。
- 删除 `~/workspace/baseline_twokey` worktree（见上节）。
- 真实 sing-box 二进制与规则集在 `/tmp/sb_test/`（沙箱重启会清；
  真实二进制测试缺失时自动 SKIP，缺失规则集时自动现下载）。
- /tmp 下残留复现脚本 `/tmp/repro_gstatic.sh`、`/tmp/debug_enable.sh`
  及若干 `tmp.*` 临时目录，均为一次性调试物，随 /tmp 清理即可。
