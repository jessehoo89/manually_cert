# ACME 自动证书申请脚本

基于 `acme.sh` 的自动化 SSL/TLS 证书申请工具，支持手动 DNS 验证模式，适用于泛域名证书申请。

## 📋 功能特点

- ✅ 自动检测并安装 `acme.sh`
- ✅ 支持单域名和泛域名（`*.example.com`）证书申请
- ✅ 支持多域名同时申请
- ✅ 手动 DNS 验证模式（适合所有 DNS 服务商）
- ✅ 灵活的配置方式（预设变量 / 环境变量 / 交互式输入）
- ✅ 自动复制证书到指定目录
- ✅ 使用 Gitee 镜像加速克隆（国内用户友好）

## 🚀 快速开始

### 1. 下载脚本

```bash
git clone <your-repo-url>
cd <repo-directory>
chmod +x acme_auto_cert.sh
```

### 2. 运行方式

#### 方式一：交互式运行（推荐新手）

直接运行脚本，按提示输入域名和证书存放路径：

```bash
./acme_auto_cert.sh
```

#### 方式二：环境变量传参（适合自动化）

```bash
DOMAIN="*.s.odn.cc *.s.3q.hair" CERT_DEST="/vol1/1000/软件/cert" ./acme_auto_cert.sh
```

#### 方式三：预设配置（适合固定场景）

编辑脚本顶部的配置区域，填入默认值后直接运行：

```bash
# 编辑脚本
vim acme_auto_cert.sh

# 修改以下变量（取消注释并填写）
DOMAIN=""           # 留空则运行时输入
CERT_DEST=""        # 留空则运行时输入
ACME_EMAIL=""       # 留空则运行时输入
ACME_HOME=""        # 留空则使用默认值 ~/.acme.sh
```

## ⚙️ 配置说明

| 变量名 | 说明 | 示例 |
|--------|------|------|
| `DOMAIN` | 要申请的域名，多个域名用空格分隔 | `"*.example.com"` 或 `"example.com www.example.com"` |
| `CERT_DEST` | 证书复制目标目录 | `/etc/nginx/ssl/` 或 `/vol1/1000/软件/cert` |
| `ACME_EMAIL` | 注册 ACME 账户的邮箱（用于证书过期通知） | `admin@example.com` |
| `ACME_HOME` | acme.sh 安装目录（可选） | `/root/.acme.sh` |

## 📝 使用流程

1. **运行脚本** - 选择上述任一方式启动脚本
2. **添加 DNS 记录** - 根据脚本输出的 TXT 记录值，在您的 DNS 服务商处添加解析
3. **确认验证** - 添加完成后按回车，脚本自动进行 DNS 验证
4. **获取证书** - 验证通过后自动下载证书并复制到指定目录

## 📁 证书文件说明

成功申请后，目标目录将包含以下文件：

| 文件名 | 说明 |
|--------|------|
| `domain.cer` | 域名证书文件 |
| `domain.key` | 私钥文件（请妥善保管） |
| `ca.cer` | 中间 CA 证书 |
| `fullchain.cer` | 完整证书链（证书 + CA） |

## 🔒 安全建议

- ⚠️ **私钥保护**：`*.key` 文件包含私钥，请设置合适的权限（建议 `600`）
- ⚠️ **定期更新**：证书有效期为 90 天，建议设置定时任务自动续期
- ⚠️ **备份证书**：重要证书的私钥请做好离线备份

## 🔄 证书续期

已申请的证书可通过以下命令续期：

```bash
# 进入 acme.sh 目录
cd ~/.acme.sh

# 执行续期（手动 DNS 模式需要重新验证）
acme.sh --renew --dns \
  --yes-I-know-dns-manual-mode-enough-go-ahead-please \
  -d "your-domain.com"
```

> 💡 **提示**：如果使用 API 自动 DNS 验证，可配置自动续期 cron 任务。

## 🛠️ 依赖要求

- Debian/Ubuntu/CentOS 等 Linux 发行版
- `git`, `curl`, `wget`, `socat`（脚本会自动检测安装）
- 有效的域名和 DNS 管理权限
- 能够访问外网（用于下载 acme.sh 和申请证书）

## ❓ 常见问题

### Q: 支持哪些 DNS 服务商？
A: 手动 DNS 模式支持所有 DNS 服务商。如需自动验证，acme.sh 支持阿里云、腾讯云、Cloudflare 等 50+ 服务商。

### Q: 证书申请失败怎么办？
A: 
1. 检查 DNS TXT 记录是否正确添加（注意前缀 `_acme-challenge.`）
2. 等待 DNS 生效（通常 1-5 分钟）
3. 添加 `--debug` 参数查看详细日志

### Q: 如何更改 CA 机构？
A: 默认使用 ZeroSSL，可在脚本中添加 `--server letsencrypt` 切换到 Let's Encrypt。

## 📄 许可证

本脚本基于 MIT 协议开源。

## 🔗 相关链接

- [acme.sh 官方文档](https://github.com/acmesh-official/acme.sh)
- [Let's Encrypt](https://letsencrypt.org/)
- [ZeroSSL](https://zerossl.com/)

---

**作者**: 基于用户实际需求定制  
**最后更新**: 2026-03-31
