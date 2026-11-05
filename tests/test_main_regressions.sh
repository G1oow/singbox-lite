#!/usr/bin/env bash
# 真实菜单与导出边界回归；外部写入仅落在临时目录。
set -uo pipefail
exec < /dev/null
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail=0
load_fn() { source <(sed -n "/^${1}() [({]$/,/^[)}]$/p" "$ROOT/singbox.sh"); }
check() {
    if [ "$2" = "$3" ]; then printf 'ok    %s\n' "$1"; else printf 'FAIL  %s (期望 %s，实际 %s)\n' "$1" "$2" "$3"; fail=$((fail + 1)); fi
}
_info() { :; }; _warn() { :; }; _warning() { :; }; _error() { :; }; _success() { :; }
RED='' GREEN='' YELLOW='' CYAN='' NC=''
(
    source <(sed -n '/^# --- 一键换 SNI 与聚合订阅 ---$/,/^# --- 一键换 SNI 与聚合订阅结束 ---$/p' "$ROOT/singbox.sh")
    _list_main_primary_inbounds() { printf '{"tag":"test"}\n'; }
    _batch_sni_plan() { printf 'test\tvless-reality\t443\treality\tnone\tTest\told.example.com\n'; }
    _batch_change_sni_apply() { printf '%s\n' "$1" > "$WORK/applied"; }
    _output_base64_subscription() { :; }
    CADDY_STATE_FILE="$WORK/not-deployed"
    _batch_change_sni <<< $'new.example.com\n\ny'
) > "$WORK/menu.log" 2>&1
check "批量 SNI 菜单确认后实际执行应用" new.example.com "$(cat "$WORK/applied" 2>/dev/null || true)"
(
    load_fn _find_proxy_name; load_fn _detect_main_node_variant; load_fn _normalize_client_server; load_fn _refresh_modified_node_artifacts
    CONFIG_FILE="$WORK/config.json"; METADATA_FILE="$WORK/metadata.json"; CLASH_YAML_FILE="$WORK/clash.yaml"; YQ_BINARY="$(command -v yq)"
    printf '%s\n' '{"inbounds":[{"tag":"any-in-20001","type":"anytls","listen_port":20001,"users":[{"password":"test"}],"tls":{"server_name":"example.com","reality":{"enabled":true,"handshake":{"server":"127.0.0.1"}}}}]}' > "$CONFIG_FILE"
    printf '%s\n' '{"any-in-20001":{"name":"LinkOnly","yaml":false,"clientServer":"192.0.2.1","publicKey":"test"}}' > "$METADATA_FILE"
    printf 'proxies: []\nproxy-groups: []\n' > "$CLASH_YAML_FILE"
    _atomic_modify_json() { local file="$1" filter="$2"; shift 2; jq "$@" "$filter" "$file" > "$file.new" && mv "$file.new" "$file"; }
    _atomic_modify_yaml() { : > "$WORK/unexpected-yaml"; return 1; }
    _show_node_link() { printf '%s\n' "$7" > "$WORK/client-sni"; }
    [ -z "$(_find_proxy_name 20001 anytls any-in-20001)" ] || exit 2
    _refresh_modified_node_artifacts any-in-20001 ''
) > "$WORK/yaml.log" 2>&1
yaml_rc=$?
[ "$yaml_rc" -eq 0 ] || cat "$WORK/yaml.log"
check "仅链接节点重建成功" 0 "$yaml_rc"
check "yaml:false 不写共享 YAML" no "$([ -f "$WORK/unexpected-yaml" ] && echo yes || echo no)"
check "Any-Reality 客户端 SNI 不使用本机回落地址" example.com "$(cat "$WORK/client-sni" 2>/dev/null || true)"
(
    load_fn _url_encode; load_fn _view_nodes
    DEFAULT_SNI=example.com; METADATA_FILE="$WORK/export.json"; ARGO_METADATA_FILE="$WORK/no-argo"
    printf '{}\n' > "$METADATA_FILE"
    node='{"tag":"vless-ws-in-443","type":"vless","listen_port":443,"users":[{"uuid":"11111111-1111-1111-1111-111111111111"}],"tls":{"enabled":true,"server_name":"example.com"},"transport":{"type":"ws","path":"/ws"}}'
    _list_main_primary_inbounds() { printf '%s\n' "$node"; }
    _find_proxy_name() { printf test; }; _get_proxy_field() { printf 192.0.2.10; }
    _tls_insecure_params() { :; }
    _output_base64_subscription() { cp "$1" "$WORK/exported-links"; }
    _view_nodes
    node='{"tag":"trojan-in-443","type":"trojan","listen_port":443,"users":[{"password":"demo#?%@"}],"transport":{"type":"ws","path":"/ws"}}'
    _output_base64_subscription() { cp "$1" "$WORK/exported-trojan"; }
    _view_nodes
    for type in trojan tuic anytls; do
        node=$(jq -cn --arg type "$type" --arg password 'demo\pass' '{tag:($type+"-in-443"),type:$type,listen_port:443,users:[{uuid:"11111111-1111-1111-1111-111111111111",password:$password}],tls:{server_name:"example.com"},transport:{type:"ws",path:"/ws"}}')
        _node_skip_verify() { printf false; }
        _output_base64_subscription() { cat "$1" >> "$WORK/backslash-links"; }
        _view_nodes
    done
) > "$WORK/view.log" 2>&1
check "缺少持久化链接仍保留 WS TLS" yes "$(grep -q 'security=tls.*type=ws' "$WORK/exported-links" && echo yes || echo no)"
check "缺少持久化链接仍保留空 flow 后的路径" yes "$(grep -q 'path=%2Fws' "$WORK/exported-links" && echo yes || echo no)"
check "查看链接的回退路径也编码密码" yes "$(grep -q 'trojan://demo%23%3F%25%40@' "$WORK/exported-trojan" && echo yes || echo no)"
check "三类回退导出保留密码中的单个反斜杠" 3 "$(grep -c 'demo%5Cpass@' "$WORK/backslash-links" || true)"
(
    load_fn _url_encode; load_fn _show_node_link
    DEFAULT_SNI=example.com; SINGBOX_DIR="$WORK"; _tls_insecure_params() { :; }; _cert_sha256_hex() { :; }
    _show_node_link trojan-ws-tls test 192.0.2.10 443 '' 'demo#?%@密码' example.com /ws false ''
    _show_node_link hysteria2 test 192.0.2.10 443 '' 'demo#?%@密码' example.com '' '' false
    _show_node_link tuic test 192.0.2.10 443 '' 11111111-1111-1111-1111-111111111111 'demo#?%@密码' example.com false
    _show_node_link anytls test 192.0.2.10 443 '' 'demo#?%@密码' example.com false
    _show_node_link any-reality test 192.0.2.10 443 '' 'demo#?%@密码' example.com public sid
) > "$WORK/password-links" 2>&1
check "五类协议的密码分别编码 URI 保留字符与中文" 5 "$(grep -c 'demo%23%3F%25%40%E5%AF%86%E7%A0%81@192.0.2.10' "$WORK/password-links" || true)"
plain='vless://11111111-1111-1111-1111-111111111111@192.0.2.10:443?security=tls&type=ws&sni=example.com&path=%2Fws'
printf '%s\n' "$plain" | bash "$ROOT/parser.sh" vless-ws-tls > "$WORK/parsed.json"
check "基础 WS TLS 仍可解析" 0 "$?"
for parameter in 'alpn=http%2F1.1' 'ed=2048'; do
    printf '%s\n' "$plain&$parameter" | bash "$ROOT/parser.sh" vless-ws-tls > "$WORK/rejected.json"
    parser_rc=$?
    check "不静默忽略未支持参数 ${parameter%%=*}" yes "$([ "$parser_rc" -ne 0 ] && jq -e 'has("error")' "$WORK/rejected.json" >/dev/null && echo yes || echo no)"
done

# 不加载主菜单；故障只注入文件写入、配置校验、服务和隧道边界。
load_main_tx() {
    local fn
    for fn in _main_tx_begin _main_tx_commit _main_tx_cleanup _main_create_tx_snapshot_file _main_create_tx_restore_file \
        _main_create_tx_snapshot _main_create_tx_restore_credentials _main_create_tx_remove_new_nft_comments \
        _main_create_tx_restore _restore_full_transaction_snapshot _recover_pending_main_transactions_locked \
        _restore_argo_deleted_runtime _delete_argo_node_locked _atomic_modify_json_locked; do
        load_fn "$fn"
    done
    source <(sed -n '/^_main_create_tx_snapshot_file() {$/,/^}$/p' "$ROOT/singbox.sh" |
        sed 's/^_main_create_tx_snapshot_file() /_fixture_snapshot_file() /')
    source <(sed -n '/^_main_create_tx_restore_file() {$/,/^}$/p' "$ROOT/singbox.sh" |
        sed 's/^_main_create_tx_restore_file() /_fixture_restore_file() /')
    _main_create_tx_snapshot_file() {
        local target="$3"
        [ "$target" != /etc/nftables.conf ] || target="$SINGBOX_DIR/nftables.conf"
        _fixture_snapshot_file "$1" "$2" "$target"
    }
    _main_create_tx_restore_file() {
        local target="$3"
        [ "$target" != /etc/nftables.conf ] || target="$SINGBOX_DIR/nftables.conf"
        _fixture_restore_file "$1" "$2" "$target"
    }
    nft() { return 1; }
    _secure_state_permissions() { :; }
    _singbox_service_running() { return 0; }
    _with_state_lock() { "$@"; }
}
seed_main_tx() {
    SINGBOX_DIR="$WORK/$1"; mkdir -p "$SINGBOX_DIR"
    CONFIG_FILE="$SINGBOX_DIR/config.json"; RELAY_CONFIG_FILE="$SINGBOX_DIR/relay.json"
    METADATA_FILE="$SINGBOX_DIR/metadata.json"; ARGO_METADATA_FILE="$SINGBOX_DIR/argo.json"
    CLASH_YAML_FILE="$SINGBOX_DIR/clash.yaml"; NFT_PERSIST_FILE="$SINGBOX_DIR/nft.nft"; NFT_TABLE=singboxlite
    SINGBOX_BIN="$SINGBOX_DIR/sing-box"; CLOUDFLARED_BIN="$SINGBOX_DIR/cloudflared"
    printf '%s\n' '{"inbounds":[{"tag":"argo-test","listen_port":8443}]}' > "$CONFIG_FILE"
    printf '%s\n' '{"argo-test":{"name":"Test","local_port":8443,"type":"fixed","token":"placeholder","protocol":"vless-ws"}}' > "$ARGO_METADATA_FILE"
    printf '{}\n' > "$METADATA_FILE"; printf '{"inbounds":[]}\n' > "$RELAY_CONFIG_FILE"
    printf 'old yaml\n' > "$CLASH_YAML_FILE"; printf running > "$SINGBOX_DIR/tunnel"
    cp "$CONFIG_FILE" "$SINGBOX_DIR/config.before"; cp "$ARGO_METADATA_FILE" "$SINGBOX_DIR/argo.before"
    cp "$CONFIG_FILE" "$SINGBOX_DIR/running"; printf 0 > "$SINGBOX_DIR/restarts"
    unset CADDY_CONF_FILE CADDY_STATE_FILE MAIN_TRANSACTION_DIR
}
for fault in config metadata yaml check restart stop success; do
    (
        load_main_tx; seed_main_tx "argo-$fault"
        _atomic_modify_json() {
            local file="$1" filter="$2"; shift 2
            [ "$fault" != config ] || [ "$file" != "$CONFIG_FILE" ] || return 1
            [ "$fault" != metadata ] || [ "$file" != "$ARGO_METADATA_FILE" ] || return 1
            _atomic_modify_json_locked "$file" "$filter" "$@"
        }
        _remove_node_from_yaml() { [ "$fault" != yaml ] || return 1; printf removed > "$CLASH_YAML_FILE"; }
        _check_combined_config_files() { [ "$fault" != check ]; }
        _manage_service() {
            local calls
            calls=$(cat "$SINGBOX_DIR/restarts"); calls=$((calls+1))
            printf '%s' "$calls" > "$SINGBOX_DIR/restarts"
            [ "$fault" != restart ] || [ "$calls" -ne 1 ] || return 1
            cp "$CONFIG_FILE" "$SINGBOX_DIR/running"
        }
        _stop_argo_tunnel() { [ "$fault" != stop ] || return 1; printf stopped > "$SINGBOX_DIR/tunnel"; }
        _argo_pid_file() { printf '%s/pid' "$SINGBOX_DIR"; }
        _is_pid_file_running_cmd() { [ "$(cat "$SINGBOX_DIR/tunnel")" = running ]; }
        _start_argo_tunnel() { printf running > "$SINGBOX_DIR/tunnel"; }
        _disable_argo_watchdog() { return 0; }
        _delete_argo_node_locked argo-test 8443 Test
    ) > "$WORK/argo-$fault.log" 2>&1
    rc=$?
    case_dir="$WORK/argo-$fault"
    if [ "$fault" = success ]; then
        check "Argo 删除成功返回零" 0 "$rc"
        check "Argo 删除成功移除入站" 0 "$(jq '.inbounds | length' "$case_dir/config.json")"
        check "Argo 删除成功停止隧道" stopped "$(cat "$case_dir/tunnel")"
    else
        check "Argo $fault 失败返回非零" yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
        check "Argo $fault 失败恢复配置" yes "$(cmp -s "$case_dir/config.json" "$case_dir/config.before" && echo yes || echo no)"
        check "Argo $fault 失败恢复元数据" yes "$(cmp -s "$case_dir/argo.json" "$case_dir/argo.before" && echo yes || echo no)"
        check "Argo $fault 失败恢复 YAML" 'old yaml' "$(cat "$case_dir/clash.yaml")"
        check "Argo $fault 失败保留运行隧道" running "$(cat "$case_dir/tunnel")"
    fi
done
(
    load_main_tx; seed_main_tx recovery
    _manage_service() { :; }
    tx=$(_main_tx_begin main) && _main_create_tx_snapshot "$tx" || exit 1
    printf changed > "$CONFIG_FILE"
    _main_tx_begin main >/dev/null 2>&1 && exit 2
    _recover_pending_main_transactions_locked || exit 3
    cmp -s "$CONFIG_FILE" "$SINGBOX_DIR/config.before" || exit 4
    [ ! -d "$tx" ] || exit 5
    printf key > "$SINGBOX_DIR/node.key"
    tx=$(_main_tx_begin main) && _main_create_tx_snapshot "$tx" || exit 6
    rm -f "$tx/credentials/node.key"
    _main_create_tx_restore "$tx" 0 && exit 7
    [ "$(cat "$SINGBOX_DIR/node.key")" = key ] || exit 8
) > "$WORK/main-recovery.log" 2>&1
check "持久化恢复可重入，损坏的凭据快照不会覆盖现有文件" 0 "$?"
(
    load_main_tx; seed_main_tx cleanup-order
    tx=$(_main_tx_begin main) && _main_create_tx_snapshot "$tx" && _main_tx_commit "$tx" || exit 1
    rm() { [[ "${!#}" != */complete ]] || return 1; command rm "$@"; }
    _main_tx_cleanup "$tx" && exit 2
    [ -f "$tx/committed" ] && [ -f "$tx/complete" ] && [ -f "$tx/config.json" ] || exit 3
    unset -f rm
    _main_tx_cleanup "$tx" || exit 4
    [ ! -d "$tx" ] || exit 5
) > "$WORK/main-cleanup.log" 2>&1
check "清理先撤销可恢复标记，失败不删除已提交快照" 0 "$?"
for signal in TERM KILL; do
    (
        load_main_tx; seed_main_tx "signal-$signal"
        load_fn _run_main_create_transaction_locked
        _manage_service() { :; }
        interrupt_mutation() { printf changed > "$CONFIG_FILE"; kill "-$signal" "$BASHPID"; }
        _run_main_create_transaction_locked interrupt_mutation
        rc=$?
        [ "$rc" -ne 0 ] || exit 1
        if [ "$signal" = KILL ]; then
            # 不经过 EXIT trap 的硬中断由下一次启动恢复。
            _recover_pending_main_transactions_locked || exit 2
        fi
        cmp -s "$CONFIG_FILE" "$SINGBOX_DIR/config.before" || exit 3
    ) > "$WORK/signal-$signal.log" 2>&1
    check "主事务 $signal 中断后恢复原配置" 0 "$?"
done

for restore_fault in no yes; do
    (
        load_main_tx; seed_main_tx "update-$restore_fault"
        load_fn _script_update_restore; load_fn _update_script_locked
        SCRIPT_DIR="$SINGBOX_DIR"; SELF_SCRIPT_PATH="$SCRIPT_DIR/singbox.sh"; SCRIPT_VERSION=1
        SCRIPT_UPDATE_URL=https://example.com/singbox.sh; GITHUB_RAW_BASE=https://example.com
        for name in singbox.sh advanced_relay.sh parser.sh xray_manager.sh; do
            printf '#!/bin/bash\nexport SCRIPT_VERSION="1"\n' > "$SCRIPT_DIR/$name"
        done
        _download_bash_script_atomic() { printf '#!/bin/bash\nexport SCRIPT_VERSION="2"\n' > "$2"; }
        _install_yq() { :; }
        mv() {
            local a previous='' source_file='' target_file=''
            for a in "$@"; do
                [[ "$a" == -* ]] && continue
                source_file="$previous"; previous="$a"; target_file="$a"
            done
            [[ "$source_file" != *'.advanced_relay.sh.stage.'* ]] || return 1
            if [ "$restore_fault" = yes ] && [[ "$source_file" == *'.script.restore.'* && "$target_file" == */singbox.sh ]]; then return 1; fi
            command mv "$@"
        }
        _update_script_locked
        rc=$?
        [ "$rc" -ne 0 ] || exit 1
        if [ "$restore_fault" = yes ]; then
            snapshot=$(find "$SINGBOX_DIR/.transactions" -mindepth 1 -maxdepth 1 -type d | head -1)
            [ -s "$snapshot/0" ] && grep -q 'SCRIPT_VERSION="1"' "$snapshot/0" || exit 2
            restore_fault=no
            _recover_pending_main_transactions_locked || exit 3
        fi
        for name in singbox.sh advanced_relay.sh parser.sh xray_manager.sh; do
            grep -q 'SCRIPT_VERSION="1"' "$SCRIPT_DIR/$name" || exit 4
        done
    ) > "$WORK/update-$restore_fault.log" 2>&1
    check "脚本更新恢复失败=$restore_fault 时保留旧组件且可再次恢复" 0 "$?"
done
(
    load_fn _state_write_allowed; load_fn _with_state_lock
    load_fn _uninstall_argo; load_fn _restart_argo_tunnel_menu
    SINGBOX_DIR="$WORK/foreign-state"; mkdir -p "$SINGBOX_DIR/.transactions"
    export SINGBOXLITE_LOCK_HELD=1
    unset MAIN_TRANSACTION_DIR MAIN_RECOVERY_ACTIVE
    _uninstall_argo_locked() { : > "$SINGBOX_DIR/unexpected"; }
    _restart_argo_tunnel_menu_locked() { : > "$SINGBOX_DIR/unexpected"; }
    for family in main caddy script-update relay xray; do
        mkdir -p "$SINGBOX_DIR/.transactions/$family-fixture"
        : > "$SINGBOX_DIR/.transactions/$family-fixture/complete"
        _uninstall_argo && exit 1
        _restart_argo_tunnel_menu && exit 2
        [ ! -f "$SINGBOX_DIR/unexpected" ] || exit 3
    done
    _recover_all_transactions_locked() { : > "$SINGBOX_DIR/recovery"; }
    _with_state_lock _recover_all_transactions_locked || exit 4
    [ -f "$SINGBOX_DIR/recovery" ] || exit 5
) > "$WORK/foreign-state.log" 2>&1
check "待恢复事务阻止 Argo 卸载和手动重启，但保留恢复入口" 0 "$?"
exit "$fail"
