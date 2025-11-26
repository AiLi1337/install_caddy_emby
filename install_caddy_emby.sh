#!/bin/bash

# ====================================================
#  Caddy Reverse Proxy for Emby - Pro Ver (Fixed)
#  Author: AiLi1337
# ====================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# 检查 root
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN} 必须使用 root 用户运行！\n" && exit 1

log() { echo -e "${GREEN}[Info]${PLAIN} $1"; }
warn() { echo -e "${YELLOW}[Warning]${PLAIN} $1"; }
error() { echo -e "${RED}[Error]${PLAIN} $1"; }

# 1. 安装基础环境
install_base() {
    log "正在更新系统..."
    if [ -f /etc/debian_version ]; then
        apt update -y && apt install -y curl wget sudo socat
    elif [ -f /etc/redhat-release ]; then
        yum install -y curl wget sudo socat
    fi
}

# 2. 安装 Caddy
install_caddy() {
    if command -v caddy &> /dev/null; then
        warn "Caddy 已安装，跳过安装步骤。"
    else
        log "正在安装 Caddy..."
        if [ -f /etc/debian_version ]; then
            apt install -y debian-keyring debian-archive-keyring apt-transport-https
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
            apt update
            apt install caddy -y
        elif [ -f /etc/redhat-release ]; then
            yum install yum-plugin-copr -y
            yum copr enable @caddyserver/caddy -y
            yum install caddy -y
        fi
        systemctl enable caddy
        log "Caddy 安装完成！"
    fi
}

# 3. 配置向导
configure_caddy() {
    echo -e "------------------------------------------------"
    echo -e "${SKYBLUE}Caddy 反代 Emby 配置向导${PLAIN}"
    echo -e "------------------------------------------------"

    # 1. 获取域名
    read -p "请输入你的新域名 (例如 emby.my.com): " DOMAIN < /dev/tty
    if [[ -z "$DOMAIN" ]]; then
        error "域名不能为空！"
        return
    fi

    # 2. 获取后端地址 (不再强制默认值，提示支持 https)
    read -p "请输入 Emby 后端地址 (例如 https://source.emby.com:443 或 127.0.0.1:8096): " EMBY_ADDRESS < /dev/tty
    if [[ -z "$EMBY_ADDRESS" ]]; then
        EMBY_ADDRESS="127.0.0.1:8096"
        warn "未输入地址，已使用默认本地地址: $EMBY_ADDRESS"
    fi

    # 备份旧配置
    if [ -f /etc/caddy/Caddyfile ]; then
        cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak.$(date +%F_%H%M%S)
        log "已备份原配置。"
    fi

    log "正在生成配置文件..."

    # 生成 Caddyfile
    # 注意：这里去掉了 email 指令，防止报错
    cat > /etc/caddy/Caddyfile <<EOF
$DOMAIN {
    encode gzip
    
    # 允许跨域
    header Access-Control-Allow-Origin *

    # 反向代理配置
    reverse_proxy $EMBY_ADDRESS {
        # 传递真实 IP 和协议
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        
        # 如果后端是 HTTPS 且域名不一致，可能需要开启 host 覆盖，
        # 但通常反代 Emby 保持 host 透传即可。如果遇到 404/403，
        # 可以尝试取消下面这行的注释:
        # header_up Host {upstream_hostport}
    }
}
EOF

    log "配置已写入，正在重启 Caddy..."
    systemctl restart caddy
    
    sleep 2
    if systemctl is-active --quiet caddy; then
        echo -e "\n${GREEN}=========================================="
        echo -e " 恭喜！反代配置成功！"
        echo -e " 访问地址: https://$DOMAIN"
        echo -e "==========================================${PLAIN}"
    else
        error "Caddy 启动失败！"
        echo "请使用 'systemctl status caddy -l' 查看详细错误。"
    fi
}

# 4. 菜单
menu() {
    clear
    echo -e "#################################################"
    echo -e "#    Caddy + Emby 一键反代脚本 (Fixed Ver)      #"
    echo -e "#################################################"
    echo -e ""
    echo -e " ${GREEN}1.${PLAIN} 安装并配置 Caddy"
    echo -e " ${GREEN}2.${PLAIN} 修改配置 (重置域名/后端)"
    echo -e " ${GREEN}3.${PLAIN} 停止服务"
    echo -e " ${GREEN}4.${PLAIN} 重启服务"
    echo -e " ${GREEN}5.${PLAIN} 卸载 Caddy"
    echo -e " ${GREEN}0.${PLAIN} 退出"
    echo -e ""
    read -p " 请输入数字: " num < /dev/tty

    case "$num" in
        1) install_base; install_caddy; configure_caddy ;;
        2) configure_caddy ;;
        3) systemctl stop caddy; log "服务已停止" ;;
        4) systemctl restart caddy; log "服务已重启" ;;
        5) apt remove caddy -y 2>/dev/null || yum remove caddy -y 2>/dev/null; rm -rf /etc/caddy; log "已卸载" ;;
        0) exit 0 ;;
        *) error "输入错误" ;;
    esac
}

menu
