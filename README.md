# Caddy + Emby 反向代理管理脚本

[![Language](https://img.shields.io/badge/Language-Bash-2f855a.svg)](install_caddy_emby.sh)
[![Version](https://img.shields.io/badge/Version-V5.4.1-e67e22.svg)](install_caddy_emby.sh)
[![License](https://img.shields.io/badge/License-MIT-2563eb.svg)](LICENSE)

用一台能够访问 Emby 源站的 Linux 服务器，为客户端提供稳定的 HTTPS 反向代理入口。脚本负责安装 Caddy、签发证书、管理多站点配置，并在失败时尽量恢复原状态。

> [!IMPORTANT]
> “直连观看”是指客户端可以通过反代域名访问 Emby。是否显示为 Emby 的
> `Direct Play`，仍取决于媒体编码、客户端能力、码率和服务端设置。
> 仅代理你拥有或获准使用的 Emby 服务和域名。脚本需要 root 权限，并会管理 Caddy 服务、软件源和 `/etc/caddy/Caddyfile`。

## 功能

- 从 Caddy 官方软件源安装 Caddy，支持 `apt-get`、`dnf` 和 `yum`。
- 支持本地 Emby、远程 HTTP/HTTPS Emby、IPv4、IPv6 和自定义前端端口。
- 自动启用 HTTPS 和 HTTP 到 HTTPS 跳转，无需手写证书配置。
- 支持多站点追加、更新和删除；仅删除带有管理标记的配置块。
- 原样透传 Emby 的 CORS 响应头，并由 Caddy 原生处理 Range 请求和 WebSocket。
- 写入前执行 `caddy validate`，原子替换配置；失败时回滚配置和服务状态。
- 检测同一主机与端口的现有路由，避免托管配置和手写配置发生冲突。
- 使用全局锁保护安装、配置、重载、停止和卸载，避免并发操作互相覆盖。
- 记录软件包、软件源和服务 mask 的原始状态；卸载时不接管来源不明的资源。

## 使用前准备

| 项目 | 要求 |
| --- | --- |
| 系统 | 使用 systemd，且提供 `apt-get`、`dnf` 或 `yum` |
| 权限 | root，或可以使用 `sudo` |
| DNS | 域名的全部 A/AAAA 记录指向反代服务器 |
| 端口 | 放行入站 TCP `80`、`443`；自定义端口也要单独放行 |
| 网络 | 反代服务器能够访问 Emby 上游和 Caddy 官方软件源 |
| 上游 HTTPS | 证书必须有效，且主机名与证书匹配 |

目前完整回归测试环境为 Debian 12。其他使用 systemd 的 Debian/Ubuntu 和 RPM 系发行版由脚本提供安装路径，但建议先在测试机验证。

## 快速开始

### 一行启动面板

复制下面这一整行到服务器执行，即可下载脚本并打开管理面板：

<!-- markdownlint-disable MD013 -->

```bash
curl -fL --retry 3 https://raw.githubusercontent.com/AiLi1337/caddy_emby/main/install_caddy_emby.sh -o caddy_emby.sh && sudo bash ./caddy_emby.sh
```

<!-- markdownlint-enable MD013 -->

脚本会保存到当前目录。首次运行后，若快捷命令注册成功，以后直接输入
`c` 即可再次打开面板。

这条命令没有使用 `curl | bash`：远程内容会先落盘为普通文件，脚本才能安全地
注册快捷命令。若希望运行前先阅读代码，请使用下一种方式。

### 下载、检查后运行

不要把远程脚本直接管道传给 root shell。先保存、检查，再执行：

```bash
base_url='https://raw.githubusercontent.com/AiLi1337/caddy_emby'
curl -fL --retry 3 \
  "$base_url/main/install_caddy_emby.sh" \
  -o caddy_emby.sh

less caddy_emby.sh
chmod 755 caddy_emby.sh
sudo bash ./caddy_emby.sh
```

### 按菜单部署

推荐顺序：

1. 选择 `1` 安装环境和 Caddy。
2. 选择 `7` 检查 `80/443` 是否被其他程序占用。
3. 选择 `2`，填写反代域名和 Emby 后端地址。
4. 首次配置可选择覆盖；已有 Caddyfile 时通常选择追加。
5. 选择 `6` 检查并重载服务。
6. 使用浏览器打开反代域名，登录并测试播放。

脚本成功注册后，也可以直接运行 `c` 再次打开菜单。若
`/usr/local/bin/caddy_emby.sh` 或 `/usr/local/bin/c` 已被其他程序使用，
脚本会保留它们并给出警告。

### 使用命令行部署

本地 Emby：

```bash
sudo bash ./caddy_emby.sh --install
sudo bash /usr/local/bin/caddy_emby.sh \
  --configure emby.example.com 127.0.0.1:8096 --overwrite
```

远程 HTTPS Emby：

```bash
sudo bash /usr/local/bin/caddy_emby.sh \
  --configure emby.example.com https://origin.example.com/ --append
```

完成后检查：

```bash
sudo bash /usr/local/bin/caddy_emby.sh --check
```

## 地址格式

### 前端站点

| 输入 | 行为 |
| --- | --- |
| `emby.example.com` | 使用默认 HTTPS 端口 `443` |
| `emby.example.com:443` | 自动规范化为 `emby.example.com` |
| `emby.example.com:8443` | 在 `8443` 上提供 HTTPS，访问时需要携带端口 |
| `*.example.com` | 拒绝；通配符证书需要额外配置 DNS Challenge |

自定义 HTTPS 端口不会自动替代 `443`。请同时确认云防火墙、系统防火墙和运营商网络允许该端口。

### Emby 后端

```text
127.0.0.1:8096
http://10.0.0.20:8096
[::1]:8096
https://origin.example.com
https://origin.example.com:443/
https://[2001:db8::10]:443
```

后端只能填写主机和可选端口，不支持 URL 路径、查询参数或片段。HTTPS 后端允许一个结尾 `/`，保存时会自动规范化。

远程 HTTPS 后端在写入前会检查 DNS、连接和 TLS。私有 CA、自签名证书或证书名称不匹配会被拒绝；脚本不会关闭 TLS 校验。

## 追加与覆盖

- `--append`：保留现有 Caddyfile，添加或更新当前脚本管理的站点。这是已有服务时的推荐方式。
- `--overwrite`：用新站点替换整个 Caddyfile，包括其中所有手写配置。只应在确认不需要旧配置时使用。
- 更新或删除：仅操作 `CADDY-EMBY-MANAGED` 标记包围的完整配置块。
- 路由冲突：若相同主机和端口已存在非托管路由，脚本会拒绝追加，避免重复匹配。

命令行面对非空 Caddyfile 时，必须明确指定 `--append` 或 `--overwrite`，不会自行猜测。

## 命令参考

```text
--install
    安装基础依赖和 Caddy。

--configure DOMAIN[:PORT] [BACKEND] --append|--overwrite
    添加或更新站点；BACKEND 默认是 127.0.0.1:8096。

--skip-upstream-check
    与 --configure 一起使用，仅跳过部署前检查；不会让 Caddy 忽略 TLS 错误。

--delete DOMAIN[:PORT] --yes
    删除指定的托管站点。

--check
    检查 Caddyfile、服务状态以及托管站点所需端口。

--reload
    校验配置并重载；服务未运行时会启动。

--stop
    停止 Caddy。

--uninstall --yes
    停止并归档后卸载脚本管理的内容。

--version
    显示脚本版本。
```

常用示例：

```bash
# 添加第二个站点
sudo bash /usr/local/bin/caddy_emby.sh \
  --configure emby2.example.com https://origin2.example.com --append

# 更新同一个托管站点的后端
sudo bash /usr/local/bin/caddy_emby.sh \
  --configure emby2.example.com 10.0.0.20:8096 --append

# 删除站点
sudo bash /usr/local/bin/caddy_emby.sh \
  --delete emby2.example.com --yes

# 校验并重载
sudo bash /usr/local/bin/caddy_emby.sh --reload
```

## 菜单说明

| 选项 | 操作 |
| ---: | --- |
| 1 | 安装环境和 Caddy |
| 2 | 添加或覆盖反代配置 |
| 3 | 删除指定托管站点 |
| 4 | 查看 Caddyfile |
| 5 | 停止 Caddy |
| 6 | 校验并重载或启动 Caddy |
| 7 | 查看 `80/443` 端口占用 |
| 8 | 确认后停止运行中的 `nginx`、`apache2`、`httpd` |
| 9 | 归档并卸载 Caddy |
| 0 | 退出 |

选项 `8` 不会强制杀死未知进程。若端口仍被占用，脚本会停止并要求人工确认。

## 配置安全与回滚

脚本先在 `/etc/caddy` 中生成候选文件，通过 `caddy validate` 后才替换正式配置。正式配置会保留最近 5 份备份：

```text
/etc/caddy/.caddy-emby-manager-Caddyfile.bak.*
```

若 reload 或启动失败，脚本会恢复旧 Caddyfile，并尽量恢复修改前的服务状态。软件包安装失败时，也会恢复原有 Caddy apt 源和 keyring。

卸载前会停止 Caddy，并把配置和证书归档到：

```text
/var/backups/caddy-emby-manager/
```

归档可能包含 TLS 私钥，请按敏感数据保护。脚本只卸载由自身记录为已安装的 Caddy 包；预先存在或归属无法确认的包、配置和数据会保留。

## V5.4.1 热修复

- 修复删除唯一托管站点时，空候选 Caddyfile 被 `caddy validate` 拒绝的问题。
- 删除最后一个站点后，脚本会写入可验证的无站点占位配置，并停止 Caddy 服务。

## V5.4 变化

- 不再删除上游 CORS 响应头，避免破坏 Emby Web 客户端和跨域 API 行为。
- 将 `domain` 与 `domain:443` 视为同一个托管站点，并兼容旧标记。
- 路由冲突检测同时考虑 Host 和端口；状态检查覆盖自定义托管端口。
- 追加、替换和删除只识别完整托管块，避免误改普通 Caddy 配置。
- 明确拒绝未配置 DNS Challenge 的通配符站点。
- 接受带结尾 `/` 的 HTTPS 上游，并统一保存格式。
- 为关键操作增加全局锁，强化 APT 来源校验、失败回滚和卸载归属保护。
- 卸载前先停止服务，并恢复安装前的 systemd mask 状态。

## 已验证项目

V5.4.1 已在 Debian 12 与 Caddy `v2.11.4` 上进行真实远程部署测试：

| 项目 | 结果 |
| --- | --- |
| Let's Encrypt 证书与 HTTP/2 | 通过 |
| HTTP 到 HTTPS 跳转 | `308` |
| Emby 公共 API 与源站内容比对 | 完全一致 |
| CORS 响应头透传 | 通过 |
| Range 分段请求 | `206 Partial Content` |
| WebSocket 升级 | `101 Switching Protocols` |
| 自定义 HTTPS 端口 `8443` | 通过 |
| 浏览器登录与实际播放 | 通过 |
| 配置失败回滚和非托管配置保护 | 通过 |
| 安装失败清理、包归属和 mask 恢复 | 通过 |

测试通过不代表脚本能够绕过上游 WAF、Access、IP 黑名单、地区限制、账号权限或 Emby 服务端策略。

## 排错

```bash
# 管理器综合检查
sudo bash /usr/local/bin/caddy_emby.sh --check

# Caddy 状态和日志
sudo systemctl status caddy --no-pager -l
sudo journalctl -u caddy -f

# 单独校验配置
sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

# 管理脚本日志
sudo tail -n 200 /var/log/caddy-emby-manager.log
```

- 证书申请失败：检查全部 A/AAAA 记录、入站 `80/443`、CDN 回源和防火墙。
- 返回 `502`：从反代服务器检查上游 DNS、端口、路由和 HTTPS 证书。
- 返回 `403/404`：检查上游虚拟主机、WAF、IP/地区限制和访问策略。
- 能登录但不能播放：检查浏览器网络面板中的媒体请求、Range 响应、客户端编码支持和 Emby 转码日志。

## 从旧版升级

先按“下载并检查脚本”获取新文件，再直接运行该文件。新版本不会覆盖无法确认归属的 `/usr/local/bin/caddy_emby.sh` 或 `/usr/local/bin/c`。

若出现保留旧文件的警告，请先检查并备份这些路径。只有确认它们确实属于旧版脚本后，才手动替换；不要覆盖其他程序使用的同名命令。

旧版生成的站点不会仅靠 `--reload` 自动改写。请使用菜单 `2` 或 `--configure ... --append` 重新更新对应站点。

## 不包含的功能

- DNS Challenge 和通配符证书
- 私有 CA 或自签名 HTTPS 上游
- Cloudflare API、WAF 或 CDN 自动配置
- 访问控制、限速、IP 黑白名单和后台路径保护
- 多上游负载均衡和 Emby 账号管理
- 强制媒体 Direct Play 或绕过上游安全策略

## License

[MIT](LICENSE)
