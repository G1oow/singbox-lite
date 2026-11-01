#!/usr/bin/env bash
# 真实菜单与导出边界回归；外部写入仅落在临时目录。
set -uo pipefail
exec < /dev/null
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail=0
load_fn() { source <(sed -n "/^${1}() {$/,/^}$/p" "$ROOT/singbox.sh"); }
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
exit "$fail"
