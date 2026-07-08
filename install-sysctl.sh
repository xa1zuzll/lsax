#!/usr/bin/env bash
#
# 内核网络调优 + 开机自启（BBR / IPv6 / TCP 缓冲区等）
# 用法: sudo bash install-sysctl.sh
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 运行: sudo bash $0" >&2
  exit 1
fi

CONF=/etc/sysctl.d/99-tuning.conf

# ---------- 1. 写入 sysctl 配置 ----------
# 放到 /etc/sysctl.d/ 而不是覆盖 /etc/sysctl.conf，
# 这样开机时 systemd-sysctl.service 会自动加载，且不破坏系统默认文件。
cat > "$CONF" << 'EOF'
# 1. 基础文件句柄限制 (适配高并发)
fs.file-max                     = 6815744
fs.nr_open                      = 6815744

# 2. 网络队列与连接优化
net.core.somaxconn              = 65535
net.ipv4.tcp_max_syn_backlog    = 8192
net.ipv4.tcp_abort_on_overflow  = 1
net.ipv4.ip_local_port_range    = 1024 65535
net.core.netdev_max_backlog     = 65536

# 3. BBR 与 拥塞控制
net.core.default_qdisc          = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen           = 3

# 4. TCP 窗口与缓冲区优化 (针对大带宽/长距离链路)
net.ipv4.tcp_window_scaling     = 1
net.ipv4.tcp_adv_win_scale      = 1
net.ipv4.tcp_moderate_rcvbuf    = 1
net.core.rmem_max               = 67108864
net.core.wmem_max               = 67108864
net.ipv4.tcp_rmem               = 4096 87380 67108864
net.ipv4.tcp_wmem               = 4096 65536 67108864
net.ipv4.udp_rmem_min           = 8192
net.ipv4.udp_wmem_min           = 8192

# 5. IPv6 专项开启与调优
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
# 扩大 IPv6 路由缓存和邻居表，防止高并发时丢包
net.ipv6.route.max_size = 1048576
net.ipv6.neigh.default.gc_thresh1 = 1024
net.ipv6.neigh.default.gc_thresh2 = 4096
net.ipv6.neigh.default.gc_thresh3 = 8192

# 6. 时间戳与连接回收
net.ipv4.tcp_timestamps         = 1
net.ipv4.tcp_tw_reuse           = 1
net.ipv4.tcp_fin_timeout        = 30
net.ipv4.tcp_slow_start_after_idle = 0

# 7. 安全与转发配置
net.ipv4.conf.all.rp_filter     = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.ip_forward             = 1
net.ipv4.conf.all.route_localnet= 1
net.ipv4.tcp_rfc1337            = 1
net.ipv4.tcp_ecn                = 0

# 8. 其他辅助优化
net.ipv4.tcp_no_metrics_save    = 1
net.ipv4.tcp_sack               = 1
net.ipv4.tcp_fack               = 1
net.ipv4.tcp_mtu_probing        = 1
EOF
echo "[+] 已写入 $CONF"

# ---------- 2. 保证 BBR 模块开机加载 ----------
# tcp_bbr 未加载时 tcp_congestion_control=bbr 会静默失败，回落 cubic。
echo tcp_bbr > /etc/modules-load.d/bbr.conf
modprobe tcp_bbr 2>/dev/null || true
echo "[+] 已配置 tcp_bbr 开机自动加载"

# ---------- 3. 兜底服务：网络就绪后重放一次 ----------
# 有些网卡相关项(IPv6 forwarding / rp_filter)在早期启动网卡未就绪时
# 可能应用不全，这个 oneshot 服务在 network-online 后再 apply 一次。
cat > /etc/systemd/system/sysctl-tuning.service << 'EOF'
[Unit]
Description=Re-apply custom sysctl tuning after network is online
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/sbin/sysctl --system
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sysctl-tuning.service >/dev/null 2>&1
echo "[+] 已启用 sysctl-tuning.service (开机兜底重放)"

# ---------- 4. 立即应用 ----------
sysctl --system

# ---------- 5. 校验关键项 ----------
echo
echo "==== 校验 ===="
echo -n "拥塞控制:   "; sysctl -n net.ipv4.tcp_congestion_control
echo -n "可用算法:   "; sysctl -n net.ipv4.tcp_available_congestion_control
echo -n "默认队列:   "; sysctl -n net.core.default_qdisc
echo -n "IPv6转发:   "; sysctl -n net.ipv6.conf.all.forwarding
echo -n "IPv4转发:   "; sysctl -n net.ipv4.ip_forward
echo
if [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == "bbr" ]]; then
  echo "[OK] BBR 已生效，开机会自动加载。"
else
  echo "[!!] BBR 未生效，请检查内核是否支持 (uname -r 建议 >= 4.9)。"
fi
