# UI 展示样本

捕获方式：`source` 实验仓库 `sbx.sh` + fixture 状态（Reality/Hy2/WARP 已装，
公网 IP `203.0.113.9` 为 TEST-NET-3 测试地址），管道输入 `q`（渲染后立即退出），
不执行任何业务操作。

- `*-ansi.txt`：`SBM_FORCE_COLOR=1` 下的原始输出（含 ANSI 颜色码，用 `cat` 查看即有颜色）。
- `*.txt`：同一份输出 strip ANSI 后的纯文本版。
- 仅保留 80 列标准宽度的代表性样本（其他宽度可用 `tools/gen-ui-samples.sh` 重新生成）。

| 文件 | 内容 |
|---|---|
| `clean-80col` | 主菜单，80 列（默认无边框样式） |
| `main-80col` | 主菜单，80 列（旧版边框样式，`SBX_STYLE=boxed`） |
| `reality-80col` | VLESS-Reality 子菜单，80 列 |
| `warp-80col` | WARP 与域名分流子菜单，80 列 |
| `export-80col` | 节点订阅中心子菜单，80 列 |
