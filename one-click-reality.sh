#!/usr/bin/env bash
# ============================================================
# one-click-reality.sh
# 一键部署 VLESS Reality + 全局 linux.do 分流
# ------------------------------------------------------------
# 功能:
#   1. 安装 v2ray-agent (VLESS Reality 无域名模式)
#   2. 注册 WireGuard 凭据连接 Cloudflare 网络
#   3. 配置 xray 分流 (节点1 直接生效)
#   4. 配置 iptables 透明代理 (节点2 及 VM 上所有进程生效)
#
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

echo -e "${GREEN}[1/6] 安装依赖...${NC}"
apt-get update -qq > /dev/null 2>&1
apt-get install -y -qq curl wget wireguard-tools python3 jq ipset iptables > /dev/null 2>&1

echo -e "${GREEN}[2/6] 安装 v2ray-agent...${NC}"
if ! command -v vasma &> /dev/null; then
    wget -q -P /root -N --no-check-certificate \
        "https://raw.githubusercontent.com/mack-a/v2ray-agent/master/install.sh"
    chmod 700 /root/install.sh
    printf '3\n1\n\n\n\n\n\n\n\n\n' | /root/install.sh
else
    echo "v2ray-agent 已安装，跳过"
fi

sleep 3
if ! systemctl is-active --quiet xray; then
    echo -e "${RED}xray 未运行，尝试启动...${NC}"
    systemctl start xray
    sleep 2
fi

echo -e "${GREEN}[3/6] 注册 WireGuard 凭据...${NC}"
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

echo -e "${GREEN}[4/6] 配置 xray 分流...${NC}"

IFS=',' read -ra DOMAINS <<< "$WARP_DOMAINS"
DOMAIN_RULES=""
for d in "${DOMAINS[@]}"; do
    d=$(echo "$d" | xargs)
    DOMAIN_RULES="${DOMAIN_RULES}\"domain:${d}\","
done
DOMAIN_RULES="[${DOMAIN_RULES%,}]"

# WireGuard 出站 (带 mark 255 防止 iptables 回环)
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
      },
      "streamSettings": {
        "sockopt": {
          "mark": 255
        }
      }
    }
  ]
}
EOF

# direct 出站也加 mark
cat > /etc/v2ray-agent/xray/conf/z_direct_outbound.json << 'EOF'
{
  "outbounds": [
    {
      "tag": "z_direct_outbound",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "AsIs"
      },
      "streamSettings": {
        "sockopt": {
          "mark": 255
        }
      }
    }
  ]
}
EOF

# 透明代理入站 (给 iptables redirect 用)
cat > /etc/v2ray-agent/xray/conf/08_tproxy_inbound.json << 'EOF'
{
  "inbounds": [
    {
      "tag": "tproxy-in",
      "port": 12345,
      "listen": "127.0.0.1",
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp,udp",
        "followRedirect": true
      },
      "streamSettings": {
        "sockopt": {
          "tproxy": "redirect"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"],
        "routeOnly": true
      }
    }
  ]
}
EOF

# 路由规则: 域名匹配 + tproxy 入站都走 warp
cat > /etc/v2ray-agent/xray/conf/09_routing.json << EOF
{
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "domain": ${DOMAIN_RULES},
        "outboundTag": "warp_out"
      },
      {
        "type": "field",
        "inboundTag": ["tproxy-in"],
        "outboundTag": "warp_out"
      }
    ]
  }
}
EOF

echo -e "${GREEN}[5/6] 配置 iptables 透明代理...${NC}"

systemctl restart xray
sleep 3

if ! systemctl is-active --quiet xray; then
    echo -e "${RED}xray 启动失败:${NC}"
    journalctl -u xray --no-pager -n 10
    exit 1
fi

# 创建 ipset 并添加目标域名的 IP
ipset create linuxdo hash:ip -exist
ipset flush linuxdo

for d in "${DOMAINS[@]}"; do
    d=$(echo "$d" | xargs)
    for ip in $(dig +short "$d" A 2>/dev/null | grep -E '^[0-9]'); do
        ipset add linuxdo "$ip" -exist
    done
done

# iptables: 非 xray 流量(无 mark 255)且目标在 ipset 中 -> 重定向到 xray 透明代理
# 排除 wg0 接口避免回环
iptables -t nat -D OUTPUT -m set --match-set linuxdo dst -p tcp -m mark ! --mark 255 ! -o wg0 -j REDIRECT --to-ports 12345 2>/dev/null || true
iptables -t nat -A OUTPUT -m set --match-set linuxdo dst -p tcp -m mark ! --mark 255 ! -o wg0 -j REDIRECT --to-ports 12345

# 持久化
apt-get install -y -qq iptables-persistent > /dev/null 2>&1 || true
netfilter-persistent save > /dev/null 2>&1 || true
ipset save > /etc/ipset.rules 2>/dev/null || true

# 开机自动恢复 ipset + 动态更新 IP
cat > /etc/cron.d/linuxdo-ipset << 'CRON'
@reboot root ipset create linuxdo hash:ip -exist && ipset restore < /etc/ipset.rules 2>/dev/null
*/30 * * * * root for d in $(cat /etc/linuxdo-domains.txt 2>/dev/null); do for ip in $(dig +short "$d" A 2>/dev/null | grep -E '^[0-9]'); do ipset add linuxdo "$ip" -exist 2>/dev/null; done; done
CRON

# 保存域名列表供 cron 使用
printf '%s\n' "${DOMAINS[@]}" > /etc/linuxdo-domains.txt

echo -e "${GREEN}[6/6] 验证...${NC}"

HTTP_CODE=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
    -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/125.0.0.0 Safari/537.36' \
    https://linux.do/ 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "403" ] || [ "$HTTP_CODE" = "200" ]; then
    echo -e "${GREEN}linux.do 分流验证通过 (HTTP ${HTTP_CODE}, Cloudflare challenge 浏览器会自动过)${NC}"
else
    echo -e "${YELLOW}linux.do 返回 HTTP ${HTTP_CODE}，浏览器访问测试为准${NC}"
fi

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  部署完成 — VLESS Reality + 全局分流${NC}"
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
echo -e "${YELLOW}分流规则 (对 VM 上所有代理节点生效):${NC}"
for d in "${DOMAINS[@]}"; do
    echo -e "  ${d} -> WireGuard 出站"
done
echo -e "  其他流量 -> 直连"
echo ""
echo -e "${CYAN}如需添加更多分流域名，重新运行:${NC}"
echo -e "  WARP_DOMAINS=\"linux.do,other.com\" bash <(curl -fsSL ...)"
echo ""
echo -e "${GREEN}============================================${NC}"
