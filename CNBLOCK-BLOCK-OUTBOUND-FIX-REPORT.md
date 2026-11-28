# CN 拦截开启失败修复报告（block 出站缺失）

**日期**：2026-11-28
**版本**：v1.10.1 → v1.10.2
**故障来源**：用户在 DediOne 上实测，CN 拦截菜单点 [1/e] 开启拦截失败

## 一、故障现象

```
ℹ geosite-cn.srs 已存在，跳过下载。
ℹ geoip-cn.srs 已存在，跳过下载。
✗ Sing-box 配置语法校验未通过！已放弃本次更改。
FATAL[0000] initialize router: rule[1]: outbound not found: block
✗ 拦截开启失败，配置已回滚。
```

## 二、根因

`protocols/cnblock/cnblock.sh` 的 `cnblock_enable()` 只往 `route.rules` 里插 3 条
`outbound: "block"` 的规则，但从来没保证配置的 `outbounds` 数组里存在
`{"type": "block", "tag": "block"}` 这个出站。`templates/base.json` 只有
`direct` 出站，DediOne 的配置同样没有 block 出站，规则引用了一个不存在的
出站，sing-box 拒绝加载，事务回滚。

**补充实测发现（2026-11-28 沙箱，真实 sing-box 1.14.4 + 真实规则集）：**
1.14.4 的 `check` 不校验路由规则的出站引用（即使写一个完全不存在的出站名
也照样通过）；失败发生在流量命中规则时——每条命中连接报
`router: outbound not found: block`，连接失败。DediOne 的版本则在启动 /
校验时就 FATAL。根因相同（缺 block 出站），只是报错时机因版本而异。
因此真实验证必须走流量，不能只看 check。

## 三、修复内容

### `protocols/cnblock/cnblock.sh`（核心）
- **`cnblock_enable()`**：在插入 3 条 block 规则的同一个 `config_transaction`
  里，先确保 `.outbounds` 含 `{type: "block", tag: "block"}`——没有就追加，
  已有（tag+type 双条件判重）不重复加；`.outbounds` 为空或不存在时用 `// []`
  兜底。幂等检查（3 条规则 + 规则集 + 文件 + 顺序）再加出站条件，
  出站缺失时不短路、走重写路径自动补回。
- **`_cnblock_probe()`**：新增 `CNBLOCK_P_OUTBOUND`（ok/missing），用 jq 检查
  `.outbounds[]? | select(.tag == "block" and .type == "block")`。Guard 的
  ACTIVE 判定加上这一项：缺 block 出站时即使规则 3/3 也判 FAILED。
- **`cnblock_disable()`**：不变——关闭时不删 block 出站（留着无害，下次开启
  直接复用），只删 3 条规则和规则集条目。
- **显示同步**：`cnblock_status`（ACTIVE/DEGRADED 显示“已就绪”，DISABLED
  显示“已存在/缺失（开启时自动补齐）”，FAILED 行追加出站状态）、
  `cnblock_verify` [2/3] 层（条件与报错都含出站状态）、`cnblock_doctor`
  （规则行追加出站状态；FAILED 且出站缺失时追加“重新开启时自动补齐”
  的建议）、菜单 `_cnblock_menu_status` + `menu_cnblock`（新增
  “block 出站”行：已就绪/缺失）。
- 文件头注释与探针注释同步更新。

### `sbx.sh`
- 主菜单诊断的 CN-BLOCK 段：“已开启”判定加上出站条件；不一致分支里出站
  缺失时给出针对性提示（重新开启自动补齐），否则沿用原建议。

### 版本与文档
- `core/env.sh` `SBM_VERSION` 1.10.1 → 1.10.2；`install.sh` `SBX_VERSION` /
  `SBX_TAG` v1.10.1 → v1.10.2；`README.md` 三处安装链接同步。
- `CHANGELOG.md` 顶部新增 v1.10.2 条目。

### 测试
- `tests/cnblock_test.sh` 新增第 22 节（27 个断言）。
- 新增 `tests/cnblock_real_binary_test.sh`（22 个断言，真实 sing-box 1.14.4
  + 真实 geosite-cn.srs / geoip-cn.srs；二进制或规则集缺失时 SKIP）。

规则计数与显示不变（仍是 3 条 block 规则）。本次不涉及 Apple 白名单
（已确认不需要做到脚本里）。

## 四、测试结果

| 套件 | 结果 |
|---|---|
| bash -n 全项目 | 通过 |
| tests/cnblock_test.sh | 155 PASS / 0 FAIL（原 128，新 22 节 +27） |
| tests/cnguard_test.sh | 通过（0 FAIL） |
| tests/cnguard_hardening_test.sh | 32 PASS / 0 FAIL |
| tests/cnblock_real_binary_test.sh（新增） | 22 PASS / 0 FAIL |
| tests/version_check.sh | 通过（1.10.2 一致） |
| warp 相关（warp_test / warp_sbx_owner / warp_healthcheck / warp_temp_cleanup / warp_verify_persist） | 全部通过 |
| tests/run_all.sh 全量 | 24/25，唯一失败为 ui_twokey_test.sh（12/13，PTY 时序抖动；单独跑两次均为 13/13，与本次改动无关，未动导航/UI 代码） |

### 新 22 节覆盖（cnblock_test.sh）
- 全新配置（无 block 出站，DediOne 场景）上 enable 返回 0，补齐恰好 1 个
  block 出站，3 条规则，direct 出站保留，探针出站 ok、Guard ACTIVE，
  status 显示“block 出站：已就绪”。
- 重复开启幂等：出站仍 1 个，规则仍 3 条。
- 手动删出站（保留 3 条规则）：探针报 missing，Guard 为 FAILED（非 ACTIVE），
  status 返回 2，verify 返回非 0 且点名出站缺失，doctor 返回非 0 且提示
  重新开启补齐。
- 重跑 enable 自动补回出站，恢复 ACTIVE；关闭后出站保留，Guard 为 DISABLED；
  关闭后再开启复用已有出站，不重复加。

### 真实二进制验证（cnblock_real_binary_test.sh）
- 负向对照：3 条规则、无 block 出站的配置，打 223.5.5.5 时日志报
  `outbound not found: block`，国内 IP 未被拦截——复现 DediOne 故障模式。
- enable 后：真实 check 通过，真实 run 正常启动（sing-box started、无 FATAL），
  探针出站 ok、Guard ACTIVE。
- 流量验证：打 223.5.5.5 被 block 出站拦截
  （`outbound/block[block]: blocked connection to 223.5.5.5:80`），
  日志无 outbound not found；打 google 走 direct 出站。
- 后加 direct 规则，顺序仍为 sniff→block×3→direct；重复 enable 幂等；
  关闭后出站保留，check 仍通过。

## 五、改动文件清单

```
M CHANGELOG.md
M README.md
M core/env.sh
M install.sh
M protocols/cnblock/cnblock.sh
M sbx.sh
M tests/cnblock_test.sh
?? tests/cnblock_real_binary_test.sh
```

未推送到 GitHub，本地工作目录待推。推送后用户可在 DediOne 上重装
v1.10.2 再点 [1/e] 开启拦截验证（预期：直接成功，无需手动补出站）。
