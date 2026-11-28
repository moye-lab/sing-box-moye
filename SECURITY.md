# 安全策略

请勿在公开 Issue 中提交订阅令牌、UUID、密码、Reality 私钥或完整配置文件。

发现安全问题时，请使用 GitHub 仓库页面的 **Security → Report a vulnerability** 私密提交（维护者需在仓库设置中启用 Private vulnerability reporting）；在修复发布前避免公开利用细节。

受支持版本：仅最新发布版本。

建议部署：
- SOCKS5 使用强随机凭据，并通过主机防火墙限制来源 IP。
- 在线订阅通过 HTTPS 反向代理提供服务，限制访问来源；订阅 URL 应视为密码。
- 定期更新 sing-box 核心与系统安全补丁。
- 备份 `/etc/sing-box` 时使用加密存储。
