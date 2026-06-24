#!/usr/bin/env bash
#
# soga 一体化管理脚本（融合自 soga-setup.sh / gen-soga-conf.sh / soga-auto-setup.sh）
#
# 用法 1（交互菜单）:
#   bash <(curl -fsSL https://raw.githubusercontent.com/xa1zuzll/lsax/main/soga.sh)
#
# 用法 2（直达某个动作，跳过菜单）:
#   ACTION=install   ...变量... bash <(curl -fsSL .../soga.sh)   # 部署soga节点(单实例)+开机自启
#   ACTION=genconf   bash <(curl -fsSL .../soga.sh)              # 生成多节点 sogaN.conf + 开机自启
#   ACTION=update    bash <(curl -fsSL .../soga.sh)              # 仅更新 routes.toml
#   也可用第一个参数代替: bash soga.sh install
#
# 用法 3（install 全自动，环境变量预设）:
#   ACTION=install SERVER_TYPE=anytls NODE_ID=5 CERT_DOMAIN=th.nodedjdom.shop REGION=1 \
#   bash <(curl -fsSL .../soga.sh)
#   (SERVER_TYPE 可选: shadowsocks/vmess/vless/trojan/anytls;
#    vless/shadowsocks 无需 CERT_DOMAIN)
#
set -uo pipefail

# ============== 公共：GitHub 源 ==============
GITHUB_RAW="https://raw.githubusercontent.com/xa1zuzll/lsax/main"
CONF_DIR="/etc/soga"

# ============== 公共：颜色输出 ==============
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
step()  { echo -e "\n${BLUE}========== $1 ==========${NC}"; }

# ============== 公共：stdin 重定向（兼容 bash <(curl ...)） ==============
# 用 bash <(curl ...) 跑时 stdin 是脚本本身，read 会读到脚本字节；重定向到 /dev/tty 修复
NON_INTERACTIVE=0
if [ -t 0 ]; then
    :
elif [ -e /dev/tty ]; then
    exec < /dev/tty
else
    warn "未检测到 tty，将仅从环境变量读取参数（菜单不可用）"
    NON_INTERACTIVE=1
fi

# ============== 公共：root 检查 ==============
require_root() {
    [ "$(id -u)" -eq 0 ] || { error "请用 root 运行"; exit 1; }
}

# ============== 公共：定位 soga 程序 ==============
locate_soga_bin() {
    local p
    for p in /usr/local/soga/soga /usr/local/bin/soga "$(command -v soga 2>/dev/null || true)"; do
        [ -n "$p" ] && [ -x "$p" ] && { echo "$p"; return 0; }
    done
    return 1
}

# ============== 公共：交互问值（环境变量优先，缺失则问） ==============
ask() {
    local var_name=$1 prompt=$2 default=${3:-}
    local current="${!var_name:-}"
    if [ -n "$current" ]; then
        info "$var_name = $current (来自环境变量)"; return
    fi
    if [ "$NON_INTERACTIVE" = "1" ]; then
        if [ -n "$default" ]; then
            printf -v "$var_name" '%s' "$default"
            info "$var_name = $default (使用默认值)"
        else
            error "缺少环境变量 $var_name 且无默认值，又没有 tty 可交互输入"; exit 1
        fi
        return
    fi
    local value
    if [ -n "$default" ]; then
        read -rp "$prompt [回车=默认: $default]: " value
        value="${value:-$default}"
    else
        read -rp "$prompt: " value
    fi
    printf -v "$var_name" '%s' "$value"
}

# ============== 公共：DNS 解锁区域表 -> 设置 OUT_SERVER/PORT/PASSWORD/REGION_NAME ==============
resolve_region() {
    case "$1" in
        1|hk|HK|香港)   OUT_SERVER="hkdns.nodedjdom.shop"; OUT_PORT="28026"; OUT_PASSWORD="9d7f1e1e470cf545"; REGION_NAME="香港";;
        2|jp|JP|日本)   OUT_SERVER="jpdns.nodedjdom.shop"; OUT_PORT="48186"; OUT_PASSWORD="df614c8bb4466ae1"; REGION_NAME="日本";;
        3|us|US|美国)   OUT_SERVER="usdns.nodedjdom.shop"; OUT_PORT="29768"; OUT_PASSWORD="64d53e68eaae4733"; REGION_NAME="美国";;
        4|uk|UK|英国)   OUT_SERVER="ukdns.nodedjdom.shop"; OUT_PORT="25184"; OUT_PASSWORD="2e8a1480303d4ee9"; REGION_NAME="英国";;
        5|sg|SG|新加坡) OUT_SERVER="sgdns.nodedjdom.shop"; OUT_PORT="39884"; OUT_PASSWORD="9eeffd23fc516fa2"; REGION_NAME="新加坡";;
        6|tw|TW|台湾)   OUT_SERVER="twdns.nodedjdom.shop"; OUT_PORT="20944"; OUT_PASSWORD="bfb08a5596498d3c"; REGION_NAME="台湾";;
        7|kr|KR|韩国)   OUT_SERVER="krdns.nodedjdom.shop"; OUT_PORT="39561"; OUT_PASSWORD="e5bb7a086e3b2ec4"; REGION_NAME="韩国";;
        *) return 1;;
    esac
    return 0
}

# ============== 公共：routes.toml 跨国出口读写（按注释定位，不依赖行号） ==============
detect_region_outbound() {
    awk '
        /#路由 跨国 出口/ { inblk=1 }
        inblk && /^[[:space:]]*server=/   { l=$0; sub(/.*server="?/,"",l); sub(/".*/,"",l); s=l }
        inblk && /^[[:space:]]*port=/     { l=$0; sub(/.*port=/,"",l); sub(/[^0-9].*/,"",l); p=l }
        inblk && /^[[:space:]]*password=/ { l=$0; sub(/.*password="?/,"",l); sub(/".*/,"",l); pw=l; print s"|"p"|"pw; exit }
    ' "$1"
}
apply_region_outbound() {
    local file=$1 server=$2 port=$3 password=$4
    awk -v s="$server" -v p="$port" -v pw="$password" '
        /#路由 跨国 出口/ { inblk=1 }
        inblk && /^[[:space:]]*server=/   { print "server=\"" s "\""; next }
        inblk && /^[[:space:]]*port=/     { print "port=" p; next }
        inblk && /^[[:space:]]*password=/ { print "password=\"" pw "\""; inblk=0; next }
        { print }
    ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

# ============== 公共：选择协议(server_type) -> 设置 SERVER_TYPE ==============
# v2board/soga 协议全集。anytls/trojan/vless/shadowsocks 已在原配置验证可用，
# 其余按 soga 常见 server_type 命名；若你的 soga 版本字符串不同请告知修正。
choose_server_type() {
    echo "请选择协议 (server_type):"
    echo "  1) shadowsocks   2) vmess   3) vless   4) trojan   5) anytls"
    local st
    while :; do
        read -rp "输入 1-5: " st
        case "$st" in
            1) SERVER_TYPE="shadowsocks"; break;;
            2) SERVER_TYPE="vmess";       break;;
            3) SERVER_TYPE="vless";       break;;
            4) SERVER_TYPE="trojan";      break;;
            5) SERVER_TYPE="anytls";      break;;
            *) error "无效,请输入 1-5";;
        esac
    done
}

# 该协议是否需要本地证书(cert_domain)。vless/shadowsocks 不需要,其余 TLS 类需要
needs_cert() {
    case "$1" in
        vless|shadowsocks) return 1;;
        *) return 0;;
    esac
}

# ====================================================================
# 动作 1：部署 soga 节点（单实例,含 patch + routes.toml + 开机自启） —— 原 soga-setup.sh install
# ====================================================================
do_install() {
    require_root

    step "Step 0: 检查 CPU 架构"
    local ARCH; ARCH=$(uname -m)
    if [ "$ARCH" != "x86_64" ]; then
        error "本动作仅支持 x86_64（patch.py 不支持 ARM），当前为: $ARCH"; exit 1
    fi
    info "架构检查通过: $ARCH ✓"

    local cmd
    for cmd in curl python3 systemctl; do
        command -v "$cmd" &>/dev/null || { error "缺少必备工具: $cmd，请先安装"; exit 1; }
    done

    step "收集配置信息（环境变量优先）"

    # 协议 server_type（环境变量优先，否则菜单选）
    if [ -n "${SERVER_TYPE:-}" ]; then
        info "SERVER_TYPE = $SERVER_TYPE (来自环境变量)"
    elif [ "$NON_INTERACTIVE" = "1" ]; then
        error "缺少环境变量 SERVER_TYPE，且无 tty 可交互输入"; exit 1
    else
        choose_server_type
    fi

    ask NODE_ID "请输入 node_id (面板里的节点ID)"

    # 证书域名：仅 TLS 类协议需要，vless/shadowsocks 留空
    if needs_cert "$SERVER_TYPE"; then
        ask CERT_DOMAIN "请输入 cert_domain (节点证书域名, 如 hk.nodedjdom.shop)"
    else
        CERT_DOMAIN=""
        info "协议 $SERVER_TYPE 无需证书，cert_domain 留空"
    fi

    echo ""
    echo "--- 选择 DNS 解锁区域 (routes.toml 跨国出站) ---"
    echo "  1) 香港   2) 日本   3) 美国   4) 英国"
    echo "  5) 新加坡 6) 台湾   7) 韩国"
    if [ -z "${REGION:-}" ]; then
        if [ "$NON_INTERACTIVE" = "1" ]; then
            error "缺少环境变量 REGION (1-7)，且无 tty 可交互输入"; exit 1
        fi
        read -rp "请选择 [回车=默认: 1 香港]: " REGION
        REGION="${REGION:-1}"
    fi
    resolve_region "$REGION" || { error "无效区域选择: $REGION，必须是 1-7"; exit 1; }
    info "已选择: $REGION_NAME (出站 $OUT_SERVER:$OUT_PORT)"

    if [ -z "${NODE_ID:-}" ] || [ -z "${SERVER_TYPE:-}" ]; then
        error "node_id / server_type 不能为空，退出"; exit 1
    fi
    if needs_cert "$SERVER_TYPE" && [ -z "${CERT_DOMAIN:-}" ]; then
        error "协议 $SERVER_TYPE 需要 cert_domain，但为空，退出"; exit 1
    fi

    step "Step 1/4: 安装 soga v2.13.7"
    bash <(curl -Ls https://raw.githubusercontent.com/vaxilu/soga/master/install.sh) 2.13.7
    info "soga 安装完成 ✓"

    step "Step 2/4: 下载并应用 patch.py"
    soga stop default 2>/dev/null || systemctl stop soga 2>/dev/null || true
    sleep 2
    curl -fsSL -o /usr/local/soga/patch.py "$GITHUB_RAW/patch.py" || { error "下载 patch.py 失败"; exit 1; }
    info "patch.py 下载完成 ✓"
    if python3 /usr/local/soga/patch.py /usr/local/soga/soga --verify 2>&1 | grep -q "WRAPPER OK"; then
        warn "二进制已经是 patched 状态，跳过 patch"
    else
        info "正在 patch 二进制..."
        python3 /usr/local/soga/patch.py /usr/local/soga/soga || { error "patch 失败"; exit 1; }
        info "patch 完成 ✓"
    fi

    step "Step 3/4: 下载并配置 soga.conf"
    curl -fsSL -o "$CONF_DIR/soga.conf" "$GITHUB_RAW/soga.conf" || { error "下载 soga.conf 失败"; exit 1; }
    sed -i "s|^server_type=.*|server_type=$SERVER_TYPE|" "$CONF_DIR/soga.conf"
    sed -i "s|^node_id=.*|node_id=$NODE_ID|" "$CONF_DIR/soga.conf"
    if needs_cert "$SERVER_TYPE"; then
        sed -i "s|^cert_mode=.*|cert_mode=http|" "$CONF_DIR/soga.conf"
        sed -i "s|^cert_domain=.*|cert_domain=$CERT_DOMAIN|" "$CONF_DIR/soga.conf"
        sed -i "s|^cert_key_length=.*|cert_key_length=ec-256|" "$CONF_DIR/soga.conf"
        info "已配置 server_type=$SERVER_TYPE, node_id=$NODE_ID, cert_domain=$CERT_DOMAIN ✓"
    else
        sed -i "s|^cert_mode=.*|cert_mode=|" "$CONF_DIR/soga.conf"
        sed -i "s|^cert_domain=.*|cert_domain=|" "$CONF_DIR/soga.conf"
        sed -i "s|^cert_key_length=.*|cert_key_length=|" "$CONF_DIR/soga.conf"
        info "已配置 server_type=$SERVER_TYPE, node_id=$NODE_ID (无证书) ✓"
    fi

    step "Step 4/4: 下载并配置 routes.toml"
    curl -fsSL -o "$CONF_DIR/routes.toml" "$GITHUB_RAW/routes.toml" || { error "下载 routes.toml 失败"; exit 1; }
    apply_region_outbound "$CONF_DIR/routes.toml" "$OUT_SERVER" "$OUT_PORT" "$OUT_PASSWORD"
    info "已配置出站 server=$OUT_SERVER, port=$OUT_PORT ✓"

    step "设为开机自启 + 重启 soga 并查看日志"
    systemctl enable soga 2>/dev/null || true
    systemctl restart soga
    sleep 3
    info "soga 已设为开机自启并重启，下面是实时日志（Ctrl+C 退出查看，soga 仍在跑）"
    echo "--------------------------------------------"
    if command -v soga &>/dev/null; then soga log default -f; else journalctl -u soga -f; fi
}

# ====================================================================
# 动作 3：仅更新 routes.toml（保留本机区域） —— 原 soga-setup.sh update
# ====================================================================
do_update_routes() {
    require_root
    step "更新 routes.toml（自动保留本机已选区域）"
    local CONF="$CONF_DIR/routes.toml"
    [ -f "$CONF" ] || { error "$CONF 不存在，请先用菜单 1「部署soga节点」完整安装"; exit 1; }

    local CUR _rest CUR_SERVER CUR_PORT CUR_PASSWORD
    CUR=$(detect_region_outbound "$CONF")
    CUR_SERVER="${CUR%%|*}"; _rest="${CUR#*|}"; CUR_PORT="${_rest%%|*}"; CUR_PASSWORD="${_rest##*|}"
    if [ -z "$CUR_SERVER" ] || [ -z "$CUR_PORT" ] || [ -z "$CUR_PASSWORD" ]; then
        error "无法从现有 routes.toml 解析出跨国出口区域，已中止（未覆盖任何文件）"; exit 1
    fi
    info "检测到本机跨国出口: server=$CUR_SERVER port=$CUR_PORT"

    local TMP; TMP=$(mktemp)
    curl -fsSL -o "$TMP" "$GITHUB_RAW/routes.toml" || { error "下载 routes.toml 失败"; rm -f "$TMP"; exit 1; }
    [ -s "$TMP" ] || { error "下载到的 routes.toml 为空，已中止"; rm -f "$TMP"; exit 1; }

    apply_region_outbound "$TMP" "$CUR_SERVER" "$CUR_PORT" "$CUR_PASSWORD"
    if ! grep -q "server=\"$CUR_SERVER\"" "$TMP"; then
        error "区域注入校验失败，已中止（未覆盖现有文件）"; rm -f "$TMP"; exit 1
    fi
    mv "$TMP" "$CONF"
    info "routes.toml 已更新，并保留区域 = $CUR_SERVER ✓"
    systemctl restart soga
    sleep 2
    info "soga 已重启 ✓"
}

# ====================================================================
# 动作 2：生成多节点配置 sogaN.conf（含开机自启,可连续添加） —— 原 gen-soga-conf.sh + soga-auto-setup.sh
# ====================================================================
do_genconf() {
    require_root
    command -v systemctl >/dev/null 2>&1 || { error "本机没有 systemd,无法配置开机自启"; exit 1; }
    if [ "$NON_INTERACTIVE" = "1" ]; then
        error "生成多节点配置需要 tty 交互，无法在非交互环境运行"; exit 1
    fi
    mkdir -p "$CONF_DIR"

    local SERVER_TYPE NODE_ID WEBAPI_URL WEBAPI_KEY CERT_MODE CERT_DOMAIN CERT_KEY_LENGTH IDX OUT st wa yn more

  while :; do
    echo -e "\n${BLUE}--- 生成新节点配置 ---${NC}"
    choose_server_type

    while :; do
        read -rp "请输入 node_id (数字): " NODE_ID
        [[ "$NODE_ID" =~ ^[0-9]+$ ]] && break
        error "node_id 必须是数字"
    done

    echo "请选择 webapi 对接:"
    echo "  1) https://nd.dofast.pro   2) https://node.biumini.xyz"
    while :; do
        read -rp "输入 1-2: " wa
        case "$wa" in
            1) WEBAPI_URL="https://nd.dofast.pro";    WEBAPI_KEY="lalallalalalalallala"; break;;
            2) WEBAPI_URL="https://node.biumini.xyz"; WEBAPI_KEY="sasuhkhkabsousaj";     break;;
            *) error "无效,请输入 1 或 2";;
        esac
    done

    if needs_cert "$SERVER_TYPE"; then
        CERT_MODE="http"; CERT_KEY_LENGTH="ec-256"
        while :; do
            read -rp "请输入 cert_domain (证书域名): " CERT_DOMAIN
            [ -n "$CERT_DOMAIN" ] && break
            error "cert_domain 不能为空"
        done
    else
        CERT_MODE=""; CERT_DOMAIN=""; CERT_KEY_LENGTH=""
    fi

    while :; do
        read -rp "输入文件编号 (如 1 -> 生成 soga1.conf): " IDX
        [[ "$IDX" =~ ^[0-9]+$ ]] && break
        error "编号必须是数字"
    done
    OUT="$CONF_DIR/soga$IDX.conf"
    if [ -e "$OUT" ]; then
        read -rp "$OUT 已存在,覆盖? (y/N): " yn
        if [[ ! "$yn" =~ ^[Yy]$ ]]; then
            warn "已跳过 soga$IDX.conf"
            read -rp "继续添加下一个节点? (y/N): " more
            [[ "$more" =~ ^[Yy]$ ]] && continue || break
        fi
    fi

    cat > "$OUT" <<EOF
# 基础配置
type=xiaov2board
server_type=$SERVER_TYPE
node_id=$NODE_ID
soga_key=90482212

# webapi 或 db 对接任选一个
api=webapi

# webapi 对接信息
webapi_url=$WEBAPI_URL
webapi_key=$WEBAPI_KEY

# db 对接信息
db_host=
db_port=
db_name=
db_user=
db_password=

# 手动证书配置
cert_file=
key_file=

# 自动证书配置
cert_mode=$CERT_MODE
cert_domain=$CERT_DOMAIN
cert_key_length=$CERT_KEY_LENGTH
dns_provider=

# proxy protocol 中转配置
proxy_protocol=false
udp_proxy_protocol=false

# 全局限制用户 IP 数配置
redis_enable=false
redis_addr=
redis_password=
redis_db=0
conn_limit_expiry=60

# 动态限速配置
dy_limit_enable=false
dy_limit_duration=
dy_limit_trigger_time=60
dy_limit_trigger_speed=100
dy_limit_speed=30
dy_limit_time=600
dy_limit_white_user_id=

# 其它杂项
user_conn_limit=0
user_speed_limit=0
user_tcp_limit=0
node_speed_limit=0

check_interval=60
submit_interval=60
forbidden_bit_torrent=true
log_level=info
auto_out_ip=true
EOF

    echo
    info "已生成: $OUT"
    echo "------------------------------------"
    grep -E '^(server_type|node_id|webapi_url|webapi_key|cert_mode|cert_domain|cert_key_length)=' "$OUT"
    echo "------------------------------------"

    # 配置开机自启并立即启动该实例
    if ensure_soga_template; then
        info "enable --now soga@$IDX（开机自启 + 立即启动）"
        systemctl enable --now "soga@$IDX" >/dev/null 2>&1 || systemctl enable --now "soga@$IDX"
        sleep 1
        report_instance "$IDX"
    else
        warn "soga 程序未安装，已生成配置但未启动；用菜单 1 部署 soga 后重跑本项即可纳管"
    fi

    read -rp "继续添加下一个节点? (y/N): " more
    [[ "$more" =~ ^[Yy]$ ]] || break
  done

    echo
    info "===== 当前已纳管的多节点实例 ====="
    list_instances
}

# ====================================================================
# 多节点开机自启 helpers (systemd soga@)   —— 原 soga-auto-setup.sh
# 供「生成多节点配置」内联调用，不再单独占菜单项
# ====================================================================

# 清理旧的 screen / crontab 自启,避免和 systemd 重复跑(首次配置时调用一次)
cleanup_old_autostart() {
    if crontab -l >/dev/null 2>&1; then
        crontab -l 2>/dev/null | grep -v 'soga' | crontab - 2>/dev/null || true
    fi
    if command -v screen >/dev/null 2>&1; then
        screen -ls 2>/dev/null | grep -oE '[0-9]+\.soga[0-9]+' | awk -F. '{print $1}' | while read -r s; do
            screen -S "$s" -X quit 2>/dev/null || true
        done
    fi
}

# 写入 soga@.service 模板(幂等)。soga 未安装则返回 1
ensure_soga_template() {
    local UNIT="/etc/systemd/system/soga@.service" SOGA_BIN
    SOGA_BIN=$(locate_soga_bin) || return 1
    if [ ! -f "$UNIT" ]; then
        info "首次配置开机自启：清理旧的 screen / crontab 自启（避免重复跑）"
        cleanup_old_autostart
    fi
    cat > "$UNIT" <<EOF
[Unit]
Description=soga%i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$CONF_DIR
ExecStart=$SOGA_BIN -c $CONF_DIR/soga%i.conf
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    return 0
}

# 打印单个实例运行状态
report_instance() {
    local n=$1 st
    st="$(systemctl is-active "soga@$n" 2>/dev/null || true)"
    if [ "$st" = "active" ]; then
        echo -e "  ${GREEN}soga@$n : running${NC}"
    else
        echo -e "  ${RED}soga@$n : ${st:-unknown}${NC}   (排查: journalctl -u soga@$n -n 30 --no-pager)"
    fi
}

# 扫描所有 sogaN.conf 并打印状态(默认 soga.conf 跳过)
list_instances() {
    local f name num n
    local -a ids=()
    for f in "$CONF_DIR"/soga*.conf; do
        [ -e "$f" ] || continue
        name="$(basename "$f" .conf)"; num="${name#soga}"
        [[ "$num" =~ ^[0-9]+$ ]] && ids+=("$num")
    done
    [ "${#ids[@]}" -gt 0 ] || { warn "暂无 sogaN.conf 实例"; return 0; }
    IFS=$'\n' ids=($(printf '%s\n' "${ids[@]}" | sort -n)); unset IFS
    for n in "${ids[@]}"; do report_instance "$n"; done
    echo "管理命令:"
    for n in "${ids[@]}"; do
        echo "  soga@$n :  systemctl status soga@$n | systemctl restart soga@$n | journalctl -u soga@$n -f"
    done
}

# ====================================================================
# 主菜单
# ====================================================================
main_menu() {
    if [ "$NON_INTERACTIVE" = "1" ]; then
        error "无 tty，无法显示菜单。请用 ACTION=install/genconf/autostart/update 指定动作"; exit 1
    fi
    echo -e "\n${BLUE}========= soga 一体化管理脚本 =========${NC}"
    echo "  1) 部署soga节点        (装soga + patch + soga.conf + routes.toml + 开机自启)"
    echo "  2) 生成多节点配置      (sogaN.conf + 开机自启,可连续添加)"
    echo "  3) 仅更新 routes.toml  (如果github更新了routes.toml配置，保留本机选择的dns解锁区域)"
    echo "  0) 退出"
    local choice
    read -rp "请选择: " choice
    case "$choice" in
        1) do_install ;;
        2) do_genconf ;;
        3) do_update_routes ;;
        0) exit 0 ;;
        *) error "无效选择: $choice"; exit 1 ;;
    esac
}

# ============== 入口分发：ACTION 环境变量 / 第一个参数 / 菜单 ==============
ACTION="${ACTION:-${1:-}}"
case "$ACTION" in
    install)               do_install ;;
    genconf|gen)           do_genconf ;;
    update|update-routes)  do_update_routes ;;
    "")                    main_menu ;;
    *)                     error "未知动作: $ACTION (可用: install/genconf/update)"; exit 1 ;;
esac
