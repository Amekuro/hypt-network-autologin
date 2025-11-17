#!/bin/sh

# ======================= 配置区 =======================
# 您的校园网账号和密码
USERNAME="你的学号"
PASSWORD="你的密码"

# 需要监控和认证的所有WAN接口，用空格隔开
# 注意：这里的名字必须和 mwan3 status 输出中的接口名完全一致 (wan, vwan1, vwan2)
INTERFACES="wan vwan1 vwan2"

# User-Agent, 一般无需修改
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/5.0 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

# 认证服务器的探测IP (用于获取认证页面)
PROBE_IP="2.2.2.2"
# ======================================================

# 日志函数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
    if [ "$DEBUG_MODE" != true ]; then
        logger -t CampusLogin "$1"
    fi
}

# --- 主程序开始 ---

DEBUG_MODE=false
if [ "$1" = "debug" ]; then
    DEBUG_MODE=true
    echo "
    ###########################
    #    DEBUG MODE ENABLED   #
    ###########################
    "
fi

log "============ 开始执行基于 mwan3 状态的精准认证任务 ============"

# 步骤 1: 获取 mwan3 的权威状态报告
# 将报告存入变量，避免在循环中重复执行命令
MWAN_STATUS=$(mwan3 status)

if [ "$DEBUG_MODE" = true ]; then
    log "------------ mwan3 status 报告全文 ------------"
    echo "$MWAN_STATUS"
    log "-------------------------------------------"
fi

# 步骤 2: 遍历所有需要监控的接口，进行精准判断和修复
for IFACE in $INTERFACES; do
    log "[$IFACE] -> 正在检查状态..."

    # 核心判断：在 mwan3 报告中查找该接口是否在线
    if echo "$MWAN_STATUS" | grep -q "interface $IFACE is online"; then
        log "[$IFACE] -> 状态: Online. 无需操作。"
    else
        log "[$IFACE] -> 状态: OFFLINE 或未知! 启动认证流程..."
        
        # --- 精准认证模块 ---
        CURL_OPTS="-s --connect-timeout 5 -m 10 --interface $IFACE"
        if [ "$DEBUG_MODE" = true ]; then
            CURL_OPTS="-v --connect-timeout 5 -m 10 --interface $IFACE"
        fi

        REDIRECT_INFO=$(curl $CURL_OPTS -i -A "$USER_AGENT" http://$PROBE_IP)
        CURL_EXIT_CODE=$?

        if [ "$DEBUG_MODE" = true ]; then
            log "[$IFACE] -> ------ Curl Raw Response Start ------"
            echo "$REDIRECT_INFO"
            log "[$IFACE] -> ------ Curl Raw Response End (Exit Code: $CURL_EXIT_CODE) ------"
        fi

        if echo "$REDIRECT_INFO" | grep -q "portalLogout.do"; then
            log "[$IFACE] -> 认证状态异常：接口已认证但 mwan3 报告离线。建议检查 mwan3 的跟踪设置。"
        elif echo "$REDIRECT_INFO" | grep -q "location.replace"; then
            log "[$IFACE] -> 收到Portal链接，执行认证..."
            
            PORTAL_URL=$(echo "$REDIRECT_INFO" | sed -n 's/.*location\.replace("\([^"]*\)".*/\1/p')
            WLAN_USER_IP=$(echo "$PORTAL_URL" | sed -n 's/.*wlanuserip=\([^&]*\).*/\1/p')
            WLAN_AC_NAME=$(echo "$PORTAL_URL" | sed -n 's/.*wlanacname=\([^&]*\).*/\1/p')
            MAC=$(echo "$PORTAL_URL" | sed -n 's/.*mac=\([^&]*\).*/\1/p')
            VLAN=$(echo "$PORTAL_URL" | sed -n 's/.*vlan=\([^&]*\).*/\1/p')

            if [ -z "$WLAN_USER_IP" ] || [ -z "$WLAN_AC_NAME" ] || [ -z "$MAC" ]; then
                log "[$IFACE] -> 错误: 从Portal URL中解析参数失败。"
                continue
            fi

            WLAN_AC_IP="10.5.0.12"; TIMESTAMP=$(date +%s%3N); UUID=$(cat /proc/sys/kernel/random/uuid); MAC_ENCODED=$(echo "$MAC" | sed 's/:/%3A/g')
            AUTH_URL="http://10.5.0.11/quickauth.do"
            QUERY_PARAMS="userid=${USERNAME}&passwd=${PASSWORD}&wlanuserip=${WLAN_USER_IP}&wlanacname=${WLAN_AC_NAME}&wlanacIp=${WLAN_AC_IP}&ssid=&vlan=${VLAN}&mac=${MAC_ENCODED}&version=0&portalpageid=1&timestamp=${TIMESTAMP}&uuid=${UUID}&portaltype=0&hostname=&bindCtrlId=&validateType=0&bindOperatorType=2&sendFttrNotice=0&skipTemporaryCheck=false&token3gpp=&noBindMac=0&roleGroupId=&roleClassId=&testGateWay="
            LOGIN_URL="${AUTH_URL}?${QUERY_PARAMS}"
            RESPONSE=$(curl $CURL_OPTS "$LOGIN_URL")

            if echo "$RESPONSE" | grep -q '"code":"0"' && echo "$RESPONSE" | grep -q '认证成功'; then
                log "[$IFACE] -> 认证成功！请等待 mwan3 恢复接口状态。"
            else
                ERROR_MSG=$(echo "$RESPONSE" | sed -n 's/.*"message":"\([^"]*\)".*/\1/p')
                log "[$IFACE] -> 认证失败: ${ERROR_MSG}"
            fi
        else
            log "[$IFACE] -> 访问探测地址失败或返回未知内容 (Curl Exit Code: $CURL_EXIT_CODE)。"
        fi
    fi
    sleep 1
done

log "============ 精准认证任务执行完毕 ============"
exit 0
