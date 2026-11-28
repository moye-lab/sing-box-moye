#!/usr/bin/env bash
# 第三方二进制的固定版本与 sha256。
# 获取方法（在有网络的机器上执行，并与 GitHub Release 页面显示的 digest 交叉核对）：
#   curl -fsSL https://github.com/cloudflare/cloudflared/releases/download/<版本>/cloudflared-linux-amd64 | sha256sum
# cloudflared 的 tag 不带 v 前缀。
# 当前值于 2026-11-22 从官方 Release 2026.11.1 实测填入（amd64 二进制 --version 验证通过）。
CF_VERSION="2026.11.1"
CF_SHA256_amd64="97bb3b02d23a5980fc9c15a1a270e692da1923f103f920d5b16d4931d5ab55e7"
CF_SHA256_arm64="b155cec3e48e489cfb8e5c602769fb8c771083018d8881d68b4d18a791567c5a"
CF_SHA256_armhf="32a51ca738fe577a488fe312e5ad01773c601dcc4e0c5133d76a3c4881be29a4"

# acme.sh（可选）。留空时 ACME 证书申请回落到官方在线安装脚本并给出警告。
# 获取方法：curl -fsSL https://github.com/acmesh-official/acme.sh/archive/refs/tags/<版本>.tar.gz | sha256sum
ACME_SH_VERSION=""
ACME_SH_SHA256=""
