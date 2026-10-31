#!/usr/bin/env bash
# Argo 守护（cron / OpenRC）回归测试
# 覆盖点：Alpine 的 BusyBox crontab/crond 不得被误判为开机自启已就绪；
#         OpenRC 分支不得吞掉 rc-update / rc-service 失败；
#         main() 启动时补齐已有 Argo 节点的开机守护。
# 依赖: bash、sed、grep
# 用法: bash tests/test_argo_watchdog.sh
set -uo pipefail
# 任何交互式读取都直接失败而不是挂起 CI
exec < /dev/null

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for bin in bash sed grep; do
    command -v "$bin" >/dev/null 2>&1 || { echo "缺少依赖: $bin" >&2; exit 1; }
done

# 占位服务名：断言服务可用性判定逻辑，不依赖系统是否装了真实 cron
TEST_CRON_SERVICE="singbox-test-cron"

fail=0
check() { # 描述 期望 实际
    if [ "$2" = "$3" ]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n      期望: %s\n      实际: %s\n' "$1" "$2" "$3"
        fail=$((fail + 1))
    fi
}
check_rc() { # 描述 期望(0/非0) 实际返回码
    if [ "$2" -eq 0 ] && [ "$3" -eq 0 ]; then
        printf 'ok    %s\n' "$1"
    elif [ "$2" -ne 0 ] && [ "$3" -ne 0 ]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n      期望返回: %s  实际返回: %s\n' "$1" "$2" "$3"
        fail=$((fail + 1))
    fi
}

# --- 抽取被测函数（singbox.sh 会直接执行主菜单，不能 source 整个文件） ---
for fn in _cron_daemon_running _ensure_argo_cron _enable_argo_watchdog; do
    sed -n "/^${fn}() {\$/,/^}\$/p" "$ROOT/singbox.sh" > "$WORK/${fn}.sh"
    [ -s "$WORK/${fn}.sh" ] || { echo "抽取 ${fn} 失败" >&2; exit 1; }
done

# 把服务名数组替换为占位服务名，避免探测真实系统的 /etc/init.d/cron 等文件
sed "s/(cron crond cronie)/(${TEST_CRON_SERVICE})/;s/(dcron crond)/(${TEST_CRON_SERVICE})/;s/(crond cronie)/(${TEST_CRON_SERVICE})/" \
    "$WORK/_ensure_argo_cron.sh" > "$WORK/_ensure_argo_cron.param.sh"

# shellcheck disable=SC1090
. "$WORK/_cron_daemon_running.sh"
# shellcheck disable=SC1090
. "$WORK/_ensure_argo_cron.param.sh"
# shellcheck disable=SC1090
. "$WORK/_enable_argo_watchdog.sh"

# --- 替身必须在被测函数之后定义，否则会被抽取出的真实实现覆盖 ----------
CALL_LOG="$WORK/calls.log"
FAKE_CRONTAB_FILE="$WORK/crontab.txt"
SELF_SCRIPT_PATH="/opt/test/singbox.sh"

# 提示函数与桩函数内部一律用 [[ ]]，避免命中下面覆盖的 [ 而自递归
_info() { :; }
_success() { :; }
_warn() { :; }
_error() { :; }

# 用变量开关替代真实进程探测，避免依赖运行环境
_cron_daemon_running() { [[ "$FAKE_DAEMON_RUNNING" == true ]]; }
_pkg_install() { printf 'pkg_install %s\n' "$1" >> "$CALL_LOG"; return 0; }

# 记录调用并按场景注入失败
rc-update() { printf 'rc-update %s\n' "$*" >> "$CALL_LOG"; [[ "$FAKE_RC_UPDATE" == ok ]]; }
rc-service() {
    printf 'rc-service %s\n' "$*" >> "$CALL_LOG"
    case "$FAKE_RC_SERVICE" in
        start-fail) [[ "${2:-}" == start ]] && return 1 ;;
        status-fail) [[ "${2:-}" == status ]] && return 1 ;;
    esac
    return 0
}
crontab() {
    case "${1:-}" in
        -l) cat "$FAKE_CRONTAB_FILE" ;;
        -) cat > "$FAKE_CRONTAB_FILE" ;;
        *) return 1 ;;
    esac
}

# 同名函数覆盖内建 test，只接管被测代码用到的文件判定，其余原样交回 builtin。
# 被测代码存在 `[ -s X ]`、`[ ! -x Y ]`、`[ ! -L Z ]` 等写法：结尾的 `]` 不是路径，
# 所以取操作符后面那个参数匹配，并自行处理开头的 `!`，否则取反语义会丢失。
# 注意函数体内必须用 [[ ]]，否则会再次命中这里而自递归。
[() {
    local target="" prev="" arg negate=false value result
    [[ "${1:-}" == "!" ]] && negate=true
    for arg in "$@"; do
        case "$prev" in
            -s|-x|-f|-d|-e|-r|-w|-L|-h|-S|-p|-b|-c|-u|-g|-k|-O|-G) target="$arg" ;;
        esac
        prev="$arg"
    done
    case "$target" in
        /run/openrc/softlevel) value="$FAKE_OPENRC_RUNNING" ;;
        /etc/init.d/"$TEST_CRON_SERVICE") value="$FAKE_SERVICE_FILE" ;;
        /etc/runlevels/default/"$TEST_CRON_SERVICE") value="$FAKE_SERVICE_ENABLED" ;;
        *) builtin [ "$@"; return ;;
    esac
    # 基础结果由场景开关决定，再叠加 `!` 的取反语义
    if [[ "$value" == true ]]; then
        result=0
    else
        result=1
    fi
    if [[ "$negate" == true ]]; then
        result=$((1 - result))
    fi
    return "$result"
}
command() {
    if [[ "${1:-}" == "-v" ]]; then
        case "${2:-}" in
            apk)
                [[ "$FAKE_APK" == true ]] || return 1
                printf 'apk\n'
                return 0
                ;;
            crontab)
                [[ "$FAKE_CRONTAB_BIN" == true ]] || return 1
                printf 'crontab\n'
                return 0
                ;;
        esac
    fi
    builtin command "$@"
}

_reset() { # init_system apk openrc_running service_file crontab_bin daemon enabled
    export INIT_SYSTEM="$1"
    FAKE_APK="$2"
    FAKE_OPENRC_RUNNING="$3"
    FAKE_SERVICE_FILE="$4"
    FAKE_CRONTAB_BIN="$5"
    FAKE_DAEMON_RUNNING="$6"
    FAKE_SERVICE_ENABLED="${7:-$4}"
    FAKE_RC_UPDATE=ok
    FAKE_RC_SERVICE=ok
    : > "$CALL_LOG"
    : > "$FAKE_CRONTAB_FILE"
}

# --- 1. OpenRC 实际运行但没有 cron 服务：必须安装依赖 -------------------
# 修复前 BusyBox 自带 crontab 就直接放过，重启后却无人执行守护任务。
# 参数顺序：init_system apk openrc_running service_file crontab_bin daemon
_reset openrc true true false true false
_ensure_argo_cron >/dev/null 2>&1
check_rc "OpenRC 运行却无 cron 服务时拒绝放行" 1 "$?"
check "缺少 cron 服务时按需安装 dcron" "pkg_install dcron" "$(grep -F 'pkg_install' "$CALL_LOG")"

# --- 2. OpenRC 实际运行且有 cron 服务：加入 default 并确认已启动 -------
_reset openrc true true true true true
_ensure_argo_cron >/dev/null 2>&1
check_rc "OpenRC 有 cron 服务时返回成功" 0 "$?"
check "把 cron 服务加入 default 运行级别" "rc-update add ${TEST_CRON_SERVICE} default" \
    "$(grep -F 'rc-update' "$CALL_LOG")"
check "启动 cron 服务并校验状态" "rc-service ${TEST_CRON_SERVICE} start|rc-service ${TEST_CRON_SERVICE} status" \
    "$(grep -F 'rc-service' "$CALL_LOG" | tr '\n' '|' | sed 's/|$//')"
check "已存在 cron 服务时不重复安装" "" "$(grep -F 'pkg_install' "$CALL_LOG")"

# --- 3. rc-update 失败必须让整体失败，而不是 `|| true` 放过 ------------
_reset openrc true true true true true
FAKE_RC_UPDATE=fail
_ensure_argo_cron >/dev/null 2>&1
check_rc "rc-update 失败时整体失败" 1 "$?"

# --- 4. rc-service 启动失败同样必须失败 -------------------------------
_reset openrc true true true true true
FAKE_RC_SERVICE=start-fail
_ensure_argo_cron >/dev/null 2>&1
check_rc "rc-service 启动失败时整体失败" 1 "$?"

# --- 5. rc-service 起来了但状态不健康也必须失败 -----------------------
_reset openrc true true true true true
FAKE_RC_SERVICE=status-fail
_ensure_argo_cron >/dev/null 2>&1
check_rc "rc-service 状态异常时整体失败" 1 "$?"

# --- 6. 容器（无 OpenRC PID 1）不校验运行级别，依赖可用即放行 ---------
_reset openrc true false false true true
_ensure_argo_cron >/dev/null 2>&1
check_rc "无 OpenRC 运行环境时不强求运行级别" 0 "$?"

# --- 7. 守护不可用时拒绝创建不受守护的 Argo 节点 ----------------------
_reset openrc true true true true false
_enable_argo_watchdog >/dev/null 2>&1
check_rc "守护不可用时 _enable_argo_watchdog 失败" 1 "$?"
check "守护不可用时不写入 crontab" "" "$(cat "$FAKE_CRONTAB_FILE")"

# --- 8. 已注册守护条目时直接复用，不重复写入 -------------------------
_reset systemd true true true true true
printf '* * * * * bash %s keepalive >/dev/null 2>&1\n' "$SELF_SCRIPT_PATH" > "$FAKE_CRONTAB_FILE"
_enable_argo_watchdog >/dev/null 2>&1
check_rc "已注册守护条目时 _enable_argo_watchdog 成功" 0 "$?"
check "已注册守护条目时不重复追加" "1" "$(grep -Fc 'keepalive' "$FAKE_CRONTAB_FILE")"

# --- 9. 未注册守护条目时写入一次 -------------------------------------
_reset systemd true true true true true
_enable_argo_watchdog >/dev/null 2>&1
check_rc "未注册守护条目时 _enable_argo_watchdog 成功" 0 "$?"
check "未注册守护条目时写入一次" "1" "$(grep -Fc 'keepalive' "$FAKE_CRONTAB_FILE")"

# --- 10. main() 启动时对已有 Argo 节点补守护，且失败仅告警 ------------
startup_guard="$(sed -n '/已有 Argo 节点升级脚本后也要补齐开机守护/,/^        fi$/p' "$ROOT/singbox.sh")"
[ -n "$startup_guard" ] || { printf 'FAIL  %s\n' "启动自检：未找到补守护代码块"; fail=$((fail + 1)); }
case "$startup_guard" in
    *'[ -s "$ARGO_METADATA_FILE" ]'*) printf 'ok    %s\n' "启动自检：以 ARGO_METADATA_FILE 非空为前提" ;;
    *) printf 'FAIL  %s\n' "启动自检：缺少 ARGO_METADATA_FILE 非空判定"; fail=$((fail + 1)) ;;
esac
case "$startup_guard" in
    *'_enable_argo_watchdog || _warn'*) printf 'ok    %s\n' "启动自检：补守护失败降级为告警，不阻塞进入菜单" ;;
    *) printf 'FAIL  %s\n' "启动自检：补守护失败未降级为告警"; fail=$((fail + 1)) ;;
esac

# --- 11. 版本号与 README 版本行保持一致 ------------------------------
script_version="$(sed -n 's/^export SCRIPT_VERSION="\([^"]*\)".*/\1/p' "$ROOT/singbox.sh" | head -n 1)"
readme_version="$(sed -n 's/.*`singbox\.sh v\([0-9][0-9]*\)`.*/\1/p' "$ROOT/README.md" | head -n 1)"
check "singbox.sh 与 README 版本号一致" "$script_version" "$readme_version"

if [ "$fail" -ne 0 ]; then
    printf '\n%d 项断言失败\n' "$fail" >&2
    exit 1
fi
printf '\n全部断言通过\n'
