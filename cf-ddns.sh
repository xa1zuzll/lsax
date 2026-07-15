#!/usr/bin/env bash
# Cloudflare DDNS —— 检测公网 IP,变了就自动更新 A 记录
# 用法: 直接跑一次   ./cf-ddns.sh
#      安装定时任务  ./cf-ddns.sh --install-cron   (每分钟自动检测)
set -euo pipefail

# ======================= 需要你填的三项 =======================
CF_API_TOKEN="cfut_lBV7Jy4Jwj94NmFwUIEm0kgDZai3IV5eNPnjGBSK52ac6288"   # CF API Token
ZONE_NAME="spzones.store"                  # 主域名(根域)
RECORD_NAME="x87anlz.spzones.store"        # 要更新的完整域名
# ============================================================

PROXIED="false"                            # 是否走 CF 代理(橙色云朵)。DDNS 一般填 false
TTL="60"                                   # 记录 TTL(秒),1=自动
LOG_PATH="/var/log/cf-ddns.log"            # 日志路径
API="https://api.cloudflare.com/client/v4"

log() { echo "[$(date '+%F %T')] $*"; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "缺少依赖: $1" >&2; exit 1; }; }
need curl

AUTH=(-H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json")

# 从 JSON 里取字段(优先用 jq,没有就退回 grep/sed)
jget() { # jget <json> <jq表达式> <grep兜底key>
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -r "$2"
  else
    printf '%s' "$1" | grep -o "\"$3\":[^,}]*" | head -n1 | sed -E 's/.*:\s*"?([^"]*)"?/\1/'
  fi
}

# ---------------- 安装定时任务 ----------------
if [[ "${1:-}" == "--install-cron" ]]; then
  need crontab
  SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  chmod +x "$SELF"
  LINE="* * * * * /bin/bash ${SELF} >> ${LOG_PATH} 2>&1"
  # 去掉本脚本已有的旧任务行,避免重复
  ( crontab -l 2>/dev/null | grep -Fv "$SELF" || true; echo "$LINE" ) | crontab -
  echo "已安装定时任务(每分钟一次): $LINE"
  echo "日志: $LOG_PATH"
  echo "立即执行一次 ↓"
  exec /bin/bash "$SELF"
fi

# ---------------- 单次执行:检测并更新 ----------------
# 1) 取当前公网 IP —— GCP 优先用元数据服务器,拿不到再退回公网服务
IP="$(curl -s --max-time 5 -H 'Metadata-Flavor: Google' \
  'http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip' 2>/dev/null || true)"
if ! [[ "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  IP="$(curl -fsS --max-time 10 https://ipv4.icanhazip.com | tr -d '[:space:]')"
fi
if ! [[ "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  log "取不到有效 IPv4: '$IP'"; exit 1
fi

# 2) 查 Zone ID
ZRESP="$(curl -fsS "${API}/zones?name=${ZONE_NAME}" "${AUTH[@]}")"
ZID="$(jget "$ZRESP" '.result[0].id // empty' id)"
[[ -n "$ZID" ]] || { log "找不到 Zone: $ZONE_NAME —— 响应: $ZRESP"; exit 1; }

# 3) 查 A 记录
RRESP="$(curl -fsS "${API}/zones/${ZID}/dns_records?type=A&name=${RECORD_NAME}" "${AUTH[@]}")"
RID="$(jget "$RRESP" '.result[0].id // empty' id)"
OLD_IP="$(jget "$RRESP" '.result[0].content // empty' content)"

# 4) 不存在→创建;IP没变→跳过;变了→更新
DATA="$(printf '{"type":"A","name":"%s","content":"%s","ttl":%s,"proxied":%s}' \
        "$RECORD_NAME" "$IP" "$TTL" "$PROXIED")"

if [[ -z "$RID" ]]; then
  RESP="$(curl -fsS -X POST "${API}/zones/${ZID}/dns_records" "${AUTH[@]}" --data "$DATA")"
  [[ "$(jget "$RESP" '.success' success)" == "true" ]] || { log "创建失败: $RESP"; exit 1; }
  log "已创建: $RECORD_NAME -> $IP"
elif [[ "$OLD_IP" == "$IP" ]]; then
  log "IP 未变化 ($IP),无需更新"
else
  RESP="$(curl -fsS -X PUT "${API}/zones/${ZID}/dns_records/${RID}" "${AUTH[@]}" --data "$DATA")"
  [[ "$(jget "$RESP" '.success' success)" == "true" ]] || { log "更新失败: $RESP"; exit 1; }
  log "已更新: $RECORD_NAME  $OLD_IP -> $IP"
fi
