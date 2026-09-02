# Caddy + Emby 反向代理管理脚本

![Language](https://img.shields.io/badge/Language-Bash-green.svg)
![Version](https://img.shields.io/badge/Version-V5.3-orange.svg)
![License](https://img.shields.io/badge/License-MIT-blue.svg)

一个以**交互式菜单**为主的 Caddy + Emby 反向代理脚本，适用于 Debian、Ubuntu、CentOS、RHEL 等 Linux 服务器。

它可以安装 Caddy、添加多个 Emby 站点、自动申请 HTTPS 证书，并在配置失败时自动回滚。

> 需要 root 权限。使用前请确认服务器、域名和 Emby 上游属于你。

## 快速开始

### 1. 下载脚本

建议先下载并检查脚本，再运行：

```bash
curl -fsSL https://raw.githubusercontent.com/AiLi1337/caddy_emby/main/install_caddy_emby.sh -o caddy_emby.sh
less caddy_emby.sh
chmod 755 caddy_emby.sh
```

### 2. 启动交互式菜单

不带参数运行：

```bash
sudo bash caddy_emby.sh
```

脚本会显示以下菜单：

```text
1. 安装环境 & Caddy
2. 添加/覆盖反代配置（支持多站）
3. 删除指定站点配置
4. 查看 Caddy 配置文件
5. 停止 Caddy
6. 校验并重载/启动 Caddy
7. 查询 80/443 端口占用
8. 确认后停止常见 Web 服务
9. 归档并完整卸载 Caddy
0. 退出脚本
```

### 3. 推荐操作顺序

1. 选择 `1`，安装基础依赖和 Caddy。
2. 选择 `7`，确认 80/443 没有被其他服务占用。
3. 选择 `2`，输入站点域名和 Emby 后端地址。
4. 已有配置时选择追加或覆盖。日常使用请选择追加。
5. 选择 `6`，校验并 reload 或启动 Caddy。
6. 用浏览器访问你的站点域名。

## 菜单 2：添加反代配置

### 站点域名

填写已经解析到本服务器的域名，例如：

```text
emby.example.com
emby.example.com:8443
*.example.com
```

只支持最左侧的单层通配符，站点端口范围为 `1-65535`。

### Emby 后端地址

本地 Emby：

```text
127.0.0.1:8096
[::1]:8096
```

远程 Emby：

```text
https://remote-emby.example.com
https://remote-emby.example.com:443
https://[2001:db8::10]:443
```

远程 HTTPS 后端会先进行 DNS、连通性和 TLS 检查。检查失败时不会直接写入配置，确认上游可用后再根据提示继续。

### 追加和覆盖

- 选择 `1`：覆盖，只保留新站点。
- 选择 `2`：追加，保留已有站点并添加或更新新站点。

## Cloudflare 和远程 HTTPS

当后端填写为 HTTPS 域名时，脚本会自动使用上游域名作为请求的 `Host`，兼容 Cloudflare 和依赖虚拟主机名的服务；同时删除上游返回的 `Access-Control-Allow-Origin: *`，但不会关闭 HTTPS 证书校验。

这可以解决“直接访问上游正常，通过反代却返回 403/404”的常见情况，但不能绕过 Cloudflare 的 WAF、Access、IP 黑名单、地区限制或其他安全规则。

如果站点之前由旧版脚本配置，需要重新通过菜单 `2` 更新该站点；单独选择菜单 `6` 只会 reload，不会改写旧配置。

## 其他菜单

- **菜单 3**：按编号或完整站点地址删除配置，执行前会再次确认。
- **菜单 4**：查看当前 Caddyfile。
- **菜单 5**：停止 Caddy。
- **菜单 6**：验证当前配置，并 reload 或启动 Caddy。
- **菜单 7**：查看 80/443 TCP 监听情况，支持 IPv4 和 IPv6。
- **菜单 8**：确认后只处理运行中的 `nginx`、`apache2`、`httpd` 服务，不会强制杀掉未知进程。
- **菜单 9**：先归档 Caddy 配置和数据，再停止并卸载 Caddy。

## 配置失败会怎样

脚本会先生成候选配置并执行 `caddy validate`，通过后才备份和替换正式 Caddyfile。reload 或启动失败时，会恢复旧配置并尽量恢复原来的 Caddy 服务状态。

管理器备份位于：

```text
/etc/caddy/.caddy-emby-manager-Caddyfile.bak.*
```

## 非交互命令（可选）

日常使用推荐交互式菜单。自动化场景可以使用：

```bash
sudo bash /usr/local/bin/caddy_emby.sh --install
sudo bash /usr/local/bin/caddy_emby.sh --check
sudo bash /usr/local/bin/caddy_emby.sh --configure emby.example.com https://remote-emby.example.com --append
sudo bash /usr/local/bin/caddy_emby.sh --delete emby.example.com --yes
sudo bash /usr/local/bin/caddy_emby.sh --reload
```

已有非空 Caddyfile 时，命令行配置必须明确指定 `--append` 或 `--overwrite`。

## 日志和排错

脚本日志位于 `/var/log/caddy-emby-manager.log`。Caddy 服务日志可以使用：

```bash
systemctl status caddy --no-pager -l
journalctl -u caddy -f
```

检查配置：

```bash
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
```

## 安全提醒

- 不要把密码、Token 或私钥写进 Caddyfile、命令历史或公开仓库。
- 使用覆盖、菜单 8 或菜单 9 前，确认没有其他业务依赖相关服务和目录。
- 脚本默认拒绝通配 CORS；确有跨域需求时请配置明确的前端来源。
- 脚本不包含 Cloudflare API、WAF 配置、访问频率限制、IP 黑名单、后台路径保护或多后端负载均衡。

## 许可证

MIT License
