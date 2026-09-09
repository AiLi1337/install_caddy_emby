#!/usr/bin/env bash

# ====================================================
#  Caddy Reverse Proxy for Emby - V5.4
#  CADDY-EMBY-MANAGER-MANAGED-SCRIPT
#  Multi-site manager with validation and rollback
# ====================================================

SCRIPT_VERSION="5.4"
SCRIPT_DEST="/usr/local/bin/caddy_emby.sh"
SHORTCUT="/usr/local/bin/c"
CADDY_DIR="/etc/caddy"
CADDYFILE="$CADDY_DIR/Caddyfile"
CADDY_DATA_DIR="/var/lib/caddy"
LOG_FILE="/var/log/caddy-emby-manager.log"
LOG_MAX_BYTES=5242880
STATE_DIR="/var/lib/caddy-emby-manager"
ALIAS_MARKER="$STATE_DIR/root-alias-added"
APT_SOURCE="/etc/apt/sources.list.d/caddy-stable.list"
APT_KEYRING="/usr/share/keyrings/caddy-stable-archive-keyring.gpg"
APT_SOURCE_BACKUP="$STATE_DIR/caddy-stable.list.before"
APT_KEYRING_BACKUP="$STATE_DIR/caddy-stable-archive-keyring.before"
APT_SOURCE_WAS_PRESENT="$STATE_DIR/apt-source-was-present"
APT_KEYRING_WAS_PRESENT="$STATE_DIR/apt-keyring-was-present"
APT_SOURCE_INSTALLED_HASH="$STATE_DIR/apt-source-installed.sha256"
APT_KEYRING_INSTALLED_HASH="$STATE_DIR/apt-keyring-installed.sha256"
APT_TRANSACTION_ACTIVE="$STATE_DIR/apt-transaction-active"
CADDY_PACKAGE_MARKER="$STATE_DIR/caddy-package-installed"
CADDY_SERVICE_WAS_MASKED="$STATE_DIR/caddy-service-was-masked"
RPM_COPR_MARKER="$STATE_DIR/caddy-copr-enabled"
CADDY_GPG_FINGERPRINT="65760C51EDEA2017CEA2CA15155B6D79CA56EA34"
CADDY_APT_REPOSITORY="https://dl.cloudsmith.io/public/caddy/stable/deb/debian"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

FORCE_YES=false
SKIP_UPSTREAM_CHECK=false
INTERACTIVE_MODE=true
BACKEND_SCHEME=""
BACKEND_CANONICAL=""
RUNTIME_FILES=()

log()   { printf '%s %b %s\n' "$(date '+%F %T')" "${GREEN}[Info]${PLAIN}" "$1"; }
warn()  { printf '%s %b %s\n' "$(date '+%F %T')" "${YELLOW}[Warning]${PLAIN}" "$1"; }
error() { printf '%s %b %s\n' "$(date '+%F %T')" "${RED}[Error]${PLAIN}" "$1"; }

usage() {
    cat <<EOF
Caddy + Emby 反代管理脚本 V${SCRIPT_VERSION}

无参数运行：进入交互式菜单

命令：
  --install                         安装基础依赖和 Caddy
  --check                           检查 Caddy 配置、服务和 80/443 端口
  --configure DOMAIN[:PORT] [BACKEND] 添加站点配置
       --append                     保留其他站点并追加/更新 DOMAIN
       --overwrite                  覆盖为仅 DOMAIN 站点
       --skip-upstream-check        跳过远程 HTTPS 后端连通性检查
  --delete DOMAIN[:PORT] --yes      删除指定站点（自动化必须显式 --yes）
  --reload                          校验并重载（或启动）Caddy
  --stop                            停止 Caddy
  --uninstall --yes                 归档后卸载 Caddy 和脚本内容（保留未确认归属的数据）
  --version                         显示版本
  -h, --help                        显示帮助

示例：
  bash caddy_emby.sh --install
  bash caddy_emby.sh --configure emby.example.com 127.0.0.1:8096 --overwrite
  bash caddy_emby.sh --configure emby2.example.com https://remote.example.com:443 --append
  bash caddy_emby.sh --delete emby2.example.com --yes
EOF
}

init_logging() {
    local log_size

   if ! command -v tee >/dev/null 2>&1; then
       warn "未找到 tee，跳过脚本日志记录。"
       return 0
   fi

    if [[ -L "$LOG_FILE" ]]; then
        warn "$LOG_FILE 是符号链接，跳过脚本日志记录。"
        return 0
    fi

   if [[ -f "$LOG_FILE" ]]; then
        log_size=$(wc -c < "$LOG_FILE" 2>/dev/null) || log_size=0
        if [[ "$log_size" =~ ^[0-9]+$ ]] && ((log_size >= LOG_MAX_BYTES)); then
            if [[ -L "$LOG_FILE.1" || ( -e "$LOG_FILE.1" && ! -f "$LOG_FILE.1" ) ]]; then
                warn "$LOG_FILE.1 是符号链接，跳过日志轮转。"
            else
                mv "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
            fi
        fi
    fi

    if ! touch "$LOG_FILE" 2>/dev/null; then
        warn "无法写入 $LOG_FILE，跳过脚本日志记录。"
        return 0
    fi

    chmod 600 "$LOG_FILE" 2>/dev/null || true
    exec > >(tee -a "$LOG_FILE") 2>&1
    log "脚本日志：$LOG_FILE"
}

cleanup_runtime_files() {
    local path

    for path in "${RUNTIME_FILES[@]:-}"; do
        [[ -n "$path" && -f "$path" && ! -L "$path" ]] || continue
        rm -f -- "$path" 2>/dev/null || true
    done
}

handle_termination() {
    local exit_code="$1"

    cleanup_runtime_files
    trap - EXIT HUP INT TERM
    exit "$exit_code"
}

track_runtime_file() {
    RUNTIME_FILES+=("$1")
}

untrack_runtime_file() {
    local target="$1"
    local kept=()
    local path

    for path in "${RUNTIME_FILES[@]:-}"; do
        [[ "$path" == "$target" ]] || kept+=("$path")
    done
    RUNTIME_FILES=("${kept[@]}")
}

with_config_lock() {
    local lock_fd
    local lock_file="$CADDY_DIR/.caddy-emby-manager.lock"
    local result

    if [[ -L "$CADDY_DIR" ]]; then
        error "Caddy 配置目录是符号链接，为避免修改外部目录已取消。"
        return 1
    fi
    if [[ -e "$CADDY_DIR" && ! -d "$CADDY_DIR" ]]; then
        error "Caddy 配置路径不是目录：$CADDY_DIR"
        return 1
    fi
    mkdir -p "$CADDY_DIR" || {
        error "无法创建 Caddy 配置目录：$CADDY_DIR"
        return 1
    }

    if ! command -v flock >/dev/null 2>&1; then
        error "未找到 flock。请先安装 util-linux，再执行配置变更。"
        return 1
    fi

    [[ ! -L "$lock_file" ]] || {
        error "配置锁是符号链接，为避免写入外部路径已取消：$lock_file"
        return 1
    }
    exec {lock_fd}>"$lock_file" || {
        error "无法创建配置锁：$lock_file"
        return 1
    }
    if ! flock -x "$lock_fd"; then
        eval "exec ${lock_fd}>&-"
        error "无法取得配置锁：$lock_file"
        return 1
    fi

    "$@"
    result=$?
    flock -u "$lock_fd" || true
    eval "exec ${lock_fd}>&-"
    return "$result"
}

with_global_lock() {
    local lock_fd
    local lock_file="/run/lock/caddy-emby-manager.lock"
    local result

    command -v flock >/dev/null 2>&1 || {
        error "未找到 flock。请先安装 util-linux。"
        return 1
    }
    [[ -d /run/lock && ! -L /run/lock ]] || {
        error "全局锁目录不可用：/run/lock"
        return 1
    }
    [[ ! -L "$lock_file" && ( ! -e "$lock_file" || -f "$lock_file" ) ]] || {
        error "全局锁文件路径不安全：$lock_file"
        return 1
    }
    exec {lock_fd}>"$lock_file" || return 1
    flock -x "$lock_fd" || {
        eval "exec ${lock_fd}>&-"
        return 1
    }
    "$@"
    result=$?
    flock -u "$lock_fd" || true
    eval "exec ${lock_fd}>&-"
    return "$result"
}

trim_whitespace() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

normalize_domain() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

canonicalize_domain() {
    local value

    value=$(trim_whitespace "$1")
    [[ "$value" != *..* ]] || return 1
    value="${value%.}"
    normalize_domain "$value"
}

confirm_action() {
    local prompt="$1"
    local answer

    if [[ "$FORCE_YES" == true ]]; then
        return 0
    fi
    if [[ "$INTERACTIVE_MODE" != true || ! -r /dev/tty ]]; then
        return 1
    fi

    read -r -p "$prompt [y/N]: " answer < /dev/tty || return 1
    [[ "$answer" =~ ^[Yy]$ ]]
}

register_shortcut() {
    local source="${BASH_SOURCE[0]:-}"
    local alias_line="alias c='bash $SCRIPT_DEST'"
    local temporary

    if [[ ! -f "$source" || "$source" == /proc/* || "$source" == /dev/fd/* ]]; then
        warn "当前通过管道或文件描述符运行，不自动把未审核的远程内容安装为 root 快捷命令。"
        warn "请先保存脚本为本地文件后重新运行，才会创建 $SCRIPT_DEST。"
        return 1
    fi

    if [[ -L "$SCRIPT_DEST" || -L "$SHORTCUT" ]]; then
        warn "脚本目标或快捷命令是符号链接，拒绝覆盖以避免写入外部路径。"
        return 1
    fi

    if [[ -e "$SCRIPT_DEST" ]] && ! is_managed_script_file "$SCRIPT_DEST"; then
        warn "$SCRIPT_DEST 已存在且不是本脚本管理的文件，保留它。"
        return 1
    fi

    if [[ "$source" == "$SCRIPT_DEST" ]]; then
        chmod 755 "$SCRIPT_DEST" || {
            error "无法设置脚本权限：$SCRIPT_DEST"
            return 1
        }
    elif ! install -m 755 "$source" "$SCRIPT_DEST"; then
        error "无法保存脚本到 $SCRIPT_DEST"
        return 1
    fi
    log "脚本已保存到 $SCRIPT_DEST"

    if [[ -e "$SHORTCUT" ]] && ! is_managed_shortcut_file "$SHORTCUT"; then
        warn "$SHORTCUT 已存在且不是本脚本管理的快捷命令，保留它。"
    elif [[ ! -e "$SHORTCUT" ]]; then
        temporary=$(mktemp "${SHORTCUT}.tmp.XXXXXX") || {
            warn "无法创建快捷命令临时文件。"
            return 1
        }
        if ! printf '#!/usr/bin/env bash\nexec bash "%s" "$@"\n' "$SCRIPT_DEST" > "$temporary" || \
            ! chmod 755 "$temporary" || ! mv "$temporary" "$SHORTCUT"; then
            rm -f "$temporary"
            warn "快捷命令 $SHORTCUT 创建失败。"
        else
            log "已注册快捷命令：下次直接输入 c 即可启动本脚本"
        fi
    fi

    if [[ -f /root/.bashrc && ! -L /root/.bashrc ]] && ! grep -Fqx "$alias_line" /root/.bashrc 2>/dev/null; then
        if ! ensure_state_dir || ! state_entry_is_safe "$ALIAS_MARKER"; then
            warn "无法安全创建 alias 状态记录，未修改 /root/.bashrc。"
            return 1
        fi
        if printf '\n%s\n' "$alias_line" >> /root/.bashrc; then
            if ! : > "$ALIAS_MARKER"; then
                warn "alias 已写入，但状态记录创建失败；请人工检查 /root/.bashrc。"
                return 1
            fi
            log "已写入 alias，重新登录后也可用 c 唤出脚本"
        else
            warn "无法写入 /root/.bashrc。"
        fi
    fi
}

package_installed_debian() {
    command -v dpkg-query >/dev/null 2>&1 || return 1
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'
}

package_installed_rpm() {
    command -v rpm >/dev/null 2>&1 && rpm -q "$1" >/dev/null 2>&1
}

install_base() {
    local packages=()
    local missing=()
    local package

    log "正在检查基础组件..."

    if command -v apt-get >/dev/null 2>&1; then
        packages=(curl sudo sed grep jq ca-certificates gnupg iproute2 util-linux tar)
        command -v awk >/dev/null 2>&1 || packages+=(gawk)
        for package in "${packages[@]}"; do
            if package_installed_debian "$package"; then
                log "$package 已安装，跳过"
            else
                missing+=("$package")
            fi
        done

        if ((${#missing[@]} > 0)); then
            log "正在安装缺失的包：${missing[*]}"
            apt-get update || {
                error "apt-get update 失败。"
                return 1
            }
            apt-get install -y "${missing[@]}" || {
                error "基础组件安装失败。"
                return 1
            }
        else
            log "所有基础组件已安装"
        fi
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        packages=(curl sudo sed grep jq ca-certificates gnupg2 iproute util-linux tar)
        command -v awk >/dev/null 2>&1 || packages+=(gawk)
        for package in "${packages[@]}"; do
            if package_installed_rpm "$package"; then
                log "$package 已安装，跳过"
            else
                missing+=("$package")
            fi
        done

        if ((${#missing[@]} > 0)); then
            log "正在安装缺失的包：${missing[*]}"
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y "${missing[@]}" || {
                    error "基础组件安装失败。"
                    return 1
                }
            else
                yum install -y "${missing[@]}" || {
                    error "基础组件安装失败。"
                    return 1
                }
            fi
        else
            log "所有基础组件已安装"
        fi
    else
        error "未检测到 apt-get、dnf 或 yum。"
        log "请手动安装：curl sudo sed grep awk jq ca-certificates gnupg iproute util-linux tar"
        return 1
    fi
}

caddy_package_is_healthy() {
    if command -v dpkg-query >/dev/null 2>&1 && package_installed_debian caddy; then
        return 0
    fi
    if package_installed_rpm caddy; then
        return 0
    fi
    return 1
}

prepare_caddy_service_unit() {
    local enabled_state

    command -v systemctl >/dev/null 2>&1 || return 0
    enabled_state=$(systemctl is-enabled caddy 2>/dev/null || true)
    [[ "$enabled_state" == masked ]] || return 0
    ensure_state_dir || return 1
    state_entry_is_safe "$CADDY_SERVICE_WAS_MASKED" || return 1
    printf 'masked\n' > "$CADDY_SERVICE_WAS_MASKED" || return 1
    systemctl unmask caddy >/dev/null 2>&1 || {
        error "无法解除 caddy.service 的 masked 状态。"
        return 1
    }
    log "已临时解除 caddy.service 的 masked 状态；卸载时会恢复。"
}

record_caddy_service_mask_state() {
    local enabled_state

    command -v systemctl >/dev/null 2>&1 || return 0
    enabled_state=$(systemctl is-enabled caddy 2>/dev/null || true)
    [[ "$enabled_state" == masked ]] || return 0
    ensure_state_dir || return 1
    state_entry_is_safe "$CADDY_SERVICE_WAS_MASKED" || return 1
    printf 'masked\n' > "$CADDY_SERVICE_WAS_MASKED"
}

ensure_caddyfile_exists() {
    local temporary

    if [[ -f "$CADDYFILE" && ! -L "$CADDYFILE" ]]; then
        return 0
    fi
    [[ ! -e "$CADDYFILE" && ! -L "$CADDYFILE" ]] || {
        error "Caddyfile 路径不是可安全创建的普通文件：$CADDYFILE"
        return 1
    }
    temporary=$(mktemp "$CADDY_DIR/.Caddyfile.initial.XXXXXX") || return 1
    if ! printf '# Caddy Emby manager: add a site with --configure before starting Caddy.\n' > "$temporary" || \
        ! chmod 644 "$temporary" || ! mv "$temporary" "$CADDYFILE"; then
        rm -f "$temporary"
        error "无法创建初始 Caddyfile。"
        return 1
    fi
}

restore_caddy_service_mask() {
    [[ -f "$CADDY_SERVICE_WAS_MASKED" && ! -L "$CADDY_SERVICE_WAS_MASKED" ]] || return 0
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl mask caddy >/dev/null 2>&1
}

repair_managed_apt_asset_permissions() {
    local path

    for path in "$APT_SOURCE" "$APT_KEYRING"; do
        [[ -f "$path" && ! -L "$path" ]] || {
            error "本脚本管理的 apt 资产缺失或路径不安全：$path"
            return 1
        }
        chmod 644 "$path" || return 1
    done
}

cleanup_failed_caddy_package() {
    if command -v apt-get >/dev/null 2>&1 && dpkg-query -W caddy >/dev/null 2>&1; then
        apt-get remove -y caddy >/dev/null 2>&1 || dpkg --remove --force-remove-reinstreq caddy >/dev/null 2>&1 || true
    elif package_installed_rpm caddy; then
        if command -v dnf >/dev/null 2>&1; then
            dnf remove -y caddy >/dev/null 2>&1 || true
        elif command -v yum >/dev/null 2>&1; then
            yum remove -y caddy >/dev/null 2>&1 || true
        fi
    fi
}

cleanup_failed_install_bookkeeping() {
    local caddyfile_was_present="$1"
    local service_marker_was_present="$2"

    if [[ "$caddyfile_was_present" != true ]] && is_initial_managed_caddyfile "$CADDYFILE"; then
        rm -f "$CADDYFILE" || true
    fi
    if [[ "$service_marker_was_present" != true && -f "$CADDY_SERVICE_WAS_MASKED" && ! -L "$CADDY_SERVICE_WAS_MASKED" ]]; then
        restore_caddy_service_mask >/dev/null 2>&1 || true
        rm -f "$CADDY_SERVICE_WAS_MASKED" || true
    fi
    rmdir "$STATE_DIR" 2>/dev/null || true
}

record_managed_caddy_package() {
    local package_kind="$1"

    ensure_state_dir || return 1
    state_entry_is_safe "$CADDY_PACKAGE_MARKER" || return 1
    printf '%s\n' "$package_kind" > "$CADDY_PACKAGE_MARKER"
}

validate_caddy_apt_source() {
    local file="$1"
    local line
    local normalized
    local binary_seen=0
    local source_seen=0

    [[ -f "$file" && ! -L "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=$(trim_whitespace "$line")
        [[ -z "$line" || "$line" == \#* ]] && continue
        normalized=$(printf '%s' "$line" | tr -s '[:space:]' ' ')
        case "$normalized" in
            "deb [signed-by=$APT_KEYRING] $CADDY_APT_REPOSITORY any-version main")
                ((binary_seen += 1))
                ;;
            "deb-src [signed-by=$APT_KEYRING] $CADDY_APT_REPOSITORY any-version main")
                ((source_seen += 1))
                ;;
            *)
                error "Caddy apt 源文件包含未授权内容：$line"
                return 1
                ;;
        esac
    done < "$file"
    ((binary_seen == 1 && source_seen <= 1))
}

validate_caddy_apt_candidate() {
    local policy
    local candidate

    command -v apt-cache >/dev/null 2>&1 || return 1
    policy=$(apt-cache policy caddy 2>/dev/null) || return 1
    candidate=$(awk '/^[[:space:]]*Candidate:/ { print $2; exit }' <<< "$policy")
    [[ -n "$candidate" && "$candidate" != "(none)" ]] || return 1
    apt-cache madison caddy 2>/dev/null | awk -F'|' -v candidate="$candidate" -v repository="$CADDY_APT_REPOSITORY" '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        trim($2) == candidate && index($3, repository) { found = 1 }
        END { exit(found ? 0 : 1) }
    '
}

caddy_copr_is_enabled() {
    local manager="$1"

    "$manager" copr list --enabled 2>/dev/null | grep -Fq '@caddyserver/caddy'
}

enable_caddy_copr() {
    local manager="$1"
    local already_enabled=false

    caddy_copr_is_enabled "$manager" && already_enabled=true
    "$manager" copr enable @caddyserver/caddy -y || return 1
    if [[ "$already_enabled" != true ]]; then
        ensure_state_dir || return 1
        state_entry_is_safe "$RPM_COPR_MARKER" || return 1
        printf '%s\n' "$manager" > "$RPM_COPR_MARKER" || return 1
    fi
}

disable_managed_caddy_copr() {
    local manager

    [[ -f "$RPM_COPR_MARKER" && ! -L "$RPM_COPR_MARKER" ]] || return 0
    manager=$(<"$RPM_COPR_MARKER")
    [[ "$manager" == dnf || "$manager" == yum ]] || return 1
    command -v "$manager" >/dev/null 2>&1 || return 1
    "$manager" copr disable @caddyserver/caddy -y
}

ensure_state_dir() {
    if [[ -L "$STATE_DIR" ]]; then
        error "状态目录是符号链接，为避免修改外部目录已取消：$STATE_DIR"
        return 1
    fi
    if [[ -e "$STATE_DIR" && ! -d "$STATE_DIR" ]]; then
        error "状态路径不是目录：$STATE_DIR"
        return 1
    fi
    mkdir -p "$STATE_DIR" || return 1
    chmod 700 "$STATE_DIR" 2>/dev/null || true
}

state_entry_is_safe() {
    [[ ! -L "$1" && ( ! -e "$1" || -f "$1" ) ]]
}

backup_apt_asset() {
    local path="$1"
    local backup="$2"
    local marker="$3"

    if [[ -L "$path" ]]; then
        error "拒绝覆盖符号链接形式的 apt 资产：$path"
        return 1
    fi
    if [[ -e "$path" && ! -f "$path" ]]; then
        error "apt 资产路径不是普通文件：$path"
        return 1
    fi
    if ! state_entry_is_safe "$backup" || ! state_entry_is_safe "$marker"; then
        error "apt 资产恢复记录路径不安全：$path"
        return 1
    fi
    if [[ -e "$path" ]]; then
        cp -p "$path" "$backup" || return 1
        printf 'present\n' > "$marker" || return 1
    else
        rm -f "$backup" "$marker"
        printf 'absent\n' > "$marker" || return 1
    fi
}

clear_apt_transaction_state() {
    rm -f "$APT_TRANSACTION_ACTIVE" \
        "$APT_SOURCE_WAS_PRESENT" "$APT_KEYRING_WAS_PRESENT" \
        "$APT_SOURCE_BACKUP" "$APT_KEYRING_BACKUP" \
        "$APT_SOURCE_INSTALLED_HASH" "$APT_KEYRING_INSTALLED_HASH"
}

rollback_apt_transaction() {
    if restore_apt_assets; then
        clear_apt_transaction_state
        return 0
    fi
    error "apt 安装事务回滚不完整，保留 $STATE_DIR 供人工恢复。"
    return 1
}

prepare_apt_assets() {
    local state_path

    ensure_state_dir || return 1
    for state_path in \
        "$APT_TRANSACTION_ACTIVE" "$APT_SOURCE_WAS_PRESENT" "$APT_KEYRING_WAS_PRESENT" \
        "$APT_SOURCE_BACKUP" "$APT_KEYRING_BACKUP" "$APT_SOURCE_INSTALLED_HASH" "$APT_KEYRING_INSTALLED_HASH"; do
        if [[ -e "$state_path" || -L "$state_path" ]]; then
            error "检测到已有或未完成的 Caddy apt 安装记录：$state_path"
            error "为避免覆盖恢复基线，请先检查 $STATE_DIR，再重试。"
            return 1
        fi
    done

    : > "$APT_TRANSACTION_ACTIVE" || return 1
    backup_apt_asset "$APT_SOURCE" "$APT_SOURCE_BACKUP" "$APT_SOURCE_WAS_PRESENT" || {
        rm -f "$APT_TRANSACTION_ACTIVE"
        error "无法备份现有 Caddy apt 源。"
        return 1
    }
    backup_apt_asset "$APT_KEYRING" "$APT_KEYRING_BACKUP" "$APT_KEYRING_WAS_PRESENT" || {
        rollback_apt_transaction || true
        error "无法备份现有 Caddy keyring。"
        return 1
    }
}

restore_apt_asset() {
    local path="$1"
    local backup="$2"
    local marker="$3"
    local state

    state_entry_is_safe "$marker" || return 1
    state_entry_is_safe "$backup" || return 1
    [[ -f "$marker" ]] || return 0
    [[ ! -L "$path" && ( ! -e "$path" || -f "$path" ) ]] || return 1
    state=$(<"$marker")
    if [[ "$state" == present ]]; then
        [[ -f "$backup" ]] || return 1
        cp -p "$backup" "$path" || return 1
    elif [[ "$state" == absent ]]; then
        rm -f "$path"
    else
        return 1
    fi
}

restore_apt_assets() {
    local result=0

    restore_apt_asset "$APT_SOURCE" "$APT_SOURCE_BACKUP" "$APT_SOURCE_WAS_PRESENT" || result=1
    restore_apt_asset "$APT_KEYRING" "$APT_KEYRING_BACKUP" "$APT_KEYRING_WAS_PRESENT" || result=1
    if ((result != 0)); then
        error "恢复 Caddy apt 源或 keyring 失败，请检查 $STATE_DIR。"
    fi
    return "$result"
}

record_apt_asset_hash() {
    local path="$1"
    local hash_file="$2"
    local hash

    [[ -f "$path" ]] || return 1
    state_entry_is_safe "$hash_file" || return 1
    hash=$(sha256sum "$path" 2>/dev/null | awk '{print $1}') || return 1
    [[ "$hash" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
    printf '%s\n' "$hash" > "$hash_file"
}

install_environment() {
    with_global_lock install_environment_locked
}

install_environment_locked() {
    install_base && with_config_lock install_caddy_locked
}

install_caddy_locked() {
    local key_download
    local source_download
    local key_stage
    local source_stage
    local package_was_present=false
    local managed_package_kind=""
    local caddyfile_was_present=false
    local service_marker_was_present=false

    [[ -e "$CADDYFILE" || -L "$CADDYFILE" ]] && caddyfile_was_present=true
    [[ -e "$CADDY_SERVICE_WAS_MASKED" || -L "$CADDY_SERVICE_WAS_MASKED" ]] && service_marker_was_present=true

    if [[ -f "$CADDY_PACKAGE_MARKER" && ! -L "$CADDY_PACKAGE_MARKER" ]]; then
        managed_package_kind=$(<"$CADDY_PACKAGE_MARKER")
    fi

    if command -v caddy >/dev/null 2>&1; then
        if ! caddy_package_is_healthy; then
            error "检测到 caddy 命令，但包管理器状态不完整或安装来源无法确认。"
            return 1
        fi
        if [[ "$managed_package_kind" == debian || "$managed_package_kind" == rpm ]]; then
            log "本脚本安装的 Caddy 已存在，正在检查服务配置。"
            if [[ "$managed_package_kind" == debian ]]; then
                repair_managed_apt_asset_permissions || return 1
            fi
            ensure_caddyfile_exists || return 1
            prepare_caddy_service_unit || return 1
        else
            warn "Caddy 已由系统包管理器安装，脚本不会取得该包的卸载归属。"
        fi
        if command -v systemctl >/dev/null 2>&1; then
            if [[ $(systemctl is-enabled caddy 2>/dev/null || true) != masked ]]; then
                systemctl reset-failed caddy >/dev/null 2>&1 || true
                systemctl enable caddy >/dev/null 2>&1 || warn "无法设置 Caddy 开机自启。"
            else
                warn "caddy.service 已被 mask，保留现状。"
            fi
        fi
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1 || ! command -v gpg >/dev/null 2>&1; then
        error "缺少 curl 或 gpg，请先执行安装环境选项。"
        return 1
    fi

    log "正在安装 Caddy..."
    record_caddy_service_mask_state || return 1
    if command -v apt-get >/dev/null 2>&1; then
        package_installed_debian caddy && package_was_present=true
        prepare_apt_assets || return 1

        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y debian-keyring debian-archive-keyring apt-transport-https; then
            error "Caddy 所需 apt 组件安装失败。"
            rollback_apt_transaction || true
            cleanup_failed_install_bookkeeping "$caddyfile_was_present" "$service_marker_was_present"
            return 1
        fi

        key_download=$(mktemp "/tmp/caddy-key.XXXXXX") || {
            rollback_apt_transaction || true
            cleanup_failed_install_bookkeeping "$caddyfile_was_present" "$service_marker_was_present"
            return 1
        }
        track_runtime_file "$key_download"
        source_download=$(mktemp "/tmp/caddy-source.XXXXXX") || {
            rm -f "$key_download"
            untrack_runtime_file "$key_download"
            rollback_apt_transaction || true
            cleanup_failed_install_bookkeeping "$caddyfile_was_present" "$service_marker_was_present"
            return 1
        }
        track_runtime_file "$source_download"
        key_stage=$(mktemp "$(dirname "$APT_KEYRING")/.caddy-keyring.XXXXXX") || {
            rm -f "$key_download" "$source_download"
            untrack_runtime_file "$key_download"
            untrack_runtime_file "$source_download"
            rollback_apt_transaction || true
            cleanup_failed_install_bookkeeping "$caddyfile_was_present" "$service_marker_was_present"
            return 1
        }
        track_runtime_file "$key_stage"
        source_stage=$(mktemp "$(dirname "$APT_SOURCE")/.caddy-source.XXXXXX") || {
            rm -f "$key_download" "$source_download" "$key_stage"
            untrack_runtime_file "$key_download"
            untrack_runtime_file "$source_download"
            untrack_runtime_file "$key_stage"
            rollback_apt_transaction || true
            cleanup_failed_install_bookkeeping "$caddyfile_was_present" "$service_marker_was_present"
            return 1
        }
        track_runtime_file "$source_stage"

        if ! curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' -o "$key_download" || \
            ! curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' -o "$source_download" || \
            ! gpg --batch --show-keys --with-colons "$key_download" | awk -F: -v expected="$CADDY_GPG_FINGERPRINT" '
                $1 == "pub" { public_keys += 1; primary_fingerprint = 1; next }
                primary_fingerprint && $1 == "fpr" {
                    if ($10 == expected) expected_primary = 1
                    primary_fingerprint = 0
                }
                END { exit(public_keys == 1 && expected_primary ? 0 : 1) }
            ' || \
            ! gpg --dearmor --yes -o "$key_stage" "$key_download" || \
            ! validate_caddy_apt_source "$source_download" || \
            ! cp "$source_download" "$source_stage"; then
            error "Caddy 官方 apt 源或 keyring 下载/准备失败。"
            rm -f "$key_download" "$source_download" "$key_stage" "$source_stage"
            untrack_runtime_file "$key_download"
            untrack_runtime_file "$source_download"
            untrack_runtime_file "$key_stage"
            untrack_runtime_file "$source_stage"
            rollback_apt_transaction || true
            cleanup_failed_install_bookkeeping "$caddyfile_was_present" "$service_marker_was_present"
            return 1
        fi
        rm -f "$key_download" "$source_download"
        untrack_runtime_file "$key_download"
        untrack_runtime_file "$source_download"

        if ! mv "$key_stage" "$APT_KEYRING" || ! mv "$source_stage" "$APT_SOURCE"; then
            error "Caddy apt 源或 keyring 写入失败。"
            rm -f "$key_stage" "$source_stage"
            untrack_runtime_file "$key_stage"
            untrack_runtime_file "$source_stage"
            rollback_apt_transaction || true
            cleanup_failed_install_bookkeeping "$caddyfile_was_present" "$service_marker_was_present"
            return 1
        fi
        untrack_runtime_file "$key_stage"
        untrack_runtime_file "$source_stage"
        ensure_caddyfile_exists || {
            rollback_apt_transaction || true
            cleanup_failed_install_bookkeeping "$caddyfile_was_present" "$service_marker_was_present"
            return 1
        }
        if ! chmod 644 "$APT_KEYRING" "$APT_SOURCE"; then
            error "无法设置 Caddy apt 源或 keyring 的读取权限。"
            rollback_apt_transaction || true
            cleanup_failed_install_bookkeeping "$caddyfile_was_present" "$service_marker_was_present"
            return 1
        fi

        if ! apt-get update \
            -o APT::Update::Error-Mode=any \
            -o Acquire::AllowInsecureRepositories=false \
            -o Acquire::AllowDowngradeToInsecureRepositories=false || \
            ! validate_caddy_apt_candidate || \
            ! DEBIAN_FRONTEND=noninteractive apt-get install -y caddy; then
            error "Caddy apt 安装失败，正在恢复原有 apt 源和 keyring。"
            [[ "$package_was_present" == true ]] || cleanup_failed_caddy_package
            rollback_apt_transaction || true
            cleanup_failed_install_bookkeeping "$caddyfile_was_present" "$service_marker_was_present"
            return 1
        fi
        if ! caddy_package_is_healthy; then
            error "Caddy apt 包安装后状态不完整，正在清理本次安装。"
            [[ "$package_was_present" == true ]] || cleanup_failed_caddy_package
            rollback_apt_transaction || true
            cleanup_failed_install_bookkeeping "$caddyfile_was_present" "$service_marker_was_present"
            return 1
        fi

        record_apt_asset_hash "$APT_SOURCE" "$APT_SOURCE_INSTALLED_HASH" || \
            warn "无法记录 Caddy apt 源校验值，卸载时将保留该源。"
        record_apt_asset_hash "$APT_KEYRING" "$APT_KEYRING_INSTALLED_HASH" || \
            warn "无法记录 Caddy keyring 校验值，卸载时将保留该 keyring。"
        rm -f "$APT_TRANSACTION_ACTIVE"
        if [[ "$package_was_present" != true ]]; then
            record_managed_caddy_package debian || warn "无法记录 Caddy 包归属；卸载时将保留该包。"
        fi
    elif command -v dnf >/dev/null 2>&1; then
        package_installed_rpm caddy && package_was_present=true
        ensure_caddyfile_exists || return 1
        dnf install -y 'dnf-command(copr)' >/dev/null 2>&1 || dnf install -y dnf-plugins-core || {
            error "Caddy COPR 插件安装失败。"
            return 1
        }
        enable_caddy_copr dnf || {
            error "Caddy COPR 源启用失败。"
            return 1
        }
        dnf install -y caddy || {
            error "Caddy 安装失败。"
            [[ "$package_was_present" == true ]] || cleanup_failed_caddy_package
            disable_managed_caddy_copr >/dev/null 2>&1 || true
            return 1
        }
        caddy_package_is_healthy || {
            [[ "$package_was_present" == true ]] || cleanup_failed_caddy_package
            disable_managed_caddy_copr >/dev/null 2>&1 || true
            return 1
        }
        [[ "$package_was_present" == true ]] || record_managed_caddy_package rpm || warn "无法记录 Caddy 包归属；卸载时将保留该包。"
    elif command -v yum >/dev/null 2>&1; then
        package_installed_rpm caddy && package_was_present=true
        ensure_caddyfile_exists || return 1
        yum install -y yum-plugin-copr || {
            error "Caddy COPR 插件安装失败。"
            return 1
        }
        enable_caddy_copr yum || {
            error "Caddy COPR 源启用失败。"
            return 1
        }
        yum install -y caddy || {
            error "Caddy 安装失败。"
            [[ "$package_was_present" == true ]] || cleanup_failed_caddy_package
            disable_managed_caddy_copr >/dev/null 2>&1 || true
            return 1
        }
        caddy_package_is_healthy || {
            [[ "$package_was_present" == true ]] || cleanup_failed_caddy_package
            disable_managed_caddy_copr >/dev/null 2>&1 || true
            return 1
        }
        [[ "$package_was_present" == true ]] || record_managed_caddy_package rpm || warn "无法记录 Caddy 包归属；卸载时将保留该包。"
    else
        error "未找到支持的包管理器。"
        return 1
    fi

    if ! command -v caddy >/dev/null 2>&1; then
        error "Caddy 安装完成后仍无法找到 caddy 命令。"
        return 1
    fi
    ensure_caddyfile_exists || return 1
    prepare_caddy_service_unit || return 1
    if command -v systemctl >/dev/null 2>&1; then
        systemctl reset-failed caddy >/dev/null 2>&1 || true
        systemctl enable caddy || warn "Caddy 已安装，但设置开机自启失败。"
    fi
    log "Caddy 安装完成！"
}

validate_domain() {
    local domain
    local label
    local labels=()
    local wildcard=false
    local start_index=0
    local index

    domain=$(canonicalize_domain "$1") || return 1
    [[ "$domain" != *..* ]] || return 1
    [[ -n "$domain" && ${#domain} -le 253 ]] || return 1
    if [[ "$domain" == \*.* ]]; then
        wildcard=true
        start_index=1
    fi
    [[ "$domain" == *.* ]] || return 1
    [[ "$domain" != .* ]] || return 1

    IFS='.' read -r -a labels <<< "$domain"
    ((${#labels[@]} >= 2)) || return 1
    if [[ "$wildcard" == true ]]; then
        [[ ${#labels[@]} -ge 3 && "${labels[0]}" == "*" ]] || return 1
    fi
    for ((index = start_index; index < ${#labels[@]}; index++)); do
        label="${labels[$index]}"
        [[ ${#label} -le 63 ]] || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([-A-Za-z0-9]*[A-Za-z0-9])?$ ]] || return 1
    done
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
    ((10#$port >= 1 && 10#$port <= 65535))
}

canonicalize_site_address() {
    local value
    local host
    local port

    value=$(trim_whitespace "$1")
    if [[ "$value" =~ ^((\*\.)?[A-Za-z0-9.-]+):([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[3]}"
        host=$(canonicalize_domain "$host") || return 1
        validate_domain "$host" || return 1
        validate_port "$port" || return 1
        if ((10#$port == 443)); then
            printf "%s" "$host"
        else
            printf "%s:%d" "$host" "$((10#$port))"
        fi
    else
        host=$(canonicalize_domain "$value") || return 1
        validate_domain "$host" || return 1
        printf "%s" "$host"
    fi
}

validate_ipv4() {
    local ip="$1"
    local octet
    local octets=()
    local old_ifs="$IFS"

    IFS='.' read -r -a octets <<< "$ip"
    IFS="$old_ifs"
    ((${#octets[@]} == 4)) || return 1
    for octet in "${octets[@]}"; do
        [[ -n "$octet" && "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        ((10#$octet <= 255)) || return 1
    done
}

validate_ipv6() {
    local ip="$1"
    local left
    local right
    local part
    local group
    local groups=()
    local count=0
    local compressed=false
    local ipv4_tail=""
    local ipv4_seen=false
    local index

    [[ "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:.]+$ ]] || return 1
    [[ "$ip" != *:::* ]] || return 1

    if [[ "$ip" == *::* ]]; then
        compressed=true
        left="${ip%%::*}"
        right="${ip#*::}"
        [[ "$left" != *::* && "$right" != *::* ]] || return 1
    else
        left="$ip"
        right=""
        [[ "$ip" != :* && "$ip" != *: ]] || return 1
    fi

    if [[ "$ip" == *.* ]]; then
        ipv4_tail="${ip##*:}"
        [[ -n "$ipv4_tail" && "$ipv4_tail" != "$ip" ]] || return 1
        [[ "${ip%:*}" != *.* ]] || return 1
        validate_ipv4 "$ipv4_tail" || return 1
    fi

    for part in "$left" "$right"; do
        [[ -n "$part" ]] || continue
        [[ "$part" != :* && "$part" != *: ]] || return 1
        IFS=":" read -r -a groups <<< "$part"
        for index in "${!groups[@]}"; do
            group="${groups[index]}"
            if [[ "$group" == *.* ]]; then
                [[ "$group" == "$ipv4_tail" && "$ipv4_seen" != true ]] || return 1
                ((index == ${#groups[@]} - 1)) || return 1
                [[ "$part" != "$left" || "$compressed" != true ]] || return 1
                ipv4_seen=true
                ((count += 2))
            else
                [[ "$group" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
                ((count += 1))
            fi
        done
    done

    [[ -z "$ipv4_tail" || "$ipv4_seen" == true ]] || return 1
    if [[ "$compressed" == true ]]; then
        ((count < 8)) || return 1
    else
        ((count == 8)) || return 1
    fi
}

validate_hostname() {
    local hostname="$1"
    local label
    local labels=()

    hostname=$(trim_whitespace "$hostname")
    [[ "$hostname" != *..* ]] || return 1
    hostname="${hostname%.}"
    [[ -n "$hostname" && ${#hostname} -le 253 ]] || return 1
    [[ "$hostname" != .* && "$hostname" != *..* ]] || return 1
    [[ "$hostname" =~ ^[A-Za-z0-9.-]+$ ]] || return 1

    IFS='.' read -r -a labels <<< "$hostname"
    for label in "${labels[@]}"; do
        [[ -n "$label" && ${#label} -le 63 ]] || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([-A-Za-z0-9]*[A-Za-z0-9])?$ ]] || return 1
    done
}

validate_backend() {
    local backend
    local scheme="http"
    local hostport
    local host
    local port=""
    local bracketed_regex='^\[([^][]+)\](:([0-9]+))?$'

    backend=$(trim_whitespace "$1")
    [[ -n "$backend" && "$backend" != *[[:space:]]* ]] || return 1

    if [[ "$backend" =~ ^(https?)://(.+)$ ]]; then
        scheme="${BASH_REMATCH[1]}"
        hostport="${BASH_REMATCH[2]}"
    elif [[ "$backend" == *://* ]]; then
        return 1
    else
        hostport="$backend"
    fi

    hostport="${hostport%/}"

    [[ -n "$hostport" && "$hostport" != */* && "$hostport" != *\?* && "$hostport" != *#* ]] || return 1

    if [[ "$hostport" =~ $bracketed_regex ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[3]}"
        validate_ipv6 "$host" || return 1
    else
        [[ "$hostport" != \[* && "$hostport" != *\]* ]] || return 1
        if [[ "$hostport" == *:* ]]; then
            [[ "$hostport" != *:*:* ]] || return 1
            host="${hostport%%:*}"
            port="${hostport#*:}"
            [[ -n "$host" && -n "$port" ]] || return 1
        else
            host="$hostport"
        fi

        if [[ "$host" =~ ^[0-9.]+$ ]]; then
            validate_ipv4 "$host" || return 1
        else
            validate_hostname "$host" || return 1
        fi
    fi

    if [[ -n "$port" ]]; then
        validate_port "$port" || return 1
    fi

    BACKEND_SCHEME="$scheme"
    if [[ "$hostport" == \[* ]]; then
        if [[ -n "$port" ]]; then
            BACKEND_CANONICAL="[$host]:$((10#$port))"
        else
            BACKEND_CANONICAL="[$host]"
        fi
    elif [[ -n "$port" ]]; then
        BACKEND_CANONICAL="${host,,}:$((10#$port))"
    else
        BACKEND_CANONICAL="${host,,}"
    fi
    if [[ "$scheme" == https ]]; then
        BACKEND_CANONICAL="https://$BACKEND_CANONICAL"
    fi
    return 0
}

check_https_backend() {
    local backend="$1"
    local status

    [[ "$BACKEND_SCHEME" == https ]] || return 0
    if [[ "${SKIP_UPSTREAM_CHECK:-false}" == true ]]; then
        warn "已跳过远程 HTTPS 后端连通性检查。"
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1; then
        error "缺少 curl，无法检查 HTTPS 后端。"
        return 1
    fi

    log "正在检查 HTTPS 后端连通性：$backend"
    if status=$(curl -sS -o /dev/null -w '%{http_code}' \
        --connect-timeout 5 --max-time 15 "$backend" 2>/dev/null) && \
        [[ "$status" =~ ^[0-9]{3}$ && "$status" != 000 ]]; then
        log "HTTPS 后端可连接，返回 HTTP $status（4xx/5xx 仍表示已完成网络连接）。"
        return 0
    fi

    warn "HTTPS 后端连接或 TLS 校验失败：$backend"
    warn "请检查 DNS、端口、防火墙和证书；Caddy 也不会默认跳过上游证书校验。"
    if [[ "$INTERACTIVE_MODE" == true ]] && confirm_action "仍然写入此后端配置吗?"; then
        return 0
    fi
    error "未写入该 HTTPS 后端配置；确认可用后重试，或显式增加 --skip-upstream-check。"
    return 1
}

list_configured_domains() {
    local file="$1"
    [[ -f "$file" && ! -L "$file" ]] || return 0

    awk '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        /^[[:space:]]*#[[:space:]]+BEGIN[[:space:]]+CADDY-EMBY-MANAGED[[:space:]]+/ {
            line = trim($0)
            sub(/^#[[:space:]]+BEGIN[[:space:]]+CADDY-EMBY-MANAGED[[:space:]]+/, "", line)
            sub(/:443$/, "", line)
            if (line != "") print tolower(line)
        }
    ' "$file" | sort -u
}

site_conflicts_with_existing_config() {
    local target="$1"
    local file="$2"
    local adapted
    local target_host="$target"
    local target_port=443

    if [[ "$target" =~ ^(.+):([0-9]+)$ ]]; then
        target_host="${BASH_REMATCH[1]}"
        target_port="$((10#${BASH_REMATCH[2]}))"
    fi

    [[ -f "$file" && ! -L "$file" ]] || return 1
    command -v jq >/dev/null 2>&1 || {
        error "缺少 jq，无法安全检测 Caddy 站点冲突。"
        return 2
    }
    adapted=$(caddy adapt --config "$file" --adapter caddyfile 2>/dev/null) || return 2
    jq -e --arg target "$target_host" --arg port "$target_port" '
        [
            .apps.http.servers // {}
            | to_entries[]
            | select(any(.value.listen[]?; endswith(":" + $port)))
            | .value.routes[]?.match[]?.host[]?
            | ascii_downcase
            | select(. == ($target | ascii_downcase))
        ] | length > 0
    ' <<< "$adapted" >/dev/null
}

site_block_exists_in_file() {
    local target
    local file="$2"

    target=$(canonicalize_site_address "$1") || return 1
    [[ -f "$file" && ! -L "$file" ]] || return 1
    awk -v target="$target" '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        BEGIN {
            target = tolower(target)
            start = tolower("# BEGIN CADDY-EMBY-MANAGED " target)
            finish = tolower("# END CADDY-EMBY-MANAGED " target)
            if (target !~ /:[0-9]+$/) {
                alternate_start = start ":443"
                alternate_finish = finish ":443"
            }
        }
        {
            line_lower = tolower(trim($0))
            if (line_lower == start || (alternate_start != "" && line_lower == alternate_start)) {
                if (inside) exit 2
                found = 1
                inside = 1
                next
            }
            if (inside && (line_lower == finish || (alternate_finish != "" && line_lower == alternate_finish))) {
                inside = 0
                next
            }
        }
        END {
            if (inside) exit 2
            exit(found ? 0 : 1)
        }
    ' "$file"
}

remove_site_block_from_file() {
    local target
    local source="$2"
    local output="$3"

    target=$(canonicalize_site_address "$1") || return 1
    [[ -f "$source" && ! -L "$source" ]] || return 1
    [[ ! -L "$output" && ( ! -e "$output" || -f "$output" ) ]] || return 1
    awk -v target="$target" '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        BEGIN {
            target = tolower(target)
            start = tolower("# BEGIN CADDY-EMBY-MANAGED " target)
            finish = tolower("# END CADDY-EMBY-MANAGED " target)
            if (target !~ /:[0-9]+$/) {
                alternate_start = start ":443"
                alternate_finish = finish ":443"
            }
        }
        {
            line_lower = tolower(trim($0))
            if (inside) {
                if (line_lower == finish || (alternate_finish != "" && line_lower == alternate_finish)) inside = 0
                next
            }
            if (line_lower == start || (alternate_start != "" && line_lower == alternate_start)) {
                if (inside) exit 2
                found = 1
                inside = 1
                next
            }
            print
        }
        END {
            if (inside) exit 2
            exit(found ? 0 : 1)
        }
    ' "$source" > "$output"
}

create_backup() {
    local backup
    local backup_path
    local index
    local backups=()
    local sorted_backups=()

    [[ -f "$CADDYFILE" ]] || return 0
    backup=$(mktemp "$CADDY_DIR/.caddy-emby-manager-Caddyfile.bak.XXXXXX") || return 1
    if ! cp -p "$CADDYFILE" "$backup"; then
        rm -f "$backup"
        return 1
    fi

    backups=("$CADDY_DIR"/.caddy-emby-manager-Caddyfile.bak.*)
    for backup_path in "${backups[@]}"; do
        [[ -f "$backup_path" && ! -L "$backup_path" ]] || continue
        sorted_backups+=("$backup_path")
    done
    if ((${#sorted_backups[@]} > 0)); then
        mapfile -t sorted_backups < <(ls -1t "${sorted_backups[@]}" 2>/dev/null)
        if ((${#sorted_backups[@]} > 5)); then
            for ((index = 5; index < ${#sorted_backups[@]}; index++)); do
                rm -f "${sorted_backups[$index]}"
            done
            log "已清理旧 Caddyfile 备份，仅保留最近 5 份。" >&2
        fi
    fi
    printf '%s' "$backup"
}

validate_caddyfile_syntax() {
    local file="$1"

    [[ -f "$file" && ! -L "$file" ]] || {
        error "Caddyfile 不存在：$file"
        return 1
    }
    command -v caddy >/dev/null 2>&1 || {
        error "未找到 caddy 命令，请先安装 Caddy。"
        return 1
    }
    log "正在验证 Caddy 配置：$file"
    caddy validate --config "$file" --adapter caddyfile
}

validate_caddyfile() {
    local file="$1"

    [[ -f "$file" && ! -L "$file" ]] || {
        error "Caddyfile 不存在：$file"
        return 1
    }
    validate_caddyfile_syntax "$file"
}

log_caddy_state() {
    if ! command -v systemctl >/dev/null 2>&1; then
        warn "未找到 systemctl，无法读取 Caddy 服务状态。"
        return 1
    fi

    if systemctl is-active --quiet caddy; then
        log "当前 Caddy 状态：运行中。"
    elif systemctl is-failed --quiet caddy; then
        warn "当前 Caddy 状态：失败。"
    else
        log "当前 Caddy 状态：未运行。"
    fi
}

show_service_failure() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl status caddy --no-pager -l 2>&1 | tail -n 25
        log "详细日志：journalctl -u caddy -f"
    fi
}

reload_caddy_locked() {
    if [[ ! -f "$CADDYFILE" || ! -s "$CADDYFILE" ]]; then
        warn "Caddyfile 不存在或为空，请先添加域名配置。"
        return 1
    fi
    validate_caddyfile "$CADDYFILE" || {
        error "配置验证失败，未触碰正在运行的 Caddy。"
        return 1
    }
    command -v systemctl >/dev/null 2>&1 || {
        error "未找到 systemctl，无法管理 Caddy 服务。"
        return 1
    }

    log "Caddy reload 前的服务状态："
    log_caddy_state || true
    if systemctl is-active --quiet caddy; then
        log "正在平滑重载 Caddy；WebSocket 客户端可能短暂重连..."
       if ! systemctl reload caddy; then
           error "Caddy 重载失败，保留原服务状态。"
           show_service_failure
            log "Caddy reload 失败后的服务状态："
            log_caddy_state || true
           return 1
       fi
    else
        log "Caddy 当前未运行，正在启动..."
       if ! systemctl start caddy; then
           error "Caddy 启动失败。"
           show_service_failure
            log "Caddy 启动失败后的服务状态："
            log_caddy_state || true
           return 1
       fi
    fi

    sleep 1
    log "Caddy reload 后的服务状态："
    log_caddy_state || true
    if systemctl is-active --quiet caddy; then
        log "操作成功！Caddy 运行中。"
        return 0
    fi
    error "Caddy 操作后未处于运行状态。"
    show_service_failure
    return 1
}

reload_caddy() {
    with_global_lock with_config_lock reload_caddy_locked
}

restore_service_state() {
    local was_active="$1"

    command -v systemctl >/dev/null 2>&1 || return 1
    if [[ "$was_active" == true ]]; then
        if systemctl is-active --quiet caddy; then
            systemctl reload caddy >/dev/null 2>&1 || \
                systemctl restart caddy >/dev/null 2>&1 || return 1
        else
            systemctl start caddy >/dev/null 2>&1 || return 1
        fi
    else
        systemctl stop caddy >/dev/null 2>&1 || return 1
    fi
}

restore_caddyfile_from_backup() {
    local backup="$1"
    local restored
    local restore_failed=false

    [[ -f "$backup" && ( ! -e "$CADDYFILE" || -f "$CADDYFILE" ) && ! -L "$CADDYFILE" ]] || return 1
    if ! restored=$(mktemp "$CADDY_DIR/.Caddyfile.restore.XXXXXX"); then
        if [[ -e "$CADDYFILE" ]] && ! rm -f "$CADDYFILE"; then
            error "无法清除失败的新 Caddyfile：$CADDYFILE"
        fi
        return 1
    fi
    if ! cp -p "$backup" "$restored" || ! chmod 644 "$restored" || ! mv "$restored" "$CADDYFILE"; then
        restore_failed=true
    fi
    if [[ "$restore_failed" == true ]]; then
        if [[ -e "$restored" ]] && ! rm -f "$restored"; then
            error "无法清理回滚临时文件：$restored"
        fi
        if [[ -e "$CADDYFILE" ]] && ! rm -f "$CADDYFILE"; then
            error "无法清除失败的新 Caddyfile：$CADDYFILE"
        fi
        return 1
    fi
}

apply_candidate() {
    local candidate="$1"
    local stop_when_empty="${2:-false}"
    local backup=""
    local had_config=false
    local was_active=false

    [[ -f "$candidate" && ! -L "$candidate" ]] || {
        error "候选配置文件不存在。"
        return 1
    }
    [[ ! -L "$CADDYFILE" ]] || {
        rm -f "$candidate"
        error "正式 Caddyfile 是符号链接，为避免覆盖外部文件已取消。"
        return 1
    }
    if [[ -e "$CADDYFILE" && ! -f "$CADDYFILE" ]]; then
        rm -f "$candidate"
        error "正式 Caddyfile 不是普通文件，为避免替换目录或特殊文件已取消。"
        return 1
    fi

    validate_caddyfile "$candidate" || {
        rm -f "$candidate"
        error "候选配置验证失败，未修改正式 Caddyfile。"
        return 1
    }

    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet caddy; then
        was_active=true
    fi
    log "配置修改前的 Caddy 状态："
    log_caddy_state || true

    if [[ -f "$CADDYFILE" ]]; then
        had_config=true
        backup=$(create_backup) || {
            rm -f "$candidate"
            error "无法备份现有 Caddyfile，取消修改。"
            return 1
        }
    fi

    if ! chmod 644 "$candidate" || ! mv "$candidate" "$CADDYFILE"; then
        rm -f "$candidate"
        error "无法原子替换正式 Caddyfile。"
        return 1
    fi

    if [[ "$stop_when_empty" == true ]]; then
        log "配置中已没有站点，正在停止 Caddy..."
        if command -v systemctl >/dev/null 2>&1 && systemctl stop caddy && ! systemctl is-active --quiet caddy; then
            log "操作成功！Caddy 服务已停止。"
            log "配置修改后的 Caddy 状态："
            log_caddy_state || true
            return 0
        fi
        error "Caddy 停止失败，准备恢复原配置。"
    elif reload_caddy_locked; then
        log "配置已应用。"
        log "配置修改后的 Caddy 状态："
        log_caddy_state || true
        return 0
    else
        error "新配置未能让 Caddy 正常运行，准备恢复原配置。"
    fi

    if [[ "$had_config" == true && -f "$backup" ]]; then
        if ! restore_caddyfile_from_backup "$backup"; then
            error "恢复备份配置失败：$backup"
            error "已保持 Caddy 停止；请检查并人工恢复 $backup。"
            command -v systemctl >/dev/null 2>&1 && systemctl stop caddy >/dev/null 2>&1 || true
            return 1
        fi
        log "已恢复备份配置：$backup"
        if ! validate_caddyfile_syntax "$CADDYFILE" >/dev/null 2>&1; then
            error "已恢复的旧配置验证失败：$CADDYFILE"
            error "已保持 Caddy 停止，请人工检查旧配置。"
            command -v systemctl >/dev/null 2>&1 && systemctl stop caddy >/dev/null 2>&1 || true
            return 1
        fi
    else
        if ! rm -f "$CADDYFILE"; then
            error "无法删除失败的新 Caddyfile，已保持 Caddy 停止；请人工删除或恢复 $CADDYFILE。"
            command -v systemctl >/dev/null 2>&1 && systemctl stop caddy >/dev/null 2>&1 || true
            return 1
        fi
    fi

    if ! restore_service_state "$was_active"; then
        error "恢复原 Caddy 服务状态失败，请人工检查。"
        return 1
    fi
    log "回滚后的 Caddy 状态："
    log_caddy_state || true
    return 1
}

print_config_block() {
    local domain="$1"
    local backend="$2"

    cat <<EOF
# BEGIN CADDY-EMBY-MANAGED $domain
$domain {
    encode gzip

    reverse_proxy $backend {
        header_up X-Real-IP {remote_host}
    }
}
# END CADDY-EMBY-MANAGED $domain
EOF
}

configure_site_locked() {
    local domain
    local backend
    local mode="$3"
    local candidate
    local without_old
    local source_status
    local conflict_status

    domain=$(canonicalize_site_address "$1") || {
        error "站点地址格式无效，请输入类似 emby.example.com 或 emby.example.com:8443 的地址。"
        return 1
    }
    if [[ "$domain" == \*.* ]]; then
        error "暂不支持通配符站点。通配符证书需要额外的 DNS Challenge 配置。"
        return 1
    fi
    backend=$(trim_whitespace "$2")
    [[ -n "$backend" ]] || backend="127.0.0.1:8096"

    [[ "$mode" == new || "$mode" == append ]] || {
        error "未知配置模式：$mode"
        return 1
    }
    validate_backend "$backend" || {
        error "后端地址格式无效。支持：127.0.0.1:8096、https://remote.example.com:443、[::1]:8096。"
        return 1
    }
    backend="$BACKEND_CANONICAL"
    command -v caddy >/dev/null 2>&1 || {
        error "未找到 Caddy，请先执行安装选项或 --install。"
        return 1
    }
    mkdir -p "$CADDY_DIR" || {
        error "无法创建 $CADDY_DIR。"
        return 1
    }

    if [[ "$mode" == append && -f "$CADDYFILE" && -s "$CADDYFILE" ]]; then
        validate_caddyfile "$CADDYFILE" || {
            error "现有 Caddyfile 无法验证，拒绝在其上追加或删除站点。"
            return 1
        }
    fi
    check_https_backend "$backend" || return 1

    candidate=$(mktemp "$CADDY_DIR/.Caddyfile.candidate.XXXXXX") || {
        error "无法创建候选配置文件。"
        return 1
    }

    if [[ "$mode" == append && -f "$CADDYFILE" ]]; then
        if [[ -s "$CADDYFILE" ]]; then
            if ! cp "$CADDYFILE" "$candidate"; then
                rm -f "$candidate"
                error "无法复制现有 Caddyfile。"
                return 1
            fi
        fi

        site_block_exists_in_file "$domain" "$candidate"
        source_status=$?
        if ((source_status == 2)); then
            rm -f "$candidate"
            error "域名 $domain 的配置块不完整，拒绝修改。"
            return 1
        elif ((source_status == 0)); then
            without_old=$(mktemp "$CADDY_DIR/.Caddyfile.without.XXXXXX") || {
                rm -f "$candidate"
                error "无法创建临时配置文件。"
                return 1
            }
            if ! remove_site_block_from_file "$domain" "$candidate" "$without_old"; then
                rm -f "$candidate" "$without_old"
                error "无法安全替换域名 $domain 的旧配置块。"
                return 1
            fi
            if ! mv "$without_old" "$candidate"; then
                rm -f "$candidate" "$without_old"
                error "无法替换域名 $domain 的旧配置块。"
                return 1
            fi
        elif ((source_status != 1)); then
            rm -f "$candidate"
            error "无法判断域名 $domain 的配置块状态。"
            return 1
        else
            site_conflicts_with_existing_config "$domain" "$candidate"
            conflict_status=$?
            if ((conflict_status == 0)); then
                rm -f "$candidate"
                error "现有 Caddyfile 已包含域名 $domain 的非托管路由；为避免重复匹配，拒绝追加。"
                return 1
            elif ((conflict_status == 2)); then
                rm -f "$candidate"
                error "无法检测域名 $domain 是否与现有 Caddy 配置冲突。"
                return 1
            fi
        fi

        if [[ -s "$candidate" ]]; then
            printf '\n' >> "$candidate"
        fi
        print_config_block "$domain" "$backend" >> "$candidate"
    else
        print_config_block "$domain" "$backend" > "$candidate"
    fi

    if [[ "$mode" == append ]]; then
        log "正在准备配置（追加模式）..."
    else
        log "正在准备配置（覆盖模式）..."
    fi
    apply_candidate "$candidate"
}

configure_site() {
    with_global_lock with_config_lock configure_site_locked "$@"
}

configure_caddy() {
    local config_mode="new"
    local domain
    local backend

    echo -e "------------------------------------------------"
    echo -e "${SKYBLUE}Caddy 反代配置（支持多站点）${PLAIN}"
    echo -e "------------------------------------------------"

    if [[ -f "$CADDYFILE" && -s "$CADDYFILE" ]]; then
        echo -e "检测到已有配置文件。"
        echo -e " ${GREEN}1.${PLAIN} 覆盖（清空旧配置，仅保留这一个站点）"
        echo -e " ${GREEN}2.${PLAIN} 追加（保留旧配置并添加或更新站点）"
        if ! read -r -p "请选择模式 [1-2]: " config_mode < /dev/tty; then
            error "无法读取终端输入。"
            return 1
        fi
        if [[ "$config_mode" == 2 ]]; then
            config_mode="append"
        elif [[ "$config_mode" == 1 ]]; then
            config_mode="new"
        else
            warn "无效选择，已取消本次配置，避免误覆盖。"
            return 1
        fi
    fi

    if ! read -r -p "请输入站点地址（例如 emby.example.com 或 emby.example.com:8443）: " domain < /dev/tty || \
        ! read -r -p "请输入后端地址（默认 127.0.0.1:8096）: " backend < /dev/tty; then
        error "无法读取终端输入。"
        return 1
    fi
    backend=$(trim_whitespace "$backend")
    [[ -n "$backend" ]] || backend="127.0.0.1:8096"
    configure_site "$domain" "$backend" "$config_mode"
}

delete_site_locked() {
    local domain
    local candidate
    local without_old
    local remaining=0
    local source_status
    local after_content

    domain=$(canonicalize_site_address "$1") || {
        error "站点地址格式无效。"
        return 1
    }
    [[ -f "$CADDYFILE" ]] || {
        error "未找到配置文件：$CADDYFILE"
        return 1
    }
    validate_caddyfile "$CADDYFILE" || {
        error "现有 Caddyfile 无法验证，拒绝删除站点。"
        return 1
    }

    site_block_exists_in_file "$domain" "$CADDYFILE"
    source_status=$?
    if ((source_status == 2)); then
        error "域名 $domain 的配置块不完整，拒绝删除。"
        return 1
    elif ((source_status != 0)); then
        error "未找到域名 $domain 的配置块。"
        return 1
    fi

    if ! confirm_action "确定要删除域名 $domain 吗?"; then
        log "已取消删除操作。"
        return 1
    fi

    candidate=$(mktemp "$CADDY_DIR/.Caddyfile.delete.XXXXXX") || {
        error "无法创建候选配置文件。"
        return 1
    }
    without_old=$(mktemp "$CADDY_DIR/.Caddyfile.without.XXXXXX") || {
        rm -f "$candidate"
        error "无法创建临时配置文件。"
        return 1
    }

    if ! remove_site_block_from_file "$domain" "$CADDYFILE" "$without_old"; then
        rm -f "$candidate" "$without_old"
        error "无法安全删除域名配置块。"
        return 1
    fi
    if ! mv "$without_old" "$candidate"; then
        rm -f "$candidate" "$without_old"
        error "无法生成删除后的 Caddyfile。"
        return 1
    fi

    while IFS= read -r domain; do
        [[ -n "$domain" ]] && ((remaining += 1))
    done < <(list_configured_domains "$candidate")

    after_content=$(grep -q '[^[:space:]]' "$candidate" 2>/dev/null; echo $?)
    if ((remaining == 0 && after_content != 0)); then
        if apply_candidate "$candidate" true; then
            log "域名配置删除完成。"
            return 0
        fi
    else
        if apply_candidate "$candidate"; then
            log "域名配置删除完成。"
            return 0
        fi
    fi
    return 1
}

delete_site() {
    with_global_lock with_config_lock delete_site_locked "$@"
}

delete_config() {
    local domains=()
    local domain
    local selected
    local index

    echo -e "------------------------------------------------"
    echo -e "${SKYBLUE}删除指定站点配置${PLAIN}"
    echo -e "------------------------------------------------"

    while IFS= read -r domain; do
        [[ -n "$domain" ]] && domains+=("$domain")
    done < <(list_configured_domains "$CADDYFILE")

    if ((${#domains[@]} == 0)); then
        warn "配置文件中未找到可管理的站点块。"
        return 1
    fi

    echo -e "当前已配置的站点地址："
    for index in "${!domains[@]}"; do
        echo -e " ${GREEN}$((index + 1)).${PLAIN} ${domains[$index]}"
    done
    echo -e "------------------------------------------------"
    if ! read -r -p "请输入要删除的站点编号或完整地址: " selected < /dev/tty; then
        error "无法读取终端输入。"
        return 1
    fi
    selected=$(trim_whitespace "$selected")
    [[ -n "$selected" ]] || return 1

    if [[ "$selected" =~ ^[0-9]+$ ]]; then
        index=$(parse_menu_index "$selected") || {
            error "无效的编号。"
            return 1
        }
        if ((index >= 0 && index < ${#domains[@]})); then
            selected="${domains[$index]}"
        else
            error "无效的编号。"
            return 1
        fi
    fi
    delete_site "$selected"
}

parse_menu_index() {
    local value="$1"

    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    while [[ "$value" == 0* && "$value" != 0 ]]; do
        value="${value#0}"
    done
    [[ "$value" != 0 && ${#value} -le 9 ]] || return 1
    printf '%s' "$((value - 1))"
}

list_tcp_listeners() {
    local include_processes="${1:-false}"

    if command -v ss >/dev/null 2>&1; then
        if [[ "$include_processes" == true ]]; then
            ss -H -ltnp 2>/dev/null
        else
            ss -H -ltn 2>/dev/null
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if [[ "$include_processes" == true ]]; then
            netstat -ltnp 2>/dev/null
        else
            netstat -ltn 2>/dev/null
        fi
    else
        error "未找到 ss 或 netstat。"
        return 1
    fi
}

filter_web_ports() {
    awk '
        function port(address) {
            sub(/^.*:/, "", address)
            return address
        }
        {
            if ($1 != "LISTEN" && $6 != "LISTEN") next
            local_port = port($4)
            if (local_port == "80" || local_port == "443") print
        }
    '
}

check_port() {
    local listeners=""

    echo -e "------------------------------------------------"
    echo -e "${SKYBLUE}正在查询 80 和 443 端口监听情况...${PLAIN}"
    echo -e "------------------------------------------------"
    if ! listeners=$(list_tcp_listeners true); then
        return 1
    fi
    listeners=$(printf '%s\n' "$listeners" | filter_web_ports)

    if [[ -n "$listeners" ]]; then
        printf '%s\n' "$listeners"
    else
        log "80/443 当前没有检测到监听进程。"
    fi
    echo -e "------------------------------------------------"
    echo -e "显示 caddy 属于正常现象；其他服务请确认后再处理。"
    return 0
}

list_managed_listen_ports() {
    local site
    local port

    printf '80\n'
    while IFS= read -r site; do
        if [[ "$site" =~ :([0-9]+)$ ]]; then
            port="${BASH_REMATCH[1]}"
        else
            port=443
        fi
        printf '%d\n' "$((10#$port))"
    done < <(list_configured_domains "$CADDYFILE")
}

tcp_port_is_listening() {
    local expected="$1"
    local listeners

    listeners=$(list_tcp_listeners false) || return 1
    printf '%s\n' "$listeners" | awk -v expected="$expected" '
        function port(address) {
            sub(/^.*:/, "", address)
            return address
        }
        ($1 == "LISTEN" || $6 == "LISTEN") && port($4) == expected { found=1 }
        END { exit(found ? 0 : 1) }
    '
}

systemd_unit_loaded() {
    local unit="$1"
    local load_state

    command -v systemctl >/dev/null 2>&1 || return 1
    load_state=$(systemctl show "$unit" -p LoadState --value 2>/dev/null) || return 1
    [[ "$load_state" == loaded ]]
}

kill_port() {
    local service
    local listeners
    local result=0

    echo -e "${RED}此操作只会停止已确认存在且正在运行的 nginx/apache2/httpd 服务，不会强杀未知进程。${PLAIN}"
    if ! confirm_action "确认继续处理常见 Web 服务吗?"; then
        log "已取消端口处理。"
        return 1
    fi
    for service in nginx apache2 httpd; do
        if systemd_unit_loaded "$service.service" && systemctl is-active --quiet "$service"; then
            log "正在停止 $service.service ..."
            systemctl stop "$service" || {
                warn "$service.service 停止失败。"
                result=1
            }
        fi
    done

    sleep 1
    check_port || result=1
    if ! listeners=$(list_tcp_listeners false); then
        result=1
    else
        listeners=$(printf '%s\n' "$listeners" | filter_web_ports)
    fi
    if [[ -n "$listeners" ]]; then
        warn "仍有进程监听 80/443；为避免误杀，脚本不会执行 kill -KILL。请根据选项 7 的 PID 手动处理。"
        result=1
    fi
    return "$result"
}

stop_caddy() {
    with_global_lock with_config_lock stop_caddy_locked
}

stop_caddy_locked() {
    command -v systemctl >/dev/null 2>&1 || {
        error "未找到 systemctl。"
        return 1
    }
    if systemctl is-active --quiet caddy; then
        if systemctl stop caddy && ! systemctl is-active --quiet caddy; then
            log "Caddy 服务已停止。"
            return 0
        fi
        error "Caddy 服务停止失败。"
        return 1
    fi
    log "Caddy 服务当前未运行。"
    return 0
}

show_config() {
    if [[ -f "$CADDYFILE" ]]; then
        echo -e "${SKYBLUE}当前 Caddyfile：${PLAIN}"
        sed -n '1,400p' "$CADDYFILE"
    else
        warn "未找到配置文件：$CADDYFILE"
    fi
}

check_status() {
    local result=0
    local port
    local expected_ports=()

    check_port || result=1
    if [[ -f "$CADDYFILE" && -s "$CADDYFILE" ]]; then
        validate_caddyfile "$CADDYFILE" || result=1
        mapfile -t expected_ports < <(list_managed_listen_ports | sort -nu)
        for port in "${expected_ports[@]}"; do
            if ! tcp_port_is_listening "$port"; then
                warn "未检测到托管站点所需的 TCP $port 端口监听。"
                result=1
            fi
        done
    else
        warn "Caddyfile 不存在或为空。"
        result=1
    fi
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet caddy; then
            log "Caddy 服务状态：运行中。"
        else
            warn "Caddy 服务状态：未运行。"
            result=1
        fi
    else
        warn "未找到 systemctl，跳过服务状态检查。"
        result=1
    fi
    return "$result"
}

remove_shortcut_and_alias() {
    local alias_line="alias c='bash $SCRIPT_DEST'"
    local grep_status
    local temporary
    local result=0

    if is_managed_shortcut_file "$SHORTCUT"; then
        if rm -f "$SHORTCUT"; then
            log "已删除快捷命令 $SHORTCUT。"
        else
            warn "无法删除快捷命令 $SHORTCUT。"
            result=1
        fi
    fi

    if [[ -f "$ALIAS_MARKER" && -L /root/.bashrc ]]; then
        warn "/root/.bashrc 是符号链接，无法安全删除管理器 alias；保留状态记录。"
        return 1
    fi
    if [[ -f "$ALIAS_MARKER" && -f /root/.bashrc && ! -L /root/.bashrc ]] && grep -Fqx "$alias_line" /root/.bashrc 2>/dev/null; then
        temporary=$(mktemp "/root/.bashrc.caddy-emby.XXXXXX") || return 1
        if ! grep -Fvx "$alias_line" /root/.bashrc > "$temporary"; then
            grep_status=$?
            if ((grep_status > 1)); then
                rm -f "$temporary"
                warn "读取 /root/.bashrc 失败，未删除 alias。"
                return 1
            fi
        fi
        if ! chmod --reference=/root/.bashrc "$temporary" 2>/dev/null || ! mv "$temporary" /root/.bashrc; then
            rm -f "$temporary"
            warn "无法原子更新 /root/.bashrc。"
            return 1
        fi
        log "已从 /root/.bashrc 删除 c alias。"
    fi
    return "$result"
}

is_managed_script_file() {
    local file="$1"

    [[ -f "$file" && ! -L "$file" ]] || return 1
    [[ "$(sed -n '1p' "$file" 2>/dev/null)" == '#!/usr/bin/env bash' ]] || return 1
    grep -Fqx '#  CADDY-EMBY-MANAGER-MANAGED-SCRIPT' "$file" 2>/dev/null
}

is_managed_shortcut_file() {
    local file="$1"
    local line_count
    local expected_exec="exec bash \"$SCRIPT_DEST\" \"\$@\""

    [[ -f "$file" && ! -L "$file" ]] || return 1
    line_count=$(wc -l < "$file" 2>/dev/null) || return 1
    [[ "$line_count" =~ ^[[:space:]]*2[[:space:]]*$ ]] || return 1
    grep -Fqx '#!/usr/bin/env bash' "$file" 2>/dev/null &&
        grep -Fqx "$expected_exec" "$file" 2>/dev/null
}

is_fully_managed_caddyfile() {
    local file="$1"

    [[ -f "$file" && ! -L "$file" ]] || return 1
    awk '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        BEGIN {
            inside = 0
            found = 0
            invalid = 0
            marker_name = ""
        }
        {
            line = trim($0)
            if (line == "") next
            if (line ~ /^# BEGIN CADDY-EMBY-MANAGED [^[:space:]]+$/) {
                if (inside) invalid = 1
                inside = 1
                found = 1
                marker_name = line
                sub(/^# BEGIN CADDY-EMBY-MANAGED /, "", marker_name)
                next
            }
            if (line ~ /^# END CADDY-EMBY-MANAGED [^[:space:]]+$/) {
                end_name = line
                sub(/^# END CADDY-EMBY-MANAGED /, "", end_name)
                if (!inside || end_name != marker_name) invalid = 1
                inside = 0
                marker_name = ""
                next
            }
            if (!inside) invalid = 1
        }
        END { exit(found && !invalid && !inside ? 0 : 1) }
    ' "$file"
}

is_initial_managed_caddyfile() {
    local file="$1"

    [[ -f "$file" && ! -L "$file" ]] || return 1
    [[ "$(wc -l < "$file" 2>/dev/null)" =~ ^[[:space:]]*1[[:space:]]*$ ]] || return 1
    grep -Fqx '# Caddy Emby manager: add a site with --configure before starting Caddy.' "$file" 2>/dev/null
}

cleanup_caddy_files() {
    local path
    local result=0

    if [[ -L "$CADDY_DIR" ]]; then
        warn "Caddy 配置目录是符号链接，保留：$CADDY_DIR"
        return 1
    fi
    if [[ -e "$CADDY_DIR" && ! -d "$CADDY_DIR" ]]; then
        warn "Caddy 配置路径不是目录，保留：$CADDY_DIR"
        return 1
    fi
    [[ -d "$CADDY_DIR" ]] || return 0
    if is_fully_managed_caddyfile "$CADDYFILE" || is_initial_managed_caddyfile "$CADDYFILE"; then
        rm -f "$CADDYFILE" || result=1
    elif [[ -e "$CADDYFILE" ]]; then
        warn "Caddyfile 含有未管理内容，保留：$CADDYFILE"
        result=1
    fi
    for path in "$CADDY_DIR"/.caddy-emby-manager-Caddyfile.bak.* "$CADDY_DIR"/.Caddyfile.candidate.* \
        "$CADDY_DIR"/.Caddyfile.without.* "$CADDY_DIR"/.Caddyfile.delete.* \
        "$CADDY_DIR"/.Caddyfile.restore.* "$CADDY_DIR"/.Caddyfile.initial.*; do
        [[ -f "$path" && ! -L "$path" ]] || continue
        rm -f "$path" || result=1
    done
    if find "$CADDY_DIR" -mindepth 1 -maxdepth 1 ! -name .caddy-emby-manager.lock -print -quit 2>/dev/null | grep -q .; then
        warn "Caddy 配置目录中存在未管理文件，保留目录：$CADDY_DIR"
        result=1
    fi
    return "$result"
}

cleanup_caddy_data() {
    if [[ -L "$CADDY_DATA_DIR" ]]; then
        warn "Caddy 数据目录是符号链接，保留：$CADDY_DATA_DIR"
        return 1
    fi
    if [[ -e "$CADDY_DATA_DIR" && ! -d "$CADDY_DATA_DIR" ]]; then
        warn "Caddy 数据路径不是目录，保留：$CADDY_DATA_DIR"
        return 1
    fi
    [[ -d "$CADDY_DATA_DIR" ]] || return 0
    warn "Caddy 数据目录归属无法由脚本确认，卸载时保留：$CADDY_DATA_DIR"
    return 0
}

cleanup_manager_state() {
    local path
    local result=0

    if [[ -L "$STATE_DIR" ]]; then
        warn "状态目录是符号链接，保留：$STATE_DIR"
        return 1
    fi
    if [[ -e "$STATE_DIR" && ! -d "$STATE_DIR" ]]; then
        warn "状态路径不是目录，保留：$STATE_DIR"
        return 1
    fi
    [[ -d "$STATE_DIR" ]] || return 0
    for path in "$ALIAS_MARKER" "$APT_SOURCE_BACKUP" "$APT_KEYRING_BACKUP" \
        "$APT_SOURCE_WAS_PRESENT" "$APT_KEYRING_WAS_PRESENT" \
        "$APT_SOURCE_INSTALLED_HASH" "$APT_KEYRING_INSTALLED_HASH" \
        "$APT_TRANSACTION_ACTIVE" "$CADDY_PACKAGE_MARKER" \
        "$CADDY_SERVICE_WAS_MASKED" "$RPM_COPR_MARKER"; do
        [[ -e "$path" ]] || continue
        if [[ -L "$path" || ! -f "$path" ]]; then
            warn "状态目录中存在无法确认归属的条目，保留：$path"
            result=1
        elif ! rm -f "$path"; then
            warn "无法删除管理器状态文件，保留：$path"
            result=1
        fi
    done

    if find "$STATE_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
        warn "状态目录中存在未管理文件，保留目录：$STATE_DIR"
        result=1
    elif ! rmdir "$STATE_DIR" 2>/dev/null; then
        warn "无法删除空状态目录：$STATE_DIR"
        result=1
    fi
    return "$result"
}

archive_caddy_data() {
    local archive_dir="/var/backups/caddy-emby-manager"
    local archive
    local archive_paths=()

    if [[ -L "$archive_dir" ]]; then
        error "卸载归档目录是符号链接，拒绝写入外部路径：$archive_dir"
        return 1
    fi
    if [[ -e "$archive_dir" && ! -d "$archive_dir" ]]; then
        error "卸载归档路径不是目录：$archive_dir"
        return 1
    fi
    [[ ! -L /etc/caddy && ! -L /var/lib/caddy ]] || {
        error "Caddy 配置或数据路径是符号链接，拒绝归档以避免跟随外部路径。"
        return 1
    }
    [[ ! -e /etc/caddy || -d /etc/caddy ]] || {
        error "Caddy 配置路径不是目录，无法归档。"
        return 1
    }
    [[ ! -e /var/lib/caddy || -d /var/lib/caddy ]] || {
        error "Caddy 数据路径不是目录，无法归档。"
        return 1
    }
    [[ -d /etc/caddy ]] && archive_paths+=(etc/caddy)
    [[ -d /var/lib/caddy ]] && archive_paths+=(var/lib/caddy)
    ((${#archive_paths[@]} > 0)) || return 0
    command -v tar >/dev/null 2>&1 || {
        error "未找到 tar，无法在卸载前归档 Caddy 配置和证书。"
        return 1
    }
    mkdir -p "$archive_dir" || return 1
    chmod 700 "$archive_dir" 2>/dev/null || true
    archive=$(mktemp "$archive_dir/caddy-emby-$(date +%F_%H%M%S).XXXXXX.tar.gz") || return 1
    if ! tar -czf "$archive" -C / "${archive_paths[@]}"; then
        rm -f "$archive"
        error "卸载前归档 Caddy 数据失败。"
        return 1
    fi
    chmod 600 "$archive" 2>/dev/null || true
    log "已归档 Caddy 配置和证书：$archive"
}

cleanup_managed_apt_asset() {
    local path="$1"
    local backup="$2"
    local marker="$3"
    local hash_file="$4"
    local label="$5"
    local expected
    local actual
    local restored

    state_entry_is_safe "$marker" || {
        warn "$label 安装标记路径不安全，保留当前文件：$path"
        return 1
    }
    state_entry_is_safe "$hash_file" || {
        warn "$label 校验值路径不安全，保留当前文件：$path"
        return 1
    }
    [[ -f "$marker" && -f "$hash_file" ]] || {
        warn "没有 $label 的安装记录，保留 $path。"
        return 1
    }
    [[ ! -L "$path" ]] || {
        warn "$label 是符号链接，保留：$path"
        return 1
    }
    expected=$(<"$hash_file")
    case "$(<"$marker")" in
        present)
            if [[ -e "$path" ]]; then
                actual=$(sha256sum "$path" 2>/dev/null | awk '{print $1}')
                if [[ ! -f "$path" || "$actual" != "$expected" ]]; then
                    warn "$label 已被修改，保留当前文件：$path"
                    return 1
                fi
            fi
            [[ -f "$backup" ]] || {
                warn "$label 原文件备份不存在，保留当前文件：$path"
                return 1
            }
            [[ ! -L "$backup" ]] || {
                warn "$label 原文件备份是符号链接，保留当前文件：$path"
                return 1
            }
            restored=$(mktemp "$(dirname "$path")/.caddy-emby-restore.XXXXXX") || return 1
            if ! cp -p "$backup" "$restored" || ! mv "$restored" "$path"; then
                rm -f "$restored"
                return 1
            fi
            log "已恢复卸载前的 $label。"
            ;;
        absent)
            if [[ -e "$path" ]]; then
                actual=$(sha256sum "$path" 2>/dev/null | awk '{print $1}')
                if [[ ! -f "$path" || "$actual" != "$expected" ]]; then
                    warn "$label 已被修改，保留当前文件：$path"
                    return 1
                fi
                rm -f "$path" || return 1
                log "已删除本次安装创建的 $label。"
            else
                log "本次安装创建的 $label 已不存在。"
            fi
            ;;
        *)
            warn "$label 安装记录无效，保留当前文件。"
            return 1
            ;;
    esac
}

uninstall_caddy_locked() {
    local package_kind="none"
    local package_removed=false
    local cleanup_result=0
    local managed_package_kind=""

    echo -e "${RED}卸载会先停止 Caddy，再归档 /etc/caddy 和 /var/lib/caddy；只移除本脚本安装的包。${PLAIN}"
    if ! confirm_action "确认完整卸载吗?"; then
        log "已取消卸载。"
        return 1
    fi
    if [[ -f "$CADDY_PACKAGE_MARKER" && ! -L "$CADDY_PACKAGE_MARKER" ]]; then
        managed_package_kind=$(<"$CADDY_PACKAGE_MARKER")
    fi
    if command -v dpkg-query >/dev/null 2>&1 && package_installed_debian caddy; then
        if [[ "$managed_package_kind" == debian ]]; then
            package_kind="debian"
        else
            warn "Caddy apt 包不是由本脚本安装，卸载时保留该包。"
        fi
    elif package_installed_rpm caddy; then
        if [[ "$managed_package_kind" == rpm ]]; then
            package_kind="rpm"
        else
            warn "Caddy rpm 包不是由本脚本安装，卸载时保留该包。"
        fi
    elif command -v caddy >/dev/null 2>&1; then
        warn "检测到手动安装的 caddy，卸载时保留该二进制。"
    fi
    if [[ "$package_kind" == debian ]] && ! command -v apt-get >/dev/null 2>&1; then
        error "未找到 apt-get，无法卸载 Caddy apt 包。"
        return 1
    fi
    if [[ "$package_kind" == rpm ]] && ! command -v dnf >/dev/null 2>&1 && ! command -v yum >/dev/null 2>&1; then
        error "未找到 dnf 或 yum，无法卸载 Caddy rpm 包。"
        return 1
    fi
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet caddy; then
        if ! systemctl stop caddy || systemctl is-active --quiet caddy; then
            error "Caddy 停止失败，已取消卸载。"
            return 1
        fi
    fi
    archive_caddy_data || return 1

    if [[ "$package_kind" == debian ]]; then
        if ! apt-get remove -y caddy; then
            error "Caddy apt 包卸载失败，保留配置和快捷命令。"
            return 1
        fi
        package_removed=true
    elif [[ "$package_kind" == rpm ]]; then
        if command -v dnf >/dev/null 2>&1; then
            dnf remove -y caddy || {
                error "Caddy dnf 包卸载失败，保留配置和快捷命令。"
                return 1
            }
        elif command -v yum >/dev/null 2>&1; then
            yum remove -y caddy || {
                error "Caddy yum 包卸载失败，保留配置和快捷命令。"
                return 1
            }
        else
            error "未找到 dnf 或 yum，无法卸载 Caddy rpm 包。"
            return 1
        fi
        package_removed=true
    else
        warn "未检测到由本脚本安装的 Caddy 包，仅继续清理脚本创建的配置。"
        package_removed=true
    fi

    if [[ "$package_removed" == true ]]; then
        if [[ -e "$APT_SOURCE_WAS_PRESENT" || -e "$APT_SOURCE_INSTALLED_HASH" || \
            -e "$APT_SOURCE_BACKUP" || -e "$APT_TRANSACTION_ACTIVE" ]]; then
            if [[ -f "$APT_SOURCE_WAS_PRESENT" && -f "$APT_SOURCE_INSTALLED_HASH" ]]; then
                cleanup_managed_apt_asset "$APT_SOURCE" "$APT_SOURCE_BACKUP" \
                    "$APT_SOURCE_WAS_PRESENT" "$APT_SOURCE_INSTALLED_HASH" "apt 源" || cleanup_result=1
            else
                warn "apt 源安装记录不完整，保留相关文件和恢复状态：$APT_SOURCE"
                cleanup_result=1
            fi
        fi
        if [[ -e "$APT_KEYRING_WAS_PRESENT" || -e "$APT_KEYRING_INSTALLED_HASH" || \
            -e "$APT_KEYRING_BACKUP" || -e "$APT_TRANSACTION_ACTIVE" ]]; then
            if [[ -f "$APT_KEYRING_WAS_PRESENT" && -f "$APT_KEYRING_INSTALLED_HASH" ]]; then
                cleanup_managed_apt_asset "$APT_KEYRING" "$APT_KEYRING_BACKUP" \
                    "$APT_KEYRING_WAS_PRESENT" "$APT_KEYRING_INSTALLED_HASH" "keyring" || cleanup_result=1
            else
                warn "Caddy keyring 安装记录不完整，保留相关文件和恢复状态：$APT_KEYRING"
                cleanup_result=1
            fi
        fi
        if ! disable_managed_caddy_copr; then
            warn "无法禁用本脚本启用的 Caddy COPR 源。"
            cleanup_result=1
        fi
        if ! restore_caddy_service_mask; then
            warn "无法恢复 caddy.service 原有的 masked 状态。"
            cleanup_result=1
        fi
    fi

    cleanup_caddy_files || cleanup_result=1
    cleanup_caddy_data || cleanup_result=1
    if [[ -e "$SCRIPT_DEST" ]]; then
        if is_managed_script_file "$SCRIPT_DEST"; then
            if ! rm -f "$SCRIPT_DEST"; then
                error "无法删除脚本 $SCRIPT_DEST。"
                cleanup_result=1
            fi
        else
            warn "$SCRIPT_DEST 不是本脚本创建的文件，保留它。"
        fi
    fi
    if is_managed_shortcut_file "$SHORTCUT"; then
        if rm -f "$SHORTCUT"; then
            log "已删除快捷命令 $SHORTCUT。"
        else
            error "无法删除快捷命令 $SHORTCUT。"
            cleanup_result=1
        fi
    fi
    remove_shortcut_and_alias || cleanup_result=1
    if ((cleanup_result == 0)); then
        if ! cleanup_manager_state; then
            warn "Caddy 已移除，但管理器状态未能完整清理，保留 $STATE_DIR 供人工检查。"
            return 1
        fi
        log "Caddy、配置和快捷命令清理完成；卸载归档已保留。"
        return 0
    fi
    warn "Caddy 已移除，但部分清理未完成；相关状态和文件已保留，请按提示人工处理。"
    return 1
}

uninstall_caddy() {
    # Keep the lock pathname stable. Removing it after releasing flock can
    # race with another process that has already opened and locked the file.
    with_global_lock with_config_lock uninstall_caddy_locked
}

run_cli() {
    local command="${1:-}"
    local domain
    local backend
    local mode="auto"
    local mode_set=false

    case "$command" in
        --install)
            [[ $# -eq 1 ]] || { error "--install 不接受额外参数。"; return 1; }
            if install_environment; then
                register_shortcut || true
            else
                return 1
            fi
            ;;
        --check)
            [[ $# -eq 1 ]] || { error "--check 不接受额外参数。"; return 1; }
            check_status
            ;;
        --configure|--config|--add)
            [[ $# -ge 2 ]] || { error "请提供 DOMAIN。"; usage; return 1; }
            domain="$2"
            shift 2
            backend="127.0.0.1:8096"
            if [[ $# -gt 0 && "$1" != --* ]]; then
                backend="$1"
                shift
            fi
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --append|--overwrite|--new)
                        if [[ "$mode_set" == true ]]; then
                            error "--append、--overwrite、--new 只能指定一个。"
                            return 1
                        fi
                        mode_set=true
                        if [[ "$1" == --append ]]; then mode="append"; else mode="new"; fi
                        ;;
                    --skip-upstream-check)
                        SKIP_UPSTREAM_CHECK=true
                        ;;
                    *)
                        error "未知参数：$1"
                        usage
                        return 1
                        ;;
                esac
                shift
            done

            if [[ "$mode" == auto ]]; then
                if [[ -f "$CADDYFILE" && -s "$CADDYFILE" ]]; then
                    error "已有 Caddyfile，请明确指定 --append 或 --overwrite。"
                    return 1
                fi
                mode="new"
            fi
            INTERACTIVE_MODE=false
            configure_site "$domain" "$backend" "$mode"
            ;;
        --delete)
            [[ $# -eq 3 && "$3" == --yes ]] || {
                error "自动化删除必须使用：--delete DOMAIN --yes"
                return 1
            }
            FORCE_YES=true
            INTERACTIVE_MODE=false
            delete_site "$2"
            ;;
        --reload)
            [[ $# -eq 1 ]] || { error "--reload 不接受额外参数。"; return 1; }
            reload_caddy
            ;;
        --stop)
            [[ $# -eq 1 ]] || { error "--stop 不接受额外参数。"; return 1; }
            stop_caddy
            ;;
        --uninstall)
            [[ $# -eq 2 && "$2" == --yes ]] || {
                error "自动化卸载必须使用：--uninstall --yes"
                return 1
            }
            FORCE_YES=true
            INTERACTIVE_MODE=false
            uninstall_caddy
            ;;
        --version)
            [[ $# -eq 1 ]] || { error "--version 不接受额外参数。"; return 1; }
            echo "V${SCRIPT_VERSION}"
            ;;
        -h|--help)
            usage
            ;;
        *)
            error "未知命令：$command"
            usage
            return 1
            ;;
    esac
}

show_menu() {
    local number
    local action_result

    command -v clear >/dev/null 2>&1 && clear
    echo -e "##########################################################"
    echo -e "#    Caddy + Emby 多站点管理脚本 (V${SCRIPT_VERSION})    #"
    echo -e "##########################################################"
    echo -e " ${GREEN}1.${PLAIN} 安装环境 & Caddy"
    echo -e " ${GREEN}2.${PLAIN} 添加/覆盖反代配置（支持多站）"
    echo -e " ${GREEN}3.${PLAIN} 删除指定站点配置"
    echo -e " ${GREEN}4.${PLAIN} 查看 Caddy 配置文件"
    echo -e "-------------------------------------------------"
    echo -e " ${GREEN}5.${PLAIN} 停止 Caddy"
    echo -e " ${GREEN}6.${PLAIN} 校验并重载/启动 Caddy"
    echo -e " ${GREEN}7.${PLAIN} 查询 80/443 端口占用"
    echo -e " ${RED}8.${PLAIN} 确认后停止常见 Web 服务"
    echo -e " ${RED}9.${PLAIN} 归档并完整卸载 Caddy"
    echo -e "-------------------------------------------------"
    echo -e " ${GREEN}0.${PLAIN} 退出脚本"
    echo -e ""
    if ! read -r -p "请输入数字 [0-9]: " number < /dev/tty; then
        error "无法读取终端输入。"
        return 1
    fi
    [[ "$number" =~ ^[0-9]$ ]] || {
        error "请输入有效的数字 (0-9)"
        return 0
    }

    case "$number" in
        1) install_environment; action_result=$? ;;
        2) install_environment && configure_caddy; action_result=$? ;;
        3) delete_config; action_result=$? ;;
        4) show_config; action_result=$? ;;
        5) stop_caddy; action_result=$? ;;
        6) reload_caddy; action_result=$? ;;
        7) check_port; action_result=$? ;;
        8) kill_port; action_result=$? ;;
        9) uninstall_caddy; action_result=$? ;;
        0) exit 0 ;;
    esac
    ((action_result != 0)) && warn "本次操作未成功完成。"
    return 0
}

main() {
    trap cleanup_runtime_files EXIT
    trap 'handle_termination 129' HUP
    trap 'handle_termination 130' INT
    trap 'handle_termination 143' TERM

    if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
        usage
        return 0
    fi
    if [[ "${1:-}" == --version ]]; then
        run_cli "$@"
        return $?
    fi
    if [[ ${EUID:-1} -ne 0 && "${1:-}" != --version ]]; then
        echo -e "${RED}错误：${PLAIN} 必须使用 root 用户运行！"
        return 1
    fi

    if (($# > 0)); then
        INTERACTIVE_MODE=false
        init_logging
        run_cli "$@"
        return $?
    fi
    if [[ ! -r /dev/tty ]]; then
        error "无参数运行需要交互式终端；自动化请使用命令行参数。"
        return 1
    fi
    init_logging
    register_shortcut || true

    while true; do
        show_menu || return 1
        echo -e "\n${GREEN}按回车键返回主菜单...${PLAIN}"
        if ! read -r < /dev/tty; then
            error "无法读取终端输入。"
            return 1
        fi
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
