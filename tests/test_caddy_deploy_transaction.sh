#!/usr/bin/env bash
# 部署失败不打掉已有站点；只替换服务与 Caddy 二进制边界。
set -uo pipefail
exec < /dev/null
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail=0
check() {
    if [ "$2" = "$3" ]; then printf 'ok    %s\n' "$1"; else printf 'FAIL  %s (期望 %s，实际 %s)\n' "$1" "$2" "$3"; fail=$((fail + 1)); fi
}
for stage in validate restart verify state acme stopped success scope-validate scope-restart scope-state; do
    dir="$WORK/$stage"; mkdir -p "$dir"
    (
        source <(sed -n '/^# --- 伪装域名（Caddy） ---$/,/^# --- 伪装域名（Caddy）结束 ---$/p' "$ROOT/singbox.sh")
        for fn in _main_tx_begin _main_tx_commit _main_tx_cleanup _main_create_tx_snapshot_file _main_create_tx_restore_file; do
            source <(sed -n "/^${fn}() {$/,/^}$/p" "$ROOT/singbox.sh")
        done
        _info() { :; }; _warn() { :; }; _error() { :; }; _success() { :; }
        SINGBOX_DIR="$dir"; CADDY_WEB_ROOT="$dir/www"; CADDY_DATA_DIR="$dir/data"
        CADDY_CONF_FILE="$dir/Caddyfile"; CADDY_STATE_FILE="$dir/state.json"; CADDY_LOG_FILE="$dir/log"; CADDY_FALLBACK_PORT=8443
        CADDY_BIN=fake_caddy; RED='' GREEN='' YELLOW='' CYAN='' NC=''
        printf 'old config\n' > "$CADDY_CONF_FILE"; printf '{"domain":"old.example.com"}\n' > "$CADDY_STATE_FILE"
        printf running > "$dir/service"
        [ "$stage" != stopped ] || printf stopped > "$dir/service"
        _with_state_lock() { "$@"; }
        _caddy_service_running() { [ "$(cat "$dir/service")" = running ]; }
        fake_caddy() { [[ "$stage" != *validate ]]; }
        _caddy_installed() { return 0; }; _camouflage_domain_valid() { return 0; }
        _caddy_check_fallback_port() { return 0; }; _camouflage_verify_domain_loop() { return 0; }
        _check_port_conflict() { return 1; }; _camouflage_default_scope() { printf loopback; }
        _caddy_write_index_page() { return 0; }; _caddy_log_tail() { :; }
        _caddy_wait_cert() { [ "$stage" != acme ]; }; _caddy_cert_file() { printf '%s/test.crt' "$dir"; }
        printf 'test certificate\n' > "$dir/test.crt"
        _caddy_verify_site() { [ "$stage" != verify ] && [ "$stage" != stopped ]; }
        _camouflage_state_write() { printf '{"domain":"new.example.com"}\n' > "$CADDY_STATE_FILE"; [[ "$stage" != *state ]]; }
        _caddy_service() {
            printf '%s\n' "$1" >> "$dir/actions"
            case "$1" in
                stop|remove) printf stopped > "$dir/service" ;;
                restart|start)
                    if [[ "$stage" == *restart ]] && ! grep -q '^old config$' "$CADDY_CONF_FILE"; then printf stopped > "$dir/service"; return 1; fi
                    printf running > "$dir/service" ;;
            esac
        }
        if [[ "$stage" == scope-* ]]; then
            _caddy_set_scope loopback
        else
            _caddy_camouflage_deploy <<< $'new.example.com\nn'
        fi
    ) > "$dir/output" 2>&1
    rc=$?
    if [ "$stage" = success ]; then
        check "Caddy 成功部署提交" 0 "$rc"
        check "Caddy 成功部署写入新配置" yes "$(grep -q new.example.com "$dir/Caddyfile" && echo yes || echo no)"
        check "Caddy 成功部署写入新状态" new.example.com "$(jq -r '.domain' "$dir/state.json")"
        check "Caddy 成功部署服务运行" running "$(cat "$dir/service")"
        check "首次写入的首页可用于自检" yes "$([ -s "$dir/www/index.html" ] && echo yes || echo no)"
    else
        check "Caddy ${stage} 失败返回非零" yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
        check "Caddy ${stage} 失败恢复旧配置" 'old config' "$(cat "$dir/Caddyfile" 2>/dev/null || true)"
        check "Caddy ${stage} 失败恢复旧状态" old.example.com "$(jq -r '.domain' "$dir/state.json" 2>/dev/null || true)"
        expected=running; [ "$stage" != stopped ] || expected=stopped
        check "Caddy ${stage} 失败恢复原服务状态" "$expected" "$(cat "$dir/service")"
    fi
done
for stage in tls-reference revert-failure stop-failure teardown-success restore-order; do
    dir="$WORK/$stage"; mkdir -p "$dir"
    (
        source <(sed -n '/^# --- 伪装域名（Caddy） ---$/,/^# --- 伪装域名（Caddy）结束 ---$/p' "$ROOT/singbox.sh")
        for fn in _main_tx_begin _main_tx_commit _main_tx_cleanup _main_create_tx_snapshot_file _main_create_tx_restore_file \
            _main_create_tx_snapshot _main_create_tx_restore_credentials _main_create_tx_remove_new_nft_comments \
            _main_create_tx_restore _restore_full_transaction_snapshot; do
            source <(sed -n "/^${fn}() {$/,/^}$/p" "$ROOT/singbox.sh")
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
        _info() { :; }; _warn() { :; }; _error() { :; }; _success() { :; }
        SINGBOX_DIR="$dir"; CONFIG_FILE="$dir/config.json"; METADATA_FILE="$dir/meta.json"
        ARGO_METADATA_FILE="$dir/argo.json"; CLASH_YAML_FILE="$dir/clash.yaml"; RELAY_CONFIG_FILE="$dir/relay.json"
        CADDY_CONF_FILE="$dir/Caddyfile"; CADDY_STATE_FILE="$dir/state.json"
        CADDY_WEB_ROOT="$dir/www"; CADDY_DATA_DIR="$dir/data"; CADDY_BIN="$dir/caddy"
        NFT_PERSIST_FILE="$dir/nft.nft"; NFT_TABLE=singboxlite; INIT_SYSTEM=direct; DEFAULT_SNI=example.org
        mkdir -p "$CADDY_WEB_ROOT" "$CADDY_DATA_DIR"
        printf certificate > "$CADDY_DATA_DIR/example.com.crt"; printf index > "$CADDY_WEB_ROOT/index.html"
        printf 'old config\n' > "$CADDY_CONF_FILE"; printf '{"domain":"example.com"}\n' > "$CADDY_STATE_FILE"
        printf '{}\n' > "$METADATA_FILE"; printf '{}\n' > "$ARGO_METADATA_FILE"; printf 'old yaml\n' > "$CLASH_YAML_FILE"
        printf '{"inbounds":[]}\n' > "$RELAY_CONFIG_FILE"; printf running > "$dir/service"
        if [ "$stage" = tls-reference ]; then
            jq -n --arg cert "$CADDY_DATA_DIR/example.com.crt" '{inbounds:[{tag:"tls-test",tls:{certificate_path:$cert}}]}' > "$CONFIG_FILE"
        elif [ "$stage" = revert-failure ]; then
            printf '%s\n' '{"inbounds":[{"tag":"reality-test","tls":{"reality":{"enabled":true,"handshake":{"server":"127.0.0.1"}}}}]}' > "$CONFIG_FILE"
        else
            printf '{"inbounds":[]}\n' > "$CONFIG_FILE"
        fi
        _caddy_service_running() { [ "$(cat "$dir/service")" = running ]; }
        _caddy_service() {
            printf '%s\n' "$1" >> "$dir/actions"
            [ "$stage" != stop-failure ] || [ "$1" != remove ] || return 1
            case "$1" in
                restart)
                    if [ "$stage" = restore-order ]; then
                        [ "$(jq -r '.inbounds[0].listen_port' "$CONFIG_FILE")" = 8443 ] || return 1
                        printf caddy >> "$dir/order"
                    fi
                    printf running > "$dir/service" ;;
                stop|remove) printf stopped > "$dir/service" ;;
            esac
        }
        _camouflage_apply_reality() { return 1; }
        _manage_service() { printf core >> "$dir/order"; }
        _secure_state_permissions() { :; }; nft() { return 1; }
        _singbox_service_running() { return 0; }
        if [ "$stage" = restore-order ]; then
            printf '{"inbounds":[{"listen_port":8443}]}\n' > "$CONFIG_FILE"
            tx=$(_main_tx_begin main) && _main_create_tx_snapshot "$tx" || exit 1
            printf '{"inbounds":[{"listen_port":443}]}\n' > "$CONFIG_FILE"
            printf loopback > "$CADDY_CONF_FILE"
            : > "$tx/caddy.restart-required"
            _main_create_tx_restore "$tx" 1 || exit 2
            [ "$(cat "$dir/order")" = corecaddy ] || exit 3
        else
            _caddy_camouflage_teardown_locked y n
        fi
    ) > "$dir/output" 2>&1
    rc=$?
    if [ "$stage" = teardown-success ]; then
        check "无证书依赖时可正常卸载" 0 "$rc"
        check "卸载成功才清理证书目录" no "$([ -e "$dir/data" ] && echo yes || echo no)"
    elif [ "$stage" = restore-order ]; then
        check "先恢复旧节点并重启核心，再交还 Caddy 监听" 0 "$rc"
    else
        check "卸载 $stage 返回非零" yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
        check "卸载 $stage 保留证书" yes "$([ -f "$dir/data/example.com.crt" ] && echo yes || echo no)"
        check "卸载 $stage 保留配置" 'old config' "$(cat "$dir/Caddyfile")"
        check "卸载 $stage 恢复运行状态" running "$(cat "$dir/service")"
    fi
done
(
    source <(sed -n '/^_caddy_service() {$/,/^# 站点就绪/{/^# 站点就绪/d;p;}' "$ROOT/singbox.sh" |
        sed 's/^_caddy_service() /_fixture_caddy_service() /')
    INIT_SYSTEM=direct; CADDY_SERVICE_NAME=review-service
    CADDY_PID_FILE="$WORK/nonexistent.pid"
    _caddy_service() {
        case "$1" in
            stop) return 1 ;;
            start) : > "$WORK/unexpected-start"; return 0 ;;
            *) _fixture_caddy_service "$@" ;;
        esac
    }
    _caddy_service restart
    [ "$?" -ne 0 ] && [ ! -f "$WORK/unexpected-start" ]
)
check "Caddy 停止失败不得继续启动或误报重启成功" 0 "$?"
(
    source <(sed -n '/^_caddy_service_restore() {$/,/^}$/p' "$ROOT/singbox.sh")
    INIT_SYSTEM=systemd; CADDY_SERVICE_NAME=review-service
    snapshot="$WORK/missing-service"; mkdir -p "$snapshot"
    printf 'systemd\n' > "$snapshot/caddy.init"
    : > "$snapshot/new-unit"
    # 只把固定的测试 service 路径映射到 fixture，不操作 /etc。
    function [() {
        if [[ "$#" == 3 && "$1" == -f && "$2" == /etc/systemd/system/review-service.service ]]; then
            builtin test -f "$snapshot/new-unit"
            return $?
        fi
        builtin test "${@:1:$#-1}"
    }
    _main_create_tx_restore_file() {
        printf restore >> "$snapshot/order"
        rm -f "$snapshot/new-unit"
    }
    systemctl() {
        if [[ "$1" == disable ]]; then printf disable >> "$snapshot/order"; fi
        return 0
    }
    _caddy_service_restore "$snapshot" || exit 1
    [[ "$(cat "$snapshot/order")" == disablerestore ]]
)
check "恢复原本不存在的 Caddy service 时先撤销新增自启" 0 "$?"
exit "$fail"
