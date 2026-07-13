#!/bin/bash
# ============================================================
#  VPS 入站端口管理脚本 - Port Manager for Linux VPS
#  适配: Ubuntu/Debian/CentOS/RHEL/Fedora/Arch/Alpine 等
#  功能: 交互式管理入站端口、修改SSH端口、快捷启动
# ============================================================

set +e

# ==================== 全局变量 ====================
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
BACKUP_DIR="/tmp/port-manager-backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ==================== 工具函数 ====================

print_banner() {
    clear
    echo -e "${CYAN}"
    cat << 'EOF'
╔═══════════════════════════════════════════════╗
║        🛡️  VPS 端口管理工具  🛡️              ║
║         Port Manager for Linux VPS            ║
╚═══════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

# 检测 root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[错误] 此脚本需要 root 权限运行！${NC}"
        echo -e "${YELLOW}请使用: sudo $0${NC}"
        exit 1
    fi
}

# 检测包管理器
detect_pkg_manager() {
    if command -v apt-get &>/dev/null; then
        PKG_MGR="apt-get"
        PKG_INSTALL="apt-get install -y"
        PKG_UPDATE="apt-get update -y"
    elif command -v dnf &>/dev/null; then
        PKG_MGR="dnf"
        PKG_INSTALL="dnf install -y"
        PKG_UPDATE="dnf makecache -y"
    elif command -v yum &>/dev/null; then
        PKG_MGR="yum"
        PKG_INSTALL="yum install -y"
        PKG_UPDATE="yum makecache -y"
    elif command -v pacman &>/dev/null; then
        PKG_MGR="pacman"
        PKG_INSTALL="pacman -S --noconfirm"
        PKG_UPDATE="pacman -Sy --noconfirm"
    elif command -v apk &>/dev/null; then
        PKG_MGR="apk"
        PKG_INSTALL="apk add --no-cache"
        PKG_UPDATE="apk update"
    elif command -v zypper &>/dev/null; then
        PKG_MGR="zypper"
        PKG_INSTALL="zypper install -y"
        PKG_UPDATE="zypper refresh"
    else
        PKG_MGR="unknown"
    fi
}

# 检测防火墙类型
detect_firewall() {
    # 优先检测 ufw
    if command -v ufw &>/dev/null; then
        FIREWALL="ufw"
    elif command -v firewall-cmd &>/dev/null; then
        FIREWALL="firewalld"
    elif command -v iptables &>/dev/null; then
        # 检测 nftables 后端
        if command -v nft &>/dev/null && nft list ruleset &>/dev/null 2>&1; then
            # 如果 nftables 有规则，优先使用 nftables
            FIREWALL="nftables"
        else
            FIREWALL="iptables"
        fi
    elif command -v nft &>/dev/null; then
        FIREWALL="nftables"
    else
        FIREWALL="none"
    fi
}

# 检测 init 系统
detect_init_system() {
    if command -v systemctl &>/dev/null; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service &>/dev/null; then
        INIT_SYSTEM="openrc"
    else
        INIT_SYSTEM="sysvinit"
    fi
}

# 检测 SSH 服务名
detect_ssh_service() {
    # 优先检查实际运行中的 ssh 服务
    if systemctl is-active ssh &>/dev/null 2>&1; then
        SSH_SERVICE="ssh"
    elif systemctl is-active sshd &>/dev/null 2>&1; then
        SSH_SERVICE="sshd"
    elif systemctl is-active ssh.service &>/dev/null 2>&1; then
        SSH_SERVICE="ssh"
    elif systemctl is-active sshd.service &>/dev/null 2>&1; then
        SSH_SERVICE="sshd"
    # 检查已安装的服务文件
    elif systemctl list-unit-files 2>/dev/null | grep -qE "^ssh\.service"; then
        SSH_SERVICE="ssh"
    elif systemctl list-unit-files 2>/dev/null | grep -qE "^sshd\.service"; then
        SSH_SERVICE="sshd"
    elif [[ -f /lib/systemd/system/ssh.service ]] || [[ -f /etc/systemd/system/ssh.service ]]; then
        SSH_SERVICE="ssh"
    elif [[ -f /lib/systemd/system/sshd.service ]] || [[ -f /etc/systemd/system/sshd.service ]]; then
        SSH_SERVICE="sshd"
    else
        # 兜底：尝试所有可能的名字
        for svc in ssh sshd; do
            if systemctl status "$svc" &>/dev/null 2>&1; then
                SSH_SERVICE="$svc"
                return
            fi
        done
        SSH_SERVICE="ssh"
    fi
}

# 检测 SSH 配置文件
detect_ssh_config() {
    if [[ -f /etc/ssh/sshd_config ]]; then
        SSH_CONFIG="/etc/ssh/sshd_config"
    elif [[ -f /etc/ssh/sshd_config.d/00-default.conf ]]; then
        SSH_CONFIG="/etc/ssh/sshd_config.d/00-default.conf"
    else
        SSH_CONFIG="/etc/ssh/sshd_config"
    fi
}

# 确保防火墙工具安装
ensure_firewall_tools() {
    detect_firewall
    detect_pkg_manager

    if [[ "$FIREWALL" == "none" ]]; then
        echo -e "${YELLOW}[提示] 未检测到防火墙工具，正在安装...${NC}"
        case "$PKG_MGR" in
            apt-get)
                $PKG_UPDATE
                $PKG_INSTALL ufw iptables
                ;;
            dnf|yum)
                $PKG_INSTALL firewalld iptables
                ;;
            pacman)
                $PKG_INSTALL ufw iptables
                ;;
            apk)
                $PKG_INSTALL iptables
                ;;
            zypper)
                $PKG_INSTALL firewalld iptables
                ;;
        esac
        detect_firewall
    fi
}

# 确保已安装依赖
ensure_dependencies() {
    detect_pkg_manager
    echo -e "${BLUE}[信息] 检测到包管理器: $PKG_MGR${NC}"

    # 检测并安装缺失的依赖
    local need_install=0
    local deps=()

    if ! command -v iptables &>/dev/null; then
        deps+=("iptables")
        need_install=1
    fi

    if ! command -v ss &>/dev/null && ! command -v netstat &>/dev/null; then
        if [[ "$PKG_MGR" == "apt-get" ]]; then
            deps+=("iproute2")
        elif [[ "$PKG_MGR" == "apk" ]]; then
            deps+=("iproute2")
        else
            deps+=("iproute")
        fi
        need_install=1
    fi

    if [[ $need_install -eq 1 ]]; then
        echo -e "${YELLOW}[提示] 安装缺失依赖: ${deps[*]}${NC}"
        $PKG_UPDATE 2>/dev/null || true
        for dep in "${deps[@]}"; do
            $PKG_INSTALL "$dep" 2>/dev/null || true
        done
    fi
}

# ==================== 防火墙操作层 ====================

# 获取当前已开放端口
get_open_ports() {
    case "$FIREWALL" in
        ufw)
            ufw status numbered 2>/dev/null | grep -E "^\[" | awk -F']' '{print $2}' | awk '{print $1, $2}' | sort -u
            ;;
        firewalld)
            firewall-cmd --list-ports 2>/dev/null | tr ' ' '\n' | sort -u
            firewall-cmd --list-services 2>/dev/null | tr ' ' '\n' | sort -u
            ;;
        nftables)
            nft list ruleset 2>/dev/null | grep -oP 'dport \K[0-9]+' | sort -u
            ;;
        iptables)
            iptables -L INPUT -n 2>/dev/null | grep -E "dpt:" | awk -F'dpt:' '{print $2}' | awk '{print $1}' | sort -u
            ;;
    esac
}

# 开放端口
open_port() {
    local port=$1
    local proto=${2:-tcp}

    case "$FIREWALL" in
        ufw)
            ufw allow ${port}/${proto} 2>/dev/null
            ;;
        firewalld)
            firewall-cmd --permanent --add-port=${port}/${proto} 2>/dev/null
            firewall-cmd --reload 2>/dev/null
            ;;
        nftables)
            # 添加到 nftables input 链
            nft add rule inet filter input ${proto} dport ${port} accept 2>/dev/null || \
                nft add rule ip filter input ${proto} dport ${port} accept 2>/dev/null
            ;;
        iptables)
            iptables -I INPUT -p ${proto} --dport ${port} -j ACCEPT 2>/dev/null
            # 尝试持久化
            if command -v iptables-save &>/dev/null; then
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
                iptables-save > /etc/iptables.rules 2>/dev/null || true
            fi
            ;;
    esac
}

# 关闭端口
close_port() {
    local port=$1
    local proto=${2:-tcp}

    case "$FIREWALL" in
        ufw)
            # 查找并删除规则
            ufw status numbered 2>/dev/null | grep -E "^\[" | while read -r line; do
                if echo "$line" | grep -qw "$port"; then
                    local num=$(echo "$line" | awk -F']' '{print $1}' | tr -d '[' | xargs)
                    [[ -n "$num" ]] && yes | ufw delete "$num" 2>/dev/null
                fi
            done
            ;;
        firewalld)
            firewall-cmd --permanent --remove-port=${port}/${proto} 2>/dev/null
            firewall-cmd --reload 2>/dev/null
            ;;
        nftables)
            # 删除匹配该端口的规则
            local handle
            handle=$(nft -a list ruleset 2>/dev/null | grep "dport ${port}" | grep -oP 'handle \K[0-9]+' | head -1)
            if [[ -n "$handle" ]]; then
                nft delete rule inet filter input handle ${handle} 2>/dev/null || \
                    nft delete rule ip filter input handle ${handle} 2>/dev/null
            fi
            ;;
        iptables)
            iptables -D INPUT -p ${proto} --dport ${port} -j ACCEPT 2>/dev/null
            iptables -D INPUT -p ${proto} --dport ${port} -j DROP 2>/dev/null
            if command -v iptables-save &>/dev/null; then
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
                iptables-save > /etc/iptables.rules 2>/dev/null || true
            fi
            ;;
    esac
}

# 查看防火墙状态
show_firewall_status() {
    echo -e "\n${BOLD}=== 防火墙状态 ($FIREWALL) ===${NC}\n"
    case "$FIREWALL" in
        ufw)
            ufw status verbose 2>/dev/null
            ;;
        firewalld)
            echo -e "${BOLD}区域:${NC} $(firewall-cmd --get-active-zones 2>/dev/null | head -1)"
            echo -e "${BOLD}已开放端口:${NC}"
            firewall-cmd --list-ports 2>/dev/null | tr ' ' '\n' | while read -r p; do
                [[ -n "$p" ]] && echo -e "  ${GREEN}●${NC} $p"
            done
            echo -e "${BOLD}已开放服务:${NC}"
            firewall-cmd --list-services 2>/dev/null | tr ' ' '\n' | while read -s; do
                [[ -n "$s" ]] && echo -e "  ${GREEN}●${NC} $s"
            done
            ;;
        nftables)
            nft list ruleset 2>/dev/null
            ;;
        iptables)
            iptables -L INPUT -n -v --line-numbers 2>/dev/null
            ;;
    esac
    echo ""
}

# ==================== SSH 端口管理 ====================

# 获取当前 SSH 端口
get_ssh_port() {
    local config_file=$(detect_ssh_config_path)
    local port=$(grep -E "^#?Port " "$config_file" 2>/dev/null | tail -1 | awk '{print $2}')
    if [[ -z "$port" ]]; then
        port=22
    fi
    echo "$port"
}

detect_ssh_config_path() {
    # 优先检查主配置文件
    local main_config="/etc/ssh/sshd_config"

    # 检查主配置文件是否有 Port 行（非注释）
    if [[ -f "$main_config" ]] && grep -qE "^Port " "$main_config" 2>/dev/null; then
        echo "$main_config"
        return
    fi

    # 检查 include 目录下的配置
    if [[ -d /etc/ssh/sshd_config.d ]]; then
        for f in /etc/ssh/sshd_config.d/*.conf; do
            if [[ -f "$f" ]] && grep -qE "^#?Port " "$f" 2>/dev/null; then
                echo "$f"
                return
            fi
        done
    fi

    # 默认写入主配置文件
    echo "$main_config"
}

# 修改 SSH 端口
change_ssh_port() {
    local new_port=$1
    local current_port=${2:-$(get_ssh_port)}
    local config_file=$(detect_ssh_config_path)

    echo -e "${BLUE}[信息] 当前 SSH 端口: ${current_port}${NC}"
    echo -e "${BLUE}[信息] 配置文件: ${config_file}${NC}"
    echo -e "${BLUE}[信息] 新 SSH 端口: ${new_port}${NC}"

    # 备份配置
    mkdir -p "$BACKUP_DIR"
    cp "$config_file" "$BACKUP_DIR/sshd_config_${TIMESTAMP}.bak"
    echo -e "${GREEN}[成功] 已备份原配置到 $BACKUP_DIR/sshd_config_${TIMESTAMP}.bak${NC}"

    # 检查主配置文件中是否有 Include sshd_config.d 行
    # 如果有，确保在 include 目录的文件中也设置端口
    local main_has_include=false
    if [[ -f /etc/ssh/sshd_config ]] && grep -qE "^Include /etc/ssh/sshd_config.d" /etc/ssh/sshd_config 2>/dev/null; then
        main_has_include=true
    fi

    # 检查配置文件中是否已有 Port 行
    if grep -qE "^#?Port " "$config_file"; then
        # 替换现有的 Port 行（包括被注释的）
        sed -i -E "s/^#?Port .*/Port ${new_port}/" "$config_file"
    else
        # 添加 Port 行
        echo "Port ${new_port}" >> "$config_file"
    fi

    # 如果主配置有 Include 但修改的是主文件，也尝试在 include 目录写入
    if [[ "$main_has_include" == "true" ]] && [[ "$config_file" == "/etc/ssh/sshd_config" ]]; then
        mkdir -p /etc/ssh/sshd_config.d 2>/dev/null
        local override_file="/etc/ssh/sshd_config.d/99-port.conf"
        echo "Port ${new_port}" > "$override_file"
        chmod 644 "$override_file"
        echo -e "${BLUE}[信息] 已写入 ${override_file}（Include 覆盖）${NC}"
    fi

    # 在防火墙中开放新端口
    echo -e "${YELLOW}[提示] 在防火墙中开放新 SSH 端口 ${new_port}...${NC}"
    open_port "$new_port" "tcp"
    open_port "$new_port" "udp"

    # 旧端口暂时保持开放，等新端口验证通过后再关闭
    echo -e "${YELLOW}[提示] 旧端口 ${current_port} 暂时保持开放，新端口验证通过后自动关闭。${NC}"

    # 验证配置
    echo -e "${BLUE}[信息] 验证 SSH 配置...${NC}"
    local sshd_cmd=""
    if command -v sshd &>/dev/null; then
        sshd_cmd="sshd"
    elif [[ -f /usr/sbin/sshd ]]; then
        sshd_cmd="/usr/sbin/sshd"
    fi

    if [[ -n "$sshd_cmd" ]]; then
        local validate_output
        validate_output=$($sshd_cmd -t 2>&1)
        local validate_rc=$?
        if [[ $validate_rc -eq 0 ]]; then
            echo -e "${GREEN}[成功] SSH 配置验证通过${NC}"
        else
            echo -e "${RED}[错误] SSH 配置验证失败！${NC}"
            echo -e "${RED}详情: ${validate_output}${NC}"
            echo -e "${YELLOW}[提示] 正在回滚配置...${NC}"
            cp "$BACKUP_DIR/sshd_config_${TIMESTAMP}.bak" "$config_file"
            # 清理可能创建的 override 文件
            rm -f /etc/ssh/sshd_config.d/99-port.conf 2>/dev/null || true
            echo -e "${YELLOW}[提示] 已回滚配置。${NC}"
            return 1
        fi
    else
        echo -e "${YELLOW}[警告] 未找到 sshd，跳过配置验证${NC}"
    fi

    # 重启 SSH 服务
    echo -e "${YELLOW}[提示] 重启 SSH 服务...${NC}"
    detect_ssh_service
    detect_init_system

    local restart_output=""
    local restart_rc=1

    # 关闭 set -e 的影响，显式处理错误
    case "$INIT_SYSTEM" in
        systemd)
            # 尝试多种服务名
            for svc in "$SSH_SERVICE" sshd ssh; do
                restart_output=$(systemctl restart "$svc" 2>&1)
                restart_rc=$?
                if [[ $restart_rc -eq 0 ]]; then
                    echo -e "${GREEN}[成功] 已通过 systemctl restart $svc 重启 SSH${NC}"
                    break
                fi
            done
            ;;
        openrc)
            for svc in sshd ssh; do
                restart_output=$(rc-service "$svc" restart 2>&1)
                restart_rc=$?
                if [[ $restart_rc -eq 0 ]]; then
                    echo -e "${GREEN}[成功] 已通过 rc-service $svc restart 重启 SSH${NC}"
                    break
                fi
            done
            ;;
        *)
            for svc in sshd ssh; do
                restart_output=$(service "$svc" restart 2>&1)
                restart_rc=$?
                if [[ $restart_rc -eq 0 ]]; then
                    echo -e "${GREEN}[成功] 已通过 service $svc restart 重启 SSH${NC}"
                    break
                fi
            done
            if [[ $restart_rc -ne 0 ]]; then
                restart_output=$(/etc/init.d/sshd restart 2>&1)
                restart_rc=$?
            fi
            ;;
    esac

    if [[ $restart_rc -eq 0 ]]; then
        echo -e "${GREEN}[成功] SSH 服务已重启${NC}"
    else
        echo -e "${RED}[错误] SSH 服务重启失败！${NC}"
        echo -e "${RED}详情: ${restart_output}${NC}"
        echo -e "${YELLOW}[提示] 配置已修改但服务未重启，请手动检查:${NC}"
        echo -e "  systemctl status sshd"
        echo -e "  journalctl -u sshd -n 20"
        return 1
    fi

    # 检查 SELinux 是否可能阻止（CentOS/RHEL）
    if command -v getenforce &>/dev/null; then
        local selinux_state=$(getenforce 2>/dev/null)
        if [[ "$selinux_state" == "Enforcing" ]]; then
            echo -e "${YELLOW}[提示] 检测到 SELinux 处于 Enforcing 状态${NC}"
            echo -e "${YELLOW}  需要为新端口添加 SELinux 策略:${NC}"
            echo -e "  ${CYAN}semanage port -a -t ssh_port_t -p tcp ${new_port}${NC}"
            echo -e "${YELLOW}  如果 semanage 不可用，安装 policycoreutils-python-utils${NC}"
            # 尝试自动添加
            if command -v semanage &>/dev/null; then
                semanage port -a -t ssh_port_t -p tcp ${new_port} 2>/dev/null || \
                    semanage port -m -t ssh_port_t -p tcp ${new_port} 2>/dev/null || true
                echo -e "${GREEN}[成功] 已添加 SELinux 端口策略${NC}"
            fi
        fi
    fi

    # 验证新端口是否在监听
    sleep 2
    local port_listening=false
    if command -v ss &>/dev/null; then
        local listening=$(ss -tlnp 2>/dev/null | grep ":${new_port}" | head -1)
        if [[ -n "$listening" ]]; then
            echo -e "${GREEN}[成功] 新 SSH 端口 ${new_port} 已在监听${NC}"
            port_listening=true
        else
            echo -e "${RED}[错误] 未检测到端口 ${new_port} 在监听！${NC}"
            echo -e "${YELLOW}旧端口 ${current_port} 保持开放，不会关闭。${NC}"
            echo -e "${YELLOW}请检查 SSH 日志: journalctl -u sshd -n 20${NC}"
            return 1
        fi
    fi

    # 新端口验证通过，自动关闭旧端口
    if [[ "$port_listening" == "true" && "$current_port" != "$new_port" ]]; then
        echo -e "${YELLOW}[提示] 正在关闭旧端口 ${current_port}...${NC}"
        close_port "$current_port" "tcp"
        close_port "$current_port" "udp"
        echo -e "${GREEN}[成功] 旧端口 ${current_port} 已关闭${NC}"
    fi

    echo -e "${GREEN}[成功] SSH 端口已修改为 ${new_port}，旧端口已关闭${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}⚠️  重要提醒:${NC}"
    echo -e "${YELLOW}1. 当前连接不会立即断开，但重连需使用新端口${NC}"
    echo -e "${YELLOW}2. 连接命令: ssh -p ${new_port} 用户名@服务器IP${NC}"
    echo -e "${YELLOW}3. 如需还原，编辑 /etc/ssh/sshd_config 恢复 Port ${current_port}${NC}"
    echo -e "${YELLOW}========================================${NC}"
}

# ==================== 端口扫描 ====================

# 显示监听中的端口
show_listening_ports() {
    echo -e "\n${BOLD}=== 当前监听端口 ===${NC}\n"
    printf "%-10s %-10s %-20s %-10s\n" "协议" "端口" "监听地址" "进程"
    echo "--------------------------------------------------"

    if command -v ss &>/dev/null; then
        ss -tulnp 2>/dev/null | grep LISTEN | awk '{
            proto=$1
            local=$5
            proc=$7
            # 提取端口
            n=split(local, a, ":")
            port=a[n]
            # 提取进程名
            if (match(proc, /users:\(\("([^"]+)"/, m)) {
                procname=m[1]
            } else {
                procname="-"
            }
            printf "%-10s %-10s %-20s %-10s\n", proto, port, local, procname
        }' | sort -t' ' -k2 -n
    elif command -v netstat &>/dev/null; then
        netstat -tulnp 2>/dev/null | grep LISTEN | awk '{
            proto=$1
            local=$4
            proc=$7
            n=split(local, a, ":")
            port=a[n]
            if (match(proc, /[0-9]+\/(.+)/, m)) {
                procname=m[1]
            } else {
                procname="-"
            }
            printf "%-10s %-10s %-20s %-10s\n", proto, port, local, procname
        }' | sort -t' ' -k2 -n
    else
        echo -e "${RED}[错误] ss 和 netstat 均不可用${NC}"
    fi
    echo ""
}

# ==================== 菜单系统 ====================

show_main_menu() {
    print_banner

    detect_firewall
    detect_init_system
    local ssh_port=$(get_ssh_port)

    echo -e "${BOLD}系统信息:${NC}"
    echo -e "  ${CYAN}操作系统:${NC} $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2 || echo 'Unknown')"
    echo -e "  ${CYAN}防火墙:${NC}   $FIREWALL"
    echo -e "  ${CYAN}SSH端口:${NC}   $ssh_port"
    echo -e "  ${CYAN}Init系统:${NC}  $INIT_SYSTEM"
    echo ""

    echo -e "${BOLD}========== 主菜单 ==========${NC}"
    echo -e "${GREEN} 1)${NC} 查看防火墙状态"
    echo -e "${GREEN} 2)${NC} 查看监听端口"
    echo -e "${GREEN} 3)${NC} 开放端口"
    echo -e "${GREEN} 4)${NC} 关闭端口"
    echo -e "${GREEN} 5)${NC} 批量开放端口"
    echo -e "${GREEN} 6)${NC} 修改 SSH 端口"
    echo -e "${GREEN} 7)${NC} 一键放行常用端口"
    echo -e "${GREEN} 8)${NC} 重置防火墙"
    echo -e "${GREEN} 9)${NC} 安装/卸载快捷命令"
    echo -e "${RED}10)${NC} 卸载脚本"
    echo -e "${RED} 0)${NC} 退出"
    echo -e "${BOLD}============================${NC}"
    echo ""
    read -p "请选择 [0-10]: " choice

    case $choice in
        1) show_firewall_status; press_enter ;;
        2) show_listening_ports; press_enter ;;
        3) menu_open_port ;;
        4) menu_close_port ;;
        5) menu_batch_open ;;
        6) menu_change_ssh_port ;;
        7) menu_open_common_ports ;;
        8) menu_reset_firewall ;;
        9) menu_setup_shortcut ;;
        10) menu_uninstall_script ;;
        0) echo -e "${GREEN}再见！${NC}"; exit 0 ;;
        *) echo -e "${RED}无效选择${NC}"; sleep 1; show_main_menu ;;
    esac
}

press_enter() {
    echo ""
    read -p "按回车键返回主菜单..."
    show_main_menu
}

menu_open_port() {
    echo -e "\n${BOLD}=== 开放端口 ===${NC}"
    read -p "请输入端口号 (1-65535): " port
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 || "$port" -gt 65535 ]]; then
        echo -e "${RED}[错误] 无效端口号${NC}"
        sleep 1; show_main_menu; return
    fi

    echo -e "选择协议:"
    echo -e "  ${GREEN}1)${NC} TCP"
    echo -e "  ${GREEN}2)${NC} UDP"
    echo -e "  ${GREEN}3)${NC} TCP+UDP"
    read -p "选择 [1-3] (默认1): " proto_choice

    case $proto_choice in
        2) proto="udp";;
        3) proto="both";;
        *) proto="tcp";;
    esac

    echo -e "${YELLOW}[提示] 正在开放端口 ${port}/${proto}...${NC}"

    if [[ "$proto" == "both" ]]; then
        open_port "$port" "tcp"
        open_port "$port" "udp"
    else
        open_port "$port" "$proto"
    fi

    echo -e "${GREEN}[成功] 端口 ${port} 已开放${NC}"
    press_enter
}

menu_close_port() {
    echo -e "\n${BOLD}=== 关闭端口 ===${NC}"

    # 显示当前开放端口
    echo -e "${BLUE}当前防火墙规则:${NC}"
    get_open_ports 2>/dev/null || echo "  (无)"

    echo ""
    read -p "请输入要关闭的端口号: " port
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}[错误] 无效端口号${NC}"
        sleep 1; show_main_menu; return
    fi

    echo -e "选择协议:"
    echo -e "  ${GREEN}1)${NC} TCP"
    echo -e "  ${GREEN}2)${NC} UDP"
    echo -e "  ${GREEN}3)${NC} TCP+UDP"
    read -p "选择 [1-3] (默认1): " proto_choice

    case $proto_choice in
        2) proto="udp";;
        3) proto="both";;
        *) proto="tcp";;
    esac

    # 安全检查：防止关闭当前 SSH 端口
    local ssh_port=$(get_ssh_port)
    if [[ "$port" == "$ssh_port" ]]; then
        echo -e "${RED}[警告] 这可能是当前 SSH 端口！关闭后可能断开连接！${NC}"
        read -p "确定要继续吗？(y/N): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo -e "${YELLOW}[提示] 已取消${NC}"
            press_enter; return
        fi
    fi

    if [[ "$proto" == "both" ]]; then
        close_port "$port" "tcp"
        close_port "$port" "udp"
    else
        close_port "$port" "$proto"
    fi

    echo -e "${GREEN}[成功] 端口 ${port} 已关闭${NC}"
    press_enter
}

menu_batch_open() {
    echo -e "\n${BOLD}=== 批量开放端口 ===${NC}"
    echo -e "${YELLOW}输入端口，用空格分隔 (如: 80 443 8080 8443)${NC}"
    read -p "端口列表: " ports

    echo -e "选择协议:"
    echo -e "  ${GREEN}1)${NC} TCP"
    echo -e "  ${GREEN}2)${NC} UDP"
    echo -e "  ${GREEN}3)${NC} TCP+UDP"
    read -p "选择 [1-3] (默认1): " proto_choice

    case $proto_choice in
        2) proto="udp";;
        3) proto="both";;
        *) proto="tcp";;
    esac

    for port in $ports; do
        if [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 && "$port" -le 65535 ]]; then
            if [[ "$proto" == "both" ]]; then
                open_port "$port" "tcp"
                open_port "$port" "udp"
            else
                open_port "$port" "$proto"
            fi
            echo -e "  ${GREEN}●${NC} 端口 ${port} 已开放"
        else
            echo -e "  ${RED}✗${NC} 端口 ${port} 无效，跳过"
        fi
    done

    echo -e "${GREEN}[成功] 批量操作完成${NC}"
    press_enter
}

menu_change_ssh_port() {
    echo -e "\n${BOLD}=== 修改 SSH 端口 ===${NC}"
    local current_port=$(get_ssh_port)
    echo -e "${BLUE}当前 SSH 端口: ${current_port}${NC}"
    echo ""

    read -p "请输入新的 SSH 端口 (1-65535): " new_port
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [[ "$new_port" -lt 1 || "$new_port" -gt 65535 ]]; then
        echo -e "${RED}[错误] 无效端口号${NC}"
        sleep 1; show_main_menu; return
    fi

    if [[ "$new_port" == "$current_port" ]]; then
        echo -e "${YELLOW}[提示] 新端口与当前端口相同${NC}"
        press_enter; return
    fi

    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}即将将 SSH 端口从 ${current_port} 修改为 ${new_port}${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${RED}⚠️  警告:${NC}"
    echo -e "  - 修改后需要使用新端口重新连接"
    echo -e "  - 新端口将自动在防火墙开放"
    echo -e "  - 新端口验证通过后，旧端口 ${current_port} 将自动关闭"
    echo -e "  - 请确保新端口能正常连接后再断开当前连接"
    echo ""

    read -p "确认修改？(y/N): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        change_ssh_port "$new_port" "$current_port"
    else
        echo -e "${YELLOW}[提示] 已取消${NC}"
    fi
    press_enter
}

menu_open_common_ports() {
    echo -e "\n${BOLD}=== 一键放行常用端口 ===${NC}"
    echo -e "  ${GREEN}1)${NC} Web 服务    (80, 443 TCP)"
    echo -e "  ${GREEN}2)${NC} Web + 管理  (80, 443, 8080, 8443 TCP)"
    echo -e "  ${GREEN}3)${NC} 数据库      (3306, 5432, 6379, 27017 TCP)"
    echo -e "  ${GREEN}4)${NC} FTP         (20, 21, 30000-31000 TCP)"
    echo -e "  ${GREEN}5)${NC} 邮件服务    (25, 465, 587, 993, 995 TCP)"
    echo -e "  ${GREEN}6)${NC} DNS         (53 TCP+UDP)"
    echo -e "  ${GREEN}7)${NC} 全部常用    (以上全部)"
    echo -e "  ${GREEN}0)${NC} 返回"
    echo ""
    read -p "请选择 [0-7]: " choice

    local ports_tcp=()
    local ports_udp=()

    case $choice in
        1) ports_tcp=(80 443) ;;
        2) ports_tcp=(80 443 8080 8443) ;;
        3) ports_tcp=(3306 5432 6379 27017) ;;
        4) ports_tcp=(20 21); for p in $(seq 30000 31000); do ports_tcp+=($p); done ;;
        5) ports_tcp=(25 465 587 993 995) ;;
        6) ports_tcp=(53); ports_udp=(53) ;;
        7) ports_tcp=(80 443 8080 8443 3306 5432 6379 27017 20 21 25 465 587 993 995 53)
           ports_udp=(53)
           for p in $(seq 30000 31000); do ports_tcp+=($p); done ;;
        0) show_main_menu; return ;;
        *) echo -e "${RED}无效选择${NC}"; sleep 1; show_main_menu; return ;;
    esac

    echo -e "${YELLOW}[提示] 正在开放端口...${NC}"

    for port in "${ports_tcp[@]}"; do
        open_port "$port" "tcp"
        echo -e "  ${GREEN}●${NC} ${port}/tcp"
    done

    for port in "${ports_udp[@]}"; do
        open_port "$port" "udp"
        echo -e "  ${GREEN}●${NC} ${port}/udp"
    done

    echo -e "${GREEN}[成功] 常用端口已开放${NC}"
    press_enter
}

menu_reset_firewall() {
    echo -e "\n${BOLD}=== 重置防火墙 ===${NC}"
    echo -e "${RED}⚠️  警告: 这将重置所有防火墙规则！${NC}"
    echo -e "${YELLOW}将先备份当前规则。${NC}"
    echo ""

    local ssh_port=$(get_ssh_port)
    echo -e "${BLUE}当前 SSH 端口: ${ssh_port} (将保持开放)${NC}"
    echo ""

    read -p "确认重置防火墙？(y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${YELLOW}[提示] 已取消${NC}"
        press_enter; return
    fi

    # 备份当前规则
    mkdir -p "$BACKUP_DIR"
    case "$FIREWALL" in
        ufw)
            ufw status verbose > "$BACKUP_DIR/ufw_rules_${TIMESTAMP}.bak" 2>/dev/null
            echo -e "${GREEN}[成功] 规则已备份到 $BACKUP_DIR/ufw_rules_${TIMESTAMP}.bak${NC}"
            # 重置
            yes | ufw reset 2>/dev/null
            # 重新启用并开放 SSH 端口
            ufw allow ${ssh_port}/tcp 2>/dev/null
            yes | ufw enable 2>/dev/null
            ;;
        firewalld)
            firewall-cmd --list-all > "$BACKUP_DIR/firewalld_rules_${TIMESTAMP}.bak" 2>/dev/null
            echo -e "${GREEN}[成功] 规则已备份到 $BACKUP_DIR/firewalld_rules_${TIMESTAMP}.bak${NC}"
            firewall-cmd --permanent --add-port=${ssh_port}/tcp 2>/dev/null
            firewall-cmd --reload 2>/dev/null
            ;;
        nftables)
            nft list ruleset > "$BACKUP_DIR/nftables_rules_${TIMESTAMP}.bak" 2>/dev/null
            echo -e "${GREEN}[成功] 规则已备份到 $BACKUP_DIR/nftables_rules_${TIMESTAMP}.bak${NC}"
            nft flush ruleset 2>/dev/null
            # 重建基本规则
            nft add table inet filter 2>/dev/null || true
            nft 'add chain inet filter input { type filter hook input priority 0; policy accept; }' 2>/dev/null || true
            nft add rule inet filter input tcp dport ${ssh_port} accept 2>/dev/null
            ;;
        iptables)
            iptables -L -n -v > "$BACKUP_DIR/iptables_rules_${TIMESTAMP}.bak" 2>/dev/null
            echo -e "${GREEN}[成功] 规则已备份到 $BACKUP_DIR/iptables_rules_${TIMESTAMP}.bak${NC}"
            iptables -F INPUT 2>/dev/null
            iptables -P INPUT ACCEPT 2>/dev/null
            iptables -A INPUT -p tcp --dport ${ssh_port} -j ACCEPT 2>/dev/null
            if command -v iptables-save &>/dev/null; then
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
                iptables-save > /etc/iptables.rules 2>/dev/null || true
            fi
            ;;
    esac

    echo -e "${GREEN}[成功] 防火墙已重置，SSH 端口 ${ssh_port} 保持开放${NC}"
    press_enter
}

# ==================== 快捷命令安装 ====================

menu_setup_shortcut() {
    echo -e "\n${BOLD}=== 安装快捷命令 ===${NC}"
    echo -e "  ${GREEN}1)${NC} 安装快捷命令 (dk)"
    echo -e "  ${GREEN}2)${NC} 卸载快捷命令"
    echo -e "  ${GREEN}0)${NC} 返回"
    echo ""
    read -p "请选择 [0-2]: " choice

    case $choice in
        1) install_shortcut ;;
        2) uninstall_shortcut ;;
        0) show_main_menu; return ;;
        *) echo -e "${RED}无效选择${NC}"; sleep 1; show_main_menu; return ;;
    esac
    press_enter
}

install_shortcut() {
    local shell_rc=""
    local current_shell=$(basename "$SHELL")

    # 检测当前 shell 的 rc 文件
    if [[ "$current_shell" == "bash" ]]; then
        shell_rc="$HOME/.bashrc"
    elif [[ "$current_shell" == "zsh" ]]; then
        shell_rc="$HOME/.zshrc"
    else
        # 默认 bash
        shell_rc="$HOME/.bashrc"
    fi

    # 创建全局快捷命令
    local shortcut_content="# VPS Port Manager 快捷命令\nalias dk='sudo bash ${SCRIPT_PATH}'"

    # 检查是否已安装
    if grep -q "VPS Port Manager" "$shell_rc" 2>/dev/null; then
        echo -e "${YELLOW}[提示] 快捷命令已存在，更新中...${NC}"
        # 删除旧条目
        sed -i '/# VPS Port Manager 快捷命令/d' "$shell_rc" 2>/dev/null
        sed -i "/alias pm='sudo bash ${SCRIPT_PATH}'/d" "$shell_rc" 2>/dev/null
        sed -i "/alias dk='sudo bash ${SCRIPT_PATH}'/d" "$shell_rc" 2>/dev/null
    fi

    # 添加新条目
    echo -e "$shortcut_content" >> "$shell_rc"

    # 也安装到 /usr/local/bin 作为全局命令
    cat > /usr/local/bin/dk << EOF
#!/bin/bash
if [[ \$EUID -ne 0 ]]; then
    echo "正在使用 sudo 重新运行..."
    exec sudo bash ${SCRIPT_PATH}
else
    exec bash ${SCRIPT_PATH}
fi
EOF
    chmod +x /usr/local/bin/dk

    echo -e "${GREEN}[成功] 快捷命令已安装！${NC}"
    echo -e "${BOLD}使用方式:${NC}"
    echo -e "  ${CYAN}dk${NC}          - 直接运行端口管理器"
    echo -e "  ${CYAN}sudo dk${NC}     - 以 root 权限运行"
    echo -e ""
    echo -e "${YELLOW}[提示] 新终端中生效，或执行: source ${shell_rc}${NC}"
}

uninstall_shortcut() {
    # 从 shell rc 文件中删除
    for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
        if [[ -f "$rc" ]]; then
            sed -i '/# VPS Port Manager 快捷命令/d' "$rc" 2>/dev/null
            sed -i "/alias pm='sudo bash ${SCRIPT_PATH}'/d" "$rc" 2>/dev/null
            sed -i "/alias dk='sudo bash ${SCRIPT_PATH}'/d" "$rc" 2>/dev/null
        fi
    done

    # 删除全局命令
    rm -f /usr/local/bin/pm 2>/dev/null || true
    rm -f /usr/local/bin/dk 2>/dev/null || true

    echo -e "${GREEN}[成功] 快捷命令已卸载${NC}"
}

# ==================== 脚本卸载 ====================

menu_uninstall_script() {
    echo -e "\n${BOLD}=== 卸载脚本 ===${NC}"
    echo -e "${RED}⚠️  警告: 将删除以下内容:${NC}"
    echo -e "  - 快捷命令 dk (/usr/local/bin/dk)"
    echo -e "  - shell rc 文件中的 alias 条目"
    echo -e "  - 脚本本体: ${SCRIPT_PATH}"
    echo -e "  - 安装标记: /etc/port-manager-installed"
    echo -e "  - 备份文件: ${BACKUP_DIR}/"
    echo -e ""
    echo -e "${YELLOW}注意: 防火墙规则和 SSH 配置不会被还原${NC}"
    echo -e "${YELLOW}注意: 已安装的依赖包不会被卸载${NC}"
    echo ""

    read -p "确认卸载？(输入 yes 确认): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo -e "${YELLOW}[提示] 已取消${NC}"
        press_enter; return
    fi

    echo -e "${YELLOW}[提示] 正在卸载...${NC}"

    # 1. 卸载快捷命令
    for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
        if [[ -f "$rc" ]]; then
            sed -i '/# VPS Port Manager 快捷命令/d' "$rc" 2>/dev/null
            sed -i "/alias pm='sudo bash ${SCRIPT_PATH}'/d" "$rc" 2>/dev/null
            sed -i "/alias dk='sudo bash ${SCRIPT_PATH}'/d" "$rc" 2>/dev/null
        fi
    done
    rm -f /usr/local/bin/pm 2>/dev/null || true
    rm -f /usr/local/bin/dk 2>/dev/null || true
    echo -e "  ${GREEN}●${NC} 快捷命令已删除"

    # 2. 删除安装标记
    rm -f /etc/port-manager-installed 2>/dev/null || true
    echo -e "  ${GREEN}●${NC} 安装标记已删除"

    # 3. 删除备份文件
    rm -rf "$BACKUP_DIR" 2>/dev/null || true
    echo -e "  ${GREEN}●${NC} 备份文件已删除"

    # 4. 删除脚本本体
    rm -f "$SCRIPT_PATH" 2>/dev/null || true
    # 如果是从 git clone 的目录，删除整个目录
    if [[ -d "$(dirname "$SCRIPT_PATH")/.git" ]]; then
        rm -rf "$(dirname "$SCRIPT_PATH")" 2>/dev/null || true
    fi
    echo -e "  ${GREEN}●${NC} 脚本已删除"

    echo ""
    echo -e "${GREEN}[成功] 脚本已完全卸载！${NC}"
    echo -e "${YELLOW}提示: 防火墙规则和 SSH 端口配置保持不变${NC}"
    echo -e "${YELLOW}提示: 如需还原 SSH 端口，手动编辑 /etc/ssh/sshd_config${NC}"
    echo ""
    echo -e "${BOLD}再见！${NC}"
    exit 0
}

# ==================== 首次安装 ====================

first_time_setup() {
    print_banner
    echo -e "${BOLD}首次运行，正在进行初始化...${NC}\n"

    # 检查 root 权限
    check_root

    # 安装依赖
    ensure_dependencies

    # 确保防火墙工具可用
    ensure_firewall_tools

    detect_firewall
    detect_init_system
    detect_ssh_service

    echo -e "${GREEN}初始化完成！${NC}"
    echo -e "  ${CYAN}防火墙类型:${NC} $FIREWALL"
    echo -e "  ${CYAN}Init系统:${NC}  $INIT_SYSTEM"
    echo -e "  ${CYAN}SSH服务:${NC}    $SSH_SERVICE"
    echo ""

    # 安装快捷命令
    read -p "是否安装快捷命令 pm？(Y/n): " install_pm
    if [[ "$install_pm" != "n" && "$install_pm" != "N" ]]; then
        install_shortcut
    fi

    echo ""
    echo -e "${GREEN}初始化完成！即将进入主菜单...${NC}"
    sleep 2
}

# ==================== 主入口 ====================

main() {
    # 检查是否首次运行
    local marker_file="/etc/port-manager-installed"
    if [[ ! -f "$marker_file" ]]; then
        first_time_setup
        touch "$marker_file" 2>/dev/null || true
    else
        check_root
        ensure_dependencies
        detect_firewall
        detect_init_system
    fi

    # 进入主菜单循环
    while true; do
        show_main_menu
    done
}

main
