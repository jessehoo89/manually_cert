# ACME 手动 DNS 验证证书脚本

基于 `acme.sh` 的 SSL/TLS 证书申请工具，走 **DNS-01 手动验证**，适用于没有 DNS API 凭证的域名（PassNAT、代理商托管域名等），可签发泛域名证书（`*.example.com`）。

## 适用与不适用

- 适用：单个/多个域名、泛域名；DNS 只能手工加 TXT 记录；几台机器上偶尔签一次证书。
- 不适用：需要无人值守自动续期。DNS 手动模式 acme.sh 明确**禁止** cron 自动续期，续期必须人工加记录（见「续期」）。

## 用法

```bash
git clone https://github.com/jessehoo89/manually_cert.git
cd manually_cert
chmod +x acme_auto_cert.sh

# 方式一：交互式（按提示填域名、邮箱、归档目录）
./acme_auto_cert.sh

# 方式二：环境变量（适合脚本化、多条隧道复用一个域名）
DOMAIN="*.odn.cc *.3q.hair" CERT_DEST=/vol2/1000/cert ./acme_auto_cert.sh

# 方式三：只续期（复用上次保存的域名与目录）
./acme_auto_cert.sh --renew
```

不需要 root。acme.sh 装到当前用户的 `~/.acme.sh`，安装时不写 cron、不改 shell 配置（`--nocron --no-profile`）。

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `DOMAIN` | 空 | 域名，空格分隔；**第一个是主域名**，决定 acme.sh 目录名与续期的 `-d` 参数 |
| `CERT_DEST` | 空 | 证书归档目录；留空则只留在 `~/.acme.sh` |
| `ACME_EMAIL` | 空 | ACME 注册邮箱，可留空 |
| `ACME_SERVER` | `letsencrypt` | 也可填 `zerossl`（ZeroSSL 需要邮箱，且走 EAB 注册） |
| `KEY_LENGTH` | `ec-256` | 也可填 `2048` / `4096`（RSA）。ECC 时目录与续期命令都会带 `_ecc` / `--ecc` |
| `ACME_HOME` | `$HOME/.acme.sh` | acme.sh 工作目录 |
| `ACME_SRC` | `/opt/acme` | acme.sh 源码克隆目录，不可写时自动回落 `~/.acme-src` |
| `DNS_WAIT` | `300` | 等待 TXT 生效的上限秒数（每 5 秒用 `dig` 查一次） |
| `ALLOW_OTHER_READ` | `0` | 置 `1` 时归档目录 755、私钥 644，供其它系统用户的服务读取（如 frp / PassNAT） |
| `ACME_DEBUG` | `0` | 置 `1` 时给 acme.sh 加 `--debug 2` |

上次的 `DOMAIN` / `CERT_DEST` / `ACME_SERVER` / `KEY_LENGTH` 会存到 `${ACME_HOME}/.manual_cert_state`，供 `--renew` 复用。

## 流程

1. 运行脚本 → acme.sh 创建订单并打印每个域名的 `_acme-challenge.<域名>` TXT 记录值（**退出码 3 属正常**，表示等你加记录）
2. 在 DNS 服务商处把 TXT 记录加好，回车继续
3. 脚本自动用 `dig` 轮询确认记录生效（默认最多等 300 秒；超时后可选择继续或放弃）
4. `acme.sh --renew --force --ecc` 完成验证与签发
5. 自检：打印 subject / issuer / 有效期 / SAN，并校验私钥与证书公钥是否匹配（MD5 比对）
6. 归档：先备份同名的旧文件到 `CERT_DEST/Backup/`，再按下面的命名复制

## 归档目录里的文件

| 文件 | 内容 |
|---|---|
| `<主域名>.cer` | **完整证书链**（叶子 + 中间证书）。frp / nginx / 反向代理直接指这个 |
| `<主域名>.leaf.cer` | 仅叶子证书（仅当某个客户端只接受单张证书时才用） |
| `<主域名>.key` | 私钥，默认 600（`ALLOW_OTHER_READ=1` 时 644） |
| `ca.cer` | 中间 CA |
| `fullchain.cer` | 与 `<主域名>.cer` 内容相同 |

> 只发叶子证书会报 `unable to verify the first certificate` —— 中间证书不在多数客户端的信任库里。这就是 `<主域名>.cer` 直接给完整链的原因。

## 续期

手动 DNS 模式**不能自动续期**，到期前重跑一次即可：

```bash
./acme_auto_cert.sh --renew
```

`--renew` 会复用上次的域名与目录，仍会打印新的 TXT 记录、等你加完再验证。

不用脚本、手敲 acme.sh 等价命令时，两个参数别漏：

```bash
# ECC 证书：必须 --ecc，否则会在 RSA 目录上操作
# 必须 --force：没到续期窗口 acme.sh 会直接 skip（看起来像成功，其实没续）
~/.acme.sh/acme.sh --renew -d '*.odn.cc' --ecc --force \
  --server letsencrypt \
  --yes-I-know-dns-manual-mode-enough-go-ahead-please
```

## 常见问题

**Q：退出码 3 是失败吗？**
不是。`CODE_DNS_MANUAL`（3）表示 acme.sh 在等你加 DNS 记录，脚本据此继续。

**Q：TXT 加了但验证失败？**
先手工确认：`dig +short TXT _acme-challenge.<域名>` 能看到完整的值。国内 DNS 常有 1~5 分钟缓存延迟；把 TTL 设小一点、或换用权威 NS 查询（`dig +short TXT _acme-challenge.odn.cc @vip1.alidns.com`）。

**Q：怎么换 CA？**
`ACME_SERVER=zerossl ./acme_auto_cert.sh`。ZeroSSL 首次需要邮箱注册 EAB 账号。

**Q：证书给 frp / PassNAT 这类服务用，报 permission denied？**
两个原因：①归档目录 700 且证书是别的用户的服务在跑 → 加 `ALLOW_OTHER_READ=1`；②路径里的中间证书缺失 → 指 `<主域名>.cer` 或 `fullchain.cer`，别指 `.leaf.cer`。

**Q：域名带 `*`，路径里的 `*` 会被当通配符吗？**
脚本内部全部加引号处理，不会。但你在自己的配置里写路径时也要加引号，例如
`crtPath = "/vol2/1000/cert/*.odn.cc_ecc/*.odn.cc.cer"` 在 TOML 里是字面量，没问题；在 shell 里则要 `"/vol2/1000/cert/*.odn.cc_ecc/*.odn.cc.cer"`。

**Q：acme.sh 从哪来？**
复用 `$ACME_HOME/acme.sh`；没有则克隆 Gitee 镜像（`gitee.com/neilpang/acme.sh`），失败回落 GitHub 官方仓库。镜像未做版本锁定，介意的话可自行 `git checkout <tag>` 后再运行。

## 依赖

- Linux（bash 4.3+）、`git`、`curl`、`openssl`
- `dig`（可选，用于 TXT 生效检查；缺失则跳过检查，手工确认即可）

## 许可证

MIT
