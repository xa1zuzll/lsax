#!/bin/bash
# 解锁机部署脚本 (shadowsocks-libev, 公开模式)
# 端口对所有人开放，靠密码隔离，适合多节点机场
#
# 用法:
#   bash unlock-server.sh install [port] [password]   首次安装，不传参则交互询问/随机
#   bash unlock-server.sh set [port] [password]       修改已安装机器的端口/密码
#   bash unlock-server.sh status                      查看状态
#   bash unlock-server.sh info                        打印连接信息（含 V2bX 配置片段）
#   bash unlock-server.sh rotate                      轮换密码（建议月度执行）

CONFIG_FILE="/etc/shadowsocks-libev/config.json"
STATE_FILE="/etc/shadowsocks-libev/.unlock-state"
METHOD="chacha20-ietf-poly1305"

red()    { printf "\033[31m%s\033[0m\n" "$*"; }
green()  { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
blue()   { printf "\033[34m%s\033[0m\n" "$*"; }

die() { red "错误: $*"; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "需要 root 权限"
}

require_debian() {
    [ -f /etc/debian_version ] || die "仅支持 Debian/Ubuntu"
}

load_state() {
    if [ -f "$STATE_FILE" ]; then
        # shellcheck disable=SC1090
        . "$STATE_FILE"
    fi
}

save_state() {
    cat > "$STATE_FILE" <<EOF
PORT="$PORT"
PASSWORD="$PASSWORD"
EOF
    chmod 600 "$STATE_FILE"
}

gen_password() {
    if command -v openssl >/dev/null; then
        openssl rand -hex 8
    else
        head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-16
    fi
}

gen_port() {
    echo $((RANDOM % 30000 + 20000))
}

valid_port() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

write_config() {
    cat > "$CONFIG_FILE" <<EOF
{
    "server":["::", "0.0.0.0"],
    "mode":"tcp_and_udp",
    "server_port":$PORT,
    "password":"$PASSWORD",
    "timeout":86400,
    "method":"$METHOD"
}
EOF
}

get_public_ip() {
    local ip
    ip=$(curl -fsSL -4 -m 5 ifconfig.me 2>/dev/null) && { echo "$ip"; return; }
    ip=$(curl -fsSL -4 -m 5 ip.sb 2>/dev/null)        && { echo "$ip"; return; }
    ip=$(curl -fsSL -4 -m 5 ipinfo.io/ip 2>/dev/null) && { echo "$ip"; return; }
    echo "<请手动填解锁机公网 IP>"
}

cmd_install() {
    require_root
    require_debian

    blue "==> 进入安装流程"

    if [ -f "$STATE_FILE" ]; then
        load_state
        yellow "检测到已有安装 (端口=${PORT:-?}, 密码=${PASSWORD:-?})"
        yellow "重新 install 会覆盖配置。"
        printf "继续? [y/N] "
        read -r ans </dev/tty || ans=""
        case "$ans" in
            y|Y) ;;
            *) blue "已取消"; exit 0 ;;
        esac
    fi

    # 端口: 命令行参数优先，否则交互询问 (回车=随机)
    if [ -n "${1:-}" ]; then
        PORT="$1"
    else
        printf "请输入端口 [回车随机]: "
        read -r PORT </dev/tty || PORT=""
        [ -n "$PORT" ] || PORT=$(gen_port)
    fi
    valid_port "$PORT" || die "端口非法: $PORT (须为 1-65535 的数字)"

    # 密码: 命令行参数优先，否则交互询问 (回车=随机)
    if [ -n "${2:-}" ]; then
        PASSWORD="$2"
    else
        printf "请输入密码 [回车随机]: "
        read -r PASSWORD </dev/tty || PASSWORD=""
        [ -n "$PASSWORD" ] || PASSWORD=$(gen_password)
    fi

    blue "==> 端口 $PORT  密码 $PASSWORD"

    blue "==> 安装 shadowsocks-libev、vnstat..."
    apt update || die "apt update 失败"
    DEBIAN_FRONTEND=noninteractive apt install -y \
        shadowsocks-libev curl vnstat \
        || die "apt install 失败"

    blue "==> 写入 $CONFIG_FILE"
    write_config

    blue "==> 启动并设为开机自启"
    systemctl restart shadowsocks-libev || die "shadowsocks-libev 启动失败"
    systemctl enable shadowsocks-libev >/dev/null 2>&1
    systemctl enable --now vnstat >/dev/null 2>&1

    save_state
    green "==> 安装完成 (公开模式 — 端口对所有人开放)"
    echo
    cmd_info
}

cmd_status() {
    load_state
    blue "==> shadowsocks-libev 服务状态"
    if systemctl is-active --quiet shadowsocks-libev; then
        green "  active (running)"
    else
        red "  inactive"
    fi
    echo
    blue "==> 监听 (端口 ${PORT:-?})"
    ss -tlnp 2>/dev/null | grep ":${PORT:-XXXXX} " || echo "  (TCP 未监听)"
    ss -ulnp 2>/dev/null | grep ":${PORT:-XXXXX} " || echo "  (UDP 未监听)"
    echo
    blue "==> 流量统计 (vnstat)"
    if command -v vnstat >/dev/null; then
        vnstat 2>/dev/null | head -20 || echo "  (vnstat 数据不足，等几分钟再看)"
    else
        echo "  (未安装 vnstat)"
    fi
}

cmd_info() {
    load_state
    [ -n "${PORT:-}" ] || die "未找到状态文件，请先 install"
    local ip
    ip=$(get_public_ip)

    green "============ 解锁机信息 ============"
    echo "公网 IP : $ip"
    echo "端口    : $PORT"
    echo "方法    : $METHOD"
    echo "密码    : $PASSWORD"
    echo
    blue "============ 受限节点 V2bX 配置片段 ============"
    yellow "把这段填入受限节点的 /etc/V2bX/custom_outbound.json (每个 unlock-* tag)"
    cat <<EOF
{
  "protocol": "shadowsocks",
  "tag": "unlock",
  "settings": {
    "servers": [{
      "address": "$ip",
      "port": $PORT,
      "method": "$METHOD",
      "password": "$PASSWORD"
    }]
  }
}
EOF
    echo
    yellow "公开模式: 端口对所有人开放，无需白名单。任何节点直接用上面的 IP+端口+密码 即可连接。"
    echo
    blue "可在浏览器查 IP 解锁能力: https://ping0.cc/ip/$ip"
}

cmd_rotate() {
    require_root
    load_state
    [ -n "${PORT:-}" ] || die "未找到状态文件，请先 install"

    local old_password="$PASSWORD"
    PASSWORD=$(gen_password)

    yellow "旧密码: $old_password"
    yellow "新密码: $PASSWORD"
    yellow "切换后所有节点的 custom_outbound.json 都要更新密码，否则解锁失效"
    printf "确认轮换? [y/N] "
    read -r ans </dev/tty || ans=""
    case "$ans" in
        y|Y) ;;
        *) blue "已取消"; return ;;
    esac

    sed -i "s/\"password\":\"[^\"]*\"/\"password\":\"$PASSWORD\"/" "$CONFIG_FILE"
    systemctl restart shadowsocks-libev || die "重启失败，配置可能已损坏"
    save_state
    green "密码已轮换为: $PASSWORD"
    yellow "记得批量更新所有节点的 custom_outbound.json"
}

cmd_set() {
    require_root
    load_state
    [ -n "${PORT:-}" ] || die "未找到状态文件，请先 install"
    [ -f "$CONFIG_FILE" ] || die "未找到配置文件 $CONFIG_FILE，请先 install"

    local old_port="$PORT" old_pass="$PASSWORD"
    local new_port="${1:-}" new_pass="${2:-}"

    # 新端口: 参数优先，否则交互询问 (回车=不变)
    if [ -z "$new_port" ]; then
        printf "新端口 [当前 %s，回车不变]: " "$old_port"
        read -r new_port </dev/tty || new_port=""
        [ -n "$new_port" ] || new_port="$old_port"
    fi
    valid_port "$new_port" || die "端口非法: $new_port (须为 1-65535 的数字)"

    # 新密码: 参数优先，否则交互询问 (回车=不变，输入 random=随机)
    if [ -z "$new_pass" ]; then
        printf "新密码 [当前 %s，回车不变，输入 random 随机]: " "$old_pass"
        read -r new_pass </dev/tty || new_pass=""
        [ -n "$new_pass" ] || new_pass="$old_pass"
    fi
    [ "$new_pass" = "random" ] && new_pass=$(gen_password)

    if [ "$new_port" = "$old_port" ] && [ "$new_pass" = "$old_pass" ]; then
        blue "端口和密码均未变化，无需修改"
        return
    fi

    PORT="$new_port"
    PASSWORD="$new_pass"

    blue "==> 写入 $CONFIG_FILE"
    write_config
    systemctl restart shadowsocks-libev || die "重启失败，配置可能已损坏"
    save_state

    green "==> 已更新"
    echo "  端口: $old_port -> $PORT"
    echo "  密码: $old_pass -> $PASSWORD"
    yellow "记得同步更新所有节点的 custom_outbound.json (端口和密码都要改)"
    echo
    cmd_info
}

cmd_help() {
    cat <<EOF
解锁机部署脚本 (公开模式 — 端口对所有人开放，靠密码隔离)

用法:
  $0 install [port] [password]   首次安装 (不传参则交互询问，回车=随机)
  $0 set [port] [password]       修改已安装机器的端口/密码 (不传参则交互询问)
  $0 status                      查看服务/端口/流量统计
  $0 info                        打印连接信息和 V2bX 配置片段
  $0 rotate                      轮换密码 (建议月度执行)

示例:
  bash $0 install                          # 交互询问端口和密码 (可回车随机)
  bash $0 install 18300 myStrongPassword   # 直接指定端口和密码
  bash $0 set 18888 newPassword            # 改成指定端口和密码
  bash $0 set                              # 交互修改 (回车保持不变)
  bash $0 info                              # 看连接信息

设计说明:
  本脚本采用「公开模式」，参考 nfdns.xyz 等商业 DNS 解锁服务的安全模型:
  - 端口对所有人开放
  - 靠强密码 + 非标准端口 + chacha20-poly1305 加密做隔离
  - 适合 N 个 V2bX 节点的机场（不用维护白名单）
  - 配合 vnstat 监控异常流量，密码定期 rotate
EOF
}

case "${1:-help}" in
    install)        shift; cmd_install "$@" ;;
    set|config)     shift; cmd_set "$@" ;;
    status|st)      cmd_status ;;
    info)           cmd_info ;;
    rotate)         cmd_rotate ;;
    help|-h|--help|*) cmd_help ;;
esac
