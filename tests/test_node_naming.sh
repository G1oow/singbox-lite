#!/usr/bin/env bash
# 节点命名规则回归测试
# 依赖: bash、jq、yq (mikefarah v4)
# 用法: bash tests/test_node_naming.sh
set -uo pipefail
# 任何交互式读取都直接失败而不是挂起 CI
exec < /dev/null

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for bin in jq yq; do
    command -v "$bin" >/dev/null 2>&1 || { echo "缺少依赖: $bin" >&2; exit 1; }
done

export SINGBOX_DIR="$WORK/sing-box"
mkdir -p "$SINGBOX_DIR"
export CLASH_YAML_FILE="$SINGBOX_DIR/clash.yaml"
export METADATA_FILE="$SINGBOX_DIR/metadata.json"
export ARGO_METADATA_FILE="$SINGBOX_DIR/argo_metadata.json"
export XRAY_METADATA="$WORK/xray/metadata.json"
export YQ_BINARY="$(command -v yq)"
export BATCH_MODE=false
export NODE_REGION=""

# 预置地区与机器ID缓存，测试不依赖网络
printf '%s\n' '🇭🇰 香港' > "$SINGBOX_DIR/node-region.cache"
printf '%s\n' 'ZT7K2M' > "$SINGBOX_DIR/machine-id"

_warn() { printf '[注意] %s\n' "$1" >&2; }

# 抽取被测函数（singbox.sh 会直接执行主菜单，不能 source 整个文件）
sed -n '/^# --- 节点命名规则/,/^# 系统环境检测/{/^# 系统环境检测/d;p}' \
    "$ROOT/singbox.sh" > "$WORK/naming.sh"
sed -n '/^# --- 节点命名规则/,/^_xray_flock_wait() {/{/^_xray_flock_wait() {/d;p}' \
    "$ROOT/xray_manager.sh" > "$WORK/xray_naming.sh"
sed -n '/^# --- 客户端连接地址/,/^# --- 节点命名规则/{/^# --- 节点命名规则/d;p}' \
    "$ROOT/singbox.sh" > "$WORK/conn.sh"
sed -n '/^# --- 客户端连接地址/,/^# --- 自签证书生成/{/^# --- 自签证书生成/d;p}' \
    "$ROOT/xray_manager.sh" > "$WORK/xray_conn.sh"
# shellcheck disable=SC1090
. "$WORK/naming.sh"
. "$WORK/conn.sh"

fail=0
check() { # 描述 期望 实际
    if [ "$2" = "$3" ]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n      期望: %s\n      实际: %s\n' "$1" "$2" "$3"
        fail=$((fail + 1))
    fi
}

if [ "${XRAY_OPERATIONS_ONLY:-0}" != 1 ]; then
echo "== 地区与旗帜 =="
check "HK 旗帜字节" "🇭🇰" "$(_node_cc_flag HK)"
check "JP 旗帜字节(小写输入)" "🇯🇵" "$(_node_cc_flag jp)"
check "US 旗帜字节" "🇺🇸" "$(_node_cc_flag US)"
check "非法代码回退地球" "🌐" "$(_node_cc_flag 1x)"
check "HK 中文名" "香港" "$(_node_cc_name HK)"
check "未收录代码返回空" "" "$(_node_cc_name ZZ)"
check "缓存命中地区" "🇭🇰 香港" "$(_node_region)"

echo "== 默认节点名 =="
check "普通节点不带端口" "🇭🇰 香港-hy2-ZT7K2M" "$(_node_default_name hy2 8443)"
check "无端口参数" "🇭🇰 香港-Vless-Reality-ZT7K2M" "$(_node_default_name Vless-Reality)"
check "批量模式强制带端口" "🇭🇰 香港-Vless-WS-2053-ZT7K2M" "$(_node_default_name Vless-WS 2053 true)"
check "NODE_REGION 覆盖" "🇯🇵 日本-tuic-ZT7K2M" "$(NODE_REGION='🇯🇵 日本' _node_default_name tuic)"
check "Argo 标签" "🇭🇰 香港-Argo-Temp-Vless-8443-ZT7K2M" \
    "$(_node_default_name "Argo-Temp-Vless" 8443 true)"

echo "== 机器ID =="
check "机器ID 复用缓存" "ZT7K2M" "$(_node_machine_id)"
printf '%s\n' 'bad id!' > "$SINGBOX_DIR/machine-id"
generated=$(_node_machine_id)
case "$generated" in
    ZT[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]) printf 'ok    非法机器ID 自动重生成: %s\n' "$generated" ;;
    *) printf 'FAIL  非法机器ID 未重生成: %s\n' "$generated"; fail=$((fail + 1)) ;;
esac
printf '%s\n' 'ZT7K2M' > "$SINGBOX_DIR/machine-id"

echo "== 重名检测 (jq: 元数据) =="
_node_name_taken "🇭🇰 香港-hy2-ZT7K2M" && r=taken || r=free
check "元数据为空时判定未占用" free "$r"
printf '%s' '{"vless-in-8443":{"name":"🇭🇰 香港-hy2-ZT7K2M"}}' > "$METADATA_FILE"
_node_name_taken "🇭🇰 香港-hy2-ZT7K2M" && r=taken || r=free
check "元数据命中判定占用" taken "$r"
_node_name_taken "🇭🇰 香港-tuic-ZT7K2M" && r=taken || r=free
check "元数据未命中判定空闲" free "$r"
check "同名时自动追加端口" "🇭🇰 香港-hy2-8443-ZT7K2M" "$(_node_default_name hy2 8443)"

echo "== 重名检测 (yq: clash.yaml) =="
cat > "$CLASH_YAML_FILE" <<'YAML'
proxies:
  - name: "🇭🇰 香港-tuic-ZT7K2M"
    type: socks5
    server: 127.0.0.1
    port: 1080
proxy-groups:
  - name: 节点选择
    type: select
    proxies:
      - "🇭🇰 香港-tuic-ZT7K2M"
YAML
_node_name_taken "🇭🇰 香港-tuic-ZT7K2M" && r=taken || r=free
check "clash.yaml 命中判定占用" taken "$r"
check "clash.yaml 同名时追加端口" "🇭🇰 香港-tuic-2053-ZT7K2M" "$(_node_default_name tuic 2053)"

echo "== 改端口只替换独立端口段 =="
check "新格式端口段替换" "🇭🇰 香港-hy2-9000-ZT7K2M" \
    "$(_node_name_replace_port "🇭🇰 香港-hy2-8443-ZT7K2M" 8443 9000)"
check "机器ID 中的数字不被改写" "🇭🇰 香港-hy2-ZT8443" \
    "$(_node_name_replace_port "🇭🇰 香港-hy2-ZT8443" 8443 9000)"
check "旧格式结尾端口替换" "VLESS-WS-9000" \
    "$(_node_name_replace_port "VLESS-WS-8443" 8443 9000)"
check "Argo 名称端口段替换" "🇭🇰 香港-Argo-Temp-Vless-9000-ZT8443" \
    "$(_node_name_replace_port "🇭🇰 香港-Argo-Temp-Vless-8443-ZT8443" 8443 9000)"

echo "== Xray 单独运行兜底 =="
standalone=$(bash -c '. "$1"; _node_default_name "Vless-Reality" 443' _ "$WORK/xray_naming.sh")
check "缓存齐全时与菜单入口一致" "🇭🇰 香港-Vless-Reality-ZT7K2M" "$standalone"
standalone_empty=$(SINGBOX_DIR="$WORK/empty" bash -c '. "$1"; _node_default_name "Vless-Reality" 443' _ "$WORK/xray_naming.sh")
check "缓存缺失时退化为旧式名称" "X-Vless-Reality-443" "$standalone_empty"

echo "== 连接地址选择 (IPv4 / IPv6) =="
# 打桩探测结果，测试不依赖外网
_info() { :; }
_warn() { :; }
_error() { :; }
_conn_ipv4() { printf '%s' "${STUB_V4:-}"; }
_conn_ipv6() { printf '%s' "${STUB_V6:-}"; }

STUB_V4="192.0.2.10"; STUB_V6="2001:db8::1"
check "双栈默认使用 IPv4" "192.0.2.10" "$(printf '\n' | _choose_connect_addr 198.51.100.10)"
check "双栈选择 IPv6" "2001:db8::1" "$(printf '2\n' | _choose_connect_addr 198.51.100.10)"
check "双栈手动输入域名" "example.com" "$(printf '3\nexample.com\n' | _choose_connect_addr 198.51.100.10)"

STUB_V4="192.0.2.10"; STUB_V6=""
check "单栈 IPv4 自动使用" "192.0.2.10" "$(_choose_connect_addr 198.51.100.10)"

STUB_V4=""; STUB_V6="2001:db8::1"
check "单栈 IPv6 自动使用" "2001:db8::1" "$(_choose_connect_addr 198.51.100.10)"

STUB_V4=""; STUB_V6=""
check "探测失败回退已检测地址" "198.51.100.10" "$(_choose_connect_addr 198.51.100.10)"
check "探测失败且无地址时手动输入" "vpn.example.org" \
    "$(printf 'vpn.example.org\n' | _choose_connect_addr 127.0.0.1)"

STUB_V4="192.0.2.10"; STUB_V6="2001:db8::1"
check "NODE_CONNECT_ADDR 覆盖" "my.domain" \
    "$(printf '\n' | NODE_CONNECT_ADDR=my.domain _choose_connect_addr 198.51.100.10)"

echo "== Xray 单独运行时的地址选择兜底 =="
standalone_addr=$(bash -c '
    . "$1"
    _info() { :; }; _warn() { :; }; _error() { :; }
    _conn_ipv4() { printf 192.0.2.10; }
    _conn_ipv6() { printf 2001:db8::1; }
    printf "\n" | _choose_connect_addr 198.51.100.10
' _ "$WORK/xray_conn.sh")
check "独立脚本可用等价实现" "192.0.2.10" "$standalone_addr"
fi

echo "== Xray 操作失败回归 =="
if ! (
    fail=0
    RED= GREEN= YELLOW= CYAN= NC=
    _info() { :; }; _error() { :; }
    _success() { :; }
    # Windows 原生 jq 使用 CRLF；只在测试边界归一化 CLI 行尾。
    jq() { command jq "$@" | tr -d '\r'; return "${PIPESTATUS[0]}"; }
    xray_load() {
        local name code
        for name in "$@"; do
            code=$(awk -v name="$name" '
                $0 == name "() {" {p=1}
                p {print}
                p && /<<.*EOF/ {heredoc=1}
                p && /^EOF$/ {heredoc=0}
                p && /^}/ && !heredoc {exit}
            ' "$ROOT/xray_manager.sh")
            [ -n "$code" ] || { printf '缺少 Xray 函数: %s\n' "$name" >&2; exit 1; }
            eval "$code"
        done
    }
    xray_load _save_xray_meta
    XRAY_DIR="$WORK/xray-operations"
    XRAY_METADATA="$XRAY_DIR/metadata.json"
    mkdir -p "$XRAY_DIR"
    printf '{}\n' > "$XRAY_METADATA"
    # 只让最终元数据替换失败，候选 JSON 仍由真实 jq 生成。
    mv() {
        if [ "${!#}" = "$XRAY_METADATA" ]; then return 1; fi
        command mv "$@"
    }
    _save_xray_meta xray-test test 'ss://placeholder@192.0.2.10:4000#test'
    rc=$?
    check "无额外字段时元数据替换失败必须上抛" failure "$([ "$rc" -ne 0 ] && printf failure || printf success)"
    _save_xray_meta xray-test test 'vless://placeholder@192.0.2.10:4000#test' publicKey=placeholder shortId=00
    rc=$?
    check "有额外字段时元数据替换失败必须上抛" failure "$([ "$rc" -ne 0 ] && printf failure || printf success)"
    check "替换失败保持原元数据" '{}' "$(jq -c . "$XRAY_METADATA" | tr -d '\r')"
    unset -f mv

    # 真实操作函数共享一套隔离文件，只替换服务、端口探测和最终文件操作边界。
    eval "$(sed -n '/^XRAY_TX_DIR=/,/^_view_xray_log() {/{/^_view_xray_log() {/d;p}' "$ROOT/xray_manager.sh")"
    xray_load _xray_atomic_modify_json _xray_atomic_modify_yaml _validate_xray_config \
        _check_and_fix_xray_listen _initialize_xray_runtime _init_xray_config _ensure_xray_clash_yaml \
        _modify_xray_port _input_port _check_xray_port_conflict _xray_add_node_to_yaml \
        _add_vless_reality_vision _generate_reality_keys _build_reality_stream \
        _delete_xray_node _delete_all_xray_nodes _xray_remove_node_from_yaml
    fixture_xray() {
        SINGBOX_DIR="$WORK/xray-operations/$1/sing-box"
        XRAY_DIR="$WORK/xray-operations/$1/xray"
        XRAY_CONFIG="$XRAY_DIR/config.json"
        XRAY_METADATA="$XRAY_DIR/metadata.json"
        CLASH_YAML_FILE="$SINGBOX_DIR/clash.yaml"
        XRAY_BIN="$XRAY_DIR/missing-binary"
        SINGBOXLITE_LOCK_HELD=1 INIT_SYSTEM=systemd
        XRAY_STATE_LOCK_OWNED=0 XRAY_TX_DIR="" XRAY_TX_ACTIVE="" XRAY_TX_BLOCKED=0
        mkdir -p "$XRAY_DIR" "$SINGBOX_DIR"
        printf '%s\n' '{"inbounds":[{"tag":"xray-vless-grpc-4000","listen":"0.0.0.0","port":4000,"protocol":"vless","streamSettings":{"grpcSettings":{"serviceName":"grpc-4000"}}}]}' > "$XRAY_CONFIG"
        printf '%s\n' '{"xray-vless-grpc-4000":{"name":"node-4000","share_link":"vless://00000000-0000-4000-8000-000000000000@[2001:db8::1]:4000?type=grpc&serviceName=grpc-4000&path=%2Froute-4000&host=example.com:4000#node-4000"}}' > "$XRAY_METADATA"
        printf '%s\n' '{"proxies":[{"name":"node-4000","type":"vless","server":"2001:db8::1","port":4000}],"proxy-groups":[{"name":"节点选择","type":"select","proxies":["node-4000"]}]}' > "$CLASH_YAML_FILE"
        command cp "$XRAY_CONFIG" "$XRAY_DIR/config.before"
        command cp "$XRAY_METADATA" "$XRAY_DIR/meta.before"
        command cp "$CLASH_YAML_FILE" "$XRAY_DIR/clash.before"
        command cp "$XRAY_CONFIG" "$XRAY_DIR/running.config"
        : > "$XRAY_DIR/service.running"
        printf original-service > "$XRAY_DIR/xray.service"
        printf enabled > "$XRAY_DIR/service.enabled"
        printf ZT7K2M > "$SINGBOX_DIR/machine-id"
        printf test-region > "$SINGBOX_DIR/node-region.cache"
        XRAY_SERVICE_CALLS=0 XRAY_RESTART_FAIL_AT=0 XRAY_META_MV_COUNT=0 XRAY_META_MV_FAIL_AT=0 XRAY_CREATE_SERVICE_FAIL=0
        XRAY_ENABLE_CREATE_FAIL=0 XRAY_ENABLE_RESTORE_FAIL=0
        XRAY_RUN_DIR="$XRAY_DIR/run" XRAY_PID_FILE="$XRAY_DIR/run/xray.pid"
        server_ip=192.0.2.10 NODE_CONNECT_ADDR=192.0.2.10
    }
    _xray_service_file() { printf '%s' "$XRAY_DIR/xray.service"; }
    systemctl() {
        case "${1:-}" in
            is-active) [ -f "$XRAY_DIR/service.running" ] ;;
            daemon-reload) return 0 ;;
            is-enabled)
                if [ ! -f "$XRAY_DIR/xray.service" ]; then printf 'not-found\n'; return 4; fi
                cat "$XRAY_DIR/service.enabled"
                [[ "$(cat "$XRAY_DIR/service.enabled")" == enabled* ]]
                ;;
            enable)
                [ -f "$XRAY_DIR/xray.service" ] || return 1
                if [ "${2:-}" = --runtime ]; then
                    printf enabled-runtime > "$XRAY_DIR/service.enabled"
                else
                    printf enabled > "$XRAY_DIR/service.enabled"
                fi
                return "$XRAY_ENABLE_CREATE_FAIL"
                ;;
            disable)
                [ "$XRAY_ENABLE_RESTORE_FAIL" -eq 0 ] || return 1
                printf disabled > "$XRAY_DIR/service.enabled"
                ;;
            *) return 1 ;;
        esac
    }
    rc-update() {
        case "$1" in
            show)
                [ "$(cat "$XRAY_DIR/service.enabled")" != enabled ] || printf ' xray | default\n'
                ;;
            add)
                [ -f "$XRAY_DIR/xray.service" ] || return 1
                printf enabled > "$XRAY_DIR/service.enabled"
                return "$XRAY_ENABLE_CREATE_FAIL"
                ;;
            del)
                [ -f "$XRAY_DIR/xray.service" ] && [ "$XRAY_ENABLE_RESTORE_FAIL" -eq 0 ] || return 1
                printf disabled > "$XRAY_DIR/service.enabled"
                ;;
            *) return 1 ;;
        esac
    }
    rc-service() { [ "$2" = status ] && [ -f "$XRAY_DIR/service.running" ]; }
    _create_xray_service() {
        printf updated-service > "$XRAY_DIR/xray.service"
        [ "$XRAY_CREATE_SERVICE_FAIL" -eq 0 ] || return "$XRAY_CREATE_SERVICE_FAIL"
        case "$INIT_SYSTEM" in
            systemd) systemctl enable xray ;;
            openrc) rc-update add xray default ;;
        esac
    }
    _manage_xray_service() {
        [ "${SINGBOXLITE_LOCK_HELD:-0}" = 1 ] || return 99
        XRAY_SERVICE_CALLS=$((XRAY_SERVICE_CALLS + 1))
        if [ "$XRAY_RESTART_FAIL_AT" = "$XRAY_SERVICE_CALLS" ]; then return 1; fi
        if [ "$1" = stop ]; then
            rm -f "$XRAY_DIR/service.running"
        else
            command cp "$XRAY_CONFIG" "$XRAY_DIR/running.config" || return 1
            : > "$XRAY_DIR/service.running"
        fi
    }
    mv() {
        if [ "${!#}" = "$XRAY_METADATA" ] && [[ "${@: -2:1}" == "$XRAY_METADATA".tmp.* ]]; then
            XRAY_META_MV_COUNT=$((XRAY_META_MV_COUNT + 1))
            if [ "$XRAY_META_MV_COUNT" = "$XRAY_META_MV_FAIL_AT" ]; then
                : > "$XRAY_DIR/meta-fault-triggered"
                return 1
            fi
        fi
        command mv "$@"
    }
    _check_xray_port_conflict() { return 1; }
    _url_encode() { printf '%s' "$1" | jq -sRr @uri; }

    echo "== Xray direct 停止失败与退出竞态 =="
    if ! (
        xray_load _manage_xray_service _xray_service_running \
            _xray_is_pid_running_cmd _xray_is_pid_file_running_cmd
        # 保留真实 stop/restart，只在意外进入 start 时截断外部进程启动。
        direct_definition=$(declare -f _manage_xray_service)
        eval "${direct_definition/_manage_xray_service/direct_manage}"
        _manage_xray_service() {
            if [ "$1" = start ]; then
                DIRECT_STARTED=1
                return 0
            fi
            direct_manage "$@"
        }
        seed_direct() {
            fixture_xray "direct-$1"
            INIT_SYSTEM=direct
            mkdir -p "$XRAY_RUN_DIR"
            printf '99999998\n' > "$XRAY_PID_FILE"
            DIRECT_RUNNING=1 DIRECT_KILL_CALLS=0 DIRECT_WAITS=0 DIRECT_STARTED=0
            DIRECT_MODE="$1" DIRECT_TERMINATING=0 DIRECT_OTHER_PROCESS=0
        }
        kill() {
            if [ "$1" = -0 ]; then
                [ "$DIRECT_RUNNING" -eq 1 ]
                return
            fi
            DIRECT_KILL_CALLS=$((DIRECT_KILL_CALLS + 1))
            case "$DIRECT_MODE" in
                denied) return 1 ;;
                exited_race) DIRECT_RUNNING=0; return 1 ;;
                delayed|timeout) DIRECT_TERMINATING=1; return 0 ;;
                *) DIRECT_RUNNING=0; return 0 ;;
            esac
        }
        ps() {
            if [ "$DIRECT_OTHER_PROCESS" -eq 1 ]; then
                printf 'unrelated-process\n'
            else
                printf '%s run -c %s\n' "$XRAY_BIN" "$XRAY_CONFIG"
            fi
        }
        sleep() {
            if [ "$DIRECT_TERMINATING" -eq 1 ]; then
                DIRECT_WAITS=$((DIRECT_WAITS + 1))
                [ -f "$XRAY_PID_FILE" ] || : > "$XRAY_DIR/pid-removed-before-exit"
                if [ "$DIRECT_MODE" = delayed ] && [ "$DIRECT_WAITS" -ge 3 ]; then
                    DIRECT_RUNNING=0
                fi
            fi
        }

        seed_direct denied
        direct_manage stop; rc=$?
        check "kill 失败且目标仍运行时 stop 返回非零" failure "$([ "$rc" -ne 0 ] && printf failure || printf success)"
        check "kill 失败保留 PID 文件" retained "$([ -f "$XRAY_PID_FILE" ] && printf retained)"
        direct_manage restart; rc=$?
        check "stop 失败时 restart 返回非零" failure "$([ "$rc" -ne 0 ] && printf failure || printf success)"
        check "stop 失败时 restart 不启动新进程" 0 "$DIRECT_STARTED"
        check "restart 失败后仍保留 PID" retained "$([ -f "$XRAY_PID_FILE" ] && printf retained)"

        seed_direct delayed
        direct_manage stop; rc=$?
        check "stop 等待目标实际退出后成功" 0 "$rc"
        check "stop 返回时目标已退出" 0 "$DIRECT_RUNNING"
        check "停止等待期间不提前删除 PID" safe "$([ ! -f "$XRAY_DIR/pid-removed-before-exit" ] && printf safe)"
        check "目标退出后删除 PID" absent "$([ ! -f "$XRAY_PID_FILE" ] && printf absent)"

        seed_direct timeout
        direct_manage stop; rc=$?
        check "TERM 成功但进程未退出时 stop 返回非零" failure "$([ "$rc" -ne 0 ] && printf failure || printf success)"
        check "等待退出超时保留 PID" retained "$([ -f "$XRAY_PID_FILE" ] && printf retained)"

        seed_direct exited_race
        direct_manage stop; rc=$?
        check "kill 报错时目标已退出不误报失败" 0 "$rc"
        check "退出竞态确认后清理 PID" absent "$([ ! -f "$XRAY_PID_FILE" ] && printf absent)"

        seed_direct reused_pid
        DIRECT_OTHER_PROCESS=1
        direct_manage stop; rc=$?
        check "PID 已由其他进程使用时不向其发信号" 0 "$DIRECT_KILL_CALLS"
        check "目标已不存在时 stop 成功" 0 "$rc"

        seed_direct rollback_denied
        DIRECT_RUNNING=0
        _xray_snapshot_state
        pending="$XRAY_TX_DIR"
        printf '{"inbounds":[]}\n' > "$XRAY_CONFIG"
        DIRECT_RUNNING=1 DIRECT_MODE=denied
        _xray_rollback_state "$pending"; rc=$?
        check "回滚停止失败返回非零" failure "$([ "$rc" -ne 0 ] && printf failure || printf success)"
        check "回滚停止失败不写 committed 且保留完整快照" retained "$([ -f "$pending/complete" ] && [ ! -f "$pending/committed" ] && printf retained)"
        check "回滚停止失败保留 PID 供恢复重试" retained "$([ -f "$XRAY_PID_FILE" ] && printf retained)"
        DIRECT_MODE=success
        _xray_recover_pending; rc=$?
        check "停止故障解除后可重试恢复" 0 "$rc"
        check "恢复重试成功还原原停止状态" 0 "$DIRECT_RUNNING"
        check "恢复重试成功删除 PID" absent "$([ ! -f "$XRAY_PID_FILE" ] && printf absent)"
        check "恢复重试成功清理快照" absent "$([ ! -d "$pending" ] && printf absent)"
        [ "$fail" -eq 0 ]
    ); then fail=$((fail + 1)); fi

    echo "== Xray 已提交快照清理中断 =="
    for cleanup_fault in complete_failure interrupted; do
        if ! (
            fixture_xray "committed-cleanup-$cleanup_fault"
            _xray_snapshot_state
            pending="$XRAY_TX_DIR"
            printf '{"inbounds":[]}\n' > "$XRAY_CONFIG"
            rm() {
                if [ "${!#}" = "$pending/complete" ]; then
                    printf 'complete\n' >> "$XRAY_DIR/cleanup.order"
                    [ "$cleanup_fault" != complete_failure ] || return 1
                elif [ "$1" = -rf ] && [ "${!#}" = "$pending" ]; then
                    printf 'recursive\n' >> "$XRAY_DIR/cleanup.order"
                    # 模拟递归清理删掉 committed 和部分数据后中断。
                    command rm -f -- "$pending/committed" "$pending/config.data"
                    return 1
                fi
                command rm "$@"
            }
            _xray_commit_state "$pending"; rc=$?
            check "$cleanup_fault 清理失败不撤回已成功提交" 0 "$rc"
            if [ "$cleanup_fault" = complete_failure ]; then
                check "complete 删除失败时不执行递归清理" complete "$(cat "$XRAY_DIR/cleanup.order")"
                check "complete 删除失败时保留 committed 和完整快照" retained "$([ -f "$pending/committed" ] && [ -f "$pending/complete" ] && [ -f "$pending/config.data" ] && printf retained)"
            else
                check "递归清理前先单独删除 complete" $'complete\nrecursive' "$(cat "$XRAY_DIR/cleanup.order")"
                check "递归清理中断后没有 complete" absent "$([ ! -f "$pending/complete" ] && printf absent)"
                _xray_recover_pending; rc=$?
                check "清理中断残留不当作未提交事务恢复" 0 "$rc"
                check "清理中断后保留已提交配置" 0 "$(jq '.inbounds | length' "$XRAY_CONFIG")"
                check "清理中断后不重启服务" 0 "$XRAY_SERVICE_CALLS"
            fi
            [ "$fail" -eq 0 ]
        ); then fail=$((fail + 1)); fi
    done

    echo "== Xray 删除与自启状态收尾回归 =="
    fixture_xray delete_all_success
    printf certificate > "$XRAY_DIR/xray-vless-grpc-4000.pem"
    printf placeholder > "$XRAY_DIR/xray-vless-grpc-4000.key"
    printf unrelated > "$XRAY_DIR/unrelated.pem"
    _delete_all_xray_nodes <<< $'y\n' > "$XRAY_DIR/delete.output"; rc=$?
    check "批量删除成功" 0 "$rc"
    check "批量删除成功清理节点证书和密钥" absent "$([ ! -f "$XRAY_DIR/xray-vless-grpc-4000.pem" ] && [ ! -f "$XRAY_DIR/xray-vless-grpc-4000.key" ] && printf absent)"
    check "批量删除保留无关证书" unrelated "$(cat "$XRAY_DIR/unrelated.pem")"
    check "批量删除成功清空配置和元数据" '0:{}' "$(jq '.inbounds | length' "$XRAY_CONFIG"):$(jq -c . "$XRAY_METADATA")"

    for init_system in systemd openrc; do
        for enabled_before in enabled enabled-runtime disabled missing; do
            [ "$init_system:$enabled_before" != openrc:enabled-runtime ] || continue
            if ! (
                fixture_xray "enable-$init_system-$enabled_before"
                INIT_SYSTEM="$init_system"
                if [ "$enabled_before" = missing ]; then
                    rm -f "$XRAY_DIR/xray.service" "$XRAY_DIR/service.running"
                    printf disabled > "$XRAY_DIR/service.enabled"
                else
                    printf '%s' "$enabled_before" > "$XRAY_DIR/service.enabled"
                fi
                xray_load _create_xray_service _create_xray_systemd_service _create_xray_openrc_service
                _xray_get_mem_limit() { printf 64; }
                XRAY_RESTART_FAIL_AT=1
                _initialize_xray_runtime; rc=$?
                check "$init_system $enabled_before 迁移失败上抛" failure "$([ "$rc" -ne 0 ] && printf failure || printf success)"
                expected_enabled="$enabled_before"
                [ "$enabled_before" != missing ] || expected_enabled=disabled
                check "$init_system $enabled_before 恢复原自启状态" "$expected_enabled" "$(cat "$XRAY_DIR/service.enabled")"
                if [ "$enabled_before" = missing ]; then
                    check "$init_system 首次创建迁移失败撤回 unit" absent "$([ ! -f "$XRAY_DIR/xray.service" ] && printf absent)"
                else
                    check "$init_system 迁移失败恢复原 unit" original-service "$(cat "$XRAY_DIR/xray.service")"
                fi
                check "$init_system 迁移失败恢复原配置" restored "$(cmp -s "$XRAY_CONFIG" "$XRAY_DIR/config.before" && printf restored)"
                [ "$fail" -eq 0 ]
            ); then fail=$((fail + 1)); fi
        done
        if ! (
            fixture_xray "enable-create-failure-$init_system"
            INIT_SYSTEM="$init_system"
            rm -f "$XRAY_DIR/xray.service" "$XRAY_DIR/service.running"
            printf disabled > "$XRAY_DIR/service.enabled"
            xray_load _create_xray_service _create_xray_systemd_service _create_xray_openrc_service
            _xray_get_mem_limit() { printf 64; }
            # 模拟添加自启链接后命令报错，确保部分成功也会撤回。
            XRAY_ENABLE_CREATE_FAIL=1
            _initialize_xray_runtime; rc=$?
            check "$init_system 首次 unit 创建部分失败上抛" failure "$([ "$rc" -ne 0 ] && printf failure || printf success)"
            check "$init_system 首次 unit 创建失败清理自启链接" disabled "$(cat "$XRAY_DIR/service.enabled")"
            check "$init_system 首次 unit 创建失败撤回文件" absent "$([ ! -f "$XRAY_DIR/xray.service" ] && printf absent)"
            [ "$fail" -eq 0 ]
        ); then fail=$((fail + 1)); fi
    done
    xray_load _with_singboxlite_lock _acquire_singboxlite_lock _release_singboxlite_lock _xray_entrypoint
    for init_system in systemd openrc; do
        fixture_xray "enable-restore-failure-$init_system"
        INIT_SYSTEM="$init_system"
        printf disabled > "$XRAY_DIR/service.enabled"
        XRAY_RESTART_FAIL_AT=1 XRAY_ENABLE_RESTORE_FAIL=1
        _initialize_xray_runtime; rc=$?
        pending="$XRAY_TX_DIR"
        check "$init_system 自启回退失败上抛" failure "$([ "$rc" -ne 0 ] && printf failure || printf success)"
        check "$init_system 自启回退失败保留快照" retained "$([ -f "$pending/complete" ] && [ ! -f "$pending/committed" ] && printf retained)"
        XRAY_ENABLE_RESTORE_FAIL=0
        _xray_entrypoint recover-pending; rc=$?
        check "$init_system 自启回退可重试" 0 "$rc"
        check "$init_system 重试恢复原 disabled" disabled "$(cat "$XRAY_DIR/service.enabled")"
    done

    echo "== Xray 跨组件事务隔离 =="
    for family in main caddy script-update relay; do
        fixture_xray "foreign-$family"
        foreign="$SINGBOX_DIR/.transactions/$family-pending"
        mkdir -p "$foreign"
        : > "$foreign/complete"
        _xray_snapshot_state; rc=$?
        check "$family 待恢复时拒绝创建 Xray 新快照" failure "$([ "$rc" -ne 0 ] && printf failure || printf success)"
        check "$family 待恢复时尚未激活 Xray 事务" "" "$XRAY_TX_ACTIVE"
        attempted_write() { : > "$XRAY_DIR/blocked-write"; }
        _with_singboxlite_lock attempted_write; rc=$?
        check "$family 待恢复时普通入口拒绝写入" absent "$([ ! -f "$XRAY_DIR/blocked-write" ] && printf absent)"
        _with_singboxlite_lock _initialize_xray_runtime; rc=$?
        check "$family 待恢复时初始化不修改 unit" original-service "$(cat "$XRAY_DIR/xray.service")"
        check "$family 待恢复时不修改共享 YAML" restored "$(cmp -s "$CLASH_YAML_FILE" "$XRAY_DIR/clash.before" && printf restored)"
    done
    fixture_xray foreign_incomplete_committed
    mkdir -p "$SINGBOX_DIR/.transactions/main-incomplete" "$SINGBOX_DIR/.transactions/relay-committed"
    : > "$SINGBOX_DIR/.transactions/relay-committed/complete"
    : > "$SINGBOX_DIR/.transactions/relay-committed/committed"
    attempted_write() { : > "$XRAY_DIR/allowed-write"; }
    _with_singboxlite_lock attempted_write; rc=$?
    check "其他 family 未 complete 或已 committed 不阻塞" 0 "$rc"
    check "其他 family 无待恢复事务时可写" present "$([ -f "$XRAY_DIR/allowed-write" ] && printf present)"

    fixture_xray recover_with_foreign
    _xray_snapshot_state
    printf '{"inbounds":[]}\n' > "$XRAY_CONFIG"
    printf '{"proxies":[]}\n' > "$CLASH_YAML_FILE"
    XRAY_TX_ACTIVE=""
    mkdir -p "$SINGBOX_DIR/.transactions/main-pending"
    : > "$SINGBOX_DIR/.transactions/main-pending/complete"
    _xray_entrypoint recover-pending; rc=$?
    check "父进程按 family 恢复时不受其他事务阻塞" 0 "$rc"
    check "其他 family 待恢复时仍能还原 Xray YAML" restored "$(cmp -s "$CLASH_YAML_FILE" "$XRAY_DIR/clash.before" && printf restored)"
    if [ "${XRAY_RECOVERY_FINISH_ONLY:-0}" = 1 ]; then
        [ "$fail" -eq 0 ]
        exit "$?"
    fi

    fixture_xray migration
    XRAY_RESTART_FAIL_AT=1
    _initialize_xray_runtime; rc=$?
    check "监听迁移重启失败返回非零" failure "$([ "$rc" -ne 0 ] && printf failure || printf success)"
    check "监听迁移失败恢复 IPv4 配置" restored "$(cmp -s "$XRAY_CONFIG" "$XRAY_DIR/config.before" && printf restored)"
    check "监听迁移失败恢复运行配置" restored "$(cmp -s "$XRAY_DIR/running.config" "$XRAY_DIR/config.before" && printf restored)"
    check "监听迁移失败恢复服务定义" original-service "$(cat "$XRAY_DIR/xray.service")"

    fixture_xray port_link
    _modify_xray_port <<< $'1\n5000\n'; rc=$?
    check "改端口成功" 0 "$rc"
    check "改端口保持 query/path 原样并更新 authority/fragment" \
        'vless://00000000-0000-4000-8000-000000000000@[2001:db8::1]:5000?type=grpc&serviceName=grpc-4000&path=%2Froute-4000&host=example.com:4000#node-5000' \
        "$(jq -r '."xray-vless-grpc-4000".share_link' "$XRAY_METADATA")"
    check "改端口不改服务端 gRPC 服务名" grpc-4000 "$(jq -r '.inbounds[0].streamSettings.grpcSettings.serviceName' "$XRAY_CONFIG")"

    fixture_xray port_meta_failure
    XRAY_META_MV_FAIL_AT=1
    _modify_xray_port <<< $'1\n5000\n'; rc=$?
    check "改端口元数据替换失败返回非零" failure "$([ "$rc" -ne 0 ] && printf failure || printf success)"
    check "改端口元数据失败恢复配置" restored "$(cmp -s "$XRAY_CONFIG" "$XRAY_DIR/config.before" && printf restored)"
    check "改端口元数据失败恢复 YAML" restored "$(cmp -s "$CLASH_YAML_FILE" "$XRAY_DIR/clash.before" && printf restored)"
    check "改端口元数据失败保持旧链接" restored "$(cmp -s "$XRAY_METADATA" "$XRAY_DIR/meta.before" && printf restored)"

    for metadata_failure_at in 1 2 3; do
        fixture_xray "add-meta-$metadata_failure_at"
        XRAY_BIN="$XRAY_DIR/fake-xray"
        cat > "$XRAY_BIN" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    uuid) printf '%s\n' 00000000-0000-4000-8000-000000000000 ;;
    x25519) printf 'PrivateKey: placeholder-private\nPublicKey: placeholder-public\n' ;;
    run) exit 0 ;;
    *) exit 1 ;;
esac
EOF
        chmod +x "$XRAY_BIN"
        XRAY_META_MV_FAIL_AT="$metadata_failure_at"
        _run_xray_transaction _add_vless_reality_vision <<< $'5000\nexample.com\nnew-node\n' > "$XRAY_DIR/add.output"; rc=$?
        check "新增节点确实到达元数据故障边界 $metadata_failure_at" reached "$([ -f "$XRAY_DIR/meta-fault-triggered" ] && printf reached)"
        check "新增节点第 $metadata_failure_at 次元数据替换失败上抛" failure "$([ "$rc" -ne 0 ] && printf failure || printf success)"
        check "新增节点元数据失败恢复服务端配置 $metadata_failure_at" restored "$(cmp -s "$XRAY_CONFIG" "$XRAY_DIR/config.before" && printf restored)"
        check "新增节点元数据失败恢复 YAML $metadata_failure_at" restored "$(cmp -s "$CLASH_YAML_FILE" "$XRAY_DIR/clash.before" && printf restored)"
        check "新增节点元数据失败恢复元数据 $metadata_failure_at" restored "$(cmp -s "$XRAY_METADATA" "$XRAY_DIR/meta.before" && printf restored)"
    done
    fake_core="$XRAY_BIN"
    fixture_xray add_success
    XRAY_BIN="$XRAY_DIR/fake-xray"
    command cp "$fake_core" "$XRAY_BIN"
    chmod +x "$XRAY_BIN"
    _run_xray_transaction _add_vless_reality_vision <<< $'5000\nexample.com\nnew-node\n' > "$XRAY_DIR/add.output"; rc=$?
    check "新增节点正常路径成功" 0 "$rc"
    check "新增节点确实加入服务端入站" 2 "$(jq '.inbounds | length' "$XRAY_CONFIG")"
    check "新增节点正常路径写入元数据" new-node "$(jq -r '."xray-vless-reality-5000".name' "$XRAY_METADATA")"

    fixture_xray initialize_failure
    rm -f "$XRAY_CONFIG" "$XRAY_METADATA" "$CLASH_YAML_FILE" "$XRAY_DIR/service.running"
    XRAY_CREATE_SERVICE_FAIL=1
    _initialize_xray_runtime; rc=$?
    check "初始化中途失败上抛" failure "$([ "$rc" -ne 0 ] && printf failure || printf success)"
    check "初始化失败撤回首次生成配置" absent "$([ ! -f "$XRAY_CONFIG" ] && [ ! -f "$XRAY_METADATA" ] && [ ! -f "$CLASH_YAML_FILE" ] && printf absent)"
    check "初始化失败恢复服务定义" original-service "$(cat "$XRAY_DIR/xray.service")"

    for deletion in single all; do
        fixture_xray "delete-$deletion"
        XRAY_RESTART_FAIL_AT=1
        printf certificate > "$XRAY_DIR/xray-vless-grpc-4000.pem"
        if [ "$deletion" = single ]; then
            _delete_xray_node <<< $'1\ny\n' > "$XRAY_DIR/delete.output"; rc=$?
        else
            _delete_all_xray_nodes <<< $'y\n' > "$XRAY_DIR/delete.output"; rc=$?
        fi
        check "$deletion 删除重启失败上抛" failure "$([ "$rc" -ne 0 ] && printf failure || printf success)"
        check "$deletion 删除失败恢复配置" restored "$(cmp -s "$XRAY_CONFIG" "$XRAY_DIR/config.before" && printf restored)"
        check "$deletion 删除失败恢复元数据" restored "$(cmp -s "$XRAY_METADATA" "$XRAY_DIR/meta.before" && printf restored)"
        check "$deletion 删除失败恢复 YAML" restored "$(cmp -s "$CLASH_YAML_FILE" "$XRAY_DIR/clash.before" && printf restored)"
        check "$deletion 删除失败保留证书" certificate "$(cat "$XRAY_DIR/xray-vless-grpc-4000.pem")"
    done

    echo "== Xray 持久化恢复与中断 =="
    fixture_xray persistent
    _xray_snapshot_state; rc=$?
    check "快照创建成功" 0 "$rc"
    case "$XRAY_TX_DIR" in "$SINGBOX_DIR"/.transactions/xray-*) r=persistent ;; *) r=temporary ;; esac
    check "快照写入共享持久化根" persistent "$r"
    check "完整快照最后写 complete" complete "$([ -f "$XRAY_TX_DIR/complete" ] && printf complete)"
    if declare -f _xray_recover_pending >/dev/null 2>&1; then
        xray_load _with_singboxlite_lock _acquire_singboxlite_lock _release_singboxlite_lock \
            _xray_exit_handler _xray_entrypoint
        fixture_xray recover
        printf certificate > "$XRAY_DIR/node.pem"
        printf placeholder > "$XRAY_DIR/node.key"
        _xray_snapshot_state
        pending="$XRAY_TX_DIR"
        printf '{"inbounds":[]}\n' > "$XRAY_CONFIG"
        printf '{}\n' > "$XRAY_METADATA"
        printf '{"proxies":[]}\n' > "$CLASH_YAML_FILE"
        printf changed > "$XRAY_DIR/node.pem"
        printf extra > "$XRAY_DIR/extra.key"
        XRAY_TX_ACTIVE=""
        _xray_entrypoint recover-pending; rc=$?
        check "recover-pending 兼容继承共享锁" 0 "$rc"
        check "待恢复事务还原配置" restored "$(cmp -s "$XRAY_CONFIG" "$XRAY_DIR/config.before" && printf restored)"
        check "待恢复事务还原元数据" restored "$(cmp -s "$XRAY_METADATA" "$XRAY_DIR/meta.before" && printf restored)"
        check "待恢复事务还原 YAML" restored "$(cmp -s "$CLASH_YAML_FILE" "$XRAY_DIR/clash.before" && printf restored)"
        check "待恢复事务还原证书" certificate "$(cat "$XRAY_DIR/node.pem")"
        check "待恢复事务清理新增密钥" absent "$([ ! -f "$XRAY_DIR/extra.key" ] && printf absent)"
        check "恢复成功清理持久化快照" absent "$([ ! -d "$pending" ] && printf absent)"

        fixture_xray incomplete
        mkdir -p "$SINGBOX_DIR/.transactions/xray-incomplete"
        printf broken > "$SINGBOX_DIR/.transactions/xray-incomplete/config.data"
        _xray_entrypoint recover-pending; rc=$?
        check "忽略未 complete 的快照" 0 "$rc"
        check "未 complete 快照不覆盖现有配置" restored "$(cmp -s "$XRAY_CONFIG" "$XRAY_DIR/config.before" && printf restored)"

        fixture_xray committed
        rm() {
            if [ "${XRAY_CLEANUP_FAIL:-0}" = 1 ] && [[ "${!#}" == */.transactions/xray-* ]]; then return 1; fi
            command rm "$@"
        }
        XRAY_CLEANUP_FAIL=1
        _run_xray_transaction true; rc=$?
        pending="$XRAY_TX_DIR"
        check "清理失败前已持久化提交标记" committed "$([ -f "$pending/committed" ] && printf committed)"
        printf '{"inbounds":[]}\n' > "$XRAY_CONFIG"
        XRAY_CLEANUP_FAIL=0 XRAY_TX_ACTIVE=""
        _xray_entrypoint recover-pending; rc=$?
        check "已 committed 事务不回退后来配置" 0 "$(jq '.inbounds | length' "$XRAY_CONFIG")"
        check "已 committed 事务仅补做清理" absent "$([ ! -d "$pending" ] && printf absent)"
        unset -f rm

        fixture_xray restore_failure
        _xray_snapshot_state
        pending="$XRAY_TX_DIR"
        printf '{"inbounds":[]}\n' > "$XRAY_CONFIG"
        XRAY_TX_ACTIVE=""
        mv() {
            if [ "${XRAY_RESTORE_FAIL:-0}" = 1 ] && [ "${!#}" = "$XRAY_CONFIG" ]; then return 1; fi
            command mv "$@"
        }
        XRAY_RESTORE_FAIL=1
        _xray_entrypoint recover-pending; rc=$?
        check "恢复失败返回非零" failure "$([ "$rc" -ne 0 ] && printf failure || printf success)"
        check "恢复失败保留完整快照" retained "$([ -f "$pending/complete" ] && printf retained)"
        blocked_write() { : > "$XRAY_DIR/unexpected-write"; }
        _with_singboxlite_lock _run_xray_transaction blocked_write; rc=$?
        check "恢复失败阻止后续写操作" absent "$([ ! -f "$XRAY_DIR/unexpected-write" ] && printf absent)"
        XRAY_RESTORE_FAIL=0
        _xray_entrypoint recover-pending; rc=$?
        check "故障解除后可重试恢复" 0 "$rc"
        unset -f mv

        fixture_xray stopped
        rm -f "$XRAY_DIR/service.running"
        _xray_snapshot_state
        XRAY_TX_ACTIVE=""
        : > "$XRAY_DIR/service.running"
        _xray_entrypoint recover-pending; rc=$?
        check "恢复不会启动原本停止的服务" stopped "$([ ! -f "$XRAY_DIR/service.running" ] && printf stopped)"

        for signal in INT TERM KILL EXIT; do
            fixture_xray "signal-$signal"
            (
                trap '_xray_exit_handler $?' EXIT
                trap '_xray_exit_handler 130' INT
                trap '_xray_exit_handler 143' TERM
                interrupt_operation() {
                    printf '{"inbounds":[]}\n' > "$XRAY_CONFIG"
                    printf '{}\n' > "$XRAY_METADATA"
                    if [ "$signal" = EXIT ]; then exit 7; fi
                    kill -s "$signal" "$BASHPID"
                }
                _run_xray_transaction interrupt_operation
            ); rc=$?
            check "$signal 中断返回非零" failure "$([ "$rc" -ne 0 ] && printf failure || printf success)"
            if [ "$signal" = KILL ]; then
                _xray_entrypoint recover-pending; rc=$?
                check "SIGKILL 后通过持久化入口恢复" 0 "$rc"
            fi
            check "$signal 中断恢复配置" restored "$(cmp -s "$XRAY_CONFIG" "$XRAY_DIR/config.before" && printf restored)"
            check "$signal 中断恢复元数据" restored "$(cmp -s "$XRAY_METADATA" "$XRAY_DIR/meta.before" && printf restored)"
        done

        fixture_xray release_order
        (
            XRAY_STATE_LOCK_OWNED=1
            exec 219>"$XRAY_DIR/fixture.lock"
            flock() {
                [ "$1" = -u ] || return 1
                if cmp -s "$XRAY_CONFIG" "$XRAY_DIR/config.before"; then
                    printf restored > "$XRAY_DIR/unlock.state"
                else
                    printf changed > "$XRAY_DIR/unlock.state"
                fi
            }
            trap '_xray_exit_handler $?' EXIT
            trap '_xray_exit_handler 143' TERM
            interrupt_before_unlock() {
                printf '{"inbounds":[]}\n' > "$XRAY_CONFIG"
                kill -TERM "$BASHPID"
            }
            _run_xray_transaction interrupt_before_unlock
        ); rc=$?
        check "信号恢复完成之后才释放自持共享锁" restored "$(cat "$XRAY_DIR/unlock.state")"
    else
        check "提供 recover-pending 事务恢复入口" available missing
    fi
    if ! (
        fixture_xray service_definition_failure
        xray_load _create_xray_service _create_xray_systemd_service
        _xray_get_mem_limit() { printf 64; }
        cat() {
            [ "$#" -ne 0 ] || return 1
            command cat "$@"
        }
        _initialize_xray_runtime; rc=$?
        check "真实服务定义写入失败返回非零" failure "$([ "$rc" -ne 0 ] && printf failure || printf success)"
        check "服务定义写入失败还原原文件" original-service "$(cat "$XRAY_DIR/xray.service")"
        check "服务定义写入失败保持原监听" restored "$(cmp -s "$XRAY_CONFIG" "$XRAY_DIR/config.before" && printf restored)"
        [ "$fail" -eq 0 ]
    ); then fail=$((fail + 1)); fi
    if ! (
        fixture_xray service_health
        xray_load _manage_xray_service
        systemctl() {
            case "$1" in
                reset-failed|restart) return 0 ;;
                is-active) return 1 ;;
                *) return 1 ;;
            esac
        }
        rc-service() {
            [ "$2" != status ]
        }
        sleep() { :; }
        _manage_xray_service restart; rc=$?
        check "systemd 命令成功但进程未存活时视为重启失败" failure "$([ "$rc" -ne 0 ] && printf failure || printf success)"
        INIT_SYSTEM=openrc
        _manage_xray_service restart; rc=$?
        check "OpenRC 命令成功但进程未存活时视为重启失败" failure "$([ "$rc" -ne 0 ] && printf failure || printf success)"
        [ "$fail" -eq 0 ]
    ); then fail=$((fail + 1)); fi
    [ "$fail" -eq 0 ]
); then fail=$((fail + 1)); fi

# 事务故障回归复用本测试入口，CI 无需新增任务。
if [ "${XRAY_OPERATIONS_ONLY:-0}" != 1 ]; then
    bash "$ROOT/tests/test_runtime_transactions.sh" || fail=$((fail + 1))
fi

echo
if [ "$fail" -ne 0 ]; then
    echo "失败 ${fail} 项"
    exit 1
fi
echo "全部通过"
