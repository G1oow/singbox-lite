#!/usr/bin/env bash
# NTP 探测与核心复核回归：不访问外网、不启动真实服务，全部使用替身函数。
set -uo pipefail
exec < /dev/null
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail=0
check() {
    if [ "$2" = "$3" ]; then printf 'ok    %s\n' "$1"; else printf 'FAIL  %s (期望 %s，实际 %s)\n' "$1" "$2" "$3"; fail=$((fail + 1)); fi
}
_info() { :; }; _warn() { :; }; _warning() { :; }; _error() { :; }; _success() { :; }

LEGACY_NTP='{"enabled":true,"interval":"30m","server":"time.apple.com","server_port":123}'
MANAGED_NTP='{"connect_timeout":"3s","enabled":true,"interval":"1m","server":"time.apple.com","server_port":123,"write_to_system":false}'

# singbox.sh 会直接执行主菜单，只能按函数边界抽取被测函数。
load_time_functions() {
    local fn
    for fn in _time_is_container _time_probe_ntp _time_core_ntp_logs _time_core_ntp_verdict \
              _time_ntp_source_rejected _time_mark_verify_window _time_confirm_core_ntp _time_has_ss2022 \
              _time_prepare_ntp_config _time_prepare_ntp_config_locked; do
        source <(sed -n "/^${fn}() {\$/,/^}\$/p" "$ROOT/singbox.sh")
    done
    # 探测方式是函数外的常量，同样要取，否则 set -u 下会直接中断。
    TIME_NTP_PROBE_METHOD=$(sed -n 's/^TIME_NTP_PROBE_METHOD="\(.*\)"$/\1/p' "$ROOT/singbox.sh" | head -n 1)
}

# 每个用例使用独立目录与独立替身，互不影响。
setup_case() {
    CASE_DIR="$WORK/$1"
    mkdir -p "$CASE_DIR"
    SINGBOX_DIR="$CASE_DIR"
    CONFIG_FILE="$CASE_DIR/config.json"
    LOG_FILE="$CASE_DIR/sing-box.log"
    INIT_SYSTEM=systemd
    TIME_PROBE_CACHE_TTL=0
    _atomic_modify_json() {
        local file="$1" filter="$2"
        shift 2
        jq "$@" "$filter" "$file" > "$file.new" && mv "$file.new" "$file"
    }
}

# --- 1. 候选源全部不可达时不得改写已有 ntp.server ---------------------------
(
    load_time_functions
    setup_case all-unreachable
    printf '%s\n' '{"ntp":{"enabled":true,"server":"time.apple.com","server_port":123,"interval":"30m"}}' > "$CONFIG_FILE"
    _time_probe_ntp() { TIME_PROBE_EPOCH=""; TIME_PROBE_OFFSET=""; TIME_PROBE_SOURCE=""; return 1; }
    _time_prepare_ntp_config_locked || exit 1
    jq -cS '.ntp' "$CONFIG_FILE" > "$WORK/all-unreachable.ntp"
    jq -r '.last_probe_status' "$SINGBOX_DIR/time-sync.json" > "$WORK/all-unreachable.status"
    jq -r '.probe_method' "$SINGBOX_DIR/time-sync.json" > "$WORK/all-unreachable.method"
) > "$WORK/all-unreachable.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || cat "$WORK/all-unreachable.log"
check "候选源全不可达时准备流程不失败" 0 "$rc"
check "探测失败保留原 ntp 配置" "$LEGACY_NTP" "$(cat "$WORK/all-unreachable.ntp" 2>/dev/null)"
check "探测失败记录 unreachable" "unreachable" "$(cat "$WORK/all-unreachable.status" 2>/dev/null)"
check "sidecar 记录探测方式" "本机直连 UDP/123，3s 超时，不经代理" "$(cat "$WORK/all-unreachable.method" 2>/dev/null)"

# --- 2. 本来没有 ntp 配置时才写显式关闭 -------------------------------------
(
    load_time_functions
    setup_case no-ntp
    printf '%s\n' '{"log":{"level":"info"}}' > "$CONFIG_FILE"
    _time_probe_ntp() { return 1; }
    _time_prepare_ntp_config_locked || exit 1
    jq -cS '.ntp' "$CONFIG_FILE" > "$WORK/no-ntp.ntp"
) > "$WORK/no-ntp.log" 2>&1
check "无 ntp 配置且探测失败时写显式关闭" '{"enabled":false}' "$(cat "$WORK/no-ntp.ntp" 2>/dev/null)"

# --- 3. TIME_NTP_LOCK=1 既不探测也不改写 ------------------------------------
(
    load_time_functions
    setup_case locked
    TIME_NTP_LOCK=1
    printf '%s\n' '{"ntp":{"enabled":true,"server":"time.apple.com","server_port":123,"interval":"30m"}}' > "$CONFIG_FILE"
    _time_probe_ntp() { printf 'probed\n' >> "$WORK/locked.probe"; return 0; }
    _time_prepare_ntp_config_locked || exit 2
    jq -cS '.ntp' "$CONFIG_FILE" > "$WORK/locked.ntp"
) > "$WORK/locked.log" 2>&1
rc=$?
check "TIME_NTP_LOCK=1 时准备流程不失败" 0 "$rc"
check "TIME_NTP_LOCK=1 保留原 ntp 配置" "$LEGACY_NTP" "$(cat "$WORK/locked.ntp" 2>/dev/null)"
check "TIME_NTP_LOCK=1 不发起探测" "no" "$([ -f "$WORK/locked.probe" ] && echo yes || echo no)"
check "TIME_NTP_LOCK=1 不写 sidecar" "no" "$([ -f "$WORK/locked/time-sync.json" ] && echo yes || echo no)"

# --- 4. TIME_NTP_SERVER 只探测锁定源并登记核心复核 --------------------------
(
    load_time_functions
    setup_case locked-server
    TIME_NTP_SERVER="ntp.example.com"
    printf '%s\n' '{"ntp":{"enabled":true,"server":"time.apple.com","server_port":123,"interval":"30m"}}' > "$CONFIG_FILE"
    _time_probe_ntp() {
        printf '%s:%s\n' "$1" "$2" >> "$WORK/locked-server.probe"
        [ "$1" = "ntp.example.com" ] || return 1
        TIME_PROBE_SOURCE="$1:$2"; TIME_PROBE_OFFSET=0
        return 0
    }
    _time_prepare_ntp_config_locked || exit 1
    jq -r '.ntp.server' "$CONFIG_FILE" > "$WORK/locked-server.server"
    jq -r '.pending_verify.source' "$SINGBOX_DIR/time-sync.json" > "$WORK/locked-server.pending-source"
    jq -c '.pending_verify.previous_ntp' "$SINGBOX_DIR/time-sync.json" > "$WORK/locked-server.pending-prev"
) > "$WORK/locked-server.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || cat "$WORK/locked-server.log"
check "锁定源写入 config.json" "ntp.example.com" "$(cat "$WORK/locked-server.server" 2>/dev/null)"
check "锁定源只探测一次" "ntp.example.com:123" "$(cat "$WORK/locked-server.probe" 2>/dev/null)"
check "锁定源登记核心复核来源" "ntp.example.com:123" "$(cat "$WORK/locked-server.pending-source" 2>/dev/null)"
check "锁定源登记改动前配置" "$LEGACY_NTP" "$(cat "$WORK/locked-server.pending-prev" 2>/dev/null)"

# --- 5. 核心日志报超时：回退原配置、只重启一次、记入不可达源 ---------------
(
    load_time_functions
    setup_case core-failed
    printf '%s\n' '{"ntp":{"enabled":true,"server":"time.apple.com","server_port":123,"interval":"30m"}}' > "$CONFIG_FILE"
    _time_probe_ntp() { TIME_PROBE_SOURCE="$1:$2"; TIME_PROBE_OFFSET=0; return 0; }
    _time_prepare_ntp_config_locked || exit 1
    jq -cS '.ntp' "$CONFIG_FILE" > "$WORK/core-failed.applied"
    TIME_CORE_VERIFY_WAIT=0
    _time_core_ntp_logs() {
        printf '%s\n' 'ERROR[0005] ntp: initialize time: read udp 192.0.2.10:41234->192.0.2.20:123: i/o timeout'
        printf '%s\n' 'TRACE[0005] start ntp service completed (5.00s)'
    }
    _manage_service() { printf '%s\n' "$1" >> "$WORK/core-failed.restarts"; }
    _time_confirm_core_ntp || exit 2
    jq -cS '.ntp' "$CONFIG_FILE" > "$WORK/core-failed.ntp"
    jq -cS '.last_probe_status' "$SINGBOX_DIR/time-sync.json" > "$WORK/core-failed.status"
    jq -cS '.pending_verify' "$SINGBOX_DIR/time-sync.json" > "$WORK/core-failed.pending"
    jq -cS '.managed_ntp' "$SINGBOX_DIR/time-sync.json" > "$WORK/core-failed.managed"
    jq -cS '.core_failed_sources' "$SINGBOX_DIR/time-sync.json" > "$WORK/core-failed.sources"
    # 回退之后再次探测：坏源必须被跳过
    TIME_PROBE_CACHE_TTL=0
    _time_probe_ntp() { printf '%s\n' "$1" >> "$WORK/core-failed.reprobe"; return 1; }
    _time_prepare_ntp_config_locked || exit 3
) > "$WORK/core-failed.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || cat "$WORK/core-failed.log"
check "核心复核失败时先写入新源" "$MANAGED_NTP" "$(cat "$WORK/core-failed.applied" 2>/dev/null)"
check "核心复核失败回退到改动前配置" "$LEGACY_NTP" "$(cat "$WORK/core-failed.ntp" 2>/dev/null)"
check "核心复核失败记录 core-unreachable" '"core-unreachable"' "$(cat "$WORK/core-failed.status" 2>/dev/null)"
check "核心复核失败清空 pending_verify" "null" "$(cat "$WORK/core-failed.pending" 2>/dev/null)"
check "核心复核失败同步 managed_ntp" "$LEGACY_NTP" "$(cat "$WORK/core-failed.managed" 2>/dev/null)"
check "核心复核失败记录不可达源" '["time.apple.com"]' "$(cat "$WORK/core-failed.sources" 2>/dev/null)"
check "核心复核失败只重启一次" "restart" "$(cat "$WORK/core-failed.restarts" 2>/dev/null)"
check "回退后不再自动探测坏源" "time.cloudflare.com
time.google.com" "$(cat "$WORK/core-failed.reprobe" 2>/dev/null)"

# --- 6. 核心日志报成功：清空待复核且不改配置、不重启 -----------------------
(
    load_time_functions
    setup_case core-ok
    printf '%s\n' '{"ntp":{"enabled":true,"server":"time.apple.com","server_port":123,"interval":"30m"}}' > "$CONFIG_FILE"
    _time_probe_ntp() { TIME_PROBE_SOURCE="$1:$2"; TIME_PROBE_OFFSET=0; return 0; }
    _time_prepare_ntp_config_locked || exit 1
    TIME_CORE_VERIFY_WAIT=0
    _time_core_ntp_logs() { printf '%s\n' 'INFO[0000] ntp: updated time: 2026-01-01T00:00:00Z'; }
    _manage_service() { printf '%s\n' "$1" >> "$WORK/core-ok.restarts"; }
    _time_confirm_core_ntp || exit 2
    jq -cS '.ntp' "$CONFIG_FILE" > "$WORK/core-ok.ntp"
    jq -cS '.last_probe_status' "$SINGBOX_DIR/time-sync.json" > "$WORK/core-ok.status"
    jq -cS '.pending_verify' "$SINGBOX_DIR/time-sync.json" > "$WORK/core-ok.pending"
) > "$WORK/core-ok.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || cat "$WORK/core-ok.log"
check "核心复核通过保持新源" "$MANAGED_NTP" "$(cat "$WORK/core-ok.ntp" 2>/dev/null)"
check "核心复核通过记录 core-reachable" '"core-reachable"' "$(cat "$WORK/core-ok.status" 2>/dev/null)"
check "核心复核通过清空 pending_verify" "null" "$(cat "$WORK/core-ok.pending" 2>/dev/null)"
check "核心复核通过不再重启" "no" "$([ -f "$WORK/core-ok.restarts" ] && echo yes || echo no)"

# --- 7. 取不到核心结论时保留配置与待复核标记 -------------------------------
(
    load_time_functions
    setup_case core-unknown
    printf '%s\n' '{"ntp":{"enabled":true,"server":"time.apple.com","server_port":123,"interval":"30m"}}' > "$CONFIG_FILE"
    _time_probe_ntp() { TIME_PROBE_SOURCE="$1:$2"; TIME_PROBE_OFFSET=0; return 0; }
    _time_prepare_ntp_config_locked || exit 1
    TIME_CORE_VERIFY_WAIT=0
    _time_core_ntp_logs() { :; }
    _manage_service() { printf '%s\n' "$1" >> "$WORK/core-unknown.restarts"; }
    _time_confirm_core_ntp || exit 2
    jq -cS '.ntp' "$CONFIG_FILE" > "$WORK/core-unknown.ntp"
    jq -cS '.last_probe_status' "$SINGBOX_DIR/time-sync.json" > "$WORK/core-unknown.status"
    jq -r '.pending_verify != null' "$SINGBOX_DIR/time-sync.json" > "$WORK/core-unknown.pending"
) > "$WORK/core-unknown.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || cat "$WORK/core-unknown.log"
check "结论未知时保留新源" "$MANAGED_NTP" "$(cat "$WORK/core-unknown.ntp" 2>/dev/null)"
check "结论未知时不改状态" '"reachable"' "$(cat "$WORK/core-unknown.status" 2>/dev/null)"
check "结论未知时保留待复核" "true" "$(cat "$WORK/core-unknown.pending" 2>/dev/null)"
check "结论未知时不重启" "no" "$([ -f "$WORK/core-unknown.restarts" ] && echo yes || echo no)"

# --- 8. TIME_CORE_VERIFY=0 时跳过核心复核 ---------------------------------
(
    load_time_functions
    setup_case verify-off
    printf '%s\n' '{"ntp":{"enabled":true,"server":"time.apple.com","server_port":123,"interval":"30m"}}' > "$CONFIG_FILE"
    _time_probe_ntp() { TIME_PROBE_SOURCE="$1:$2"; TIME_PROBE_OFFSET=0; return 0; }
    _time_prepare_ntp_config_locked || exit 1
    TIME_CORE_VERIFY=0
    TIME_CORE_VERIFY_WAIT=0
    _time_core_ntp_logs() { printf '%s\n' 'ERROR[0005] ntp: initialize time: i/o timeout'; }
    _manage_service() { printf '%s\n' "$1" >> "$WORK/verify-off.restarts"; }
    _time_confirm_core_ntp || exit 2
    jq -r '.pending_verify != null' "$SINGBOX_DIR/time-sync.json" > "$WORK/verify-off.pending"
) > "$WORK/verify-off.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || cat "$WORK/verify-off.log"
check "TIME_CORE_VERIFY=0 不读核心日志" "true" "$(cat "$WORK/verify-off.pending" 2>/dev/null)"
check "TIME_CORE_VERIFY=0 不重启" "no" "$([ -f "$WORK/verify-off.restarts" ] && echo yes || echo no)"

# --- 9. 每次启动/重启都把复核窗口刷新到本次重启 ---------------------------
(
    load_time_functions
    setup_case window
    printf '%s\n' '{"ntp":{"enabled":true,"server":"time.apple.com","server_port":123,"interval":"30m"}}' > "$CONFIG_FILE"
    _time_probe_ntp() { TIME_PROBE_SOURCE="$1:$2"; TIME_PROBE_OFFSET=0; return 0; }
    _time_prepare_ntp_config_locked || exit 1
    jq -r '.pending_verify.since' "$SINGBOX_DIR/time-sync.json" > "$WORK/window.before"
    # 固定时间，避免用例依赖真实时钟
    date() {
        case "$*" in
            *"%Y-%m-%d %H:%M:%S"*) printf '2030-01-02 03:04:05\n' ;;
            *) command date "$@" ;;
        esac
    }
    _time_mark_verify_window || exit 2
    jq -r '.pending_verify.since' "$SINGBOX_DIR/time-sync.json" > "$WORK/window.after"
) > "$WORK/window.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || cat "$WORK/window.log"
check "复核窗口刷新到本次重启时间" "2030-01-02 03:04:05" "$(cat "$WORK/window.after" 2>/dev/null)"
check "复核前窗口为写入时刻" "no" "$([ "$(cat "$WORK/window.before" 2>/dev/null)" = "2030-01-02 03:04:05" ] && echo yes || echo no)"

if [ "$fail" -ne 0 ]; then
    printf '\n%d 项失败\n' "$fail"
    exit 1
fi
printf '\nNTP 探测与核心复核回归全部通过\n'
