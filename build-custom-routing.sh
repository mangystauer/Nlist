~ # cat /opt/etc/xray/build-custom-routing.sh
#!/bin/sh

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

# Create original backup on first run
if [ ! -f "$ORIGINAL_ROUTING" ]; then
  echo "[$(date)] Creating original backup..." >> $LOG_FILE
  # Restore from backup if available
  if [ -f "$BASE_BACKUP" ]; then
    cp "$BASE_BACKUP" "$ORIGINAL_ROUTING"
  else
    # Create minimal original (3 Russian rules + catch-all)
    cat > "$ORIGINAL_ROUTING" << 'JSONEOF'
{
  "routing": {
    "rules": [
      {
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
        "ip": [
          "188.124.45.105/30"
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

# Always start from ORIGINAL, not from current (prevents duplication)
cp "$ORIGINAL_ROUTING" "$BASE_ROUTING"
echo "[$(date)] Reset to original config (prevents duplication)" >> $LOG_FILE

# Create backup of original
cp "$ORIGINAL_ROUTING" "$BASE_BACKUP"

# Download override list
GITHUB_SUCCESS=0
if curl -sL "$GITHUB_URL" -o "$OVERRIDE_FILE" 2>/dev/null && [ -s "$OVERRIDE_FILE" ]; then
  echo "[$(date)] ✓ Downloaded override from GitHub" >> $LOG_FILE
  GITHUB_SUCCESS=1
  cp "$OVERRIDE_FILE" "$OVERRIDE_CACHE"
fi

# If GitHub failed, use cache
if [ $GITHUB_SUCCESS -eq 0 ]; then
  if [ -f "$OVERRIDE_CACHE" ]; then
    echo "[$(date)] GitHub unavailable - using cached override" >> $LOG_FILE
    cp "$OVERRIDE_CACHE" "$OVERRIDE_FILE"
  else
    echo "[$(date)] ERROR: GitHub unavailable and no cache exists" >> $LOG_FILE
    exit 1
  fi
fi

# Validate
if ! jq empty "$OVERRIDE_FILE" 2>/dev/null; then
  echo "[$(date)] ERROR: Invalid override.json" >> $LOG_FILE
  exit 1
fi

DIRECT=$(jq '.direct | length' "$OVERRIDE_FILE")
VLESS=$(jq '.vless | length' "$OVERRIDE_FILE")
echo "[$(date)] Using: $DIRECT direct + $VLESS vless domains" >> $LOG_FILE

# Clean base config: remove comments
sed 's/\/\/.*$//' "$BASE_ROUTING" | sed '/^[[:space:]]*$/d' > "$CLEAN_BASE"

if [ ! -s "$CLEAN_BASE" ]; then
  echo "[$(date)] ERROR: Cleaned base config is empty" >> $LOG_FILE
  exit 1
fi

# Extract rules
RULES_ONLY=$(jq '.routing.rules' "$CLEAN_BASE" 2>/dev/null)
if [ $? -ne 0 ]; then
  echo "[$(date)] ERROR: Failed to extract rules from base config" >> $LOG_FILE
  exit 1
fi

echo "[$(date)] Extracted $(echo "$RULES_ONLY" | jq 'length') existing rules" >> $LOG_FILE

# Build new config
cat > "$TEMP_ROUTING" << 'JSONEOF'
{
  "routing": {
    "rules": []
  }
}
JSONEOF

# Add custom rules + existing rules
jq \
  --slurpfile override "$OVERRIDE_FILE" \
  --argjson existing "$RULES_ONLY" \
  '.routing.rules = [
    {
      "comment": "Custom from GitHub - direct",
      "domain": $override[0].direct,
      "outboundTag": "direct"
    },
    {
      "comment": "Custom from GitHub - vless",
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

# Validate
if ! jq empty "$TEMP_ROUTING" 2>/dev/null; then
  echo "[$(date)] ERROR: Generated config is invalid" >> $LOG_FILE
  exit 1
fi

TOTAL=$(jq '.routing.rules | length' "$TEMP_ROUTING")
echo "[$(date)] ✓ Built config with $TOTAL rules (2 custom + 3 Russian)" >> $LOG_FILE

# Replace
cp "$TEMP_ROUTING" "$BASE_ROUTING"
echo "[$(date)] ✓ Config file written" >> $LOG_FILE

# Restart XKeen
if xkeen -restart > /tmp/xkeen-restart.log 2>&1; then
  sleep 2
  if xkeen -status 2>&1 | grep -q "запущен"; then
    echo "[$(date)] ✓ XKeen restarted successfully" >> $LOG_FILE
    echo "[$(date)] ✓ Update complete!" >> $LOG_FILE
  else
    echo "[$(date)] ERROR: XKeen not running after restart - restoring backup" >> $LOG_FILE
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
