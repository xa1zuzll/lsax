#!/usr/bin/env bash
#
# server-cleanup.sh
# ------------------------------------------------------------
# 修改 root 密码 + 清除命令历史 + 清除登录/SSH 日志
# 在目标服务器上以 root 身份运行:  bash server-cleanup.sh
# ------------------------------------------------------------

set -u

# ============ 配置区 ============
# 想改的新密码。留空则跳过改密码这一步。
NEW_PASSWORD="改成你的新密码"
# 要改密码的用户
TARGET_USER="root"
# ================================

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "[!] 请用 root 运行 (sudo bash $0)"
        exit 1
    fi
}

# 1) 修改密码
change_password() {
    if [ -z "${NEW_PASSWORD}" ] || [ "${NEW_PASSWORD}" = "改成你的新密码" ]; then
        echo "[=] 未设置 NEW_PASSWORD，跳过改密码"
        return
    fi
    echo "${TARGET_USER}:${NEW_PASSWORD}" | chpasswd \
        && echo "[+] 已修改 ${TARGET_USER} 密码" \
        || echo "[!] 改密码失败"
}

# 2) 清除登录记录 (last / lastb / lastlog)
clear_login_records() {
    for f in /var/log/wtmp /var/log/btmp /var/log/lastlog; do
        [ -f "$f" ] && cat /dev/null > "$f" && echo "[+] 已清空 $f"
    done
}

# 3) 清除 SSH / 认证日志 (Debian 与 RHEL 两种路径都覆盖)
clear_ssh_logs() {
    for f in /var/log/auth.log /var/log/auth.log.* \
             /var/log/secure /var/log/secure.* ; do
        [ -f "$f" ] && cat /dev/null > "$f" && echo "[+] 已清空 $f"
    done
    # systemd-journald (很多新系统真正的日志在这里)
    if command -v journalctl >/dev/null 2>&1; then
        journalctl --rotate            >/dev/null 2>&1
        journalctl --vacuum-time=1s    >/dev/null 2>&1
        echo "[+] 已清理 systemd journal"
    fi
}

# 4) 清除命令历史 (bash 与 zsh 都处理)
clear_shell_history() {
    for hf in /root/.bash_history /root/.zsh_history \
              "${HOME}/.bash_history" "${HOME}/.zsh_history"; do
        [ -f "$hf" ] && cat /dev/null > "$hf" && echo "[+] 已清空 $hf"
    done
    # 遍历所有普通用户的 home
    for d in /home/*; do
        [ -d "$d" ] || continue
        for hf in "$d/.bash_history" "$d/.zsh_history"; do
            [ -f "$hf" ] && cat /dev/null > "$hf" && echo "[+] 已清空 $hf"
        done
    done
    # 让本次会话退出后不再写回历史
    unset HISTFILE 2>/dev/null
    history -c 2>/dev/null
    echo "[+] 已清空当前会话内存历史 (本次退出不写回)"
}

main() {
    need_root
    echo "===== server-cleanup 开始 ====="
    change_password
    clear_login_records
    clear_ssh_logs
    clear_shell_history
    echo "===== 完成 ====="
    echo "[i] 验证: 运行 last / lastb / lastlog 应为空"
    echo "[i] 提示: 退出登录前若再产生新记录，可再跑一次本脚本"
}

main "$@"
