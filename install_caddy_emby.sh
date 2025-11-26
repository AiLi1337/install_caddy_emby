#!/bin/bash

# ====================================================
#  Caddy Reverse Proxy for Emby - V4 (Fixed)
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
    log "正在检查并安装基础组件..."
    if [ -f /etc/debian_version ]; then
        apt update -y && apt install -y curl wget sudo socat net-tools psmisc
    elif [ -f /etc/redhat-release ]; then
        yum install -y curl wget sudo socat net-tools psmisc
    fi
}

# 2. 端口占用查询
check_port() {
    echo -e "------------------------------------------------"
    echo -e "${SKYBLUE}正在查询 80 和 443 端口占用情况...${PLAIN}"
    echo -e "------------------------------------------------"
    
    if command -v netstat &> /dev/null; then
        netstat -tunlp | grep -E ":80|:443"
    else
        ss -tulpn | grep -E ":80|:443"
    fi

    echo -e "------------------------------------------------"
    echo -e "如果有内容显示，说明端口被占用。"
    echo -e "如果是 nginx/apache，请使用菜单 [7] 清理。"
    echo -e "如果是 caddy，说明服务正在运行，属正常现象。"
}

# 3. 强制清理端口
kill_port() {
    echo -e "${RED}正在强制停止常见 Web 服务并清理端口...${PLAIN}"
    
    systemctl stop nginx 2>/dev/null
    systemctl disable nginx 2>/dev/null
    log "已停止 Nginx"

    systemctl stop apache2 2>/dev/null
    systemctl disable apache2 2>/dev/null
    systemctl stop httpd 2>/dev/null
    log "已停止 Apache"

    if command -v fuser &> /dev/null; then
        fuser -k 80/tcp 2>/dev/null
        fuser -k 443/tcp 2>/dev/null
    else
        killall -9 caddy 2>/dev/null
        killall -9 nginx 2>/dev/null
        killall -9 httpd 2>/dev/null
    fi
    
    log "清理完成！现在端口应该是干净的。"
    sleep 1
}

# 4. 安装 Caddy
install_caddy() {
    if command -v caddy &> /dev/null; then
        warn "Caddy 已安装。"
    else
        log "正在安装 Caddy..."
        install_base
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

# 5. 配置向导
configure_caddy() {
    echo -e "------------------------------------------------"
    echo -e "${SKYBLUE}Caddy 反代 Emby 配置向导${PLAIN}"
    echo -e "------------------------------------------------"

    read -p "请输入你的新域名 (例如 emby.my.com): " DOMAIN < /dev/tty
    if [[ -z "$DOMAIN" ]]; then
        error "域名不能为空"
        return
    fi

    read -p "请输入 Emby 后端地址 (如 https://source.com:443 或 127.0.0.1:8096): " EMBY_ADDRESS < /dev/tty
    if [[ -z "$EMBY_ADDRESS" ]]; then
        EMBY_ADDRESS="127.0.0.1:8096"
        warn "使用默认地址: $EMBY_ADDRESS"
    fi

    if [ -f /etc/caddy/Caddyfile ]; then
        cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak.$(date +%F_%H%M%S)
    fi

    log "正在生成配置文件..."

    cat > /etc/caddy/Caddyfile <<EOF
$DOMAIN {
    encode gzip
    header Access-Control-Allow-Origin *

    reverse_proxy $EMBY_ADDRESS {
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        header_up Host {upstream_hostport}
    }
}
EOF

    log "配置已写入，正在重启 Caddy..."
    
    killall -9 caddy 2>/dev/null
    systemctl restart caddy
    
    sleep 3
    if systemctl is-active --quiet caddy; then
        echo -e "\n${GREEN}=========================================="
        echo -e " 恭喜！反代配置成功！"
        echo -e " 访问地址: https://$DOMAIN"
        echo -e "==========================================${PLAIN}"
    else
        error "Caddy 启动失败！"
        echo "请尝试在菜单中选择 [7] 清理端口占用，然后重试 [4] 重启服务。"
        echo "日志: systemctl status caddy -l"
    fi
}

# 6. 菜单循环
show_menu() {
    clear
    echo -e "#################################################"
    echo -e "#    Caddy + Emby 一键反代脚本 (V4 Fixed)       #"
    echo -e "#################################################"
    echo -e " ${GREEN}1.${PLAIN} 安装环境 & Caddy"
    echo -e " ${GREEN}2.${PLAIN} 配置反代 (输入域名/IP)"
    echo -e " ${GREEN}3.${PLAIN} 停止 Caddy"
    echo -e " ${GREEN}4.${PLAIN} 重启 Caddy"
    echo -e " ${GREEN}5.${PLAIN} 卸载 Caddy"
    echo -e "-------------------------------------------------"
    echo -e " ${YELLOW}6.${PLAIN} 查询 443/80 端口占用"
    echo -e " ${RED}7.${PLAIN} 暴力处理端口占用 (修复启动失败)"
    echo -e "-------------------------------------------------"
    echo -e " ${GREEN}0.${PLAIN} 退出脚本"
    echo -e ""
    read -p " 请输入数字 [0-7]: " num < /dev/tty

    # 这里的 in 千万不要改成中文的 在
    case "$num" in
        1) install_base; install_caddy ;;
        2) install_base; configure_caddy ;;
        3) systemctl stop caddy; log "服务已停止" ;;
        4) systemctl restart caddy; log "服务已重启" ;;
        5) apt remove caddy -y 2>/dev/null; yum remove caddy -y 2>/dev/null; rm -rf /etc/caddy; log "已卸载" ;;
        6) install_base; check_port ;;
        7) install_base; kill_port ;;
        0) exit 0 ;;
        *) error "请输入正确的数字" ;;
    esac
}

# 主循环
while true; do
    show_menu
    echo -e "\n${GREEN}按回车键返回主菜单...${PLAIN}"
    read temp < /dev/tty
done
