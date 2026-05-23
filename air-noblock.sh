#!/usr/bin/env bash
# ============================================================
# air-noblock.sh —— 基于 ssss.nyc.mn/air.sh 的无屏蔽版本
# ------------------------------------------------------------
# 原版 air.sh 部署的节点代码(eooce/node-ws 和 eooce/python-ws)
# 在源码中硬编码了一个 BLOCKED_DOMAINS 数组,会拒绝代理以下域名:
#   speedtest.net / fast.com / speedtest.cn / speed.cloudflare.com
#   speedof.me / testmy.net / bandwidth.place / speed.io
#   librespeed.org / speedcheck.org
#
# 本版本在 wget 源码之后、混淆之前,用 sed -z 把数组清空,
# 使所有此前被屏蔽的网站(尤其是 fast.com)可以正常访问。
# 其他行为与原版完全一致。
#
# 原脚本: https://main.ssss.nyc.mn/air.sh
# 源码来源:
#   https://github.com/eooce/node-ws    (Node.js)
#   https://github.com/eooce/python-ws  (Python)
#
# 用法:
#   bash air-noblock.sh           随机选择 Node.js 或 Python
#   bash air-noblock.sh -js       强制使用 Node.js (推荐,更稳定)
#   bash air-noblock.sh -py       强制使用 Python
#   bash air-noblock.sh -u        卸载
#
# 可选环境变量:
#   UUID=xxx           自定义 UUID,默认随机生成
#   DOMAIN=xxx         反代域名 (Cloudflare 反代后的域名)
#   NEZHA_SERVER=xxx   哪吒探针服务端
#   NEZHA_PORT=xxx     哪吒 v0 端口 (v1 不需要)
#   NEZHA_KEY=xxx      哪吒 client_secret
#   AUTO_ACCESS=true   自动访问保活
#   NAME=xxx           节点名称前缀
# ============================================================

set -e
export UUID=${UUID:-$(uuidgen -r)}
export DEBIAN_FRONTEND=noninteractive

# 安装目录
APP_DIR="/opt/myapp"
STATE_FILE="${APP_DIR}/.project_type"
APP_NAME=$(tr -dc a-z </dev/urandom | head -c 6)
SUBPATH=${UUID}

[[ $EUID -ne 0 ]] && echo -e "\033[1;91m请root用户下运行脚本,输入:sudo -i 切换到root用户后再次运行!\033[0m" && exit 1

# 卸载模式: 支持 -u 或 uninstall
if [[ "$1" == "-u" || "$1" == "u" || "$1" == "uninstall" ]]; then
    echo "执行卸载操作..."

    if [[ -f "${STATE_FILE}" ]]; then
        INSTALLED_TYPE=$(cat "${STATE_FILE}")
        echo "检测到已安装项目: ${INSTALLED_TYPE}"
    else
        echo "未检测到项目状态文件,将执行清理..."
        INSTALLED_TYPE="unknown"
    fi

    pm2 delete all 2>/dev/null || true
    pm2 save >/dev/null 2>&1 || true

    echo "删除 PM2 开机自启"
    pm2 unstartup systemd -u root --hp /root >/dev/null 2>&1 || true

    echo "删除项目目录"
    rm -rf "${APP_DIR}"

    echo ""
    echo -e "\e[1;32m卸载完成\033[0m"
    exit 0
fi

# 选择项目类型
if [[ "$1" == "-js" || "$1" == "js" || "$1" == "nodejs" ]]; then
    PROJECT_TYPE="nodejs"
elif [[ "$1" == "-py" || "$1" == "py" || "$1" == "python" ]]; then
    PROJECT_TYPE="python"
elif [[ -z "$1" ]]; then
    RANDOM_CHOICE=$((RANDOM % 2))
    if [[ $RANDOM_CHOICE -eq 0 ]]; then
        PROJECT_TYPE="nodejs"
        echo -e "\e[1;33m未指定项目类型,随机选择: Nodejs\033[0m"
    else
        PROJECT_TYPE="python"
        echo -e "\e[1;33m未指定项目类型,随机选择: Python\033[0m"
    fi
else
    echo -e "\e[1;31m错误:无效参数\033[0m"
    echo "用法:"
    echo "  bash air-noblock.sh         随机选择 Nodejs 或 Python 项目"
    echo "  bash air-noblock.sh -js     启动 Node.js 项目"
    echo "  bash air-noblock.sh -py     启动 Python 项目"
    echo "  bash air-noblock.sh -u      卸载项目"
    exit 1
fi

# 安装公共依赖
echo "安装依赖中,请稍等..."
apt-get update -qq
apt-get install -y -qq curl wget git ca-certificates gnupg >/dev/null 2>&1

mkdir -p "${APP_DIR}"
echo "${PROJECT_TYPE}" > "${STATE_FILE}"
cd "${APP_DIR}"

# ===========================================
# Node.js 项目流程
# ===========================================
if [[ "$PROJECT_TYPE" == "nodejs" ]]; then
    echo "正在安装 Node.js,请稍等..."
    curl -fsSL https://deb.nodesource.com/setup_current.x | bash - >/dev/null 2>&1
    apt-get install -y -qq nodejs >/dev/null 2>&1

    echo "正在安装 PM2,请稍等..."
    npm install -g pm2 >/dev/null 2>&1

    echo "下载核心文件..."
    wget -q -O index.html https://raw.githubusercontent.com/eooce/node-ws/main/index.html
    wget -q -O index.js   https://raw.githubusercontent.com/eooce/node-ws/main/index.js

    echo "初始化 npm ..."
    npm init -y >/dev/null 2>&1

    echo "安装项目依赖中,请稍等..."
    npm install axios ws javascript-obfuscator >/dev/null 2>&1

    echo "配置 UUID 和路径..."
    sed -i "13s/const UUID = process.env.UUID || '[^']*'/const UUID = process.env.UUID || '${UUID}'/" index.js
    sed -i "20s/|| 'sub'/|| '${SUBPATH}'/" index.js

    # ============ 关键改动:解除测速站屏蔽 ============
    echo -e "\e[1;36m[noblock] 解除 BLOCKED_DOMAINS 屏蔽 (fast.com / speedtest 等)...\e[0m"
    BEFORE_HITS=$(grep -c "'fast.com'" index.js || echo 0)
    sed -i -z "s/const BLOCKED_DOMAINS = \[[^]]*\];/const BLOCKED_DOMAINS = [];/" index.js
    AFTER_HITS=$(grep -c "'fast.com'" index.js || echo 0)
    if [[ "${BEFORE_HITS}" -gt 0 && "${AFTER_HITS}" -eq 0 ]]; then
        echo -e "\e[1;32m[noblock] OK - 屏蔽数组已清空\e[0m"
    else
        echo -e "\e[1;91m[noblock] 警告: BLOCKED_DOMAINS 未被清空 (before=${BEFORE_HITS}, after=${AFTER_HITS})\e[0m"
        echo -e "\e[1;91m[noblock]   可能上游 GitHub 源码结构变了,请手动检查 ${APP_DIR}/index.js\e[0m"
    fi
    # ===============================================

    echo "正在混淆文件..."
    npx javascript-obfuscator index.js \
        --output ${APP_NAME}.js \
        --compact true \
        --control-flow-flattening true \
        --control-flow-flattening-threshold 0.5 \
        --dead-code-injection true \
        --dead-code-injection-threshold 0.2 \
        --string-array true \
        --string-array-threshold 0.75 \
        --rename-globals false \
        >/dev/null 2>&1

    rm -f index.js >/dev/null 2>&1

    echo "启动项目..."
    pm2 start ${APP_NAME}.js --name "${APP_NAME}" >/dev/null 2>&1

# ===========================================
# Python 项目流程
# ===========================================
elif [[ "$PROJECT_TYPE" == "python" ]]; then
    echo "正在安装 Python3 和虚拟环境..."
    apt-get install -y -qq python3 python3-venv python3-pip >/dev/null 2>&1

    if ! command -v python3 &> /dev/null; then
        echo -e "\e[1;31mPython3 安装失败\033[0m"
        exit 1
    fi

    echo "正在安装 PM2 ..."
    if ! command -v pm2 &> /dev/null; then
        if ! command -v node &> /dev/null; then
            curl -fsSL https://deb.nodesource.com/setup_current.x | bash - >/dev/null 2>&1
            apt-get install -y -qq nodejs >/dev/null 2>&1
        fi
        npm install -g pm2 >/dev/null 2>&1
    fi

    echo "下载 Python 项目文件..."
    wget -q -O app.py           https://github.com/eooce/python-ws/raw/refs/heads/main/app.py
    wget -q -O index.html       https://github.com/eooce/python-ws/raw/refs/heads/main/index.html
    wget -q -O requirements.txt https://github.com/eooce/python-ws/raw/refs/heads/main/requirements.txt

    echo "创建 Python 虚拟环境..."
    python3 -m venv venv
    source venv/bin/activate

    echo "安装 Python 依赖..."
    pip install --upgrade pip >/dev/null 2>&1
    pip install -r requirements.txt >/dev/null 2>&1

    echo "配置 UUID 和路径..."
    sed -i "18s/UUID = os.environ.get('UUID', '[^']*')/UUID = os.environ.get('UUID', '${UUID}')/" app.py
    sed -i "23s/SUB_PATH = os.environ.get('SUB_PATH', 'sub')/SUB_PATH = os.environ.get('SUB_PATH', '${SUBPATH}')/" app.py

    # ============ 关键改动:解除测速站屏蔽 ============
    echo -e "\e[1;36m[noblock] 解除 BLOCKED_DOMAINS 屏蔽 (fast.com / speedtest 等)...\e[0m"
    BEFORE_HITS=$(grep -c "'fast.com'" app.py || echo 0)
    sed -i -z "s/BLOCKED_DOMAINS = \[[^]]*\]/BLOCKED_DOMAINS = []/" app.py
    AFTER_HITS=$(grep -c "'fast.com'" app.py || echo 0)
    if [[ "${BEFORE_HITS}" -gt 0 && "${AFTER_HITS}" -eq 0 ]]; then
        echo -e "\e[1;32m[noblock] OK - 屏蔽数组已清空\e[0m"
    else
        echo -e "\e[1;91m[noblock] 警告: BLOCKED_DOMAINS 未被清空 (before=${BEFORE_HITS}, after=${AFTER_HITS})\e[0m"
        echo -e "\e[1;91m[noblock]   可能上游 GitHub 源码结构变了,请手动检查 ${APP_DIR}/app.py\e[0m"
    fi
    # ===============================================

    echo "正在混淆 Python 代码..."
    CODE_JSON=$(cat app.py | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')

    OBFUSCATED=$(curl -s -X POST https://obf.eooce.com/api/obfuscate \
        -H "Content-Type: application/json" \
        -d "{\"code\": ${CODE_JSON}}" | \
        grep -o '"obfuscated":"[^"]*"' | \
        sed 's/"obfuscated":"//' | \
        sed 's/"$//' | \
        sed 's/\\n/\n/g' | \
        sed 's/\\"/"/g' | \
        sed 's/\\\\/\\/g')

    if [[ -n "${OBFUSCATED}" ]]; then
        echo "${OBFUSCATED}" > ${APP_NAME}.py
        rm -f app.py >/dev/null 2>&1
    else
        echo -e "\e[1;33m警告:代码混淆失败,使用原始代码 (功能不受影响)\033[0m"
        mv app.py ${APP_NAME}.py
    fi

    echo "启动 Python 项目..."
    pm2 start ${APP_NAME}.py \
        --name "${APP_NAME}" \
        --interpreter "${APP_DIR}/venv/bin/python3" \
        >/dev/null 2>&1
fi

# 公共后续操作
pm2 startup systemd -u root --hp /root >/dev/null 2>&1
pm2 save >/dev/null 2>&1

IP=$(curl -sm 5 https://api-ipv4.ip.sb/ip)

echo ""
echo -e "\e[1;32m========================================\e[0m"
echo -e "\e[1;32m安装完成 [无屏蔽版本 / noblock]\e[0m"
echo -e "\e[1;32m========================================\e[0m"
echo ""
echo "项目类型: ${PROJECT_TYPE}"
echo "APP_NAME: ${APP_NAME}"
echo "UUID:     ${UUID}"
echo -e "\e[1;32m订阅地址: http://${IP}:3000/${SUBPATH}\e[0m"
echo ""
echo -e "\e[1;33m提示:若使用 CDN/反代,请将订阅链接和节点中的 3000 改为反代端口\e[0m"
echo -e "\e[1;36m本版本已清空 BLOCKED_DOMAINS 数组,所有测速站(含 fast.com)均可正常访问\e[0m"
echo ""
