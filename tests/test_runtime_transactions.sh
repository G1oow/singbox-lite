#!/usr/bin/env bash
# 动态抽取真实事务函数，仅替换文件故障、nft 与服务等外部边界。
set -uo pipefail
exec < /dev/null
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
if command -v cygpath >/dev/null 2>&1; then WORK=$(cygpath -m "$WORK"); fi
trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK"
fail=0
load() {
    local file="$1" name code
    shift
    for name in "$@"; do
        code=$(awk -v name="$name" '$0 == name "() {" {p=1} p {print} p && /^}/ {exit}' "$ROOT/$file")
        [ -n "$code" ] || { printf 'missing function: %s\n' "$name" >&2; exit 1; }
        eval "$code"
    done
}
check() {
    if "$@"; then printf 'ok    %s\n' "$*"; else printf 'FAIL  %s\n' "$*"; fail=$((fail+1)); fi
}
_info() { :; }; _warn() { :; }; _error() { printf '%s\n' "$*" >> "$WORK/errors"; }; _success() { :; }
load xray_manager.sh _xray_service_file _xray_service_running _xray_check_foreign_transactions _xray_snapshot_state _xray_restore_file \
    _xray_restore_state _xray_drop_snapshot _xray_commit_state _xray_recover_pending _run_xray_transaction _xray_rollback_state
SINGBOX_DIR="$WORK/xray-state"
XRAY_DIR="$SINGBOX_DIR/xray"; mkdir -p "$XRAY_DIR"
XRAY_CONFIG="$XRAY_DIR/config.json"; XRAY_METADATA="$XRAY_DIR/metadata.json"; CLASH_YAML_FILE="$SINGBOX_DIR/clash.yaml"
XRAY_SERVICE_FILE="$SINGBOX_DIR/xray.service"
XRAY_TX_DIR="" XRAY_TX_ACTIVE="" XRAY_TX_BLOCKED=0 INIT_SYSTEM=systemd XRAY_TEST_RUNNING=1
seed_xray() {
    rm -rf "$SINGBOX_DIR/.transactions"
    XRAY_TX_DIR="" XRAY_TX_ACTIVE="" XRAY_TX_BLOCKED=0 XRAY_TEST_RUNNING=1
    printf config > "$XRAY_CONFIG"; printf metadata > "$XRAY_METADATA"
    printf clash > "$CLASH_YAML_FILE"; printf certificate > "$XRAY_DIR/node.pem"
    printf service > "$XRAY_SERVICE_FILE"
}
cp() { [[ "$*" == *"${CP_FAIL_MATCH:-NEVER_MATCH}"* ]] && return 1; command cp "$@"; }
mkdir() { [[ "$*" == *"${MKDIR_FAIL_MATCH:-NEVER_MATCH}"* ]] && return 1; command mkdir "$@"; }
_xray_service_file() { printf '%s\n' "$XRAY_SERVICE_FILE"; }
_xray_service_running() { [ "$XRAY_TEST_RUNNING" = 1 ]; }
systemctl() { [ "${1:-}" != is-enabled ] || printf 'enabled\n'; return 0; }
_manage_xray_service() {
    [ "${SERVICE_FAIL:-0}" = 0 ] || return 1
    case "$1" in start|restart) XRAY_TEST_RUNNING=1 ;; stop) XRAY_TEST_RUNNING=0 ;; esac
}
_validate_xray_config() { return 0; }
mutate_xray() { printf changed > "$XRAY_CONFIG"; return 1; }
if [[ "${1:-all}" == all || "${1:-}" == xray ]]; then
    echo '== Xray 快照 / 恢复 =='
    export SINGBOXLITE_LOCK_HELD=1
    seed_xray
    CP_FAIL_MATCH="$XRAY_CONFIG"
    _run_xray_transaction mutate_xray; rc=$?
    check test "$rc" -ne 0
    check test "$(cat "$XRAY_CONFIG")" = config
    unset CP_FAIL_MATCH
    seed_xray
    MKDIR_FAIL_MATCH=/certs
    _xray_snapshot_state; rc=$?
    check test "$rc" -ne 0
    unset MKDIR_FAIL_MATCH
    seed_xray
    CP_FAIL_MATCH=node.pem
    _xray_snapshot_state; rc=$?
    check test "$rc" -ne 0
    unset CP_FAIL_MATCH
    partial=$(mktemp -d)
    _xray_restore_state "$partial"; rc=$?
    check test "$rc" -ne 0
    check test -f "$XRAY_CONFIG"
    check test -f "$XRAY_METADATA"
    check test -f "$XRAY_DIR/node.pem"
    seed_xray
    _xray_snapshot_state
    snapshot="$XRAY_TX_DIR"
    CP_FAIL_MATCH=node.pem
    _xray_restore_state "$snapshot"; rc=$?
    check test "$rc" -ne 0
    check test "$(cat "$XRAY_DIR/node.pem" 2>/dev/null)" = certificate
    unset CP_FAIL_MATCH
    seed_xray
    # 只在恢复阶段失败，快照创建仍走真实 cp。
    mutate_restore_failure() { CP_FAIL_MATCH=/config.json; mutate_xray; }
    _run_xray_transaction mutate_restore_failure; rc=$?
    check test "$rc" -ne 0
    check test -d "$XRAY_TX_DIR"
    unset CP_FAIL_MATCH
    seed_xray
    _xray_snapshot_state; snapshot="$XRAY_TX_DIR"
    printf changed > "$XRAY_CONFIG"; printf extra > "$XRAY_DIR/extra.key"
    _xray_restore_state "$snapshot"; rc=$?
    check test "$rc" -eq 0
    check test "$(cat "$XRAY_CONFIG")" = config
    check test ! -f "$XRAY_DIR/extra.key"
    seed_xray
    _xray_snapshot_state; snapshot="$XRAY_TX_DIR"
    rm -f "$snapshot/certs/node.pem"
    _xray_restore_state "$snapshot"; rc=$?
    check test "$rc" -ne 0
    check test "$(cat "$XRAY_DIR/node.pem")" = certificate
    seed_xray
    SERVICE_FAIL=1
    _run_xray_transaction mutate_xray; rc=$?
    check test "$rc" -ne 0
    check test -d "$XRAY_TX_DIR"
    unset SERVICE_FAIL
    unset SINGBOXLITE_LOCK_HELD
fi

if [[ "${1:-all}" == all || "${1:-}" == relay || "${1:-}" == relay-service ]]; then
    echo '== 中转服务操作必须核验最终运行态 =='
    (
        load advanced_relay.sh _manage_service _restart_checked
        STATE_LOCK_OWNED=false STATE_LOCK_FD="" SINGBOX_BIN="$WORK/fixture-core"
        SINGBOX_PID_FILE="$WORK/fixture.pid"
        _check_combined_config() { return 0; }
        _prepare_run_dir() { return 0; }
        sleep() { :; }
        service_command() {
            local action="$1"
            case "$action" in
                is-active|status) [ "$HEALTHY" = 1 ] ;;
                start|restart|stop) return "${COMMAND_FAIL:-0}" ;;
                reset-failed) return 0 ;;
                *) return 1 ;;
            esac
        }
        systemctl() { service_command "$1"; }
        rc-service() { service_command "$2"; }
        for INIT_SYSTEM in systemd openrc; do
            HEALTHY=0
            _restart_checked; rc=$?
            check test "$rc" -ne 0
            _manage_service start; rc=$?
            check test "$rc" -ne 0
            HEALTHY=1
            _restart_checked; rc=$?
            check test "$rc" -eq 0
            _manage_service stop; rc=$?
            check test "$rc" -ne 0
            HEALTHY=0
            _manage_service stop; rc=$?
            check test "$rc" -eq 0
            HEALTHY=1 COMMAND_FAIL=1
            _manage_service restart; rc=$?
            check test "$rc" -ne 0
            unset COMMAND_FAIL
        done
        INIT_SYSTEM=direct
        _is_pid_running_cmd() { [ "$DIRECT_ALIVE" = 1 ]; }
        _is_pid_file_running_cmd() { return 0; } # 拦住旧实现误走 start，测试绝不启动真实核心。
        kill() {
            [ "${KILL_FAIL:-0}" = 0 ] || return 1
            [ "${KEEP_ALIVE:-0}" = 1 ] || DIRECT_ALIVE=0
        }
        printf '12345\n' > "$SINGBOX_PID_FILE"
        DIRECT_ALIVE=1 KILL_FAIL=1
        _manage_service stop; rc=$?
        check test "$rc" -ne 0
        check test -s "$SINGBOX_PID_FILE"
        printf '12345\n' > "$SINGBOX_PID_FILE"
        _manage_service restart; rc=$?
        check test "$rc" -ne 0
        check test -s "$SINGBOX_PID_FILE"
        unset KILL_FAIL
        DIRECT_ALIVE=1 KEEP_ALIVE=1
        printf '12345\n' > "$SINGBOX_PID_FILE"
        _manage_service stop; rc=$?
        check test "$rc" -ne 0
        check test -s "$SINGBOX_PID_FILE"
        unset KEEP_ALIVE
        _manage_service stop; rc=$?
        check test "$rc" -eq 0
        check test ! -e "$SINGBOX_PID_FILE"
        [ "$fail" -eq 0 ]
    ) || fail=$((fail + 1))
fi

if [[ "${1:-all}" == all || "${1:-}" == relay || "${1:-}" == relay-state ]]; then
    echo '== nft 删除与引擎切换事务 =='
    load advanced_relay.sh _nft_delete_rules_by_comment _pf_delete_nft_rule_set _pf_nft_addr_key _pf_nft_dnat_target _pf_apply_nft_rules \
        _pf_apply_singbox_rules _pf_build_inbound_json _pf_build_rule_json _pf_delete _pf_switch_engine \
        _txn_snapshot_file _txn_restore_file _restart_checked _pf_txn_snapshot _pf_txn_restore _pf_txn_cleanup _pf_switch_engine_locked _pf_switch_engine_apply _save_nftables_rules _pf_clear _pf_modify _pf_modify_apply _pf_store_metadata _pf_dns_refresh _pf_dns_refresh_locked _relay_txn_snapshot _clear_all_relays _nft_apply_redirect_rule
    eval "$(awk '/^# --- 中转持久事务 ---$/,/^# --- 中转持久事务结束 ---$/' "$ROOT/advanced_relay.sh")"
    GREEN= CYAN= YELLOW= NC= PF_ENGINE=nftables PF_ENV_KIND=test PF_ACCESS_HINT= PF_PUBLISH_HINT=false
    SINGBOX_DIR="$WORK/relay-state"; mkdir -p "$SINGBOX_DIR"
    RELAY_AUX_DIR="$SINGBOX_DIR"; RELAY_CLASH_YAML="$SINGBOX_DIR/clash.yaml"
    PF_METADATA_FILE="$WORK/pf.json"; RELAY_CONFIG_FILE="$WORK/relay.json"
    NFT_TABLE=singboxlite; NFT_PERSIST_FILE="$WORK/persist.nft"; NFT_CONFIG_FILE="$WORK/nftables.conf"
    table="$WORK/table"; running="$WORK/running"; service_state="$WORK/relay-service.state"; locked=0
    _state_lock_acquire() { locked=1; }
    _state_lock_release() { locked=0; }
    _secure_state_file() { :; }
    _pf_ensure_metadata() { :; }
    _pf_count() { jq length "$PF_METADATA_FILE"; }
    _pf_auto_manage_dns_cron() { :; }
    _pf_guess_target_family() { printf ipv4; }
    _pf_detect_engine() { PF_ENGINE=nftables; }
    _pf_find_hy2_hop_conflict() { :; }
    _pf_prepare_nft_target() { printf 'ipv4\t192.0.2.1\tfalse\n'; }
    _pf_enable_forwarding() { :; }
    _remove_node_from_relay_yaml() { printf changed > "$RELAY_CLASH_YAML"; }
    _pf_dns_log() { :; }
    _pf_resolve_domain_family() { printf '192.0.2.2\n'; }
    _check_combined_config() { return "${CHECK_FAIL:-0}"; }
    _manage_service() {
        printf '%s\n' "$1" >> "$WORK/relay-service.calls"
        case "$1" in
            status) [ "$(cat "$service_state")" = running ] ;;
            start|restart)
                command cp "$RELAY_CONFIG_FILE" "$running"
                [ "${RESTART_FAIL:-0}" = 0 ] || return 1
                printf 'running\n' > "$service_state"
                ;;
            stop)
                [ "${STOP_FAIL:-0}" = 0 ] || return 1
                [ "${STOP_LIES:-0}" = 0 ] || return 0
                printf 'stopped\n' > "$service_state"
                ;;
            *) return 1 ;;
        esac
    }
    _atomic_write_json() {
        [ "${META_FAIL:-0}" = 1 ] && [ "$1" = "$PF_METADATA_FILE" ] && return 1
        printf '%s\n' "$2" > "$1"
    }
    _atomic_modify_json() {
        local json
        json=$(jq "$2" "$1") || return 1
        _atomic_write_json "$1" "$json"
    }
    _nft_ensure_base() { [ -e "$table" ] || : > "$table"; }
    nft() {
        [ "$locked" -eq 1 ] || { printf 'unlocked nft access\n' >> "$WORK/unlocked"; }
        printf '%s\n' "$*" >> "$WORK/nft.calls"
        case "$*" in
            'list tables') [ ! -f "$table" ] || printf 'table inet %s\n' "$NFT_TABLE" ;;
            '-a list table inet '*)
                [ "${NFT_LIST_FAIL:-0}" = 0 ] || return 1
                cat "$table" | awk '{ if (match($0, /singboxlite-[^ "]+/)) printf "chain prerouting {\n comment \"%s\" # handle %d\n}\n", substr($0, RSTART, RLENGTH), NR }' ;;
            'delete rule inet '*)
                local line
                line=$(sed -n "${7}p" "$table")
                [[ "$line" == *"${DELETE_FAIL_MATCH:-NEVER_MATCH}"* ]] && return 1
                sed -i "${7}d" "$table" ;;
            "list table inet $NFT_TABLE") cat "$table" ;;
            "delete table inet $NFT_TABLE") rm -f "$table" ;;
            '-f '*) [ "${NFT_RESTORE_FAIL:-0}" = 0 ] || return 1; sed '/^delete table inet /d' "$2" > "$table" ;;
            'add rule '*) printf '%s\n' "$*" >> "$table" ;;
            *) return 1 ;;
        esac
    }
    # nft 的替身维护规则文本，删除逻辑仍使用源码中的真实函数。
    mv() { [ "${SAVE_FAIL:-0}" = 1 ] && [[ "$*" == *"$NFT_PERSIST_FILE"* ]] && return 1; command mv "$@"; }
    systemctl() { :; }; rc-update() { :; }
    seed_relay() {
        local engine="$1"
        RELAY_TX_ACTIVE="" RELAY_TX_BLOCKED=0 RELAY_TX_RECOVERING=0
        printf 'running\n' > "$service_state"
        : > "$WORK/relay-service.calls"
        rm -rf "$SINGBOX_DIR/.transactions"
        jq -n --arg engine "$engine" '{"8443":{engine:$engine,name:"test",target_addr:"192.0.2.1",target_port:443,network:"tcp",network_display:"TCP",target_family:"ipv4",resolved_ip:"192.0.2.1"}}' > "$PF_METADATA_FILE"
        printf '{"inbounds":[],"outbounds":[],"route":{"rules":[]}}\n' > "$RELAY_CONFIG_FILE"
        printf 'original singboxlite-pf-8443-tcp-prerouting\nunrelated\n' > "$table"
        if [ "$engine" = singbox ]; then
            _pf_apply_singbox_rules add 8443 192.0.2.1 443 tcp
            printf 'unrelated\n' > "$table"
        fi
        command cp "$RELAY_CONFIG_FILE" "$running"
        command cp "$table" "$NFT_PERSIST_FILE"
        command cp "$PF_METADATA_FILE" "$WORK/meta.before"
        command cp "$RELAY_CONFIG_FILE" "$WORK/relay.before"
        command cp "$table" "$WORK/table.before"
    }
    if [[ "${1:-all}" != relay-state ]]; then
    seed_relay nftables
    DELETE_FAIL_MATCH=tcp-prerouting
    _pf_delete_nft_rule_set 8443; rc=$?
    check test "$rc" -ne 0
    check test "$(grep -c '^-a list table inet ' "$WORK/nft.calls")" = 9
    _pf_apply_nft_rules delete 8443 192.0.2.1 443 tcp ipv4; rc=$?
    check test "$rc" -ne 0
    _pf_delete <<< $'1\n'; rc=$?
    check test "$rc" -ne 0
    check cmp -s "$PF_METADATA_FILE" "$WORK/meta.before"
    unset DELETE_FAIL_MATCH
    seed_relay nftables
    SAVE_FAIL=1
    _pf_delete <<< $'1\n'; rc=$?
    check test "$rc" -ne 0
    check cmp -s "$PF_METADATA_FILE" "$WORK/meta.before"
    unset SAVE_FAIL

    echo '== DDNS 持久化失败必须恢复旧地址 =='
    seed_relay nftables
    jq '."8443".target_is_domain = true | ."8443".target_addr = "example.com"' "$PF_METADATA_FILE" > "$WORK/new-meta"
    command mv "$WORK/new-meta" "$PF_METADATA_FILE"
    command cp "$PF_METADATA_FILE" "$WORK/meta.before"
    SAVE_FAIL=1
    _state_lock_acquire
    _pf_dns_refresh; rc=$?
    _state_lock_release
    check test "$rc" -ne 0
    check cmp -s "$PF_METADATA_FILE" "$WORK/meta.before"
    check cmp -s "$table" "$WORK/table.before"
    check cmp -s "$NFT_PERSIST_FILE" "$WORK/table.before"
    unset SAVE_FAIL
    rm -f "$WORK/unlocked"
    seed_relay nftables
    NFT_LIST_FAIL=1
    _pf_delete_nft_rule_set 8443; rc=$?
    check test "$rc" -ne 0
    unset NFT_LIST_FAIL
    rm -f "$WORK/unlocked"
    for case_engine in nftables singbox; do
        for fault in META_FAIL SAVE_FAIL CHECK_FAIL RESTART_FAIL; do
            seed_relay "$case_engine"
            printf -v "$fault" %s 1
            _pf_switch_engine <<< $'1\ny\n'; rc=$?
            check test "$rc" -ne 0
            check cmp -s "$PF_METADATA_FILE" "$WORK/meta.before"
            check cmp -s "$RELAY_CONFIG_FILE" "$WORK/relay.before"
            check cmp -s "$running" "$WORK/relay.before"
            check cmp -s "$table" "$WORK/table.before"
            check cmp -s "$NFT_PERSIST_FILE" "$WORK/table.before"
            check test "$locked" -eq 0
            unset "$fault"
        done
        seed_relay "$case_engine"
        _pf_switch_engine <<< $'1\ny\n'; rc=$?
        check test "$rc" -eq 0
        [ "$case_engine" = nftables ] && expected=singbox || expected=nftables
        check test "$(jq -r '."8443".engine' "$PF_METADATA_FILE")" = "$expected"
        check cmp -s "$running" "$RELAY_CONFIG_FILE"
        check cmp -s "$NFT_PERSIST_FILE" "$table"
        check test "$locked" -eq 0
    done
    # 回滚本身失败必须保留快照，并且不能误报成功。
    seed_relay nftables
    META_FAIL=1 NFT_RESTORE_FAIL=1
    _pf_switch_engine <<< $'1\ny\n'; rc=$?
    check test "$rc" -ne 0
    retained=$(printf '%s\n' "$SINGBOX_DIR"/.transactions/relay-*/complete | head -n 1)
    check test -f "$retained"
    check test "$locked" -eq 0
    unset META_FAIL NFT_RESTORE_FAIL
    check test ! -f "$WORK/unlocked"

    echo '== 清空端口转发失败必须整体恢复 =='
    for fault in DELETE_FAIL_MATCH SAVE_FAIL META_FAIL; do
        seed_relay nftables
        if [ "$fault" = DELETE_FAIL_MATCH ]; then
            DELETE_FAIL_MATCH=tcp-prerouting
        else
            printf -v "$fault" %s 1
        fi
        _pf_clear <<< $'y\n\n'; rc=$?
        check test "$rc" -ne 0
        check cmp -s "$PF_METADATA_FILE" "$WORK/meta.before"
        check cmp -s "$table" "$WORK/table.before"
        check cmp -s "$NFT_PERSIST_FILE" "$WORK/table.before"
        check test "$locked" -eq 0
        unset "$fault"
    done

    echo '== 修改端口转发的保存失败必须整体恢复 =='
    seed_relay nftables
    SAVE_FAIL=1
    _pf_modify <<< $'1\n\n192.0.2.2\n4443\n0\n\n'; rc=$?
    check test "$rc" -ne 0
    check cmp -s "$PF_METADATA_FILE" "$WORK/meta.before"
    check cmp -s "$table" "$WORK/table.before"
    check cmp -s "$NFT_PERSIST_FILE" "$WORK/table.before"
    unset SAVE_FAIL

    echo '== 中转清空失败必须恢复证书和跳跃规则 =='
    seed_relay nftables
    printf '%s\n' '{"inbounds":[{"tag":"hysteria2-in-8443","listen_port":8443}],"outbounds":[{"tag":"relay-out-8443"}],"route":{"rules":[{"inbound":"hysteria2-in-8443","outbound":"relay-out-8443"}]}}' > "$RELAY_CONFIG_FILE"
    printf '%s\n' '{"hysteria2-in-8443":{"node_name":"relay-test","listen_port":8443,"port_hopping":"30000-30010"}}' > "$RELAY_AUX_DIR/relay_links.json"
    printf clash > "$RELAY_CLASH_YAML"
    printf certificate > "$RELAY_AUX_DIR/hysteria2-in-8443.pem"
    printf fixture-key > "$RELAY_AUX_DIR/hysteria2-in-8443.key"
    printf 'original singboxlite-relay-hop-hysteria2-in-8443\n' >> "$table"
    command cp "$RELAY_CONFIG_FILE" "$WORK/relay.before"
    command cp "$table" "$WORK/table.before"
    command cp "$table" "$NFT_PERSIST_FILE"
    command cp "$RELAY_AUX_DIR/relay_links.json" "$WORK/links.before"
    DELETE_FAIL_MATCH=singboxlite-relay-hop
    _clear_all_relays; rc=$?
    check test "$rc" -ne 0
    check cmp -s "$RELAY_CONFIG_FILE" "$WORK/relay.before"
    check cmp -s "$RELAY_AUX_DIR/relay_links.json" "$WORK/links.before"
    check test "$(cat "$RELAY_CLASH_YAML")" = clash
    check test "$(cat "$RELAY_AUX_DIR/hysteria2-in-8443.pem")" = certificate
    check test "$(cat "$RELAY_AUX_DIR/hysteria2-in-8443.key")" = fixture-key
    check cmp -s "$table" "$WORK/table.before"
    check cmp -s "$NFT_PERSIST_FILE" "$WORK/table.before"
    unset DELETE_FAIL_MATCH

    echo '== 持久事务恢复与中断 =='
    seed_relay nftables
    dir=$(_txn_begin)
    _pf_txn_snapshot "$dir" true
    _pf_apply_nft_rules delete 8443 192.0.2.1 443 tcp ipv4
    printf '{}\n' > "$PF_METADATA_FILE"
    printf changed > "$NFT_PERSIST_FILE"
    # 模拟新进程：没有内存中的 active，但磁盘上的 complete 必须足以恢复。
    RELAY_TX_ACTIVE="" RELAY_TX_BLOCKED=0 locked=0
    _relay_recover_pending; rc=$?
    check test "$rc" -eq 0
    check cmp -s "$PF_METADATA_FILE" "$WORK/meta.before"
    check cmp -s "$table" "$WORK/table.before"
    check cmp -s "$NFT_PERSIST_FILE" "$WORK/table.before"
    check test ! -d "$dir"
    check test "$locked" -eq 0

    seed_relay nftables
    dir=$(_txn_begin)
    _pf_txn_snapshot "$dir" true
    printf changed > "$table"
    RELAY_TX_ACTIVE=""
    NFT_RESTORE_FAIL=1
    _relay_recover_pending; rc=$?
    check test "$rc" -ne 0
    check test -f "$dir/complete"
    _pf_clear <<< $'y\n\n'; rc=$?
    check test "$rc" -ne 0
    check test "$(cat "$table")" = changed
    unset NFT_RESTORE_FAIL
    RELAY_TX_ACTIVE="" RELAY_TX_BLOCKED=0
    _relay_recover_pending; rc=$?
    check test "$rc" -eq 0
    check cmp -s "$table" "$WORK/table.before"

    seed_relay nftables
    dir=$(_txn_begin)
    _txn_snapshot_file "$dir" relay "$RELAY_CONFIG_FILE"
    printf incomplete-current > "$RELAY_CONFIG_FILE"
    _relay_recover_pending; rc=$?
    check test "$rc" -eq 0
    check test "$(cat "$RELAY_CONFIG_FILE")" = incomplete-current
    check test -d "$dir"

    seed_relay nftables
    dir=$(_txn_begin)
    _pf_txn_snapshot "$dir" true
    printf committed-current > "$RELAY_CONFIG_FILE"
    : > "$dir/committed"
    RELAY_TX_ACTIVE=""
    _relay_recover_pending; rc=$?
    check test "$rc" -eq 0
    check test "$(cat "$RELAY_CONFIG_FILE")" = committed-current
    check test ! -d "$dir"

    for signal in INT TERM KILL; do
        seed_relay nftables
        (
            trap '_relay_exit "$?"' EXIT
            trap '_relay_exit 130' INT
            trap '_relay_exit 143' TERM
            _save_nftables_rules() { kill -s "$signal" "$BASHPID"; }
            _pf_clear <<< $'y\n\n'
        ) >/dev/null 2>&1
        rc=$?
        check test "$rc" -ne 0
        if [ "$signal" = KILL ]; then
            RELAY_TX_ACTIVE="" RELAY_TX_BLOCKED=0
            _relay_recover_pending; rc=$?
            check test "$rc" -eq 0
        fi
        check cmp -s "$PF_METADATA_FILE" "$WORK/meta.before"
        check cmp -s "$table" "$WORK/table.before"
        check cmp -s "$NFT_PERSIST_FILE" "$WORK/table.before"
    done

    # 执行真正的命令分派，恢复入口不得先运行菜单初始化或安装依赖。
    seed_relay nftables
    dir=$(_txn_begin)
    _pf_txn_snapshot "$dir" true
    printf changed > "$table"
    RELAY_TX_ACTIVE=""
    (
        _check_root() { return 0; }
        _check_deps() { return 99; }
        _init_relay_dirs() { return 99; }
        set -- recover-pending
        eval "$(sed -n '/^case \"${1:-}\" in$/,/^esac$/p' "$ROOT/advanced_relay.sh")"
    ); rc=$?
    check test "$rc" -eq 0
    check cmp -s "$table" "$WORK/table.before"

    seed_relay nftables
    dir=$(_txn_begin)
    _pf_txn_snapshot "$dir" true
    printf changed > "$table"
    RELAY_TX_ACTIVE=""
    (
        trap - EXIT
        load advanced_relay.sh _state_lock_acquire _state_lock_release
        export SINGBOXLITE_LOCK_HELD=1
        STATE_LOCK_OWNED=false STATE_LOCK_FD="" locked=1
        flock() { return 99; }
        _relay_recover_pending &&
            [ "${SINGBOXLITE_LOCK_HELD:-0}" = 1 ] &&
            [ "$STATE_LOCK_OWNED" = false ]
    ); rc=$?
    check test "$rc" -eq 0
    check cmp -s "$table" "$WORK/table.before"

    echo '== 其他 family 的待恢复事务阻止新写入 =='
    for family in main caddy script-update xray; do
        seed_relay nftables
        pending="$SINGBOX_DIR/.transactions/${family}-fixture"
        mkdir -p "$pending"; : > "$pending/complete"
        _relay_write_boundary; rc=$?
        check test "$rc" -ne 0
        _pf_clear <<< $'y\n\n'; rc=$?
        check test "$rc" -ne 0
        check cmp -s "$PF_METADATA_FILE" "$WORK/meta.before"
        check cmp -s "$table" "$WORK/table.before"
        : > "$pending/committed"
        dir=$(_txn_begin); rc=$?
        check test "$rc" -eq 0
    done

    seed_relay nftables
    dir=$(_txn_begin)
    _pf_txn_snapshot "$dir" true
    printf changed > "$table"
    RELAY_TX_ACTIVE=""
    pending="$SINGBOX_DIR/.transactions/main-fixture"
    mkdir -p "$pending"; : > "$pending/complete"
    _relay_recover_pending; rc=$?
    check test "$rc" -eq 0
    check cmp -s "$table" "$WORK/table.before"
    check test -f "$pending/complete"
    fi

    echo '== 回退恢复原运行态，纯 nft 不启动已停止的核心 =='
    for tx_type in relay pf warp; do
        seed_relay nftables
        printf 'stopped\n' > "$service_state"
        _state_lock_acquire
        dir=$(_txn_begin)
        case "$tx_type" in
            relay)
                printf '{}\n' > "$RELAY_AUX_DIR/relay_links.json"
                printf 'clash\n' > "$RELAY_CLASH_YAML"
                _relay_txn_snapshot "$dir" false
                ;;
            pf) _pf_txn_snapshot "$dir" true ;;
            warp)
                _txn_snapshot_file "$dir" relay "$RELAY_CONFIG_FILE"
                for state_key in warp-reg warp-rules warp-nodes; do
                    printf '{}\n' > "$WORK/$state_key.json"
                    _txn_snapshot_file "$dir" "$state_key" "$WORK/$state_key.json"
                done
                _txn_activate "$dir" warp
                ;;
        esac
        check test "$(cat "$dir/service.state" 2>/dev/null)" = stopped
        printf changed > "$RELAY_CONFIG_FILE"
        _txn_rollback "$dir"; rc=$?
        check test "$rc" -eq 0
        check test "$(cat "$service_state")" = stopped
        check test "$(grep -Ec '^(start|restart)$' "$WORK/relay-service.calls")" -eq 0
        check cmp -s "$RELAY_CONFIG_FILE" "$WORK/relay.before"
        _state_lock_release
    done

    for stop_fault in STOP_FAIL STOP_LIES; do
        seed_relay nftables
        printf 'stopped\n' > "$service_state"
        _state_lock_acquire
        dir=$(_txn_begin)
        _pf_txn_snapshot "$dir" true
        printf 'running\n' > "$service_state"
        printf -v "$stop_fault" %s 1
        _txn_rollback "$dir"; rc=$?
        check test "$rc" -ne 0
        check test -f "$dir/complete"
        check test "${RELAY_TX_BLOCKED:-0}" -eq 1
        unset "$stop_fault"
        RELAY_TX_ACTIVE="" RELAY_TX_BLOCKED=0
        _relay_recover_pending; rc=$?
        check test "$rc" -eq 0
        check test "$(cat "$service_state")" = stopped
    done

    seed_relay nftables
    printf 'stopped\n' > "$service_state"
    (
        trap '_relay_exit "$?"' EXIT
        _save_nftables_rules() { kill -KILL "$BASHPID"; }
        _pf_clear <<< $'y\n\n'
    ) >/dev/null 2>&1
    rc=$?
    check test "$rc" -ne 0
    RELAY_TX_ACTIVE="" RELAY_TX_BLOCKED=0
    _relay_recover_pending; rc=$?
    check test "$rc" -eq 0
    check test "$(cat "$service_state")" = stopped
    check test "$(grep -Ec '^(start|restart)$' "$WORK/relay-service.calls")" -eq 0
    check cmp -s "$table" "$WORK/table.before"

    seed_relay nftables
    _state_lock_acquire
    dir=$(_txn_begin)
    _pf_txn_snapshot "$dir" false
    check test "$(cat "$dir/service.state")" = running
    rm -f "$dir/service.state"
    printf changed > "$RELAY_CONFIG_FILE"
    _txn_rollback "$dir"; rc=$?
    check test "$rc" -ne 0
    check test -f "$dir/complete"
    check test "$(cat "$RELAY_CONFIG_FILE")" = changed
    _state_lock_release

    echo '== 回退重启后不健康必须保留事务 =='
    (
        load advanced_relay.sh _manage_service
        STATE_LOCK_OWNED=false STATE_LOCK_FD=""
        sleep() { :; }
        health_command() {
            case "$1" in
                is-active|status) [ "$ROLLBACK_HEALTHY" = 1 ] ;;
                restart) ROLLBACK_HEALTHY=0 ;;
                reset-failed) return 0 ;;
                *) return 1 ;;
            esac
        }
        systemctl() { health_command "$1"; }
        rc-service() { health_command "$2"; }
        for INIT_SYSTEM in systemd openrc; do
            seed_relay nftables
            _state_lock_acquire
            ROLLBACK_HEALTHY=1
            dir=$(_txn_begin)
            _pf_txn_snapshot "$dir" false
            printf changed > "$RELAY_CONFIG_FILE"
            _txn_rollback "$dir"; rc=$?
            check test "$rc" -ne 0
            check test -f "$dir/complete"
            check test ! -f "$dir/committed"
            check test "${RELAY_TX_BLOCKED:-0}" -eq 1
            check cmp -s "$RELAY_CONFIG_FILE" "$WORK/relay.before"
            _state_lock_release
        done
        [ "$fail" -eq 0 ]
    ) || fail=$((fail + 1))
fi
printf 'runtime transactions: %s failure(s)\n' "$fail"
[ "$fail" -eq 0 ]
