#!/bin/bash

# ==============================================================================
# Ubuntu Server Global Proxy Control Script
#
# 使用环境变量来设置系统级代理，适用于命令行环境。
# ==============================================================================

# ==============================================================================
# 配置变量（根据你的环境修改）
# ==============================================================================
CLASH_PATH="$HOME/share/clash/clash"             # Clash可执行文件路径 (请修改为你的路径)
CONFIG_PATH="$HOME/share/clash/config.yaml"      # Clash配置文件路径
WORK_DIR=$(dirname "$CLASH_PATH")                # Clash运行目录（工作目录）

PROXY_TYPE="HTTP"                                # 代理类型：HTTP 或 SOCKS5
PROXY_HOST="127.0.0.1"                           # 代理服务器地址
HTTP_PROXY_PORT="7890"                           # HTTP 代理端口
SOCKS5_PROXY_PORT="7891"                         # SOCKS5 代理端口

# --- 新增 ---
# 配置要跳过代理的地址列表
IGNORE_HOSTS=(
    "localhost"
    "127.0.0.1"
    "*.lan"
    "*.local"
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
)

# ==============================================================================
# 函数定义
# ==============================================================================

check_clash_running() {
    if pgrep -x "clash" > /dev/null; then return 0; else return 1; fi
}

# Export proxy environment variables (set both lowercase and uppercase)
set_proxy_env() {
    if [[ "$PROXY_TYPE" == "HTTP" ]]; then
        export http_proxy="http://${PROXY_HOST}:${HTTP_PROXY_PORT}"
        export https_proxy="http://${PROXY_HOST}:${HTTP_PROXY_PORT}"
        unset all_proxy

        export HTTP_PROXY="$http_proxy"
        export HTTPS_PROXY="$https_proxy"
        unset ALL_PROXY

        echo "Proxy enabled (HTTP)"
    elif [[ "$PROXY_TYPE" == "SOCKS5" ]]; then
        export all_proxy="socks5://${PROXY_HOST}:${SOCKS5_PROXY_PORT}"
        unset http_proxy https_proxy

        export ALL_PROXY="$all_proxy"
        unset HTTP_PROXY HTTPS_PROXY

        echo "Proxy enabled (SOCKS5)"
    else
        echo "Error: Invalid PROXY_TYPE ($PROXY_TYPE). Use HTTP or SOCKS5." >&2
        exit 1
    fi

    # Setup ignore hosts
    local no_proxy_list=""
    for host in "${IGNORE_HOSTS[@]}"; do
        if [[ -z "$no_proxy_list" ]]; then
            no_proxy_list="$host"
        else
            no_proxy_list="$no_proxy_list,$host"
        fi
    done
    export no_proxy="$no_proxy_list"
    export NO_PROXY="$no_proxy_list"

    echo "No Proxy list set: $no_proxy"
}

# Unset proxy environment variables (both lowercase and uppercase)
unset_proxy_env() {
    unset http_proxy https_proxy all_proxy no_proxy
    unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
    echo "Proxy disabled (environment variables unset)"
}

check_proxy_functional() {
    if ! command -v jq &> /dev/null; then
        echo "Warning: 'jq' not found, location info is unavailable. Run: sudo apt install jq" >&2
        return 1
    fi

    local proxy_url
    if [[ "$PROXY_TYPE" == "HTTP" ]]; then
        proxy_url="http://${PROXY_HOST}:${HTTP_PROXY_PORT}"
    else
        proxy_url="socks5://${PROXY_HOST}:${SOCKS5_PROXY_PORT}"
    fi

    local test_urls=("http://ip-api.com/json" "http://ipinfo.io")

    local direct_response_json=""
    for url in "${test_urls[@]}"; do
        direct_response_json=$(curl -s -m 8 "$url")
        [[ -n "$direct_response_json" ]] && break
    done

    local proxied_response_json=""
    for url in "${test_urls[@]}"; do
        proxied_response_json=$(curl -s -m 8 --proxy "$proxy_url" "$url")
        [[ -n "$proxied_response_json" ]] && break
    done

    parse_location() {
        local response_json="$1"; local url="$2"
        if [[ "$url" == *"ip-api.com"* ]]; then
            ip=$(echo "$response_json" | jq -r '.query')
            city=$(echo "$response_json" | jq -r '.city')
            region=$(echo "$response_json" | jq -r '.regionName')
            country=$(echo "$response_json" | jq -r '.country')
        else
            ip=$(echo "$response_json" | jq -r '.ip')
            city=$(echo "$response_json" | jq -r '.city')
            region=$(echo "$response_json" | jq -r '.region')
            country=$(echo "$response_json" | jq -r '.country')
        fi
        echo "$ip | $city,$region,$country"
    }

    local direct_info=$(parse_location "$direct_response_json" "ip-api.com")
    local proxied_info=$(parse_location "$proxied_response_json" "ip-api.com")

    local direct_ip=$(echo "$direct_info" | cut -d'|' -f1 | xargs)
    local proxied_ip=$(echo "$proxied_info" | cut -d'|' -f1 | xargs)

    echo "  Real IP: $direct_info"
    echo " Proxy IP: $proxied_info"

    if [[ "$proxied_ip" != "$direct_ip" && -n "$proxied_ip" ]]; then
        echo "   Status: Proxy is functional."
        return 0
    else
        echo "   Status: Proxy test failed."
        return 1
    fi
}

enable_proxy() {
    if [[ ! -f "$CLASH_PATH" ]]; then
        echo "Error: Clash executable not found at $CLASH_PATH" >&2; exit 1; fi
    if [[ ! -f "$CONFIG_PATH" ]]; then
        echo "Error: Clash config file not found at $CONFIG_PATH" >&2; exit 1; fi

    if check_clash_running; then
        echo "Clash is already running"
    else
        echo "Starting Clash..."
        (cd "$WORK_DIR" && "$CLASH_PATH" -d "$WORK_DIR" -f "$CONFIG_PATH" > /tmp/clash.log 2>&1 &)
        sleep 2
    fi

    set_proxy_env
    echo "--- IP & Connectivity ---"
    check_proxy_functional
}

disable_proxy() {
    unset_proxy_env
    if check_clash_running; then
        echo "Stopping Clash..."
        pkill -x clash
        sleep 1
    fi
}

show_status() {
    echo "=== Proxy Status ==="
    if check_clash_running; then
        echo "Clash is running (PID: $(pgrep -x clash))"
    else
        echo "Clash is not running"
    fi

    echo "--- IP & Connectivity ---"
    check_proxy_functional
}

# ==============================================================================
# Main Logic
# ==============================================================================
case "$1" in
    on) enable_proxy ;;
    off) disable_proxy ;;
    info) show_status ;;
    *) echo "Usage: $0 {on|off|info}" >&2; exit 1 ;;
esac
