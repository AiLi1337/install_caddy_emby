# Caddy + Emby 反向代理管理脚本

![Language](https://img.shields.io/badge/Language-Bash-green.svg)
![Version](https://img.shields.io/badge/Version-V5.3-orange.svg)
![License](https://img.shields.io/badge/License-MIT-blue.svg)

一个面向 Linux 服务器的 Caddy + Emby 反向代理管理脚本。它负责安装和管理 Caddy、创建多个 HTTPS 站点、代理本地或远程 Emby，并在配置变更时提供校验、备份、平滑 reload 和失败回滚。

脚本支持将公网域名反代到本地或远程 HTTP/HTTPS Emby 服务。对于经过 Cloudflare 或依赖虚拟主机名的 HTTPS 上游，脚本会自动使用上游主机名发送 `Host` 请求头。

> 这是一个需要 root 权限运行的服务器管理工具。正式使用前请先阅读脚本和本说明，并确认 DNS、服务器端口以及上游服务均属于你。

## 功能概览

- **Caddy 安装**：支持 Debian/Ubuntu 的 `apt`，以及 RHEL/CentOS 系的 `dnf`/`yum`。
- **多站点管理**：追加、覆盖、更新和删除单个站点，不影响其他站点。
- **配置事务保护**：候选文件先经过 `caddy validate`，再备份并原子替换；reload 失败时自动恢复配置和原服务状态。
- **平滑应用配置**：Caddy 已运行时优先执行 `systemctl reload caddy`，正常更新不主动 restart。
- **HTTPS 上游检查**：默认使用 `curl` 检查远程 HTTPS 上游的 DNS、连通性和 TLS；可显式跳过预检。
- **Cloudflare 兼容**：HTTPS 域名上游自动设置 `header_up Host {upstream_hostport}`，解决常见的上游 403/404。
- **CORS 限制**：拒绝配置中的 `Access-Control-Allow-Origin *`，并移除脚本管理反代上游返回的通配 CORS 响应头。
- **地址边界校验**：支持域名尾点、大小写、单层通配符、站点端口、IPv4、IPv6 和 IPv4-mapped IPv6。
- **状态与日志**：检查 Caddy 服务、80/443 监听端口，并记录管理器日志。
- **谨慎卸载**：卸载前归档 Caddy 配置和数据，并尽量只清理可以确认由脚本管理的文件。

## 快速开始

### 1. 下载并检查

推荐先下载到本地文件，再执行。不要在没有审核内容的情况下直接使用 curl | bash：

```bash
curl -fsSL https://raw.githubusercontent.com/AiLi1337/caddy_emby/main/install_caddy_emby.sh \\
  -o caddy_emby.sh
less caddy_emby.sh
chmod 755 caddy_emby.sh
```

### 2. 安装 Caddy

```bash
sudo bash caddy_emby.sh --install
```

安装成功后，脚本通常会保存到 `/usr/local/bin/caddy_emby.sh`，并尝试创建快捷命令 `c`。通过管道运行时不会自动安装快捷命令。

### 3. 准备 DNS 和端口

在添加站点前确认：

1. 站点域名的 A/AAAA 记录指向此服务器。
2. 服务器安全组和防火墙允许 TCP 80、443。
3. 本机没有其他服务抢占 Caddy 需要的端口。
4. 远程上游可以从此服务器访问。

### 4. 添加站点

首次创建本地 Emby 站点：

```bash
sudo /usr/local/bin/caddy_emby.sh \\
  --configure emby.example.com \\
  127.0.0.1:8096 \\
  --overwrite
```

在已有站点上追加远程 HTTPS Emby：

```bash
sudo /usr/local/bin/caddy_emby.sh \\
  --configure emby.example.com \\
  https://remote-emby.example.com \\
  --append
```

脚本会依次执行上游检查、候选配置校验、备份、原子替换和 reload。

## 命令行参数

| 命令 | 说明 |
| --- | --- |
| `--install` | 安装基础依赖和 Caddy，并尝试注册脚本快捷命令。 |
| `--check` | 检查 Caddy 配置、服务和 80/443 监听端口。 |
| `--configure DOMAIN[:PORT] [BACKEND] --append` | 保留其他站点，添加或更新目标站点。 |
| `--configure DOMAIN[:PORT] [BACKEND] --overwrite` | 用目标站点覆盖现有 Caddyfile。 |
| `--configure ... --skip-upstream-check` | 跳过远程 HTTPS 上游预检；仅在你确认上游可用时使用。 |
| `--delete DOMAIN[:PORT] --yes` | 删除指定站点；非交互执行必须显式提供 `--yes`。 |
| `--reload` | 校验当前 Caddyfile，并 reload 或启动 Caddy。 |
| `--stop` | 停止 Caddy 服务。 |
| `--uninstall --yes` | 归档并卸载 Caddy；非交互执行必须显式提供 `--yes`。 |
| `--version` | 输出脚本版本。 |
| `--help` | 显示帮助。 |

`--configure` 也接受 `--config` 和 `--add`。已有非空 Caddyfile 时，必须明确选择 `--append` 或 `--overwrite`，避免误覆盖。

### 常用示例

```bash
# 查看整体状态
sudo /usr/local/bin/caddy_emby.sh --check

# 追加本地 Emby
sudo /usr/local/bin/caddy_emby.sh \\
  --configure emby.example.com 127.0.0.1:8096 --append

# 追加远程 HTTPS Emby
sudo /usr/local/bin/caddy_emby.sh \\
  --configure emby.example.com https://remote-emby.example.com:443 --append

# 远程检查受限时，显式跳过检查
sudo /usr/local/bin/caddy_emby.sh \\
  --configure emby.example.com https://remote-emby.example.com:443 \\
  --append --skip-upstream-check

# 删除站点
sudo /usr/local/bin/caddy_emby.sh --delete emby.example.com --yes

# 校验并 reload
sudo /usr/local/bin/caddy_emby.sh --reload
```

## 支持的地址格式

### 站点地址

站点地址支持可选端口，端口范围为 `1-65535`：

```text
emby.example.com
emby.example.com:8443
*.example.com
*.example.com:8443
```

只支持最左侧的单层通配符，例如 `*.example.com`；`foo.*.example.com` 会被拒绝。

### Emby 上游

```text
127.0.0.1:8096
192.168.1.20:8096
emby.internal.example.com:8096
https://remote-emby.example.com
https://remote-emby.example.com:443
[::1]:8096
https://[2001:db8::10]:443
```

HTTPS 上游 URL 不支持路径、查询字符串或片段；脚本只把它作为上游主机和端口使用。

## Cloudflare 与远程 HTTPS 上游

### 脚本自动处理的情况

当后端写成 HTTPS 域名时，脚本会生成类似下面的配置：

```caddy
reverse_proxy https://remote-emby.example.com {
    header_up Host {upstream_hostport}
    header_down -Access-Control-Allow-Origin
    header_up X-Real-IP {remote_host}
}
```

`header_up Host {upstream_hostport}` 会让 Cloudflare 或远程虚拟主机看到上游域名，而不是用户访问的公网域名。这可以解决常见的“直接访问上游正常，但通过反代返回 403/404”的情况。

更新已经存在的旧站点时，需要重新执行一次 `--configure ... --append` 或 `--overwrite` 来生成新配置；单独执行 `--reload` 不会改写旧配置块。

### 脚本不能绕过的情况

上述处理不等于绕过 Cloudflare 安全策略。以下情况仍需在 Cloudflare 或上游服务侧处理：

- WAF 规则、IP 黑名单、地区限制或 Bot 管理拦截。
- Cloudflare Access、登录认证或来源校验。
- 上游只允许特定源 IP。
- 上游证书无效、DNS 错误、端口不可达。

如果域名使用 Cloudflare 代理，建议确认 Cloudflare 到源站的 SSL/TLS 模式、源站 80/443 放行规则和证书挑战条件。

## 配置变更与回滚

对追加、覆盖和删除操作，脚本采用以下流程：

1. 校验输入和现有配置。
2. 生成候选 Caddyfile。
3. 使用 `caddy validate --config FILE --adapter caddyfile` 校验候选配置。
4. 记录配置变更前的 Caddy 服务状态。
5. 备份当前 Caddyfile，并原子替换正式文件。
6. 校验正式配置并优先执行 `systemctl reload caddy`。
7. 检查 reload 后服务状态。
8. 如果应用失败，恢复备份并尽量恢复原来的服务运行状态。

管理器备份保存在：

```text
/etc/caddy/.caddy-emby-manager-Caddyfile.bak.*
```

默认最多保留最近 5 份管理器备份。候选文件验证失败时不会触碰正式 Caddyfile，也不会触碰正在运行的 Caddy。

## 交互式菜单

不带参数运行会进入菜单：

```text
1. 安装环境和 Caddy
2. 添加或覆盖反代配置
3. 删除指定站点配置
4. 查看 Caddy 配置文件
5. 停止 Caddy
6. 校验并 reload 或启动 Caddy
7. 查询 80/443 端口占用
8. 确认后停止常见 Web 服务
9. 归档并完整卸载 Caddy
0. 退出脚本
```

删除菜单支持输入编号或完整站点地址，并会在执行前确认。编号按十进制解析，类似 `08` 的输入不会被当作八进制。

## 日志、状态与端口

脚本日志：

```text
/var/log/caddy-emby-manager.log
```

日志文件会尝试设置为仅 root 可读写，并在达到约 5 MiB 时轮转为 `.1`。Caddy 自身的运行日志仍由 systemd journal 管理：

```bash
systemctl status caddy --no-pager -l
journalctl -u caddy -f
```

查看端口：

```bash
ss -ltnp | awk '$4 ~ /:(80|443)$/ { print }'
```

脚本只识别 TCP `LISTEN`，并同时处理 IPv4 和 IPv6 监听地址。菜单中的常见 Web 服务处理只会停止已确认存在且正在运行的 `nginx`、`apache2` 或 `httpd` systemd 服务，不会强制 kill 未知进程。

## 安装与卸载说明

### 运行要求

- Linux，root 权限。
- Bash、systemd、curl、gpg、tar。
- Debian/Ubuntu 使用 apt；RHEL/CentOS 系使用 dnf 或 yum。
- 配置变更需要 `flock`；端口检查优先使用 `ss`，没有时尝试 `netstat`。

### 卸载行为

执行卸载前，脚本会要求确认，并尝试：

1. 将 `/etc/caddy` 和 `/var/lib/caddy` 归档到 `/var/backups/caddy-emby-manager`。
2. 停止 Caddy 服务。
3. 使用包管理器移除 Caddy；Debian 使用 `apt remove`，不会主动 `purge` 用户配置。
4. 只删除能确认由脚本管理的 Caddyfile、快捷命令、脚本和管理器状态。含有未管理内容的配置文件会保留。
5. 对 apt 源和 keyring 做归属及校验值检查，内容被修改时保留并提示人工处理。

卸载前请确认归档目录有足够空间，并确认没有其他程序依赖 `/etc/caddy` 或 `/var/lib/caddy`。

## 安全边界

- 不要把密码、Token 或私钥写进 Caddyfile、命令历史或公开仓库。
- 不要在未确认目标主机和当前配置的情况下使用 `--overwrite`、端口处理或卸载。
- 脚本不会默认生成通配 CORS；如果应用确实需要跨域，请在 Caddy 配置中明确允许具体来源。
- 脚本不提供 Cloudflare API、WAF、限流、IP 黑名单、后台路径保护或多后端负载均衡配置。
- `--skip-upstream-check` 只跳过预检，不会关闭 Caddy 的上游 TLS 证书校验。

## 许可证

MIT License
