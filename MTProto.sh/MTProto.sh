#!/bin/bash

# --- Script Setup ---
SCRIPT_COMMAND_NAME="mtp"
SCRIPT_FILE_BASENAME="MTProto.sh"
SCRIPT_VERSION="2.0.0"
SCRIPT_DATE="2026-01-22"

# MTProto (mtg) Paths & Services
MTG_INSTALL_PATH="/usr/local/bin/mtg"
MTG_CONFIG_DIR="/etc/mtg"
MTG_CONFIG_FILE="${MTG_CONFIG_DIR}/config.toml"
MTG_VARS_FILE="${MTG_CONFIG_DIR}/install_vars_mtg.conf"
MTG_SERVICE_NAME_SYSTEMD="mtg.service"
MTG_SERVICE_NAME_OPENRC="mtg"
LOG_FILE_MTG_OUT="/var/log/mtg.log"
LOG_FILE_MTG_ERR="/var/log/mtg.error.log"
MTG_TARGET_VERSION="2.1.7"

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
        REQUIRED_PKGS_OS_SPECIFIC="openrc ca-certificates"
    elif [[ "$DISTRO_FAMILY" == "debian" || "$DISTRO_FAMILY" == "rhel" ]]; then
        if [[ "$DISTRO_FAMILY" == "debian" ]]; then
            export DEBIAN_FRONTEND=noninteractive
            PKG_INSTALL_CMD="apt-get install -y -q"
            PKG_UPDATE_CMD="apt-get update -q"
            PKG_REMOVE_CMD="apt-get remove -y -q"
        else
            PKG_INSTALL_CMD="dnf install -y -q"
            PKG_UPDATE_CMD="dnf makecache -y -q"
            PKG_REMOVE_CMD="dnf remove -y -q"
            if ! command -v dnf &>/dev/null && command -v yum &>/dev/null; then
                PKG_INSTALL_CMD="yum install -y -q"
                PKG_UPDATE_CMD="yum makecache -y -q"
                PKG_REMOVE_CMD="yum remove -y -q"
            fi
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
    if [ ! -f "$script_path" ]; then
        _log_error "无法定位脚本路径，跳过命令安装。"
        return 1
    fi
    _log_info "安装/更新 '${SCRIPT_COMMAND_NAME}' 命令到 ${installed_script_path}..."
    if cp "$script_path" "$installed_script_path"; then
        chmod +x "$installed_script_path"
        _log_success "'${SCRIPT_COMMAND_NAME}' 命令已可用。"
    else
        _log_error "安装 '${SCRIPT_COMMAND_NAME}' 命令失败。"
        return 1
    fi
}

_is_mtg_installed() {
    _detect_os
    if [ -f "$MTG_INSTALL_PATH" ] && [ -f "$MTG_CONFIG_FILE" ]; then
        if [ "$INIT_SYSTEM" == "systemd" ] && [ -f "/etc/systemd/system/$MTG_SERVICE_NAME_SYSTEMD" ]; then
            return 0
        elif [ "$INIT_SYSTEM" == "openrc" ] && [ -f "/etc/init.d/$MTG_SERVICE_NAME_OPENRC" ]; then
            return 0
        fi
    fi
    return 1
}

_check_service_status() {
    local current_service_name_val=""
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        current_service_name_val="$MTG_SERVICE_NAME_SYSTEMD"
        local status_output
        status_output=$($SERVICE_CMD_SYSTEMCTL is-active "$current_service_name_val" 2>/dev/null)
        if [[ "$status_output" == "active" ]]; then
            echo -e "${GREEN}✓ MTProto 服务正在运行${NC}"
            return 0
        else
            echo -e "${RED}✗ MTProto 服务未运行${NC}"
            return 1
        fi
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        current_service_name_val="$MTG_SERVICE_NAME_OPENRC"
        local status_output
        status_output=$($SERVICE_CMD_OPENRC "$current_service_name_val" status 2>/dev/null)
        if echo "$status_output" | grep -q "started" || pgrep -f "$MTG_INSTALL_PATH.*$MTG_CONFIG_FILE" >/dev/null; then
            echo -e "${GREEN}✓ MTProto 服务正在运行${NC}"
            return 0
        else
            if echo "$status_output" | grep -q "crashed"; then
                echo -e "${RED}✗ MTProto 服务已崩溃${NC}"
            else
                echo -e "${RED}✗ MTProto 服务未运行${NC}"
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
        current_service_name_val="$MTG_SERVICE_NAME_SYSTEMD"
        service_cmd_val="$SERVICE_CMD_SYSTEMCTL"
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        current_service_name_val="$MTG_SERVICE_NAME_OPENRC"
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
                echo "  输出: tail -n 30 $LOG_FILE_MTG_OUT"
                echo "  错误: tail -n 30 $LOG_FILE_MTG_ERR"
                return 1
            fi
            ;;
        status)
            _check_service_status
            ;;
        enable)
            _ensure_root
            _log_info "启用 MTProto 开机自启..."
            if $ENABLE_CMD_PREFIX "$current_service_name_val" $ENABLE_CMD_SUFFIX >/dev/null 2>&1; then
                _log_success "已启用 MTProto 开机自启。"
            else
                _log_error "启用 MTProto 开机自启失败。"
                return 1
            fi
            ;;
        disable)
            _ensure_root
            _log_info "禁用 MTProto 开机自启..."
            if [[ "$INIT_SYSTEM" == "systemd" ]]; then
                $service_cmd_val disable "$current_service_name_val" >/dev/null 2>&1 || true
            else
                rc-update del "$current_service_name_val" default >/dev/null 2>&1 || true
            fi
            _log_success "已禁用 MTProto 开机自启。"
            ;;
        *)
            _log_error "未知服务操作: $action"
            return 1
            ;;
    esac
}

_download_mtg_binary() {
    local expected_version="$1"
    _ensure_root
    _detect_os
    _log_info "下载 MTProto 代理 (9seconds/mtg 版本 ${expected_version})..."
    local arch_mtg ARCH
    ARCH=$(uname -m)
    case ${ARCH} in
        x86_64) arch_mtg="amd64" ;;
        aarch64) arch_mtg="arm64" ;;
        armv7l) arch_mtg="armv7" ;;
        armv6l) arch_mtg="armv6" ;;
        armhf) arch_mtg="armv7" ;;
        armel) arch_mtg="armv6" ;;
        i386 | i686) arch_mtg="386" ;;
        *)
            _log_error "不支持的CPU架构: ${ARCH}"
            return 1
            ;;
    esac

    local mtg_tag="v${expected_version}"
    local download_url="https://github.com/9seconds/mtg/releases/download/${mtg_tag}/mtg-${expected_version}-linux-${arch_mtg}.tar.gz"
    local tmp_archive="/tmp/mtg-${expected_version}-linux-${arch_mtg}.tar.gz"
    local tmp_extract_dir="/tmp/mtg_extract_$$"
    rm -rf "$tmp_extract_dir"
    mkdir -p "$tmp_extract_dir"
    _log_debug "下载 URL: $download_url"
    if ! wget -qO "$tmp_archive" "$download_url"; then
        _log_error "下载 MTG 失败。"
        rm -f "$tmp_archive"
        rm -rf "$tmp_extract_dir"
        return 1
    fi
    _log_debug "解压 MTG..."
    if ! tar -xzf "$tmp_archive" -C "$tmp_extract_dir"; then
        _log_error "解压 MTG 失败。"
        rm -f "$tmp_archive"
        rm -rf "$tmp_extract_dir"
        return 1
    fi
    local extracted_binary_path="$tmp_extract_dir/mtg-${expected_version}-linux-${arch_mtg}/mtg"
    if [ ! -f "$extracted_binary_path" ]; then
        extracted_binary_path="$tmp_extract_dir/mtg"
    fi
    if [ ! -f "$extracted_binary_path" ]; then
        _log_error "MTG 二进制文件未找到。"
        rm -f "$tmp_archive"
        rm -rf "$tmp_extract_dir"
        return 1
    fi
    mv "$extracted_binary_path" "$MTG_INSTALL_PATH"
    chmod +x "$MTG_INSTALL_PATH"
    rm -f "$tmp_archive"
    rm -rf "$tmp_extract_dir"
    _log_success "MTG 下载并安装成功: $MTG_INSTALL_PATH"
    return 0
}

_generate_mtg_config() {
    _log_info "开始配置 MTProto 代理..."
    mkdir -p "$MTG_CONFIG_DIR"
    local mtg_port mtg_domain mtg_secret
    _read_from_tty mtg_port "请输入 MTProto 代理监听端口" "45678"
    mtg_port=${mtg_port:-45678}
    _read_from_tty mtg_domain "请输入用于生成FakeTLS密钥的伪装域名 (建议常用可访问域名)" "www.cn.bing.com"
    mtg_domain=${mtg_domain:-"www.cn.bing.com"}
    if ! command -v "$MTG_INSTALL_PATH" &>/dev/null; then
        _log_error "MTG 程序 ($MTG_INSTALL_PATH) 未找到或未安装。无法生成密钥。"
        return 1
    fi
    _log_debug "正在为域名 '${mtg_domain}' 生成 MTProto 密钥 (FakeTLS 'ee' 类型)..."
    mtg_secret=$("$MTG_INSTALL_PATH" generate-secret --hex "$mtg_domain")
    if [ -z "$mtg_secret" ] || [[ "$mtg_secret" != ee* ]]; then
        _log_error "MTProto 密钥生成失败或格式不正确 (需要 'ee' 开头)。输出: $mtg_secret"
        return 1
    fi
    _log_success "MTProto 密钥已生成。"
    _log_debug "正在创建 MTProto 配置文件: $MTG_CONFIG_FILE"
    cat >"$MTG_CONFIG_FILE" <<EOF
# MTProto proxy (mtg) configuration file
# Generated by ${SCRIPT_COMMAND_NAME} v${SCRIPT_VERSION} on $(date)
secret = "${mtg_secret}"
bind-to = "0.0.0.0:${mtg_port}"
EOF
    _log_success "MTProto 配置文件已创建。"
    echo "MTG_PORT='${mtg_port}'" >"$MTG_VARS_FILE"
    echo "MTG_SECRET='${mtg_secret}'" >>"$MTG_VARS_FILE"
    return 0
}

_create_mtg_service_file() {
    _log_debug "创建 MTProto 服务文件..."
    local current_service_name_val=""
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        current_service_name_val="$MTG_SERVICE_NAME_SYSTEMD"
        _log_debug "创建 systemd 服务: $current_service_name_val"
        cat >"/etc/systemd/system/$current_service_name_val" <<EOF
[Unit]
Description=MTProto Proxy Server (mtg) by ${SCRIPT_COMMAND_NAME}
Documentation=https://github.com/9seconds/mtg
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${MTG_INSTALL_PATH} run ${MTG_CONFIG_FILE}
Restart=always
RestartSec=3
StandardOutput=append:${LOG_FILE_MTG_OUT}
StandardError=append:${LOG_FILE_MTG_ERR}
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        chmod 644 "/etc/systemd/system/$current_service_name_val"
        $SERVICE_CMD_SYSTEMCTL daemon-reload 2>/dev/null
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        current_service_name_val="$MTG_SERVICE_NAME_OPENRC"
        _log_debug "创建 OpenRC 服务: $current_service_name_val"
        cat >"/etc/init.d/$current_service_name_val" <<EOF
#!/sbin/openrc-run
name="$MTG_SERVICE_NAME_OPENRC"
command="$MTG_INSTALL_PATH"
command_args="run $MTG_CONFIG_FILE"
pidfile="/var/run/\${name}.pid"
command_background="yes"
output_log="$LOG_FILE_MTG_OUT"
error_log="$LOG_FILE_MTG_ERR"
depend() { need net; after firewall; }
start_pre() { checkpath -f "\$output_log" -m 0644; checkpath -f "\$error_log" -m 0644; }
start() { ebegin "Starting \$name"; start-stop-daemon --start --quiet --background --make-pidfile --pidfile "\$pidfile" --stdout "\$output_log" --stderr "\$error_log" --exec "\$command" -- \$command_args; eend \$?; }
stop() { ebegin "Stopping \$name"; start-stop-daemon --stop --quiet --pidfile "\$pidfile"; eend \$?; }
EOF
        chmod +x "/etc/init.d/$current_service_name_val"
    fi
    _log_success "MTProto 服务文件创建成功。"
}

_get_mtg_link_info() {
    MTG_LINK_VAR=""
    if [ ! -f "$MTG_CONFIG_FILE" ]; then
        _log_error "MTG 配置文件 $MTG_CONFIG_FILE 未找到。"
        return 1
    fi
    if ! command -v "$MTG_INSTALL_PATH" &>/dev/null; then
        _log_error "MTG 程序 $MTG_INSTALL_PATH 未找到。"
        return 1
    fi
    _log_debug "正在从 $MTG_CONFIG_FILE 和 MTG 程序获取连接信息..."
    local mtg_access_json
    mtg_access_json=$("$MTG_INSTALL_PATH" access "$MTG_CONFIG_FILE" 2>/dev/null)
    if [ -z "$mtg_access_json" ]; then
        _log_warning "执行 'mtg access' 命令失败或无输出。尝试手动构造..."
        if [ -f "$MTG_VARS_FILE" ]; then
            local mtg_port_val mtg_secret_val
            mtg_port_val=$(grep '^MTG_PORT=' "$MTG_VARS_FILE" | cut -d"'" -f2)
            mtg_secret_val=$(grep '^MTG_SECRET=' "$MTG_VARS_FILE" | cut -d"'" -f2)
            local server_ip=$(_get_server_address | tr -d '[]')
            if [ -n "$server_ip" ] && [ -n "$mtg_port_val" ] && [ -n "$mtg_secret_val" ]; then
                MTG_LINK_VAR="tg://proxy?server=${server_ip}&port=${mtg_port_val}&secret=${mtg_secret_val}"
                _log_debug "手动构造的 MTG 链接: $MTG_LINK_VAR"
                return 0
            fi
        fi
        _log_error "无法构造 MTG 链接。"
        return 1
    fi

    MTG_LINK_VAR=$(echo "$mtg_access_json" | tr -d '\n\r ' | grep -o '"ipv4":{[^}]*"tg_url":"[^"]*' | grep -o '"tg_url":"[^"]*' | sed -e 's/"tg_url":"//' -e 's/"//')
    if [ -z "$MTG_LINK_VAR" ]; then
        MTG_LINK_VAR=$(echo "$mtg_access_json" | tr -d '\n\r ' | grep -o '"ipv6":{[^}]*"tg_url":"[^"]*' | grep -o '"tg_url":"[^"]*' | sed -e 's/"tg_url":"//' -e 's/"//')
    fi
    if [ -z "$MTG_LINK_VAR" ]; then
        MTG_LINK_VAR=$(echo "$mtg_access_json" | grep -o '"tg_url":"[^"]*"' | head -n 1 | sed -e 's/"tg_url":"//' -e 's/"//g' -e 's/\\//g')
    fi
    if [ -z "$MTG_LINK_VAR" ]; then
        _log_error "无法从 'mtg access' 输出中解析 tg_url。"
        return 1
    fi
    return 0
}

_display_mtg_link() {
    if [ -z "$MTG_LINK_VAR" ]; then
        _log_error "MTG 链接为空。"
        return 1
    fi
    echo ""
    _log_info "MTProto 订阅链接:"
    echo -e "${GREEN}${MTG_LINK_VAR}${NC}"
    echo ""
}

_show_mtg_link() {
    _detect_os
    if ! _is_mtg_installed; then
        _log_error "MTProto 代理 (mtg) 未安装。"
        return 1
    fi
    if ! _get_mtg_link_info; then
        _log_error "无法获取 MTProto 链接信息。"
        return 1
    fi
    _display_mtg_link
}

_do_install_mtg() {
    _ensure_root
    _detect_os
    if _is_mtg_installed; then
        _read_confirm_tty confirm_mtg_install "MTProto 代理 (mtg) 已安装。是否强制安装(覆盖配置)? [y/N]: "
        if [[ "$confirm_mtg_install" != "y" && "$confirm_mtg_install" != "Y" ]]; then
            _log_info "MTProto 安装取消。"
            return 0
        fi
        _log_warning "正强制安装 MTProto (mtg)..."
    fi

    _log_info "--- 开始 MTProto 依赖安装 ---"
    _install_dependencies
    _log_info "--- MTProto 依赖安装结束 ---"

    if _is_mtg_installed; then
        _log_info "准备更新 MTG 二进制，将先停止现有服务..."
        _control_service "stop"
        sleep 1
    fi
    if ! _download_mtg_binary "$MTG_TARGET_VERSION"; then
        _log_error "MTG 下载失败，安装中止。"
        return 1
    fi
    if ! _generate_mtg_config; then
        _log_error "生成 MTG 配置失败。"
        return 1
    fi
    _create_mtg_service_file
    _control_service "enable"
    _log_info "准备启动/重启 MTG 服务..."
    _control_service "restart"
    sleep 2
    if _control_service "status" >/dev/null; then
        _log_success "MTProto 服务已成功运行！"
    else
        _log_error "MTProto 服务状态异常!"
    fi
    _setup_command
    _log_success "MTProto 安装配置完成！"
    echo "------------------------------------------------------------------------"
    _show_mtg_link
    echo "------------------------------------------------------------------------"
}

_do_uninstall_mtg() {
    _ensure_root
    _detect_os
    if ! _is_mtg_installed; then
        _log_info "MTProto 未安装或未完全安装。跳过卸载。"
        return 0
    fi

    _read_confirm_tty confirm_uninstall "这将卸载 MTProto (mtg) 并删除所有相关配置和文件。确定? [y/N]: "
    if [[ "$confirm_uninstall" != "y" && "$confirm_uninstall" != "Y" ]]; then
        _log_info "MTProto 卸载取消。"
        return 0
    fi

    _log_info "正在卸载 MTProto (mtg)..."
    _log_info "停止 MTG 服务..."
    _control_service "stop"

    local current_service_name_val=""
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        current_service_name_val="$MTG_SERVICE_NAME_SYSTEMD"
        _log_debug "禁用 MTG systemd 服务..."
        "$SERVICE_CMD_SYSTEMCTL" disable "$current_service_name_val" >/dev/null 2>/dev/null || true
        _log_debug "移除 MTG systemd 服务文件..."
        rm -f "/etc/systemd/system/$current_service_name_val"
        find /etc/systemd/system/ -name "$current_service_name_val" -delete 2>/dev/null
        "$SERVICE_CMD_SYSTEMCTL" daemon-reload 2>/dev/null
        "$SERVICE_CMD_SYSTEMCTL" reset-failed "$current_service_name_val" >/dev/null 2>/dev/null || true
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        current_service_name_val="$MTG_SERVICE_NAME_OPENRC"
        _log_debug "移除 MTG OpenRC 服务..."
        rc-update del "$current_service_name_val" default >/dev/null 2>&1 || true
        _log_debug "移除 MTG OpenRC 脚本..."
        rm -f "/etc/init.d/$current_service_name_val"
    fi

    _log_debug "移除 MTG 二进制: $MTG_INSTALL_PATH"
    rm -f "$MTG_INSTALL_PATH"
    _log_debug "移除 MTG 配置: $MTG_CONFIG_DIR"
    rm -rf "$MTG_CONFIG_DIR"
    _log_debug "移除 MTG 日志: $LOG_FILE_MTG_OUT, $LOG_FILE_MTG_ERR"
    rm -f "$LOG_FILE_MTG_OUT" "$LOG_FILE_MTG_ERR"
    _log_debug "移除 MTG 变量文件: $MTG_VARS_FILE"
    rm -f "$MTG_VARS_FILE"
    _log_success "MTProto 卸载完成。"
}

_show_menu() {
    clear
    _log_info "===================== ${SCRIPT_COMMAND_NAME} 管理菜单 ====================="
    echo "1. 安装/重装 MTProto (mtg)"
    echo "2. 启动 MTProto 服务"
    echo "3. 停止 MTProto 服务"
    echo "4. 重启 MTProto 服务"
    echo "5. 查看 MTProto 服务状态"
    echo "6. 显示 MTProto 订阅链接"
    echo "7. 卸载 MTProto (mtg)"
    echo "0. 退出"
    echo "==========================================================================="
}

_menu_loop() {
    while true; do
        _show_menu
        _read_from_tty menu_selection "请选择 [0-7]: "
        case "$menu_selection" in
            1)
                _do_install_mtg
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
                _show_mtg_link
                ;;
            7)
                _do_uninstall_mtg
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
