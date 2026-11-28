#!/usr/bin/env bash
set -e

SBX_VERSION="v1.10.3"
# 远程安装必须从本仓库拉包，不得指向其他仓库
# （2026-11-15 TUI 教训：URL 写错仓库，一键安装装的不是目标代码，
# 实验仓跑的根本不是实验代码）。
SBX_REPO="sing-box-moye"
SBX_TAG="v1.10.3"

# 远程一键安装引导：当通过 bash <(wget -qO- ...) / curl ... | bash 方式执行时，
# BASH_SOURCE 指向 /dev/fd/63 等非真实路径，身边没有 core/env.sh，
# 此时先下载发布包到临时目录再转交执行。
_SCRIPT_SRC="${BASH_SOURCE[0]}"
if [[ "$_SCRIPT_SRC" == /dev/fd/* ]] || [[ ! -f "$(dirname "$_SCRIPT_SRC")/core/env.sh" ]]; then
    if [[ $EUID -ne 0 ]]; then
        echo "请使用 root 权限执行一键安装！"
        exit 1
    fi
    _TMPD="$(mktemp -d)"
    trap 'rm -rf "$_TMPD"' EXIT
    _URL="https://github.com/moye-lab/${SBX_REPO}/archive/refs/tags/${SBX_TAG}.tar.gz"
    echo "正在下载 ${SBX_REPO} ${SBX_TAG} ..."
    if [[ "$SBX_TAG" != v* ]]; then
        echo "提示：正在从分支 ${SBX_TAG} 安装（内容可能随时变化）；建议改用带版本号的 tag，或设置 SBX_SHA256 校验发布包。"
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q --https-only --tries=3 --timeout=30 -O "${_TMPD}/pkg.tar.gz" "$_URL" || {
            echo "下载失败：$_URL（请检查网络，或确认该版本/分支存在）"; exit 1; }
    else
        curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --connect-timeout 10 -m 120 \
            -o "${_TMPD}/pkg.tar.gz" "$_URL" || {
            echo "下载失败：$_URL（请检查网络，或确认该版本/分支存在）"; exit 1; }
    fi
    # 可选完整性校验：SBX_SHA256=<发布包 sha256> bash <(wget -qO- ...)
    if [[ -n "${SBX_SHA256:-}" ]]; then
        echo "${SBX_SHA256}  ${_TMPD}/pkg.tar.gz" | sha256sum -c - >/dev/null 2>&1 || {
            echo "发布包 sha256 校验失败，已中止安装。"; exit 1; }
    fi
    tar -xzf "${_TMPD}/pkg.tar.gz" -C "$_TMPD" || { echo "发布包解压失败"; exit 1; }
    [[ -f "${_TMPD}/${SBX_REPO}-${SBX_TAG#v}/install.sh" ]] || { echo "发布包结构异常，已中止安装。"; exit 1; }
    exec bash "${_TMPD}/${SBX_REPO}-${SBX_TAG#v}/install.sh" "$@"
fi
unset _SCRIPT_SRC _TMPD _URL

if [[ $EUID -ne 0 ]]; then
    echo "请使用 root 权限执行 install.sh！"
    exit 1
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="/usr/local/etc/sbx"

source "${SRC_DIR}/core/env.sh"
command -v systemctl >/dev/null 2>&1 || {
    echo "当前系统未检测到 systemd/systemctl；本项目目前要求 systemd 环境。"
    exit 1
}
install_deps

mkdir -p "$TARGET_DIR"
if [[ "$SRC_DIR" != "$TARGET_DIR" ]]; then
    # 只安装运行必需的文件；tests/、docs/、报告等开发资料不进入 /usr/local/etc/sbx
    for _item in sbx.sh install.sh core protocols utils templates; do
        rm -rf "${TARGET_DIR:?}/${_item}"
        cp -a "${SRC_DIR}/${_item}" "${TARGET_DIR}/"
    done
    unset _item
    # 清理旧版本整包复制留下的开发资料
    rm -rf "${TARGET_DIR:?}/tests" "${TARGET_DIR:?}/docs" "${TARGET_DIR:?}/.github"
fi
chmod +x "$TARGET_DIR/sbx.sh" "$TARGET_DIR/install.sh"
chmod +x "$TARGET_DIR"/core/*.sh "$TARGET_DIR"/protocols/*.sh "$TARGET_DIR"/utils/*.sh

# 清理旧版 sbm 残留（命令更名升级衔接）
systemctl stop sbm-hop 2>/dev/null || true
systemctl disable sbm-hop 2>/dev/null || true
rm -f /etc/systemd/system/sbm-hop.service
systemctl stop sbm-subscription.service 2>/dev/null || true
systemctl disable sbm-subscription.service 2>/dev/null || true
rm -f /etc/systemd/system/sbm-subscription.service
rm -f /usr/local/bin/sbm
if [[ "$SRC_DIR" != "/usr/local/etc/sb-modular" ]]; then
    rm -rf /usr/local/etc/sb-modular
fi
systemctl daemon-reload 2>/dev/null || true

# 设置全局指令: sbx
ln -sf "$TARGET_DIR/sbx.sh" /usr/local/bin/sbx

# 升级重断言（v1.8.2 起）：拦截已开启的老用户，升级后规则仍是旧版的
# 2 条（无补漏域名规则）且可能被 WARP 规则压在后面。留标记，主菜单
# 首次检测到内核+配置就绪时执行一次 cnblock_enable 重写规则；拦截
# 未开启时不留标记（尊重用户关闭拦截的决定）。全新安装不留任何标记，
# 拦截默认关闭——开源项目只提供选择，不替用户做默认拦截的决定。
if [[ -f "$SB_ETC/state.json" ]] && jq -e '.cnblock.enabled == true' "$SB_ETC/state.json" >/dev/null 2>&1; then
    : > "$SB_ETC/.cnblock-reassert"
fi

log_ok "sing-box-moye (v${SBM_VERSION}) 已安装！以后输入 'sbx' 即可随时启动管理面板。"
if [[ -t 0 && -t 1 ]]; then
    /usr/local/bin/sbx
else
    echo "安装完成。请在终端执行：sbx"
fi
