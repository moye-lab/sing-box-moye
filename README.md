# sing-box-moye-cnguard

> 模块化的 Linux `sing-box` 服务端部署与运维管理工具，内置 **CN 出站拦截（CN Egress Guard）**、多协议管理、Cloudflare WARP / Argo 集成与自适应终端 UI。

![Platform](https://img.shields.io/badge/platform-Linux-lightgrey.svg)
![Shell](https://img.shields.io/badge/shell-Bash-green.svg)
![CI](https://img.shields.io/badge/CI-Automated%20Tests-brightgreen.svg)
![License](https://img.shields.io/badge/license-MIT-blue.svg)

[项目简介](#项目简介) · [核心特性](#核心特性) · [环境要求](#环境要求) · [快速开始](#快速开始) · [功能模块](#功能模块) · [使用指南](#使用指南) · [CN 出站拦截](#cn-出站拦截cn-egress-guard) · [项目结构](#项目结构) · [测试与开发](#测试与开发)

---

## 项目简介

`sing-box-moye-cnguard` 是一套面向 Linux 服务器的模块化 [sing-box](https://sing-box.sagernet.org/) 部署与运维工具（主控入口 `sbx.sh`）。一条命令即可完成 VLESS-Reality、Hysteria 2、TUIC、AnyTLS 与 Cloudflare Argo 的部署；底层由基于 `jq` 的状态机持久化所有参数，重装不丢配置，节点命名、订阅导出与系统调优一气呵成。

项目采用分层架构，将环境初始化、状态管理、JSON 配置生成、终端 UI 渲染与各协议模块解耦，在提供开箱即用的多协议管理之外，重点强化 **CN 出站拦截**、**Cloudflare WARP 稳定性保障**以及**跨客户端一致的终端交互体验**。

## 核心特性

* **多协议模块化支持**：独立封装 VLESS-Reality、Hysteria 2、TUIC v5、AnyTLS 与 SOCKS5，按需部署、互不干扰。
* **CN 出站拦截（CN Egress Guard）**：在服务端出站路由层拦截发往中国大陆目标的代理流量与高危域名请求，确保 VPS 不成为大陆目标的代理出口。
* **Cloudflare 出口与隧道集成**：内置 Cloudflare WARP 出口分流（含 5 层健康检查与临时文件清理机制）及 Cloudflare Argo 临时/固定隧道支持。
* **状态机驱动**：通过 `/etc/sing-box/state.json` 持久化已装协议与参数，安装幂等、卸载彻底，随时可查可改。
* **智能节点命名**：首次运行自动进行 GeoIP 与 ASN 探测；识别到 Oracle / Google / AWS / Azure / Cloudflare 直接采用厂商全名（如 `Oracle-Reality`），其余默认采用「国家-主机名-协议」（如 `US-RN-Reality`）。
* **配置导出与本地订阅**：一键导出标准 URI、Base64 聚合订阅、Mihomo YAML、Sing-box JSON 与终端二维码，并附带轻量级 Python 本地订阅服务（`utils/subscription_server.py`）。
* **自适应终端 UI**：独立封装的 `core/ui/` 组件库，支持默认纯净样式（`clean`）与经典边框样式（`boxed`），兼容多档终端宽度及移动端 SSH 客户端（如 Termius）。
* **工程化保障与自动化测试**：通过 `core/pins.sh` 管理关键依赖版本与校验值，内置覆盖核心逻辑、UI 交互、CN 出站拦截、WARP 回归与订阅服务的自动化测试套件和 CI 工作流。

---

## 环境要求

* **操作系统**：主流 Linux 发行版（推荐 Debian 11+ / Ubuntu 20.04+，需支持 `systemd`）
* **运行权限**：`root` 或具备 `sudo` 权限的账户
* **支持架构**：`x86_64`、`aarch64/arm64`、`armv7`（具体二进制可用性以 sing-box / cloudflared 上游发布为准）
* **基础依赖**：`bash`、`curl`、`jq`、`openssl`、`tar`、`python3`、`iptables`、`systemd`；`qrencode` 为可选依赖（仅二维码导出需要）
* **依赖安装**：Debian / Ubuntu（`apt`）、Fedora / RHEL 系（`dnf` / `yum`）可自动安装基础依赖；其他发行版需提前手动准备
* **内核获取**：`sing-box` 内核缺失时自动下载最新正式版；下载仅允许 HTTPS，并校验压缩包格式与路径
* **运行限制**：强依赖 `systemd` 管理服务，不支持 OpenWrt `procd`、Alpine `OpenRC` 或无 `systemd` 容器直接部署

---

## 快速开始

### 方式一：一键安装（推荐）

```bash
bash <(wget -qO- https://raw.githubusercontent.com/moye-lab/sing-box-moye/v1.10.3/install.sh)
```

无 `wget` 时可使用 `curl`：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/moye-lab/sing-box-moye/v1.10.3/install.sh)
```

### 方式二：源码克隆安装

```bash
git clone https://github.com/moye-lab/sing-box-moye.git
cd sing-box-moye-cnguard
sudo bash install.sh
```

### 方式三：发布包安装（无需 Git）

```bash
curl -fsSL https://github.com/moye-lab/sing-box-moye/archive/refs/tags/v1.10.3.tar.gz -o sing-box-moye.tar.gz
tar -xzf sing-box-moye.tar.gz
cd sing-box-moye-cnguard
sudo bash install.sh
```

安装完成后，交互式终端会自动进入管理面板；非交互环境会直接结束安装。之后随时输入 `sbx` 即可重新打开面板。

日常维护、服务状态排查与运维规范，请参阅 [运维文档](docs/OPERATIONS.md)。

---

## 功能模块

| 分类 | 模块名称 | 源码路径 | 说明 |
| :--- | :--- | :--- | :--- |
| **入站协议** | VLESS Reality | `protocols/reality.sh` | 无证书伪装传输协议配置与管理 |
| **入站协议** | Hysteria 2 | `protocols/hysteria2.sh` | 基于 QUIC 的抗丢包高速代理协议 |
| **入站协议** | TUIC v5 | `protocols/tuic.sh` | 基于 QUIC 的低延迟代理协议 |
| **入站协议** | AnyTLS | `protocols/anytls.sh` | 抗特征识别的 TLS 代理协议 |
| **入站协议** | SOCKS5 | `protocols/socks5.sh` | 标准 SOCKS5 代理入站（仅参数管理，不进节点导出） |
| **安全防护** | CN 出站拦截 | `protocols/cnblock/cnblock.sh` | 大陆目标出站拦截与高危域名防护 |
| **出口扩展** | Cloudflare WARP | `protocols/warp.sh` | WARP 出口接入、健康检查与状态持久化 |
| **隧道扩展** | Cloudflare Argo | `protocols/argo.sh` | Cloudflare Argo 隧道接入与管理 |
| **运维工具** | 证书与系统调优 | `utils/cert.sh`、`utils/sysctl.sh` | TLS 证书管理与 Linux 内核网络参数优化 |
| **客户端对接** | 导出与订阅服务 | `utils/export.sh`、`utils/subscription*.{sh,py}` | 节点链接/配置导出与本地订阅托管 |

---

## 使用指南

### 终端界面

默认采用 `clean` 样式：无边框、状态优先，一屏看完（80 列下约 20 行，24 行 SSH 窗口和手机竖屏均可完整显示）。

* **主页信息**：顶部三行摘要（内核状态/版本/PID/内存、公网 IP/ASN/归属地、网络/WARP/拦截/订阅四枚状态药丸），下方为协议列表（已启用协议显示端口与 SNI）及管理命令网格。
* **按键交互**：字母键即时响应，无需回车；旧版数字编号仍兼容（数字 + 回车，不在界面展示）；`Esc` 返回上一级（主菜单中退出），`q` 退出，不依赖方向键。
* **宽度自适应**：支持 120+ 列宽屏、80 列默认、60 列紧凑、40 列窄屏与 30 列以下纯文本降级，内容不越界；可通过 `SBM_COLS=100 sbx` 强制指定宽度。
* **样式与配色控制**：
  * `SBX_STYLE=boxed sbx`：切换为旧版边框样式（含完整仪表盘）
  * `NO_COLOR=1`：关闭 ANSI 颜色输出
  * `SBM_ASCII=1`：强制 ASCII 符号（非 UTF-8 终端自动降级）
  * `SBM_FORCE_COLOR=1`：在非 TTY 环境下强制输出颜色
* **安全确认与进度**：危险操作（彻底卸载、WARP 卸载）默认取消，需显式输入 `y` 确认；耗时操作提供阶段提示与状态药丸。

典型界面（主面板、纯净视图、Reality、WARP、配置导出）的 80 列渲染样例位于 [`docs/ui-samples/`](docs/ui-samples/README.md)（`clean-*` 为默认样式，`main-*` 为旧边框样式）。

### 快捷命令

| 命令 | 说明 |
| :--- | :--- |
| `sbx` | 打开交互式管理面板 |
| `sbx r` | 安装 / 管理 VLESS-Reality |
| `sbx h` | 安装 / 管理 Hysteria 2 |
| `sbx t` | 安装 / 管理 TUIC v5 |
| `sbx a` | 安装 / 管理 AnyTLS（需 `sing-box ≥ 1.12.0`，版本不足时自动升级） |
| `sbx p` | 安装 / 管理 Cloudflare Argo（含临时隧道域名刷新） |
| `sbx y` | 安装 / 管理 SOCKS5（仅参数展示，不进节点导出） |
| `sbx w` | WARP 与域名分流（解锁 AI 服务） |
| `sbx c` | 进入 CN 出站拦截管理菜单 |
| `sbx cnblock on\|off\|status\|verify\|update\|test\|doctor` | 通过 CLI 控制、更新、测试与诊断 CN 出站拦截 |
| `sbx all` | 一键安装常用节点协议（Reality + Hy2 + TUIC + AnyTLS，默认配置；不含 SOCKS5 / Argo） |
| `sbx rename "US-vps01"` | 设置自定义节点前缀（协议短名自动追加） |
| `sbx e` | 重新生成并查看所有节点导出 |
| `sbx o` | 一键开启 BBR 与 UDP 缓冲区调优 |
| `sbx subscription enable` / `disable` | 启停本地在线订阅服务 |
| `sbx subscription rotate` | 重置订阅令牌（旧链接立即失效，端口与监听地址不变） |
| `sbx doctor` | 检查依赖、状态文件与 `sing-box` 配置健康度 |
| `sbx version` | 查看当前脚本版本 |
| `sbx <协议> del` | 卸载指定协议（如 `sbx h del`） |

节点协议安装后会自动生成链接、Base64 聚合订阅、二维码、Mihomo 配置块与 Sing-box 客户端配置到 `/etc/sing-box/export/`。SOCKS5 不属于节点体系，不会进入任何节点导出或在线订阅内容。

### 节点命名

* **自动命名**：识别到主流云厂商（Oracle / Google / AWS / Azure / Cloudflare，优先 ASN 精确匹配、运营商名称兜底）时，前缀直接使用厂商全名（如 `Oracle-Reality`）；未匹配时采用「国家代码-主机名」（如 `US-RN-Reality`）。主机名读取系统 `hostname -s` 并保留原始大小写。
* **协议短名**：统一为 `Reality`、`Hy2`、`TUIC`、`AnyTLS`、`Argo`；Argo 多优选 IP 按 `-1`、`-2` 依次编号。
* **刷新与自定义**：节点名仅在命名中心（菜单 `9`）选择「重新探测」时刷新；也可通过 `sbx rename "前缀"` 手动指定前缀（协议短名自动追加）。

### WARP 与域名分流

当 VPS 原生 IP 被 AI 服务限制（例如 Gemini 提示地区不可用）时，可通过 WARP 出口定向分流绕过：

1. 主菜单选 `11/w` 进入「WARP 与域名分流」，选 `1` 安装 WARP（自动注册 Cloudflare 账号并生成 WireGuard 出站）。
2. 选 `2` 应用「AI 解锁分流」预设，按需选择模式：
   * **精简模式（推荐，27 个域名）**：仅分流 AI 专用域名（`gemini.google.com`、`openai.com`、`claude.ai` 等），普通 Google 搜索、Gmail、YouTube 保持直连。
   * **兼容模式（32 个域名）**：在精简模式基础上增加 `google.com`、`googleapis.com`、`accounts.google.com`，适配依赖完整 Google 生态的 AI 服务。
3. 支持手动追加自定义域名（空格分隔，后缀匹配，自动覆盖子域名）。
4. 选 `1/c` 执行 5 层健康检查（配置 → 服务 → 分流规则 → 实际流量连通性验证），确认 WARP 真实生效。

> **注意**：分流仅作用于列表内的域名，其余流量仍走 VPS 直连，不影响常规访问速度。此外，Claude（`anthropic.com` / `claude.ai`）会屏蔽 Cloudflare WARP IP，如需使用请将其从分流列表中移除，改走 VPS 原生 IP。

---

## CN 出站拦截（CN Egress Guard）

### 功能定位

目标只有一个：**确保这台 VPS 不成为中国大陆目标的代理出口**。一旦客户端分流规则漏网（全局模式、规则不全或误配置），微信、支付宝等国内应用会经代理以境外 IP 登录，等同于将实名身份与该服务器直接关联。

本功能作为 VPS 端的最后一道防线——客户端分流是第一层，VPS 出口防护是第二层：发往中国大陆目标的代理请求会在 VPS 侧直接被拒绝（打不开、可感知），而不会静默登录成功；海外目标则正常放行。

拦截规则仅作用于经由 `sing-box` 转发的**出站代理流量**，不会在系统防火墙层阻断来自中国大陆的正常客户端入站连接。

### 核心机制

拦截由三层规则组成，且优先级始终高于 WARP 等分流规则，互不冲突：

1. **`geosite-cn` 规则集**：覆盖中国大陆常见域名（约 9,000 个后缀，包含全部 `.cn` 域名）。
2. **`geoip-cn` 规则集**：覆盖中国大陆 IP 段（同时包含 IPv4 与 IPv6，避免仅拦 IPv4 放过 IPv6 的旁路）。
3. **45 个高风险补漏国内域名**：对照规则集源码逐项核对的漏网域名，定义于 `protocols/cnblock/rules/high-risk-domains.conf`（每行一个）。

域名层与 IP 层缺一不可：部分国内域名会解析到境外 CDN 或香港 IP（例如 `baidu.com` 在特定网络下解析至香港节点），仅靠 IP 拦截会出现漏网；域名层按目标域名直接匹配，不受 DNS 解析结果影响。

<details>
<summary>展开查看 45 个高风险补漏域名完整名单</summary>

* **银行与支付（14）**：农业银行 `abcchina.com`、平安银行 `pingbank.com`、上海银行 `bankofshanghai.com`、丰收互联 `zj96596.com`、拉卡拉 `lakala.com`、快钱 `99bill.com`、通联支付 `allinpay.com`、重庆农商行 `cqrcb.com`、汉口银行 `hkbchina.com`、青岛银行 `qdccb.com`、台州银行 `tzbank.com`、泰隆银行 `zjtlcb.com`、中信证券 `citics.com`、招商证券 `cmschina.com`
* **汽车与出行（8）**：上汽大众 `svw-volkswagen.com`、零跑 `leapmotor.com`、哪吒 `netaauto.com`、问界 `aito.com`、极氪 `zeekr.com`、智己 `im-motors.com`、阿维塔 `avatr.com`、上汽集团 `saicmotor.com`
* **游戏（6）**：巨人网络 `ztgame.com`、昆仑万维 `kunlun.com`、2144 `2144.com`、51wan `51wan.com`、9377 `9377.com`、8090 `8090.com`
* **视频与 AI（5）**：红果短剧 `hongguoduanju.com`、月之暗面 `moonshot.ai`、阶跃星辰 `stepfun.com`、零一万物 `01.ai`、DeepSeek `deepseek.com`
* **房产（3）**：贝壳 `beike.com`、我爱我家 `5i5j.com`、Q 房网 `qfang.com`
* **航空（3）**：祥鹏航空 `luckair.com`、九元航空 `9air.com`、奥凯航空 `okair.com`
* **保险（3）**：阳光保险 `sinosig.com`、众安保险 `zhongan.com`、水滴 `shuidi.com`
* **社交与医疗（2）**：陌陌 `momo.com`、微医挂号 `guahao.com`
* **电商（1）**：蜜芽 `mia.com`

</details>

### 使用说明

在主菜单选 `12/c` 进入管理界面，或直接使用 CLI：`sbx cnblock on|off|status|verify|update|test|doctor`。

**该功能默认关闭，需手动开启**（开源工具仅提供选择，不替用户默认拦截流量）。

* **规则集更新**：`sbx cnblock update` 下载最新 `geosite-cn` / `geoip-cn`（写入临时文件 → 校验 → 备份旧规则 → 原子替换 → 重载服务；任一步失败均保留旧规则并记录原因）。规则集超过 30 天未更新时状态降级为 `DEGRADED`（拦截仍生效），`status` 与 `doctor` 会提示更新。
* **实测与诊断**：
  * `sbx cnblock test`：紧凑实测（5 个国内域名 + 国内 IPv4 + 有 IPv6 时的国内 IPv6 均应被拒，3 个海外对照站应正常连通）。
  * `sbx cnblock test <目标>`：实测单个域名或 IP，输出动作与命中层推断（`sing-box` 不返回命中的具体规则，命中层为推断结果）。
  * `sbx cnblock verify`：三层全面验证（配置校验、规则与规则集探针、SOCKS5 实测 25 个国内目标——含 IPv6 时 26 个——外加 2 个海外对照站）。
  * `sbx cnblock doctor`：输出整体健康汇总与可操作修复建议。
* **状态分级**：`sbx cnblock status` 报告四种状态——`ACTIVE`（拦截正常）、`DEGRADED`（规则集过期或上次更新失败，但拦截仍生效）、`FAILED`（规则不完整或顺序异常）、`DISABLED`（未开启）。
* **配合客户端分流排查**：启用后，若国内网站突然无法访问，通常是因为客户端处于全局代理（Global）模式或本地分流规则漏掉该域名，导致流量发往 VPS 后被拦截。请先检查客户端代理模式，切换为规则分流（Rule / Bypass CN）或为该域名配置直连。
* **自定义高危规则**：如需增删补漏域名，可编辑 `/usr/local/etc/sbx/protocols/cnblock/rules/high-risk-domains.conf`（直接从源码目录运行时对应仓库内 `protocols/cnblock/rules/high-risk-domains.conf`），随后执行 `sbx cnblock on`（或在面板中关闭再开启）使其生效。

> **边界说明**：开启后国内站点请走本地直连；如有境外访问国内服务的需求，请关闭本功能。本功能旨在确保 VPS 不向中国大陆目标提供代理出口，并不承诺掩盖代理特征或避免被检测/标记；同时规则集无法穷尽所有新注册域名、新分配 IP 段及 CDN 边缘节点，仍存在漏网可能，不可视为绝对保障。

---

## 协议与订阅功能说明

### 协议补充说明

* **端口自定义**：Reality / Hy2 / TUIC 默认监听端口均可自定义，支持输入 `r` 随机生成。
* **TLS 证书**：Hy2 / TUIC 默认生成 ECC 自签名证书（客户端开启「跳过证书验证」即可使用），也支持通过 ACME 申请真实域名证书。
* **Hy2 端口跳跃**：端口跳跃规则通过 `systemd` 持久化，开机自动恢复；重装或卸载协议时自动清理。
* **Argo 固定隧道**：Token 保存在权限为 `600` 的 `EnvironmentFile` 中，不再暴露于 `systemd` unit 文件或进程启动参数中；需在 Cloudflare Zero Trust 后台将 Public Hostname 指向 `http://127.0.0.1:<本地回环端口>`。
* **Argo 临时隧道**：VPS 或进程重启后随机域名会变化，打开管理面板或导出订阅时会自动同步最新域名（菜单亦提供手动刷新）。

### SOCKS5 代理参数

* 基于 `sing-box` 原生 SOCKS5 inbound，默认监听 `1080` 端口，支持 TCP 与 UDP associate。
* 强制启用用户名/密码认证；每次安装生成高强度随机密码，用户名限制为安全字符集。
* 主菜单 `[6/y] SOCKS5` 支持安装、重装与卸载；在「节点订阅中心」内可随时查看手动配置参数。
* 安装完成后立即展示服务器、端口、用户名、密码及 Telegram 手动配置路径。
* 不纳入节点体系，不会出现在 `links.txt`、Base64 在线订阅、Mihomo YAML 或 Sing-box 客户端 `outbounds` 中。
* 建议配合防火墙限制来源 IP，切勿将 SOCKS5 端口直接暴露于整个公网。

### 在线订阅链接

* 可在「节点订阅中心 → 在线订阅服务」中开启，或执行 `sbx subscription enable`。
* 采用 256-bit 随机令牌作为路径凭据；错误令牌返回 `404`，响应头禁止缓存。
* 动态读取最新 `links.txt` 并返回 Base64 内容，增删协议节点后无需重启订阅服务。
* 默认仅监听 `127.0.0.1:8765`，避免未经配置直接暴露公网。如需远程拉取可显式绑定 `0.0.0.0`，但原始 HTTP 不加密——**生产环境必须通过 HTTPS 反向代理暴露**并配合防火墙来源限制；订阅 URL 本身等同访问凭据，请勿公开分享。
* 执行 `sbx subscription disable` 会立即停止服务并撤销旧令牌；彻底卸载时也会同步清理订阅服务。

> **安全提示**：在线订阅服务仅为轻量级只读分发端点，并非通用 Web 管理面板，请勿在不可信网络中传输明文 HTTP 订阅地址。SOCKS5 凭据与协议私钥均保存在权限受限的 `/etc/sing-box` 状态文件中。

---

## 彻底卸载

主菜单输入 `x`，经一次确认后将移除 `sing-box` 内核、全部协议配置与系统服务，仅保留 `sbx` 管理命令本体以便后续需要时重新初始化。

---

## 部署边界与隐私

* **外部网络探测**：首次初始化会向 `ipwho.is` 请求公网 IP、国家/城市、ASN 及运营商（ISP / Org）信息，用于云厂商识别、节点命名与仪表盘展示；公网 IP 检测亦会请求 `api.ipify.org`。当前版本暂未提供完全离线的 GeoIP 开关。
* **运行权限与凭据保护**：管理器以 `root` 权限运行 `sing-box` 以便绑定低端口与读取证书；状态文件、订阅令牌与配置文件应始终保持仅 `root` 可读。
* **防火墙策略**：安装器不会自动修改主机防火墙或云厂商安全组规则，部署前请按所用协议自行放行对应 TCP / UDP 端口。
* **网络连通性前提**：Reality / Hy2 / TUIC 的证书、SNI、端口及公网地址需与实际网络环境匹配，配置成功生成并不等同公网链路必然连通。
* **订阅监听安全**：订阅服务默认绑定 `127.0.0.1`；若需公网监听，必须显式选择 `0.0.0.0` 并搭配 HTTPS 反代与访问控制。
* **依赖校验**：Argo 所依赖的 `cloudflared` 要求在 `core/pins.sh` 中锁定版本与 SHA-256 校验和，未配置时将拒绝安装。临时跳过校验可设置 `SBX_ALLOW_UNVERIFIED=1`（不推荐）。
* **服务沙箱加固**：`sing-box` 的 `systemd` 单元默认启用沙箱加固（`ProtectSystem=strict`、`ProtectHome=read-only`、`PrivateTmp=true` 等），仅允许写入 `/etc/sing-box`。
* **一键安装校验**：下载强制 HTTPS 并带超时重试；可用 `SBX_SHA256=<发布包 sha256> bash <(wget -qO- …)` 在解压前校验发布包。从分支（如 `master`）安装时会提示内容可能变化，生产环境建议使用带版本号的 tag。
* **端口保护**：Hy2 端口跳跃应用前会检查跳跃段内是否有 TUIC / SOCKS5 或系统其他正在绑定的 UDP 端口，冲突则拒绝并列出端口；随机端口与手动输入端口也会避开已分配端口与跳跃段。
* **SOCKS5 凭据不进命令行**：`sbx cnblock verify / test` 与 WARP 出口检测经本机 SOCKS5 发起请求时，凭据通过环境变量传递，不出现在 `curl` 命令行（`/proc/<pid>/cmdline` 本机任何用户可读）。
* **ACME 证书**：可在 `core/pins.sh` 固定 `ACME_SH_VERSION` 与 `ACME_SH_SHA256`，走“下载 → 校验 → 本地安装”；留空时回落到官方在线安装脚本并给出警告。

---

## 项目结构

```text
sing-box-moye-cnguard/
├── .github/                   # Issue / PR 模板与 CI 工作流 (ci.yml)
├── install.sh                 # 安装与环境初始化脚本
├── sbx.sh                     # 主控脚本与交互入口
├── core/                      # 核心引擎与公共基础库
│   ├── engine.sh              # 运行时与服务控制引擎
│   ├── env.sh                 # 环境变量与基础检测
│   ├── json_builder.sh        # sing-box JSON 配置构建器
│   ├── pins.sh                # 依赖版本与校验和锁定
│   ├── state_manager.sh       # 状态持久化管理
│   ├── ui.sh                  # UI 统一入口
│   └── ui/                    # 自适应终端 UI 组件库（14 个子模块）
├── protocols/                 # 协议与核心功能模块
│   ├── anytls.sh              # AnyTLS
│   ├── argo.sh                # Cloudflare Argo
│   ├── hysteria2.sh           # Hysteria 2
│   ├── reality.sh             # VLESS-Reality
│   ├── socks5.sh              # SOCKS5
│   ├── tuic.sh                # TUIC v5
│   ├── warp.sh                # Cloudflare WARP
│   └── cnblock/               # CN 出站拦截实现与高危域名规则
│       ├── cnblock.sh
│       └── rules/high-risk-domains.conf
├── utils/                     # 证书、sysctl 调优、配置导出与订阅服务
├── templates/                 # 基础配置模板 (base.json)
├── tests/                     # 冒烟测试、功能测试、UI 与回归测试套件
├── tools/                     # 开发辅助工具 (gen-ui-samples.sh)
└── docs/                      # 运维手册 (OPERATIONS.md) 与 UI 渲染样例
```

---

## 测试与开发

仓库已配置自动化测试与 CI（`.github/workflows/ci.yml`）。运行完整测试套件需提前安装 `jq`、`python3` 与 `python3-yaml`（PyYAML）。提交变更或发起 Pull Request 前，建议在本地运行：

```bash
# 运行全部自动化测试
bash tests/run_all.sh

# 运行基础冒烟与版本检查
bash tests/smoke.sh
bash tests/version_check.sh

# 运行 CN 出站拦截专项测试
bash tests/cnblock_test.sh
bash tests/cnguard_test.sh
bash tests/cnguard_hardening_test.sh

# 运行订阅服务、端口保护与令牌重置测试
python3 tests/subscription_test.py
bash tests/subscription_rotate_test.sh
bash tests/port_guard_test.sh

# 修改 UI 组件后重新生成 80 列终端渲染样例
bash tools/gen-ui-samples.sh
```

日常环境检查可直接运行 `sbx doctor`，用于核对基础依赖、状态文件结构、`sing-box` 配置与服务状态。详细的分支规范、编码约定与提交流程，请参阅 [CONTRIBUTING.md](CONTRIBUTING.md)。

---

## 文档与治理

* **运维指南**：[docs/OPERATIONS.md](docs/OPERATIONS.md)
* **变更记录**：[CHANGELOG.md](CHANGELOG.md)
* **贡献指南**：[CONTRIBUTING.md](CONTRIBUTING.md)
* **安全策略**：如发现安全漏洞或配置隐患，请勿公开提交 Issue，请按 [SECURITY.md](SECURITY.md) 指引私下报告。

---

## 免责声明与开源协议

* **免责声明**：本项目仅用于网络协议研究、Linux 自动化运维学习及合规的服务器管理场景。使用者须遵守服务器所在地及自身所在国家/地区的法律法规，项目维护者不对任何滥用行为承担责任。
* **开源协议**：本项目遵循 MIT 协议，详见仓库根目录 [LICENSE](LICENSE) 文件。