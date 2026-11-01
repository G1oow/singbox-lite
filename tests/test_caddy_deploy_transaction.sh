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
for stage in validate restart verify state acme stopped success; do
    dir="$WORK/$stage"; mkdir -p "$dir"
    (
        source <(sed -n '/^# --- 伪装域名（Caddy） ---$/,/^# --- 伪装域名（Caddy）结束 ---$/p' "$ROOT/singbox.sh")
        for fn in _main_create_tx_snapshot_file _main_create_tx_restore_file; do
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
        fake_caddy() { [ "$stage" != validate ]; }
        _caddy_installed() { return 0; }; _camouflage_domain_valid() { return 0; }
        _caddy_check_fallback_port() { return 0; }; _camouflage_verify_domain_loop() { return 0; }
        _check_port_conflict() { return 1; }; _camouflage_default_scope() { printf loopback; }
        _caddy_write_index_page() { return 0; }; _caddy_log_tail() { :; }
        _caddy_wait_cert() { [ "$stage" != acme ]; }; _caddy_cert_file() { printf '%s/test.crt' "$dir"; }
        printf 'test certificate\n' > "$dir/test.crt"
        _caddy_verify_site() { [ "$stage" != verify ] && [ "$stage" != stopped ]; }
        _camouflage_state_write() { printf '{"domain":"new.example.com"}\n' > "$CADDY_STATE_FILE"; [ "$stage" != state ]; }
        _caddy_service() {
            printf '%s\n' "$1" >> "$dir/actions"
            case "$1" in
                stop|remove) printf stopped > "$dir/service" ;;
                restart|start)
                    if [ "$stage" = restart ] && ! grep -q '^old config$' "$CADDY_CONF_FILE"; then printf stopped > "$dir/service"; return 1; fi
                    printf running > "$dir/service" ;;
            esac
        }
        _caddy_camouflage_deploy <<< $'new.example.com\nn'
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
exit "$fail"
