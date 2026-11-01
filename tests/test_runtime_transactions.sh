#!/usr/bin/env bash
# 动态抽取真实事务函数，仅替换文件故障、nft 与服务等外部边界。
set -uo pipefail
exec < /dev/null
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
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
load xray_manager.sh _xray_snapshot_state _xray_restore_file _xray_restore_state _xray_drop_snapshot _run_xray_transaction _xray_rollback_state
XRAY_DIR="$WORK/xray"; mkdir -p "$XRAY_DIR"
XRAY_CONFIG="$XRAY_DIR/config.json"; XRAY_METADATA="$XRAY_DIR/metadata.json"; CLASH_YAML_FILE="$WORK/clash.yaml"
seed_xray() {
    printf config > "$XRAY_CONFIG"; printf metadata > "$XRAY_METADATA"
    printf clash > "$CLASH_YAML_FILE"; printf certificate > "$XRAY_DIR/node.pem"
}
cp() { [[ "$*" == *"${CP_FAIL_MATCH:-NEVER_MATCH}"* ]] && return 1; command cp "$@"; }
mkdir() { [[ "$*" == *"${MKDIR_FAIL_MATCH:-NEVER_MATCH}"* ]] && return 1; command mkdir "$@"; }
_manage_xray_service() { return "${SERVICE_FAIL:-0}"; }
_validate_xray_config() { return 0; }
mutate_xray() { printf changed > "$XRAY_CONFIG"; return 1; }
if [[ "${1:-all}" == all || "${1:-}" == xray ]]; then
    echo '== Xray 快照 / 恢复 =='
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
fi

if [[ "${1:-all}" == all || "${1:-}" == relay ]]; then
    echo '== nft 删除与引擎切换事务 =='
    load advanced_relay.sh _nft_delete_rules_by_comment _pf_delete_nft_rule_set _pf_nft_addr_key _pf_nft_dnat_target _pf_apply_nft_rules \
        _pf_apply_singbox_rules _pf_build_inbound_json _pf_build_rule_json _pf_delete _pf_switch_engine \
        _txn_snapshot_file _txn_restore_file _restart_checked _pf_txn_snapshot _pf_txn_restore _pf_txn_cleanup _pf_switch_engine_locked _pf_switch_engine_apply _save_nftables_rules
    GREEN= CYAN= YELLOW= NC= PF_ENGINE=nftables
    PF_METADATA_FILE="$WORK/pf.json"; RELAY_CONFIG_FILE="$WORK/relay.json"
    NFT_TABLE=singboxlite; NFT_PERSIST_FILE="$WORK/persist.nft"; NFT_CONFIG_FILE="$WORK/nftables.conf"
    table="$WORK/table"; running="$WORK/running"; locked=0
    _state_lock_acquire() { locked=1; }
    _state_lock_release() { locked=0; }
    _txn_begin() { local dir; dir=$(mktemp -d "$WORK/txn.XXXXXX") || return 1; printf '%s\n' "$dir" > "$WORK/latest-txn"; printf '%s\n' "$dir"; }
    _txn_cleanup() { :; } # 被测 PF 清理会在实际成功路径调用；临时目录由 EXIT 回收。
    _secure_state_file() { :; }
    _pf_ensure_metadata() { :; }
    _pf_count() { jq length "$PF_METADATA_FILE"; }
    _pf_auto_manage_dns_cron() { :; }
    _pf_guess_target_family() { printf ipv4; }
    _pf_detect_engine() { PF_ENGINE=nftables; }
    _pf_find_hy2_hop_conflict() { :; }
    _pf_prepare_nft_target() { printf 'ipv4\t192.0.2.1\tfalse\n'; }
    _pf_enable_forwarding() { :; }
    _check_combined_config() { return "${CHECK_FAIL:-0}"; }
    _manage_service() { command cp "$RELAY_CONFIG_FILE" "$running"; return "${RESTART_FAIL:-0}"; }
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
                cat "$table" | awk '{ if (match($0, /singboxlite-pf-[^ "]+/)) printf "chain prerouting {\n comment \"%s\" # handle %d\n}\n", substr($0, RSTART, RLENGTH), NR }' ;;
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
    retained="$(cat "$WORK/latest-txn")/complete"
    check test -f "$retained"
    check test "$locked" -eq 0
    unset META_FAIL NFT_RESTORE_FAIL
    check test ! -f "$WORK/unlocked"
fi
printf 'runtime transactions: %s failure(s)\n' "$fail"
[ "$fail" -eq 0 ]
