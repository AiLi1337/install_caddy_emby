#!/bin/bash

# ====================================================
#  Caddy Reverse Proxy for Emby - One-Click Script
#  Based on common NodeSeek/Community Best Practices
# ====================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 检查是否为 root 用户
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN} 必须使用 root 用户运行此脚本！\n" && exit 1

log() {
    echo -e "${GREEN}[Info]${PLAIN} $1"
}

warn() {
    echo -e "${YELLOW}[Warning]${PLAIN} $1"
}

error() {
    echo -e "${RED}[Error]${PLAIN} $1"
}

# 1. 安装 Caddy
install_caddy() {
    log "正在检测系统并安装 Caddy..."

    if [ -f /etc/debian_version ]; then
        # Debian/Ubuntu 系统
        apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
        apt update
        apt install caddy -y
    elif [ -f /etc/redhat-release ]; then
        # CentOS/RHEL/Fedora 系统
        yum install yum-plugin-copr -y
        yum copr enable @caddyserver/caddy -y
        yum install caddy -y
    else
        error "不支持的操作系统，脚本仅支持 Debian/Ubuntu 或 CentOS/Almalinux。"
        exit 1
    fi

    if ! command -v caddy &> /dev/null; then
        error "Caddy 安装失败，请检查网络或源设置。"
        exit 1
    fi
    log "Caddy 安装成功！"
}

# 2. 配置 Caddy
configure_caddy() {
    echo "------------------------------------------------"
    echo "请根据提示输入配置信息"
    echo "------------------------------------------------"

    # 获取域名
    read -p "请输入你的域名 (例如 emby.example.com): " DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        error "域名不能为空！"
        exit 1
    fi

    # 获取邮箱
    read -p "请输入你的邮箱 (用于 Let's Encrypt 证书申请): " EMAIL
    if [[ -z "$EMAIL" ]]; then
        warn "邮箱为空，可能导致证书申请受限，建议填写。"
    fi

    # 获取 Emby 地址
    read -p "请输入 Emby 的本地地址 (默认 127.0.0.1:8096): " EMBY_ADDRESS
    if [[ -z "$EMBY_ADDRESS" ]]; then
        EMBY_ADDRESS="127.0.0.1:8096"
    fi

    log "正在生成 Caddyfile 配置..."

    # 写入配置文件
    # 这里使用了常见的优化配置：开启 gzip，透传 X-Forwarded-For 等
    cat > /etc/caddy/Caddyfile <<EOF
$DOMAIN {
    # 申请证书用的邮箱
    ${EMAIL:+email $EMAIL}

    # 开启 Gzip 压缩，节省带宽
    encode gzip

    # 反向代理设置
    reverse_proxy $EMBY_ADDRESS {
        # 这里的 header_up 用于确保 Emby 能正确识别客户端 IP
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
    
    # 日志设置 (可选，如果不想要日志可删除下面两行)
    log {
        output file /var/log/caddy/emby.log
    }
}
EOF
    
    log "配置已写入 /etc/caddy/Caddyfile"
}

# 3. 启动服务
start_service() {
    log "正在启动 Caddy 服务..."
    systemctl enable caddy
    systemctl restart caddy

    if systemctl is-active --quiet caddy; then
        echo "------------------------------------------------"
        echo -e "${GREEN}Caddy 安装并配置完成！${PLAIN}"
        echo -e "访问地址: ${GREEN}https://$DOMAIN${PLAIN}"
        echo -e "后端地址: ${YELLOW}$EMBY_ADDRESS${PLAIN}"
        echo "------------------------------------------------"
        echo "如果是首次访问，请等待几秒钟让 SSL 证书自动签发。"
    else
        error "Caddy 启动失败，请检查配置文件或端口占用情况。"
        echo "可以使用 'systemctl status caddy' 查看详细错误信息。"
    fi
}

# 主执行流程
install_caddy
configure_caddy
start_service
