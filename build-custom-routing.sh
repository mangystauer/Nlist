#!/bin/sh

GITLAB_URL="http://192.168.1.88/nktz/Nlist/-/raw/main/override.json"
GITHUB_URL="https://raw.githubusercontent.com/mangystauer/Nlist/refs/heads/main/override.json"
OVERRIDE_FILE="/tmp/override.json"
BASE_ROUTING="/opt/etc/xray/configs/05_routing.json"
BASE_BACKUP="/opt/etc/xray/configs/05_routing.json.bak"
OVERRIDE_CACHE="/opt/etc/xray/override.json.cache"
ORIGINAL_ROUTING="/opt/etc/xray/configs/05_routing.original.json"
TEMP_ROUTING="/tmp/05_routing.tmp.json"
CLEAN_BASE="/tmp/05_routing.clean.json"
LOG_FILE="/var/log/xkeen-custom-routing.log"

echo "[$(date)] Starting custom routing build..." >> $LOG_FILE

if [ ! -f "$ORIGINAL_ROUTING" ]; then
  echo "[$(date)] Creating original backup..." >> $LOG_FILE
  if [ -f "$BASE_BACKUP" ]; then
    cp "$BASE_BACKUP" "$ORIGINAL_ROUTING"
  else
    cat > "$ORIGINAL_ROUTING" << 'JSONEOF'
{
  "routing": {
    "rules": [
      {
        "comment": "RU domains - direct",
        "domain": [
          "xn--",
          "domain:su",
          "domain:ru",
          "domain:by",
          "domain:moscow",
          "yandex",
          "yastatic.net"
        ],
        "outboundTag": "direct"
      },
      {
        "comment": "Instagram/Facebook - vless",
        "domain": [
          "domain:instagram.com",
          "domain:facebook.com",
          "domain:fbcdn.net",
          "domain:instagram.fbsbx.com",
          "domain:scontent.cdninstagram.com"
        ],
        "outboundTag": "vless-reality"
      },
      {
        "ip": [
          "188.124.45.105/30"
        ],
        "outboundTag": "direct"
      },
      {
        "ip": [
          "ext:geoip_zkeenip.dat:ru"
        ],
        "outboundTag": "direct"
      },
      {
        "network": "tcp,udp",
        "outboundTag": "vless-reality"
      }
    ]
  }
}
JSONEOF
  fi
fi

cp "$ORIGINAL_ROUTING" "$BASE_ROUTING"
echo "[$(date)] Reset to original config" >> $LOG_FILE
cp "$ORIGINAL_ROUTING" "$BASE_BACKUP"

# Download override — GitLab first, GitHub fallback, then cache
DOWNLOAD_SUCCESS=0

if curl -sL --connect-timeout 5 "$GITLAB_URL" -o "$OVERRIDE_FILE" 2>/dev/null && [ -s "$OVERRIDE_FILE" ] && jq empty "$OVERRIDE_FILE" 2>/dev/null; then
  echo "[$(date)] ✓ Downloaded override from GitLab" >> $LOG_FILE
  DOWNLOAD_SUCCESS=1
  cp "$OVERRIDE_FILE" "$OVERRIDE_CACHE"
fi

if [ $DOWNLOAD_SUCCESS -eq 0 ]; then
  echo "[$(date)] GitLab unavailable, trying GitHub..." >> $LOG_FILE
  if curl -sL --connect-timeout 10 "$GITHUB_URL" -o "$OVERRIDE_FILE" 2>/dev/null && [ -s "$OVERRIDE_FILE" ] && jq empty "$OVERRIDE_FILE" 2>/dev/null; then
    echo "[$(date)] ✓ Downloaded override from GitHub" >> $LOG_FILE
    DOWNLOAD_SUCCESS=1
    cp "$OVERRIDE_FILE" "$OVERRIDE_CACHE"
  fi
fi

if [ $DOWNLOAD_SUCCESS -eq 0 ]; then
  if [ -f "$OVERRIDE_CACHE" ]; then
    echo "[$(date)] Both sources unavailable - using cached override" >> $LOG_FILE
    cp "$OVERRIDE_CACHE" "$OVERRIDE_FILE"
  else
    echo "[$(date)] ERROR: All sources unavailable and no cache exists" >> $LOG_FILE
    exit 1
  fi
fi

if ! jq empty "$OVERRIDE_FILE" 2>/dev/null; then
  echo "[$(date)] ERROR: Invalid override.json" >> $LOG_FILE
  exit 1
fi

DIRECT=$(jq '.direct | length' "$OVERRIDE_FILE")
DIRECT_IPS=$(jq '.direct_ips | length' "$OVERRIDE_FILE" 2>/dev/null || echo "0")
VLESS=$(jq '.vless | length' "$OVERRIDE_FILE")
echo "[$(date)] Using: $DIRECT domains, $DIRECT_IPS IPs (direct) + $VLESS domains (vless)" >> $LOG_FILE

sed 's/\/\/.*$//' "$BASE_ROUTING" | sed '/^[[:space:]]*$/d' > "$CLEAN_BASE"

if [ ! -s "$CLEAN_BASE" ]; then
  echo "[$(date)] ERROR: Cleaned base config is empty" >> $LOG_FILE
  exit 1
fi

RULES_ONLY=$(jq '.routing.rules' "$CLEAN_BASE" 2>/dev/null)
if [ $? -ne 0 ]; then
  echo "[$(date)] ERROR: Failed to extract rules" >> $LOG_FILE
  exit 1
fi

echo "[$(date)] Extracted $(echo "$RULES_ONLY" | jq 'length') existing rules" >> $LOG_FILE

cat > "$TEMP_ROUTING" << 'JSONEOF'
{
  "routing": {
    "rules": []
  }
}
JSONEOF

jq \
  --slurpfile override "$OVERRIDE_FILE" \
  --argjson existing "$RULES_ONLY" \
  '.routing.rules = [
    {
      "comment": "Custom - direct domains",
      "domain": $override[0].direct,
      "outboundTag": "direct"
    },
    {
      "comment": "Custom - direct IPs (Telegram, etc)",
      "ip": $override[0].direct_ips,
      "outboundTag": "direct"
    },
    {
      "comment": "Custom - vless domains (blocked sites)",
      "domain": $override[0].vless,
      "outboundTag": "vless-reality"
    }
  ] + $existing' \
  "$TEMP_ROUTING" > "$TEMP_ROUTING.new"

if [ $? -ne 0 ]; then
  echo "[$(date)] ERROR: Failed to build config with jq" >> $LOG_FILE
  exit 1
fi

mv "$TEMP_ROUTING.new" "$TEMP_ROUTING"

if ! jq empty "$TEMP_ROUTING" 2>/dev/null; then
  echo "[$(date)] ERROR: Generated config is invalid" >> $LOG_FILE
  exit 1
fi

TOTAL=$(jq '.routing.rules | length' "$TEMP_ROUTING")
echo "[$(date)] ✓ Built config with $TOTAL rules" >> $LOG_FILE

cp "$TEMP_ROUTING" "$BASE_ROUTING"
echo "[$(date)] ✓ Config file written" >> $LOG_FILE

if xkeen -restart > /tmp/xkeen-restart.log 2>&1; then
  sleep 2
  if xkeen -status 2>&1 | grep -q "запущен"; then
    echo "[$(date)] ✓ XKeen restarted successfully" >> $LOG_FILE
    echo "[$(date)] ✓ Update complete!" >> $LOG_FILE
  else
    echo "[$(date)] ERROR: XKeen not running - restoring backup" >> $LOG_FILE
    cp "$BASE_BACKUP" "$BASE_ROUTING"
    xkeen -restart
    exit 1
  fi
else
  echo "[$(date)] ERROR: XKeen restart failed - restoring backup" >> $LOG_FILE
  cp "$BASE_BACKUP" "$BASE_ROUTING"
  xkeen -restart
  exit 1
fi
