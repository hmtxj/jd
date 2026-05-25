#!/usr/bin/env bash
# ============================================================
# one-click-reality.sh
# 一键部署 VLESS Reality + linux.do 自动分流(WireGuard出站)
# ------------------------------------------------------------
# 用法:
#   bash <(curl -fsSL https://raw.githubusercontent.com/hmtxj/jd/main/one-click-reality.sh)
#
# 可选环境变量:
#   WARP_DOMAINS="linux.do,example.com"  自定义走WireGuard的域名(逗号分隔)
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

WARP_DOMAINS=${WARP_DOMAINS:-"linux.do"}

echo -e "${GREEN}[1/5] 安装依赖...${NC}"
apt-get update -qq > /dev/null 2>&1
apt-get install -y -qq curl wget wireguard-tools python3 jq > /dev/null 2>&1

echo -e "${GREEN}[2/5] 安装 v2ray-agent...${NC}"
if ! command -v vasma &> /dev/null; then
    wget -q -P /root -N --no-check-certificate \
        "https://raw.githubusercontent.com/mack-a/v2ray-agent/master/install.sh"
    chmod 700 /root/install.sh
    # 非交互: 选3(Reality无域名) -> 选1(xray-core) -> 其余回车默认
    printf '3\n1\n\n\n\n\n\n\n\n\n' | /root/install.sh
else
    echo "v2ray-agent 已安装，跳过"
fi

# 等待 xray 启动
sleep 3
if ! systemctl is-active --quiet xray; then
    echo -e "${RED}xray 未运行，尝试启动...${NC}"
    systemctl start xray
    sleep 2
fi

echo -e "${GREEN}[3/5] 注册 WireGuard 凭据...${NC}"
WG_PRIVATE=$(wg genkey)
WG_PUBLIC=$(echo "$WG_PRIVATE" | wg pubkey)

REG_RESULT=$(curl -sS -X POST 'https://api.cloudflareclient.com/v0a2158/reg' \
    -H 'Content-Type: application/json' \
    -H 'User-Agent: okhttp/3.12.1' \
    -d "{
        \"key\":\"${WG_PUBLIC}\",
        \"install_id\":\"\",
        \"fcm_token\":\"\",
        \"tos\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",
        \"model\":\"Linux\",
        \"serial_number\":\"$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)\"
    }")

PEER_PUB=$(echo "$REG_RESULT" | jq -r '.config.peers[0].public_key')
PEER_ENDPOINT=$(echo "$REG_RESULT" | jq -r '.config.peers[0].endpoint.host')
ADDR_V4=$(echo "$REG_RESULT" | jq -r '.config.interface.addresses.v4')
ADDR_V6=$(echo "$REG_RESULT" | jq -r '.config.interface.addresses.v6')
CLIENT_ID=$(echo "$REG_RESULT" | jq -r '.config.client_id')
RESERVED=$(python3 -c "import base64,json; print(json.dumps(list(base64.b64decode('${CLIENT_ID}'))))")

if [ -z "$PEER_PUB" ] || [ "$PEER_PUB" = "null" ]; then
    echo -e "${RED}WireGuard 注册失败:${NC}"
    echo "$REG_RESULT"
    exit 1
fi
echo -e "${CYAN}WireGuard 注册成功, 分配 IP: ${ADDR_V4}${NC}"

echo -e "${GREEN}[4/5] 配置分流规则...${NC}"

# 构建域名规则数组
DOMAIN_RULES=""
IFS=',' read -ra DOMAINS <<< "$WARP_DOMAINS"
for d in "${DOMAINS[@]}"; do
    d=$(echo "$d" | xargs)
    DOMAIN_RULES="${DOMAIN_RULES}\"domain:${d}\","
done
DOMAIN_RULES="[${DOMAIN_RULES%,}]"

# WireGuard 出站配置
cat > /etc/v2ray-agent/xray/conf/10_warp_outbound.json << EOF
{
  "outbounds": [
    {
      "tag": "warp_out",
      "protocol": "wireguard",
      "settings": {
        "secretKey": "${WG_PRIVATE}",
        "address": ["${ADDR_V4}/32", "${ADDR_V6}/128"],
        "peers": [
          {
            "publicKey": "${PEER_PUB}",
            "allowedIPs": ["0.0.0.0/0", "::/0"],
            "endpoint": "${PEER_ENDPOINT}"
          }
        ],
        "reserved": ${RESERVED},
        "mtu": 1280
      }
    }
  ]
}
EOF

# 分流规则
cat > /etc/v2ray-agent/xray/conf/09_routing.json << EOF
{
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "domain": ${DOMAIN_RULES},
        "outboundTag": "warp_out"
      }
    ]
  }
}
EOF

echo -e "${GREEN}[5/5] 重启 xray...${NC}"
systemctl restart xray
sleep 2

if systemctl is-active --quiet xray; then
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  部署完成 — VLESS Reality + 分流${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""

    SUBSCRIBE_DIR="/etc/v2ray-agent/subscribe_local/default"
    if [ -d "$SUBSCRIBE_DIR" ]; then
        echo -e "${CYAN}节点链接:${NC}"
        for f in "$SUBSCRIBE_DIR"/*; do
            cat "$f"
            echo ""
        done
    fi

    echo ""
    echo -e "${YELLOW}分流规则:${NC}"
    for d in "${DOMAINS[@]}"; do
        echo -e "  ${d} -> WireGuard 出站 (绕过 IP 封锁)"
    done
    echo -e "  其他流量 -> 直连"
    echo ""
    echo -e "${GREEN}============================================${NC}"
else
    echo -e "${RED}xray 启动失败:${NC}"
    journalctl -u xray --no-pager -n 20
    exit 1
fi
