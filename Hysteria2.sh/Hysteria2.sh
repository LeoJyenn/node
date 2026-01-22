#!/bin/bash

# --- Script Setup ---
SCRIPT_COMMAND_NAME="hy"
SCRIPT_FILE_BASENAME="Hysteria2.sh"
SCRIPT_VERSION="2.0.0"
SCRIPT_DATE="2026-01-22"
SCRIPT_DOWNLOAD_URL="https://raw.githubusercontent.com/LeoJyenn/node/main/Hysteria2.sh/Hysteria2.sh"

# Hysteria Paths & Services
HYSTERIA_INSTALL_PATH="/usr/local/bin/hysteria"
HYSTERIA_CONFIG_DIR="/etc/hysteria"
HYSTERIA_CONFIG_FILE="${HYSTERIA_CONFIG_DIR}/config.yaml"
HYSTERIA_CERTS_DIR="${HYSTERIA_CONFIG_DIR}/certs"
HYSTERIA_INSTALL_VARS_FILE="${HYSTERIA_CONFIG_DIR}/install_vars.conf"
HYSTERIA_SERVICE_NAME_SYSTEMD="hysteria.service"
HYSTERIA_SERVICE_NAME_OPENRC="hysteria"
LOG_FILE_HYSTERIA_OUT="/var/log/hysteria.log"
LOG_FILE_HYSTERIA_ERR="/var/log/hysteria.error.log"

# --- Color Definitions ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Global OS Detection Variables ---
DISTRO_FAMILY=""
PKG_INSTALL_CMD=""
PKG_UPDATE_CMD=""
PKG_REMOVE_CMD=""
INIT_SYSTEM=""
SERVICE_CMD_SYSTEMCTL="systemctl"
SERVICE_CMD_OPENRC="rc-service"
ENABLE_CMD_PREFIX=""
ENABLE_CMD_SUFFIX=""
SETCAP_DEPENDENCY_PKG=""
REQUIRED_PKGS_OS_SPECIFIC=""

# --- Utility Functions ---
_log_error() { echo -e "${RED}错误: $1${NC}" >&2; }
_log_success() { echo -e "${GREEN}$1${NC}" >&2; }
_log_warning() { echo -e "${YELLOW}警告: $1${NC}" >&2; }
_log_info() { echo -e "${BLUE}信息: $1${NC}" >&2; }
_log_debug() { :; }

_ensure_root() {
    if [ "$(id -u)" -ne 0 ]; then
        _log_error "此操作需 root 权限。请用 sudo。"
        exit 1
    fi
}

_read_from_tty() {
    local var_name="$1"
    local prompt_str="$2"
    local default_val_display="$3"
    local actual_prompt="${BLUE}${prompt_str}${NC}"
    if [ -n "$default_val_display" ]; then
        actual_prompt="${BLUE}${prompt_str} (当前: ${default_val_display:-未设置}, 回车不改): ${NC}"
        if [[ "$prompt_str" == *"密码"* && -n "$default_val_display" ]]; then
            actual_prompt="${BLUE}${prompt_str} (回车不改): ${NC}"
        elif [[ "$prompt_str" == *"密码"* ]]; then
            actual_prompt="${BLUE}${prompt_str} (回车随机生成): ${NC}"
        fi
    fi
    echo -n -e "$actual_prompt"
    read "$var_name" </dev/tty
}

_read_confirm_tty() {
    local var_name="$1"
    local prompt_str="$2"
    echo -n -e "${YELLOW}${prompt_str}${NC}"
    read "$var_name" </dev/tty
}

_detect_os() {
    if [ -n "$DISTRO_FAMILY" ]; then
        return 0
    fi
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" == "alpine" ]]; then
            DISTRO_FAMILY="alpine"
        elif [[ "$ID" == "debian" || "$ID" == "ubuntu" || "$ID_LIKE" == *"debian"* || "$ID_LIKE" == *"ubuntu"* ]]; then
            DISTRO_FAMILY="debian"
        elif [[ "$ID" == "rhel" || "$ID" == "centos" || "$ID" == "rocky" || "$ID" == "almalinux" || "$ID_LIKE" == *"rhel"* || "$ID_LIKE" == *"fedora"* ]]; then
            DISTRO_FAMILY="rhel"
        else
            _log_error "不支持发行版 '$ID'."
            exit 1
        fi
    elif command -v apk >/dev/null 2>&1; then
        DISTRO_FAMILY="alpine"
    elif command -v apt-get >/dev/null 2>&1; then
        DISTRO_FAMILY="debian"
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        DISTRO_FAMILY="rhel"
    else
        _log_error "无法确定发行版."
        exit 1
    fi

    if [[ "$DISTRO_FAMILY" == "alpine" ]]; then
        PKG_INSTALL_CMD="apk add --no-cache"
        PKG_UPDATE_CMD="apk update"
        PKG_REMOVE_CMD="apk del"
        INIT_SYSTEM="openrc"
        ENABLE_CMD_PREFIX="rc-update add"
        ENABLE_CMD_SUFFIX="default"
        SETCAP_DEPENDENCY_PKG="libcap"
        REQUIRED_PKGS_OS_SPECIFIC="openrc ca-certificates"
    elif [[ "$DISTRO_FAMILY" == "debian" || "$DISTRO_FAMILY" == "rhel" ]]; then
        if [[ "$DISTRO_FAMILY" == "debian" ]]; then
            export DEBIAN_FRONTEND=noninteractive
            PKG_INSTALL_CMD="apt-get install -y -q"
            PKG_UPDATE_CMD="apt-get update -q"
            PKG_REMOVE_CMD="apt-get remove -y -q"
            SETCAP_DEPENDENCY_PKG="libcap2-bin"
        else
            PKG_INSTALL_CMD="dnf install -y -q"
            PKG_UPDATE_CMD="dnf makecache -y -q"
            PKG_REMOVE_CMD="dnf remove -y -q"
            if ! command -v dnf &>/dev/null && command -v yum &>/dev/null; then
                PKG_INSTALL_CMD="yum install -y -q"
                PKG_UPDATE_CMD="yum makecache -y -q"
                PKG_REMOVE_CMD="yum remove -y -q"
            fi
            SETCAP_DEPENDENCY_PKG="libcap"
        fi
        INIT_SYSTEM="systemd"
        ENABLE_CMD_PREFIX="systemctl enable"
        ENABLE_CMD_SUFFIX=""
        REQUIRED_PKGS_OS_SPECIFIC="ca-certificates"
    else
        _log_error "在 _detect_os 中未能识别或支持的发行版家族 '$DISTRO_FAMILY' 以设置包命令。"
        exit 1
    fi
}

_install_dependencies() {
    _log_info "更新包列表 (${DISTRO_FAMILY})..."
    if ! $PKG_UPDATE_CMD >/dev/null; then
        _log_error "更新包列表 (${PKG_UPDATE_CMD}) 失败。请检查网络和软件源配置。"
        exit 1
    fi
    _log_debug "检查并安装依赖包..."
    REQUIRED_PKGS_COMMON="wget curl openssl lsof coreutils tar"
    REQUIRED_PKGS="$REQUIRED_PKGS_COMMON"
    if [ -n "$REQUIRED_PKGS_OS_SPECIFIC" ]; then
        REQUIRED_PKGS="$REQUIRED_PKGS $REQUIRED_PKGS_OS_SPECIFIC"
    fi

    if ! command -v realpath &>/dev/null; then
        local coreutils_installed=false
        if [[ "$DISTRO_FAMILY" == "debian" ]]; then
            if dpkg-query -W -f='${Status}' coreutils 2>/dev/null | grep -q "install ok installed"; then
                coreutils_installed=true
            fi
        elif [[ "$DISTRO_FAMILY" == "alpine" ]]; then
            if apk info -e coreutils &>/dev/null; then
                coreutils_installed=true
            fi
        elif [[ "$DISTRO_FAMILY" == "rhel" ]]; then
            if rpm -q coreutils &>/dev/null; then
                coreutils_installed=true
            fi
        fi
        if ! $coreutils_installed || ! command -v realpath &>/dev/null; then
            _log_debug "核心工具 'realpath' 未找到或coreutils未安装, 尝试安装 'coreutils'..."
            if ! $PKG_INSTALL_CMD coreutils >/dev/null; then
                _log_warning "尝试安装/确保 coreutils 失败。"
            fi
        fi
        if ! command -v realpath &>/dev/null; then
            _log_error "realpath 命令在安装 coreutils 后仍然不可用。"
            exit 1
        fi
    fi

    local missing_pkgs_arr=()
    for pkg in $REQUIRED_PKGS; do
        installed=false
        if [[ "$DISTRO_FAMILY" == "alpine" ]]; then
            if apk info -e "$pkg" &>/dev/null; then
                installed=true
            fi
        elif [[ "$DISTRO_FAMILY" == "debian" ]]; then
            if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
                installed=true
            fi
        elif [[ "$DISTRO_FAMILY" == "rhel" ]]; then
            if rpm -q "$pkg" >/dev/null 2>&1; then
                installed=true
            fi
        fi
        if ! $installed; then
            missing_pkgs_arr+=("$pkg")
        fi
    done

    if [ ${#missing_pkgs_arr[@]} -gt 0 ]; then
        _log_info "下列依赖包需要安装: ${missing_pkgs_arr[*]}"
        if [[ "$DISTRO_FAMILY" == "rhel" ]]; then
            _log_debug "正在尝试一次性安装所有 RHEL 缺失依赖..."
            if ! $PKG_INSTALL_CMD "${missing_pkgs_arr[@]}" >/dev/null; then
                _log_error "一次性安装 RHEL 依赖失败。将尝试逐个安装..."
                for pkg_item in "${missing_pkgs_arr[@]}"; do
                    _log_debug "正在安装 $pkg_item..."
                    if ! $PKG_INSTALL_CMD "$pkg_item" >/dev/null; then
                        _log_error "安装 $pkg_item 失败。"
                        exit 1
                    fi
                done
            fi
        else
            for pkg_item in "${missing_pkgs_arr[@]}"; do
                _log_debug "正在安装 $pkg_item..."
                if ! $PKG_INSTALL_CMD "$pkg_item" >/dev/null; then
                    _log_error "安装 $pkg_item 失败。"
                    exit 1
                fi
            done
        fi
    else
        _log_debug "所有基础依赖已满足。"
    fi
    _log_success "依赖包检查与安装完成。"
}

_generate_uuid() {
    local bytes
    bytes=$(od -x -N 16 /dev/urandom | head -1 | awk '{OFS=""; $1=""; print}')
    local byte7=${bytes:12:4}
    byte7=$((0x${byte7} & 0x0fff | 0x4000))
    byte7=$(printf "%04x" "$byte7")
    local byte9=${bytes:20:4}
    byte9=$((0x${byte9} & 0x3fff | 0x8000))
    byte9=$(printf "%04x" "$byte9")
    echo "${bytes:0:8}-${bytes:8:4}-${byte7}-${byte9}-${bytes:24:12}" | tr '[:upper:]' '[:lower:]'
}

_generate_random_lowercase_string() {
    LC_ALL=C tr -dc 'a-z' </dev/urandom | head -c 8
}

_get_server_address() {
    local ipv6_ip
    local ipv4_ip
    _log_debug "检测公网IP..."
    _log_debug "尝试IPv6..."
    for ip_service in "https://ifconfig.me" "https://ip.sb" "https://api64.ipify.org" "https://ipv6.icanhazip.com" "https://v6.ident.me"; do
        ipv6_ip=$(curl -s -m 5 -6 "$ip_service" || true)
        if [ -n "$ipv6_ip" ] && [[ "$ipv6_ip" == *":"* ]]; then
            _log_debug "IPv6: $ipv6_ip"
            echo "[$ipv6_ip]"
            return
        fi
    done
    _log_debug "无IPv6."

    _log_debug "尝试IPv4..."
    for ip_service in "https://ifconfig.me" "https://ip.sb" "https://api.ipify.org" "https://ipv4.icanhazip.com" "https://v4.ident.me"; do
        ipv4_ip=$(curl -s -m 5 -4 "$ip_service" || true)
        if [ -n "$ipv4_ip" ] && [[ "$ipv4_ip" != *":"* ]]; then
            _log_debug "IPv4: $ipv4_ip"
            echo "$ipv4_ip"
            return
        fi
    done
    _log_debug "无IPv4."

    _log_error "无法获取公网IP. 请检查网络连接或手动指定IP。"
    exit 1
}

_get_script_path() {
    local script_path
    script_path=$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0")
    echo "$script_path"
}

_setup_command() {
    _ensure_root
    local installed_script_path="/usr/local/bin/${SCRIPT_COMMAND_NAME}"
    local script_path
    script_path=$(_get_script_path)
    _log_info "安装/更新 '${SCRIPT_COMMAND_NAME}' 命令到 ${installed_script_path}..."
    if [ -f "$script_path" ]; then
        if cp "$script_path" "$installed_script_path"; then
            chmod +x "$installed_script_path"
            _log_success "'${SCRIPT_COMMAND_NAME}' 命令已可用。"
            return 0
        fi
        _log_warning "复制脚本失败，尝试从远程下载..."
    else
        _log_warning "无法定位脚本路径，尝试从远程下载..."
    fi

    if [ -z "$SCRIPT_DOWNLOAD_URL" ]; then
        _log_error "未设置脚本下载地址，无法安装命令。"
        return 1
    fi

    local download_content
    if command -v curl >/dev/null 2>&1; then
        download_content=$(curl -fsSL "$SCRIPT_DOWNLOAD_URL" 2>/dev/null)
    elif command -v wget >/dev/null 2>&1; then
        download_content=$(wget -qO- "$SCRIPT_DOWNLOAD_URL" 2>/dev/null)
    else
        _log_error "curl 或 wget 不可用，无法下载脚本。"
        return 1
    fi

    if [ -z "$download_content" ]; then
        _log_error "脚本下载失败。"
        return 1
    fi
    if ! echo "$download_content" | head -n 1 | grep -q "^#!/bin/bash"; then
        _log_error "下载内容不是有效脚本，安装中止。"
        return 1
    fi

    if echo "$download_content" >"$installed_script_path"; then
        chmod +x "$installed_script_path"
        _log_success "'${SCRIPT_COMMAND_NAME}' 命令已可用。"
        return 0
    fi
    _log_error "写入 '${SCRIPT_COMMAND_NAME}' 命令失败。"
    return 1
}

_is_hysteria_installed() {
    _detect_os
    if [ -f "$HYSTERIA_INSTALL_PATH" ] && [ -f "$HYSTERIA_CONFIG_FILE" ]; then
        if [ "$INIT_SYSTEM" == "systemd" ] && [ -f "/etc/systemd/system/$HYSTERIA_SERVICE_NAME_SYSTEMD" ]; then
            return 0
        elif [ "$INIT_SYSTEM" == "openrc" ] && [ -f "/etc/init.d/$HYSTERIA_SERVICE_NAME_OPENRC" ]; then
            return 0
        fi
    fi
    return 1
}

_check_service_status() {
    local current_service_name_val=""
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        current_service_name_val="$HYSTERIA_SERVICE_NAME_SYSTEMD"
        local status_output
        status_output=$($SERVICE_CMD_SYSTEMCTL is-active "$current_service_name_val" 2>/dev/null)
        if [[ "$status_output" == "active" ]]; then
            echo -e "${GREEN}✓ Hysteria 服务正在运行${NC}"
            return 0
        else
            echo -e "${RED}✗ Hysteria 服务未运行${NC}"
            return 1
        fi
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        current_service_name_val="$HYSTERIA_SERVICE_NAME_OPENRC"
        local status_output
        status_output=$($SERVICE_CMD_OPENRC "$current_service_name_val" status 2>/dev/null)
        if echo "$status_output" | grep -q "started" || pgrep -f "$HYSTERIA_INSTALL_PATH.*$HYSTERIA_CONFIG_FILE" >/dev/null; then
            echo -e "${GREEN}✓ Hysteria 服务正在运行${NC}"
            return 0
        else
            if echo "$status_output" | grep -q "crashed"; then
                echo -e "${RED}✗ Hysteria 服务已崩溃${NC}"
            else
                echo -e "${RED}✗ Hysteria 服务未运行${NC}"
            fi
            return 1
        fi
    else
        _log_error "不支持的初始化系统: $INIT_SYSTEM"
        return 1
    fi
}

_control_service() {
    local action="$1"
    _detect_os

    local current_service_name_val=""
    local service_cmd_val=""
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        current_service_name_val="$HYSTERIA_SERVICE_NAME_SYSTEMD"
        service_cmd_val="$SERVICE_CMD_SYSTEMCTL"
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        current_service_name_val="$HYSTERIA_SERVICE_NAME_OPENRC"
        service_cmd_val="$SERVICE_CMD_OPENRC"
    else
        _log_error "不支持的初始化系统: $INIT_SYSTEM"
        return 1
    fi

    case "$action" in
        start | stop | restart)
            _ensure_root
            local cmd_output
            if [[ "$INIT_SYSTEM" == "systemd" ]]; then
                _log_info "执行: ${service_cmd_val} ${action} ${current_service_name_val}"
                cmd_output=$($service_cmd_val "$action" "$current_service_name_val" 2>&1)
            else
                _log_info "执行: ${service_cmd_val} ${current_service_name_val} ${action}"
                cmd_output=$($service_cmd_val "$current_service_name_val" "$action" 2>&1)
            fi
            if [ $? -eq 0 ]; then
                _log_success "操作 '${action}' 成功。"
                sleep 1
                _check_service_status
            else
                _log_error "操作 '${action}' 失败。输出:"
                echo "$cmd_output"
                _log_warning "请检查日志:"
                echo "  输出: tail -n 30 $LOG_FILE_HYSTERIA_OUT"
                echo "  错误: tail -n 30 $LOG_FILE_HYSTERIA_ERR"
                return 1
            fi
            ;;
        status)
            _check_service_status
            ;;
        enable)
            _ensure_root
            _log_info "启用 Hysteria 开机自启..."
            if $ENABLE_CMD_PREFIX "$current_service_name_val" $ENABLE_CMD_SUFFIX >/dev/null 2>&1; then
                _log_success "已启用 Hysteria 开机自启。"
            else
                _log_error "启用 Hysteria 开机自启失败。"
                return 1
            fi
            ;;
        disable)
            _ensure_root
            _log_info "禁用 Hysteria 开机自启..."
            if [[ "$INIT_SYSTEM" == "systemd" ]]; then
                $service_cmd_val disable "$current_service_name_val" >/dev/null 2>&1 || true
            else
                rc-update del "$current_service_name_val" default >/dev/null 2>&1 || true
            fi
            _log_success "已禁用 Hysteria 开机自启。"
            ;;
        *)
            _log_error "未知服务操作: $action"
            return 1
            ;;
    esac
}

_get_hysteria_link_params() {
    unset HY_PASSWORD HY_LINK_ADDRESS HY_PORT HY_LINK_SNI HY_LINK_INSECURE HY_SNI_VALUE DOMAIN_FROM_CONFIG CERT_PATH_FROM_CONFIG
    if [ ! -f "$HYSTERIA_CONFIG_FILE" ]; then
        _log_error "Hysteria 配置文件 $HYSTERIA_CONFIG_FILE 未找到。"
        return 1
    fi
    _log_debug "解析 Hysteria 配置生成订阅链接..."
    HY_PORT=$(grep -E '^\s*listen:\s*:([0-9]+)' "$HYSTERIA_CONFIG_FILE" | sed -E 's/^\s*listen:\s*://' || echo "")
    HY_PASSWORD=$(grep 'password:' "$HYSTERIA_CONFIG_FILE" | head -n 1 | sed -e 's/^.*password:[[:space:]]*//' -e 's/#.*//' -e 's/[[:space:]]*$//' -e 's/["'\''']//g' || echo "")
    if grep -q '^\s*acme:' "$HYSTERIA_CONFIG_FILE"; then
        DOMAIN_FROM_CONFIG=$(grep -A 1 '^\s*domains:' "$HYSTERIA_CONFIG_FILE" | grep '^\s*-\s*' | sed -e 's/^\s*-\s*//' -e 's/#.*//' -e 's/[ \t]*$//' -e 's/^["'\'']// -e 's/["'\'']$//')
        if [ -z "$DOMAIN_FROM_CONFIG" ]; then
            _log_error "无法从 Hysteria 配置解析 ACME 域名。"
            return 1
        fi
        HY_LINK_SNI="$DOMAIN_FROM_CONFIG"
        HY_LINK_ADDRESS="$DOMAIN_FROM_CONFIG"
        HY_LINK_INSECURE="0"
        HY_SNI_VALUE="$DOMAIN_FROM_CONFIG"
    elif grep -q '^\s*tls:' "$HYSTERIA_CONFIG_FILE"; then
        CERT_PATH_FROM_CONFIG=$(grep '^\s*cert:' "$HYSTERIA_CONFIG_FILE" | head -n 1 | sed -e 's/^\s*cert:[[:space:]]*//' -e 's/#.*//' -e 's/[[:space:]]*$//' -e 's/^["'\'']// -e 's/["'\'']$//' || echo "")
        if [ -z "$CERT_PATH_FROM_CONFIG" ]; then
            _log_error "无法从 Hysteria 配置解析证书路径。"
            return 1
        fi
        if [[ "$CERT_PATH_FROM_CONFIG" != /* ]]; then
            CERT_PATH_FROM_CONFIG="${HYSTERIA_CONFIG_DIR}/${CERT_PATH_FROM_CONFIG}"
        fi
        if command -v realpath &>/dev/null; then
            CERT_PATH_FROM_CONFIG=$(realpath -m "$CERT_PATH_FROM_CONFIG" 2>/dev/null || echo "$CERT_PATH_FROM_CONFIG")
        fi
        if [ ! -f "$CERT_PATH_FROM_CONFIG" ]; then
            _log_error "证书路径 '$CERT_PATH_FROM_CONFIG' 无效或文件不存在。"
            return 1
        fi
        HY_SNI_VALUE=$(openssl x509 -noout -subject -nameopt RFC2253 -in "$CERT_PATH_FROM_CONFIG" 2>/dev/null | sed -n 's/.*CN=\([^,]*\).*/\1/p')
        if [ -z "$HY_SNI_VALUE" ]; then
            HY_SNI_VALUE=$(openssl x509 -noout -subject -in "$CERT_PATH_FROM_CONFIG" 2>/dev/null | sed -n 's/.*CN ?= ?\([^,]*\).*/\1/p' | head -n 1 | sed 's/^[ \t]*//;s/[ \t]*$//')
        fi
        if [ -z "$HY_SNI_VALUE" ]; then
            HY_SNI_VALUE=$(openssl x509 -noout -text -in "$CERT_PATH_FROM_CONFIG" 2>/dev/null | grep 'DNS:' | head -n 1 | sed 's/.*DNS://' | tr -d ' ' | cut -d, -f1)
        fi
        if [ -z "$HY_SNI_VALUE" ]; then
            HY_SNI_VALUE="sni_unknown"
        fi
        HY_LINK_SNI="$HY_SNI_VALUE"
        HY_LINK_ADDRESS=$(_get_server_address)
        if [ -z "$HY_LINK_ADDRESS" ]; then
            _log_error "获取公网地址失败。"
            return 1
        fi
        HY_LINK_INSECURE="1"
    else
        _log_error "无法确定 Hysteria TLS 模式。"
        return 1
    fi
    if [ -z "$HY_PORT" ] || [ -z "$HY_PASSWORD" ] || [ -z "$HY_LINK_ADDRESS" ] || [ -z "$HY_LINK_SNI" ] || [ -z "$HY_LINK_INSECURE" ] || [ -z "$HY_SNI_VALUE" ]; then
        _log_error "未能解析生成 Hysteria 链接所需的参数。"
        return 1
    fi
    return 0
}

_display_hysteria_link() {
    local final_remark="Hysteria-${HY_SNI_VALUE}"
    local hysteria_subscription_link="hysteria2://${HY_PASSWORD}@${HY_LINK_ADDRESS}:${HY_PORT}/?sni=${HY_LINK_SNI}&alpn=h3&insecure=${HY_LINK_INSECURE}#${final_remark}"
    echo ""
    _log_info "Hysteria 订阅链接 (备注: ${final_remark}):"
    echo -e "${GREEN}${hysteria_subscription_link}${NC}"
    echo ""
}

_show_hysteria_link() {
    _detect_os
    if ! _is_hysteria_installed; then
        _log_error "Hysteria 未安装。"
        return 1
    fi
    if ! _get_hysteria_link_params; then
        _log_error "无法从当前 Hysteria 配置生成订阅链接。"
        return 1
    fi
    _display_hysteria_link
}

_do_install_hysteria() {
    _ensure_root
    _detect_os
    if _is_hysteria_installed; then
        _read_confirm_tty confirm_install "Hysteria 已安装。是否强制安装(覆盖配置)? [y/N]: "
        if [[ "$confirm_install" != "y" && "$confirm_install" != "Y" ]]; then
            _log_info "Hysteria 安装取消。"
            return 0
        fi
        _log_warning "正强制安装 Hysteria..."
    fi

    _log_info "--- 开始 Hysteria 依赖安装 ---"
    _install_dependencies
    _log_info "--- Hysteria 依赖安装结束 ---"

    DEFAULT_MASQUERADE_URL="https://www.cn.bing.com"
    DEFAULT_PORT="34567"
    DEFAULT_ACME_EMAIL="$(_generate_random_lowercase_string)@gmail.com"
    echo ""
    _log_info "请选择 Hysteria TLS 验证方式:"
    echo "1. 自定义证书"
    echo "2. ACME HTTP 验证"
    _read_from_tty TLS_TYPE "选择 [1-2, 默认 1]: "
    TLS_TYPE=${TLS_TYPE:-1}

    CERT_PATH=""
    KEY_PATH=""
    DOMAIN=""
    SNI_VALUE=""
    ACME_EMAIL=""

    case $TLS_TYPE in
        1)
            _log_info "--- 自定义证书模式 ---"
            _read_from_tty USER_CERT_PATH "证书路径(.crt/.pem)(留空则自签): "
            if [ -z "$USER_CERT_PATH" ]; then
                _log_info "将生成自签名证书。"
                if ! command -v openssl &>/dev/null; then
                    _log_error "openssl 未安装 ($PKG_INSTALL_CMD openssl)"
                    exit 1
                fi
                _read_from_tty SELF_SIGN_SNI "自签名证书SNI(默认www.cn.bing.com): "
                SELF_SIGN_SNI=${SELF_SIGN_SNI:-"www.cn.bing.com"}
                SNI_VALUE="$SELF_SIGN_SNI"
                mkdir -p "$HYSTERIA_CERTS_DIR"
                CERT_PATH="$HYSTERIA_CERTS_DIR/server.crt"
                KEY_PATH="$HYSTERIA_CERTS_DIR/server.key"
                _log_debug "正生成自签证书(CN=$SNI_VALUE)..."
                if ! openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) -keyout "$KEY_PATH" -out "$CERT_PATH" -subj "/CN=$SNI_VALUE" -days 36500 >/dev/null 2>&1; then
                    _log_error "自签证书生成失败!"
                    exit 1
                fi
                _log_success "自签证书已生成: $CERT_PATH, $KEY_PATH"
            else
                _log_info "提供证书路径: $USER_CERT_PATH"
                _read_from_tty USER_KEY_PATH "私钥路径(.key/.pem): "
                if [ -z "$USER_KEY_PATH" ]; then
                    _log_error "私钥路径不能为空。"
                    exit 1
                fi
                TMP_CERT_PATH=$(realpath "$USER_CERT_PATH" 2>/dev/null || echo "$USER_CERT_PATH")
                TMP_KEY_PATH=$(realpath "$USER_KEY_PATH" 2>/dev/null || echo "$USER_KEY_PATH")
                if [ ! -f "$TMP_CERT_PATH" ]; then
                    _log_error "证书 '$USER_CERT_PATH' 无效。"
                    exit 1
                fi
                if [ ! -f "$TMP_KEY_PATH" ]; then
                    _log_error "私钥 '$USER_KEY_PATH' 无效。"
                    exit 1
                fi
                CERT_PATH="$TMP_CERT_PATH"
                KEY_PATH="$TMP_KEY_PATH"
                SNI_VALUE=$(openssl x509 -noout -subject -nameopt RFC2253 -in "$CERT_PATH" 2>/dev/null | sed -n 's/.*CN=\([^,]*\).*/\1/p')
                if [ -z "$SNI_VALUE" ]; then
                    SNI_VALUE=$(openssl x509 -noout -subject -in "$CERT_PATH" 2>/dev/null | sed -n 's/.*CN ?= ?\([^,]*\).*/\1/p' | head -n 1 | sed 's/^[ \t]*//;s/[ \t]*$//')
                fi
                if [ -z "$SNI_VALUE" ]; then
                    SNI_VALUE=$(openssl x509 -noout -text -in "$CERT_PATH" 2>/dev/null | grep 'DNS:' | head -n 1 | sed 's/.*DNS://' | tr -d ' ' | cut -d, -f1)
                fi
                if [ -z "$SNI_VALUE" ]; then
                    _read_from_tty MANUAL_SNI "无法提取SNI, 请手动输入: "
                    if [ -z "$MANUAL_SNI" ]; then
                        _log_error "SNI不能为空!"
                        exit 1
                    fi
                    SNI_VALUE="$MANUAL_SNI"
                else
                    _log_info "提取到SNI: $SNI_VALUE"
                fi
            fi
            ;;
        2)
            _log_info "--- ACME HTTP 验证 ---"
            _read_from_tty DOMAIN "域名(eg: example.com): "
            if [ -z "$DOMAIN" ]; then
                _log_error "域名不能为空!"
                exit 1
            fi
            _read_from_tty INPUT_ACME_EMAIL "ACME邮箱(默认 $DEFAULT_ACME_EMAIL): "
            ACME_EMAIL=${INPUT_ACME_EMAIL:-$DEFAULT_ACME_EMAIL}
            if [ -z "$ACME_EMAIL" ]; then
                _log_error "邮箱不能为空!"
                exit 1
            fi
            SNI_VALUE=$DOMAIN
            _log_debug "检查80端口..."
            if lsof -i:80 -sTCP:LISTEN -P -n &>/dev/null; then
                _log_warning "80端口被占用!"
                PID_80=$(lsof -t -i:80 -sTCP:LISTEN)
                [ -n "$PID_80" ] && _log_info "占用进程PID: $PID_80"
            else
                _log_debug "80端口可用。"
            fi
            ;;
        *)
            _log_error "无效TLS选项。"
            exit 1
            ;;
    esac

    _read_from_tty PORT_INPUT "Hysteria监听端口(默认 $DEFAULT_PORT): "
    PORT=${PORT_INPUT:-$DEFAULT_PORT}
    _read_from_tty PASSWORD_INPUT "Hysteria密码(回车随机): " "random"
    if [ -z "$PASSWORD_INPUT" ] || [ "$PASSWORD_INPUT" == "random" ]; then
        PASSWORD=$(_generate_uuid)
        _log_info "使用随机密码: $PASSWORD"
    else
        PASSWORD="$PASSWORD_INPUT"
    fi
    _read_from_tty MASQUERADE_URL_INPUT "伪装URL(默认 $DEFAULT_MASQUERADE_URL): "
    MASQUERADE_URL=${MASQUERADE_URL_INPUT:-$DEFAULT_MASQUERADE_URL}
    SERVER_PUBLIC_ADDRESS=$(_get_server_address)

    mkdir -p "$HYSTERIA_CONFIG_DIR"
    _log_info "下载 Hysteria..."
    ARCH=$(uname -m)
    case ${ARCH} in
        x86_64) HYSTERIA_ARCH="amd64" ;;
        aarch64) HYSTERIA_ARCH="arm64" ;;
        armv7l) HYSTERIA_ARCH="arm" ;;
        *)
            _log_error "不支持架构: ${ARCH}"
            exit 1
            ;;
    esac
    if ! wget -qO "$HYSTERIA_INSTALL_PATH" "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HYSTERIA_ARCH}"; then
        _log_warning "GitHub 下载失败,尝试旧地址..."
        if ! wget -qO "$HYSTERIA_INSTALL_PATH" "https://download.hysteria.network/app/latest/hysteria-linux-${HYSTERIA_ARCH}"; then
            _log_error "下载 Hysteria 失败!"
            exit 1
        fi
    fi
    chmod +x "$HYSTERIA_INSTALL_PATH"

    if [ "$TLS_TYPE" -eq 2 ]; then
        _log_debug "设置 cap_net_bind_service 权限(ACME)..."
        if ! command -v setcap &>/dev/null; then
            _log_warning "setcap 未找到,尝试安装 $SETCAP_DEPENDENCY_PKG..."
            if ! $PKG_INSTALL_CMD "$SETCAP_DEPENDENCY_PKG" >/dev/null; then
                _log_error "安装 $SETCAP_DEPENDENCY_PKG 失败。"
            else
                _log_success "$SETCAP_DEPENDENCY_PKG 安装成功。"
            fi
        fi
        if command -v setcap &>/dev/null; then
            if ! setcap 'cap_net_bind_service=+ep' "$HYSTERIA_INSTALL_PATH"; then
                _log_error "setcap 失败。"
            else
                _log_success "setcap 成功。"
            fi
        else
            _log_error "setcap 仍不可用。"
        fi
    fi

    _log_debug "生成 Hysteria 配置文件 $HYSTERIA_CONFIG_FILE..."
    cat >"$HYSTERIA_CONFIG_FILE" <<EOF
# Hysteria 2 服务器配置文件
# 由 ${SCRIPT_COMMAND_NAME} v${SCRIPT_VERSION} 在 $(date) 生成

listen: :$PORT

auth:
  type: password
  password: $PASSWORD

masquerade:
  type: proxy
  proxy:
    url: $MASQUERADE_URL
    rewriteHost: true
EOF
    case $TLS_TYPE in
        1)
            cat >>"$HYSTERIA_CONFIG_FILE" <<EOF

tls:
  cert: $CERT_PATH
  key: $KEY_PATH
EOF
            _log_warning "Hysteria 自定义证书客户端需设 insecure: true"
            ;;
        2)
            cat >>"$HYSTERIA_CONFIG_FILE" <<EOF

acme:
  domains:
    - $DOMAIN
  email: $ACME_EMAIL
EOF
            ;;
    esac
    _log_success "Hysteria 配置文件完成。"

    local current_service_name_for_hysteria=""
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        current_service_name_for_hysteria="$HYSTERIA_SERVICE_NAME_SYSTEMD"
        _log_debug "创建 Hysteria systemd 服务..."
        cat >"/etc/systemd/system/$current_service_name_for_hysteria" <<EOF
[Unit]
Description=Hysteria 2 Service by $SCRIPT_COMMAND_NAME
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${HYSTERIA_INSTALL_PATH} server --config ${HYSTERIA_CONFIG_FILE}
Restart=on-failure
RestartSec=10
StandardOutput=append:${LOG_FILE_HYSTERIA_OUT}
StandardError=append:${LOG_FILE_HYSTERIA_ERR}
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
        chmod 644 "/etc/systemd/system/$current_service_name_for_hysteria"
        $SERVICE_CMD_SYSTEMCTL daemon-reload 2>/dev/null
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        current_service_name_for_hysteria="$HYSTERIA_SERVICE_NAME_OPENRC"
        _log_debug "创建 Hysteria OpenRC 服务..."
        cat >"/etc/init.d/$current_service_name_for_hysteria" <<EOF
#!/sbin/openrc-run
name="$HYSTERIA_SERVICE_NAME_OPENRC"
command="$HYSTERIA_INSTALL_PATH"
command_args="server --config $HYSTERIA_CONFIG_FILE"
pidfile="/var/run/\${name}.pid"
command_background="yes"
output_log="$LOG_FILE_HYSTERIA_OUT"
error_log="$LOG_FILE_HYSTERIA_ERR"
depend() { need net; after firewall; }
start_pre() { checkpath -f "\$output_log" -m 0644; checkpath -f "\$error_log" -m 0644; }
start() { ebegin "Starting \$name"; start-stop-daemon --start --quiet --background --make-pidfile --pidfile "\$pidfile" --stdout "\$output_log" --stderr "\$error_log" --exec "\$command" -- \$command_args; eend \$?; }
stop() { ebegin "Stopping \$name"; start-stop-daemon --stop --quiet --pidfile "\$pidfile"; eend \$?; }
EOF
        chmod +x "/etc/init.d/$current_service_name_for_hysteria"
    fi
    _log_success "Hysteria 服务文件创建成功。"

    _control_service "enable"
    _log_info "准备启动/重启 Hysteria 服务..."
    _control_service "restart"
    sleep 2
    if _control_service "status" >/dev/null; then
        _log_success "Hysteria 服务已成功运行！"
    else
        _log_error "Hysteria 服务状态异常!"
    fi
    _setup_command
    _log_success "Hysteria 安装配置完成！"
    echo "------------------------------------------------------------------------"
    _show_hysteria_link
    echo "------------------------------------------------------------------------"
}

_do_uninstall_hysteria() {
    _ensure_root
    _detect_os
    if ! _is_hysteria_installed; then
        _log_info "Hysteria 未安装或未完全安装。跳过卸载。"
        return 0
    fi

    _read_confirm_tty confirm_uninstall "这将卸载 Hysteria 并删除所有相关配置和文件。确定? [y/N]: "
    if [[ "$confirm_uninstall" != "y" && "$confirm_uninstall" != "Y" ]]; then
        _log_info "Hysteria 卸载取消。"
        return 0
    fi

    _log_info "正在卸载 Hysteria..."
    _log_info "停止 Hysteria 服务..."
    _control_service "stop"

    local current_service_name_val=""
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        current_service_name_val="$HYSTERIA_SERVICE_NAME_SYSTEMD"
        _log_debug "禁用 Hysteria systemd 服务..."
        "$SERVICE_CMD_SYSTEMCTL" disable "$current_service_name_val" >/dev/null 2>/dev/null || true
        _log_debug "移除 Hysteria systemd 服务文件..."
        rm -f "/etc/systemd/system/$current_service_name_val"
        find /etc/systemd/system/ -name "$current_service_name_val" -delete 2>/dev/null
        "$SERVICE_CMD_SYSTEMCTL" daemon-reload 2>/dev/null
        "$SERVICE_CMD_SYSTEMCTL" reset-failed "$current_service_name_val" >/dev/null 2>/dev/null || true
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        current_service_name_val="$HYSTERIA_SERVICE_NAME_OPENRC"
        _log_debug "移除 Hysteria OpenRC 服务..."
        rc-update del "$current_service_name_val" default >/dev/null 2>&1 || true
        _log_debug "移除 Hysteria OpenRC 脚本..."
        rm -f "/etc/init.d/$current_service_name_val"
    fi

    _log_debug "移除 Hysteria 二进制: $HYSTERIA_INSTALL_PATH"
    rm -f "$HYSTERIA_INSTALL_PATH"

    _log_debug "移除 Hysteria 配置: $HYSTERIA_CONFIG_DIR"
    rm -rf "$HYSTERIA_CONFIG_DIR"

    _log_debug "清理 Hysteria 配置备份..."
    find "$(dirname "$HYSTERIA_CONFIG_DIR")" -maxdepth 1 -type d -name "$(basename "$HYSTERIA_CONFIG_DIR")_backup_*" -exec rm -rf {} \; 2>/dev/null

    _log_debug "移除 Hysteria 日志: $LOG_FILE_HYSTERIA_OUT, $LOG_FILE_HYSTERIA_ERR"
    rm -f "$LOG_FILE_HYSTERIA_OUT" "$LOG_FILE_HYSTERIA_ERR"

    _log_debug "移除 Hysteria 旧版变量文件 (如果存在): $HYSTERIA_INSTALL_VARS_FILE"
    rm -f "$HYSTERIA_INSTALL_VARS_FILE"

    _log_success "Hysteria 卸载完成。"
}

_show_menu() {
    clear
    _log_info "===================== ${SCRIPT_COMMAND_NAME} 管理菜单 ====================="
    echo "1. 安装/重装 Hysteria 2"
    echo "2. 启动 Hysteria 服务"
    echo "3. 停止 Hysteria 服务"
    echo "4. 重启 Hysteria 服务"
    echo "5. 查看 Hysteria 服务状态"
    echo "6. 显示 Hysteria 订阅链接"
    echo "7. 卸载 Hysteria 2"
    echo "0. 退出"
    echo "==========================================================================="
}

_menu_loop() {
    while true; do
        _show_menu
        _read_from_tty menu_selection "请选择 [0-7]: "
        case "$menu_selection" in
            1)
                _do_install_hysteria
                ;;
            2)
                _control_service "start"
                ;;
            3)
                _control_service "stop"
                ;;
            4)
                _control_service "restart"
                ;;
            5)
                _control_service "status"
                ;;
            6)
                _show_hysteria_link
                ;;
            7)
                _do_uninstall_hysteria
                ;;
            0)
                _log_info "已退出。"
                exit 0
                ;;
            *)
                _log_warning "无效选项，请重新选择。"
                ;;
        esac
        _read_from_tty _continue "按回车键继续..."
    done
}

if [ "$#" -gt 0 ]; then
    _log_error "仅支持菜单模式，请直接运行 ${SCRIPT_COMMAND_NAME}。"
    exit 1
fi

_menu_loop
