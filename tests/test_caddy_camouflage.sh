#!/usr/bin/env bash
# 伪装域名（Caddy）与跨协议证书复用回归测试
# 依赖: bash、jq、sed、grep
# 用法: bash tests/test_caddy_camouflage.sh
set -uo pipefail
# 任何交互式读取都直接失败而不是挂起 CI
exec < /dev/null

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for bin in jq sed grep; do
    command -v "$bin" >/dev/null 2>&1 || { echo "缺少依赖: $bin" >&2; exit 1; }
done

export SINGBOX_DIR="$WORK/sing-box"
mkdir -p "$SINGBOX_DIR"
export CONFIG_FILE="$SINGBOX_DIR/config.json"
export METADATA_FILE="$SINGBOX_DIR/metadata.json"
export CLASH_YAML_FILE="$SINGBOX_DIR/clash.yaml"
export ARGO_METADATA_FILE="$SINGBOX_DIR/argo_metadata.json"
export RELAY_CONFIG_FILE="$SINGBOX_DIR/relay.json"
export CADDY_STATE_FILE="$SINGBOX_DIR/caddy_camouflage.json"
export CADDY_CONF_FILE="$SINGBOX_DIR/Caddyfile"
export CADDY_WEB_ROOT="$SINGBOX_DIR/www"
export CADDY_DATA_DIR="$SINGBOX_DIR/caddy"
export CADDY_LOG_FILE="$WORK/caddy.log"
export CADDY_BIN="$WORK/bin/caddy"
export CADDY_FALLBACK_PORT="8443"
export DEFAULT_SNI="www.amd.com"
export GITHUB_RAW_BASE="https://example.invalid/singbox-lite/main"
RED='' GREEN='' YELLOW='' CYAN='' NC='' ORANGE=''

# singbox.sh 会直接执行主菜单，不能 source 整个文件，只能按注释锚点抽取被测块
sed -n '/^# --- 伪装域名（Caddy） ---$/,/^# --- 伪装域名（Caddy）结束 ---$/p' \
    "$ROOT/singbox.sh" > "$WORK/camouflage.sh"
[ -s "$WORK/camouflage.sh" ] || { echo "抽取伪装域名功能块失败" >&2; exit 1; }
sed -n '/^_reality_handshake_is_local() {$/,/^}$/p' "$ROOT/singbox.sh" > "$WORK/handshake-local.sh"
[ -s "$WORK/handshake-local.sh" ] || { echo "抽取 handshake 判定函数失败" >&2; exit 1; }

fail=0
check() { # 描述 期望 实际
    if [ "$2" = "$3" ]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n      期望: %s\n      实际: %s\n' "$1" "$2" "$3"
        fail=$((fail + 1))
    fi
}
check_true() { # 描述 退出码
    if [ "$2" = "0" ]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n      期望成功，实际失败\n' "$1"
        fail=$((fail + 1))
    fi
}
check_false() { # 描述 退出码
    if [ "$2" != "0" ]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n      期望失败，实际成功\n' "$1"
        fail=$((fail + 1))
    fi
}

# --- 被测函数的轻量替身 -------------------------------------------------
_info() { printf '[信息] %s\n' "$1" >&2; }
_success() { printf '[成功] %s\n' "$1" >&2; }
_warn() { printf '[注意] %s\n' "$1" >&2; }
_warning() { _warn "$1"; }
_error() { printf '[错误] %s\n' "$1" >&2; }
_pkg_install() { return 0; }
_conn_ipv4() { printf '%s' "${STUB_LOCAL_IPV4:-}"; }
_conn_ipv6() { printf '%s' "${STUB_LOCAL_IPV6:-}"; }
_atomic_modify_json() {
    local file="$1" filter="$2"; shift 2
    [ -f "$file" ] || return 1
    jq "$@" "$filter" "$file" > "${file}.new" && mv "${file}.new" "$file"
}
# 443 占用情况由用例通过 PORT_CONFLICT_443 控制，测试不依赖真实端口状态
_check_port_conflict() {
    local port="$1" proto="${2:-tcp}"
    [ "$port" = "443" ] && [ "${PORT_CONFLICT_443:-false}" = "true" ] && return 0
    return 1
}
# 路径比较在不同平台（含 MSYS 路径转换）下不可靠，这里只比对文件名与目录标记。
check_cert_pair() { # 描述 实际 "<cert>\t<key>"
    local desc="$1" actual="$2" cert key
    IFS=$'\t' read -r cert key <<< "$actual"
    if [ "$(basename "${cert:-none}")" = "vpn.example.com.crt" ] \
        && [ "$(basename "${key:-none}")" = "vpn.example.com.key" ]; then
        printf 'ok    %s\n' "$desc"
    else
        printf 'FAIL  %s\n      证书对不符合预期: %s\n' "$desc" "$actual"
        fail=$((fail + 1))
    fi
}
_find_proxy_name() { printf '%s' "${3:-}"; }
_list_main_primary_inbounds() {
    local node tag
    while IFS= read -r node; do
        [ -n "$node" ] || continue
        tag=$(printf '%s' "$node" | jq -r '.tag // empty')
        case "$tag" in *-hop-*) continue ;; esac
        printf '%s\n' "$node"
    done < <(jq -c '.inbounds[]?' "$CONFIG_FILE" 2>/dev/null)
}
_detect_main_node_variant() {
    jq -r --arg tag "$1" '
        .inbounds[]? | select(.tag == $tag) |
        if (.tls.reality.enabled // false) and .type == "vless" then "vless-reality"
        elif (.tls.reality.enabled // false) and .type == "anytls" then "any-reality"
        else "unsupported" end
    ' "$CONFIG_FILE" 2>/dev/null | head -n 1
}
# 用可控替身替代 DoH，测试不依赖外网
_camouflage_doh_ips() {
    case "${1}:${2}" in
        vpn.example.com:A) printf '198.51.100.7\n' ;;
        vpn.example.com:AAAA) printf '2001:db8::7\n' ;;
        dual.example.com:A) printf '198.51.100.9\n' ;;
        dual.example.com:AAAA) printf '2001:db8::99\n' ;;
        proxied.example.com:A) printf '192.0.2.10\n' ;;
        *) : ;;
    esac
}

# shellcheck disable=SC1090
. "$WORK/camouflage.sh"
# shellcheck disable=SC1090
. "$WORK/handshake-local.sh"

# 源文件里定义了真实的 DoH 查询，必须在 source 之后覆盖为替身才生效
_camouflage_doh_ips() {
    case "${1}:${2}" in
        vpn.example.com:A) printf '198.51.100.7\n' ;;
        vpn.example.com:AAAA) printf '2001:db8::7\n' ;;
        dual.example.com:A) printf '198.51.100.9\n' ;;
        dual.example.com:AAAA) printf '2001:db8::99\n' ;;
        proxied.example.com:A) printf '192.0.2.10\n' ;;
        *) : ;;
    esac
}
_camouflage_dns_ips() {
    _camouflage_doh_ips "$1" A
    _camouflage_doh_ips "$1" AAAA
}

# --- 域名格式校验 -------------------------------------------------------
_camouflage_domain_valid "vpn.example.com";           check_true  "普通域名通过格式校验" "$?"
_camouflage_domain_valid "a.b-c.example.co";          check_true  "多级与连字符域名通过" "$?"
_camouflage_domain_valid "198.51.100.7";              check_false "IPv4 字面量被拒绝" "$?"
_camouflage_domain_valid "2001:db8::1";               check_false "IPv6 字面量被拒绝" "$?"
_camouflage_domain_valid "https://vpn.example.com/a"; check_false "带协议前缀的输入被拒绝" "$?"
_camouflage_domain_valid "-bad.example.com";          check_false "以连字符开头的标签被拒绝" "$?"
_camouflage_domain_valid "localhost";                 check_false "无点的单标签被拒绝" "$?"
_camouflage_domain_valid "";                          check_false "空输入被拒绝" "$?"

# --- 解析比对 -----------------------------------------------------------
STUB_LOCAL_IPV4="198.51.100.7" STUB_LOCAL_IPV6=""
_camouflage_domain_matches "vpn.example.com"
check_true "A 记录命中本机 IPv4 时判定绑定成功" "$?"

STUB_LOCAL_IPV4="203.0.113.1" STUB_LOCAL_IPV6="2001:db8::7"
_camouflage_domain_matches "vpn.example.com"
check_true "AAAA 记录命中本机 IPv6 时判定绑定成功" "$?"

STUB_LOCAL_IPV4="203.0.113.1" STUB_LOCAL_IPV6=""
_camouflage_domain_matches "proxied.example.com"
check_false "解析到 CDN 边缘地址时判定绑定失败" "$?"

STUB_LOCAL_IPV4="203.0.113.1" STUB_LOCAL_IPV6="2001:db8::99"
_camouflage_domain_matches "dual.example.com"
check_true "双栈仅 IPv6 命中时也判定成功" "$?"

STUB_LOCAL_IPV4="" STUB_LOCAL_IPV6=""
_camouflage_domain_matches "vpn.example.com"
check_false "本机公网地址未知时判定失败" "$?"

# --- 状态文件读写与幂等 -------------------------------------------------
check "无状态文件时域名为空" "" "$(_camouflage_state_domain)"
check "无状态文件时字段为空" "" "$(_camouflage_state_field '.fallbackPort')"

_camouflage_state_write "vpn.example.com" 8443 "acme" "/tmp/cert.pem" "" "vless-in-443" "Dec  1 00:00:00 2027 GMT"
check_true "状态文件写入成功" "$?"
check "读取伪装域名" "vpn.example.com" "$(_camouflage_state_domain)"
check "读取回落端口" "8443" "$(_camouflage_state_field '.fallbackPort')"
check "读取 443 节点" "vless-in-443" "$(_camouflage_state_field '.port443Tag')"
# Windows/MSYS 的 Git Bash 没有 POSIX 权限语义，只在 Linux 上断言
if [ "$(uname -s 2>/dev/null)" = "Linux" ]; then
    check_true "状态文件权限为 600" \
        "$([ "$(stat -c '%a' "$CADDY_STATE_FILE")" = "600" ] && echo 0 || echo 1)"
fi

# 端口迁移后 tag 会被重写，状态文件必须跟随
_camouflage_state_rebind_tag "vless-in-443-renamed"
check "443 节点 tag 跟随更新" "vless-in-443-renamed" "$(_camouflage_state_field '.port443Tag')"
check "重绑定不影响域名" "vpn.example.com" "$(_camouflage_state_domain)"

# 覆盖写入即为幂等
_camouflage_state_write "new.example.com" 8443 "acme" "/tmp/c2.pem" "" "" ""
check "重复写入覆盖为最新域名" "new.example.com" "$(_camouflage_state_domain)"
check_true "没有残留的临时状态文件" \
    "$([ "$(ls -1 "${CADDY_STATE_FILE}".tmp.* 2>/dev/null | wc -l)" -eq 0 ] && echo 0 || echo 1)"

# --- Caddyfile 生成 -----------------------------------------------------
_caddy_write_config "vpn.example.com" 8443 "acme"
check_true "ACME 模式 Caddyfile 生成成功" "$?"
conf="$(cat "$CADDY_CONF_FILE")"
case "$conf" in
    *"https://vpn.example.com:8443 {"*) echo "ok    Caddyfile 站点地址带回落端口" ;;
    *) echo "FAIL  Caddyfile 站点地址缺少回落端口"; fail=$((fail + 1)) ;;
esac
case "$conf" in
    *"disable_tlsalpn_challenge"*) echo "ok    禁用 TLS-ALPN-01（443 归 Reality）" ;;
    *) echo "FAIL  未禁用 TLS-ALPN-01"; fail=$((fail + 1)) ;;
esac
case "$conf" in
    *"admin off"*) echo "ok    关闭 Caddy admin API" ;;
    *) echo "FAIL  未关闭 Caddy admin API"; fail=$((fail + 1)) ;;
esac
case "$conf" in
    *"root * ${CADDY_WEB_ROOT}"*) echo "ok    站点根目录落在 SINGBOX_DIR" ;;
    *) echo "FAIL  站点根目录路径不符"; fail=$((fail + 1)) ;;
esac

_caddy_write_config "vpn.example.com" 8443 "custom" "/tmp/fullchain.pem" "/tmp/privkey.pem"
conf="$(cat "$CADDY_CONF_FILE")"
case "$conf" in
    *"tls /tmp/fullchain.pem /tmp/privkey.pem"*) echo "ok    自定义证书模式写入证书路径" ;;
    *) echo "FAIL  自定义证书模式未写入证书路径"; fail=$((fail + 1)) ;;
esac
case "$conf" in
    *"issuer acme"*) echo "FAIL  自定义证书模式不应启用 ACME"; fail=$((fail + 1)) ;;
    *) echo "ok    自定义证书模式未启用 ACME" ;;
esac

# --- 监听范围：无 Reality 节点时 Caddy 直接对外 ---------------------------
_caddy_write_config "vpn.example.com" 8443 "acme" "" "" "loopback"
conf="$(cat "$CADDY_CONF_FILE")"
case "$conf" in
    *"https://vpn.example.com {"*) echo "FAIL  loopback 模式不应直接对外监听 443"; fail=$((fail + 1)) ;;
    *) echo "ok    loopback 模式只生成回环站点" ;;
esac
case "$conf" in
    *"https://vpn.example.com:8443 {"*) echo "ok    loopback 模式监听回落端口" ;;
    *) echo "FAIL  loopback 模式缺少回落站点"; fail=$((fail + 1)) ;;
esac
case "$conf" in
    *"bind 127.0.0.1"*) echo "ok    loopback 模式显式绑定 127.0.0.1" ;;
    *) echo "FAIL  loopback 模式未绑定 127.0.0.1（回落端口会暴露到公网）"; fail=$((fail + 1)) ;;
esac
_caddy_write_config "vpn.example.com" 8443 "acme" "" "" "public"
conf="$(cat "$CADDY_CONF_FILE")"
case "$conf" in
    *"https://vpn.example.com {"*) echo "ok    public 模式直接对外监听 443" ;;
    *) echo "FAIL  public 模式缺少对外站点"; fail=$((fail + 1)) ;;
esac
case "$conf" in
    *"https://vpn.example.com:8443 {"*) echo "FAIL  public 模式不得再写回环站点（会触发 automation policy 冲突）"; fail=$((fail + 1)) ;;
    *) echo "ok    public 模式不写回环站点" ;;
esac
check "public 模式只生成一个 site 块" "1" "$(grep -c '^https://' "$CADDY_CONF_FILE")"
check "同一域名只有一份证书自动化策略" "1" "$(grep -c 'issuer acme' "$CADDY_CONF_FILE")"

_caddy_write_config "vpn.example.com" 8443 "acme" "" "" "loopback"
check "loopback 模式只生成一个 site 块" "1" "$(grep -c '^https://' "$CADDY_CONF_FILE")"
check "loopback 模式只有一份证书自动化策略" "1" "$(grep -c 'issuer acme' "$CADDY_CONF_FILE")"

# --- loopback + ACME 必须让 :80 challenge 对外可达 -----------------------
# 实测：loopback 站点的 bind 127.0.0.1 会被 Caddy 继承给 auto_https 动态创建的
# ACME :80 challenge 服务器，变成 127.0.0.1:80，公网校验必然失败并卡满超时。
# 443 被节点占用时只能走 loopback，这条路径必须仍然能签证书。
case "$(cat "$CADDY_CONF_FILE")" in
    *"http://:80 {"*) echo "ok    loopback+ACME 补了 :80 challenge 站点" ;;
    *) echo "FAIL  loopback+ACME 缺少 :80 challenge 站点（HTTP-01 会卡住）"; fail=$((fail + 1)) ;;
esac
case "$(cat "$CADDY_CONF_FILE")" in
    *"bind 0.0.0.0"*) echo "ok    :80 challenge 站点对外监听 0.0.0.0" ;;
    *) echo "FAIL  :80 challenge 站点未绑 0.0.0.0（公网不可达）"; fail=$((fail + 1)) ;;
esac
check "loopback 站点自身仍只绑回环" "1" "$(grep -c 'bind 127.0.0.1' "$CADDY_CONF_FILE")"

# custom 证书不需要 challenge，不应占用 80
_caddy_write_config "vpn.example.com" 8443 "custom" "/tmp/f.pem" "/tmp/k.pem" "loopback"
case "$(cat "$CADDY_CONF_FILE")" in
    *"http://:80 {"*) echo "FAIL  custom 模式不应占用 80"; fail=$((fail + 1)) ;;
    *) echo "ok    custom 模式不占用 80" ;;
esac

# public 模式由 Caddy 自动处理 :80，不应重复声明
_caddy_write_config "vpn.example.com" 8443 "acme" "" "" "public"
case "$(cat "$CADDY_CONF_FILE")" in
    *"http://:80 {"*) echo "FAIL  public 模式不应重复声明 :80"; fail=$((fail + 1)) ;;
    *) echo "ok    public 模式不重复声明 :80" ;;
esac

# 443 是否被占用决定默认监听范围
PORT_CONFLICT_443="false"
check "443 空闲时默认直接对外" "public" "$(_camouflage_default_scope)"
PORT_CONFLICT_443="true"
check "443 被占用时只用回环回落" "loopback" "$(_camouflage_default_scope)"
PORT_CONFLICT_443="false"

# --- 伪装站证书被其他协议复用 -------------------------------------------
mkdir -p "${CADDY_DATA_DIR}/caddy/certificates/acme-v02.api.letsencrypt.org-directory/vpn.example.com"
ACME_DIR="${CADDY_DATA_DIR}/caddy/certificates/acme-v02.api.letsencrypt.org-directory/vpn.example.com"
# MSYS 下 -subj "/CN=..." 会被路径转换破坏，改用配置文件声明主题
openssl_conf="$(mktemp)"
cat > "$openssl_conf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = vpn.example.com
[ext]
subjectAltName = DNS:vpn.example.com
EOF
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 30 -config "$openssl_conf" \
    -keyout "${ACME_DIR}/vpn.example.com.key" -out "${ACME_DIR}/vpn.example.com.crt" >/dev/null 2>&1
check_true "生成 ACME 目录下的测试证书" "$?"
rm -f "$openssl_conf"

_camouflage_state_write "vpn.example.com" 8443 "acme" "${ACME_DIR}/vpn.example.com.crt" "" "" "" "public"
pair="$(_caddy_cert_pair "vpn.example.com")"
check_cert_pair "ACME 证书对可解析" "$pair"

shared="$(_camouflage_shared_cert "vpn.example.com")"
check_cert_pair "伪装域名可复用证书" "$shared"
_camouflage_shared_cert "other.example.com" >/dev/null 2>&1
check_false "域名不一致时拒绝复用证书" "$?"

tls_triplet="$(_camouflage_tls_cert_for "vpn.example.com")"
check "复用伪装站证书时客户端无需跳过验证" "false" "${tls_triplet##*$'\t'}"
_camouflage_tls_cert_for "other.example.com" >/dev/null 2>&1
check_false "域名不一致时不返回证书三元组" "$?"

check "状态文件记录监听范围" "public" "$(_camouflage_state_field '.listenScope')"
check_true "public 模式判定" "$(_camouflage_public_scope && echo 0 || echo 1)"

_camouflage_state_write "vpn.example.com" 8443 "acme" "${ACME_DIR}/vpn.example.com.crt" "" "" "" "loopback"
_camouflage_public_scope
check_false "loopback 模式不判定为对外监听" "$?"

# --- 其他 TLS 协议同步到伪装域名 ----------------------------------------
cat > "$CONFIG_FILE" <<'JSON'
{"inbounds":[
 {"type":"vless","tag":"vless-ws-in-30001","listen_port":30001,
  "users":[{"uuid":"11111111-1111-1111-1111-111111111111"}],
  "tls":{"enabled":true,"server_name":"old.example.com",
         "certificate_path":"OLD_CERT","key_path":"OLD_KEY"},
  "transport":{"type":"ws","path":"/ws"}}
]}
JSON
cat > "$METADATA_FILE" <<'JSON'
{"vless-ws-in-30001":{"name":"WS 节点","yaml":true}}
JSON
cat > "$CLASH_YAML_FILE" <<'YAML'
proxies:
  - name: "WS 节点"
    type: vless
    server: 198.51.100.7
    port: 30001
    skip-cert-verify: true
YAML
_camouflage_state_write "vpn.example.com" 8443 "acme" "${ACME_DIR}/vpn.example.com.crt" "" "" "" "public"

_batch_sni_plan() {
    printf 'vless-ws-in-30001\tvless-ws-tls\t30001\ttls\tcustom\tWS 节点\told.example.com\n'
}
_refresh_modified_node_artifacts() { return 0; }
_atomic_modify_yaml() {
    local file="$1" filter="$2"
    [ -f "$file" ] || return 1
    case "$filter" in
        *skip-cert-verify*) sed -i 's/skip-cert-verify: true/skip-cert-verify: false/' "$file" ;;
    esac
    return 0
}

_camouflage_mutate_tls_nodes "vpn.example.com"
check_true "TLS 类节点可复用伪装域名" "$?"
check "TLS 节点 SNI 更新为伪装域名" "vpn.example.com" \
    "$(jq -r '.inbounds[] | select(.tag == "vless-ws-in-30001") | .tls.server_name' "$CONFIG_FILE")"
check "TLS 节点证书改为伪装站证书" "vpn.example.com.crt" \
    "$(basename "$(jq -r '.inbounds[] | select(.tag == "vless-ws-in-30001") | .tls.certificate_path' "$CONFIG_FILE")")"
check "TLS 节点私钥改为伪装站私钥" "vpn.example.com.key" \
    "$(basename "$(jq -r '.inbounds[] | select(.tag == "vless-ws-in-30001") | .tls.key_path' "$CONFIG_FILE")")"
check "复用公网证书后客户端不再跳过验证" "false" \
    "$(sed -n 's/.*skip-cert-verify: //p' "$CLASH_YAML_FILE")"

# 伪装站不存在时不能凭空同步
rm -f "$CADDY_STATE_FILE"
_camouflage_mutate_tls_nodes "vpn.example.com" >/dev/null 2>&1
check_false "伪装站未部署时拒绝同步" "$?"

# --- 443 候选选择 -------------------------------------------------------
write_nodes() {
    cat > "$CONFIG_FILE" <<'JSON'
{"inbounds":[
 {"type":"vless","tag":"vless-in-8443","listen_port":8443,"users":[{"uuid":"11111111-1111-1111-1111-111111111111"}],
  "tls":{"enabled":true,"server_name":"vpn.example.com","reality":{"enabled":true,"handshake":{"server":"127.0.0.1","server_port":8443},"private_key":"k","short_id":["a"]}}},
 {"type":"vless","tag":"vless-in-9443","listen_port":9443,"users":[{"uuid":"22222222-2222-2222-2222-222222222222"}],
  "tls":{"enabled":true,"server_name":"vpn.example.com","reality":{"enabled":true,"handshake":{"server":"127.0.0.1","server_port":8443},"private_key":"k","short_id":["b"]}}}
]}
JSON
    cat > "$METADATA_FILE" <<'JSON'
{"vless-in-8443":{"name":"A-Node","publicKey":"pk1"},
 "vless-in-9443":{"name":"B-Node","publicKey":"pk2"}}
JSON
}

# CI 里没有任何输入，选择函数必须回落到第一个节点而不是卡住
write_nodes
check "多节点且无 443 时默认选中第一个" "vless-in-8443" "$(_camouflage_pick_port443_tag 2>/dev/null)"

# 已存在 443 节点时必须直接复用，不再抢第二个 443
cat > "$CONFIG_FILE" <<'JSON'
{"inbounds":[
 {"type":"anytls","tag":"any-in-9443","listen_port":9443,"users":[{"password":"p1"}],
  "tls":{"enabled":true,"server_name":"vpn.example.com","reality":{"enabled":true,"handshake":{"server":"127.0.0.1","server_port":8443},"private_key":"k","short_id":["a"]}}},
 {"type":"vless","tag":"vless-in-443","listen_port":443,"users":[{"uuid":"33333333-3333-3333-3333-333333333333"}],
  "tls":{"enabled":true,"server_name":"vpn.example.com","reality":{"enabled":true,"handshake":{"server":"127.0.0.1","server_port":8443},"private_key":"k","short_id":["b"]}}}
]}
JSON
check "已存在 443 节点时直接复用" "vless-in-443" "$(_camouflage_pick_port443_tag 2>/dev/null)"

# 没有 reality 节点时不能凭空选出 443 候选
cat > "$CONFIG_FILE" <<'JSON'
{"inbounds":[
 {"type":"hysteria2","tag":"hy2-in-8443","listen_port":8443,"users":[{"password":"p"}],
  "tls":{"enabled":true,"alpn":["h3"],"certificate_path":"/tmp/a.pem","key_path":"/tmp/a.key"}}
]}
JSON
_camouflage_pick_port443_tag >/dev/null 2>&1
check_false "没有 Reality 节点时选择失败" "$?"

# --- handshake 本机判定 -------------------------------------------------
write_nodes
_reality_handshake_is_local "vless-in-8443"
check_true "handshake 指向 127.0.0.1 时判定为本机回落" "$?"

jq '.inbounds[0].tls.reality.handshake.server = "www.amd.com"' "$CONFIG_FILE" > "$CONFIG_FILE.new" \
    && mv "$CONFIG_FILE.new" "$CONFIG_FILE"
_reality_handshake_is_local "vless-in-8443"
check_false "handshake 指向公网域名时不判定为本机回落" "$?"

_reality_handshake_is_local "missing-tag"
check_false "节点不存在时判定失败" "$?"

# --- 伪装页兜底 ---------------------------------------------------------
_caddy_write_index_page >/dev/null 2>&1
 check_true "仓库不可达时仍写入兜底页" "$?"
 check_true "兜底页是合法 HTML" \
     "$(grep -qi '<html' "${CADDY_WEB_ROOT}/index.html" && echo 0 || echo 1)"

 # 主页依赖 assets/ 下的样式与脚本；同步逻辑必须覆盖这些文件，
 # 否则线上会变成没有样式的裸页。
 check_true "同步清单包含样式表" \
     "$(grep -q 'assets/site.css' "$ROOT/singbox.sh" && echo 0 || echo 1)"
 check_true "同步清单包含站点脚本" \
     "$(grep -q 'assets/site.js' "$ROOT/singbox.sh" && echo 0 || echo 1)"
 check_true "同步清单包含测速脚本" \
     "$(grep -q 'assets/speedtest.js' "$ROOT/singbox.sh" && echo 0 || echo 1)"
 check_true "同步清单包含子页面" \
     "$(grep -q 'status.html api.html about.html legal.html' "$ROOT/singbox.sh" && echo 0 || echo 1)"

# --- [20] 换 SNI 时必须保留本机 handshake -------------------------------
cat > "$CONFIG_FILE" <<'JSON'
{"inbounds":[
 {"type":"vless","tag":"vless-in-443","listen_port":443,"users":[{"uuid":"11111111-1111-1111-1111-111111111111"}],
  "tls":{"enabled":true,"server_name":"vpn.example.com","reality":{"enabled":true,"handshake":{"server":"127.0.0.1","server_port":8443},"private_key":"k","short_id":["a"]}}}
]}
JSON
# 与 _batch_sni_apply_config 的 reality 分支保持同一过滤器
jq '
    (.inbounds[] | select(.tag == "vless-in-443") | .tls.server_name) = "other.example.com"
' "$CONFIG_FILE" > "$CONFIG_FILE.changed"
check "SNI 变更改写 server_name" "other.example.com" \
    "$(jq -r '.inbounds[0].tls.server_name' "$CONFIG_FILE.changed")"
check "handshake 指向保持 127.0.0.1 不被改写" "127.0.0.1" \
    "$(jq -r '.inbounds[0].tls.reality.handshake.server' "$CONFIG_FILE.changed")"
check "handshake 端口保持 8443 不被改写" "8443" \
    "$(jq -r '.inbounds[0].tls.reality.handshake.server_port' "$CONFIG_FILE.changed")"
rm -f "$CONFIG_FILE.changed"

# --- 主脚本接线 ---------------------------------------------------------
grep -q '21) _require_singbox && _caddy_camouflage_menu ;;' "$ROOT/singbox.sh"
check_true "主菜单 [21] 已接线" "$?"
grep -q '请输入选项 \[0-21\]' "$ROOT/singbox.sh"
check_true "主菜单提示范围已放宽到 21" "$?"
grep -q '_batch_sni_camouflage_warning' "$ROOT/singbox.sh"
check_true "[20] 已接入伪装域名冲突告警" "$?"
grep -q '_reality_handshake_is_local' "$ROOT/singbox.sh"
check_true "节点修改已接入 handshake 保持逻辑" "$?"
grep -q '_caddy_cert_health_check' "$ROOT/singbox.sh"
check_true "配置检查已接入证书健康检查" "$?"
grep -q '同步其他 TLS 类节点到该域名' "$ROOT/singbox.sh"
check_true "无 Reality 节点时菜单提示跨协议同步" "$?"
grep -q '_camouflage_apply_tls_nodes' "$ROOT/singbox.sh"
check_true "[21] 已接入跨协议证书复用" "$?"
grep -q '_choose_tls_material' "$ROOT/singbox.sh"
check_true "节点创建已接入证书选择菜单" "$?"
grep -q '正在复用 ${domain} 的伪装站证书' "$ROOT/singbox.sh"
check_true "卸载伪装站会提示证书被复用" "$?"
grep -q '_caddy_set_scope loopback' "$ROOT/singbox.sh"
check_true "Reality 迁移 443 前会让 Caddy 退出公网 443" "$?"
# 卸载脚本必须显式清理 Caddy 产物，否则会留下常驻进程
grep -q '_caddy_service remove' "$ROOT/singbox.sh"
check_true "卸载路径会停止 Caddy 服务" "$?"
grep -q 'rm -f -- "${CADDY_BIN}"' "$ROOT/singbox.sh"
check_true "卸载路径会清理 Caddy 二进制" "$?"
# 安装必须校验官方 SHA-256，不允许无校验下载
grep -q 'Caddy SHA-256 校验失败' "$ROOT/singbox.sh"
check_true "Caddy 安装包含 SHA-256 校验" "$?"
# 版本号改动容易漏同步：脚本与 README 必须一致，且不低于上一次发布
script_version=$(sed -n 's/^export SCRIPT_VERSION="\([^"]*\)".*/\1/p' "$ROOT/singbox.sh" | head -n 1)
readme_version=$(sed -n 's/.*`singbox\.sh v\([0-9][0-9]*\)`.*/\1/p' "$ROOT/README.md" | head -n 1)
check_true "脚本 SCRIPT_VERSION 为纯数字" "$([[ "$script_version" =~ ^[0-9]+$ ]] && echo 0 || echo 1)"
check "README 记录的版本与脚本一致" "$script_version" "$readme_version"
check_true "版本号不低于 v103（伪装域名跨协议复用）" \
    "$([ "${script_version:-0}" -ge 103 ] && echo 0 || echo 1)"

# 仅截取主菜单区域，避免匹配到 Argo 子菜单里的同名标题
menu_section() { # 起始标题 结束标题
    awk -v s="【$1】" -v e="【$2】" '
        index($0, "sing-box 管理脚本 v") { inmenu=1 }
        !inmenu { next }
        index($0, s) { insec=1; next }
        insec && index($0, e) { insec=0 }
        insec { print }
    ' "$ROOT/singbox.sh"
}
node_section=$(menu_section "节点管理" "服务控制")
advanced_section=$(menu_section "进阶功能" "退出脚本")

case "$node_section" in
    *"[20]"*|*"[21]"*) echo "FAIL  【节点管理】仍残留 [20]/[21]"; fail=$((fail + 1)) ;;
    *) echo "ok    【节点管理】只保留 [1]-[5]" ;;
esac
case "$advanced_section" in
    *"[20]"*"[21]"*|*"[21]"*"[20]"*) echo "ok    【进阶功能】含 [20] 与 [21]" ;;
    *) echo "FAIL  【进阶功能】缺少 [20] 或 [21]"; fail=$((fail + 1)) ;;
esac
# 编号与 case 分支必须保持一一对应，移动菜单不能漏改调度
for opt in 20 21; do
    grep -qE "^[[:space:]]+${opt}\\) " "$ROOT/singbox.sh"
    check_true "case 分支 [${opt}] 仍然存在" "$?"
done

# --- 重新部署：回环端口被上一次部署残留的自身 Caddy 占用 -----------------
# 场景：上次部署卡住，Caddy 仍在 127.0.0.1:8443 提供服务（甚至状态文件已丢）。
# 期望：识别为自身占用并继续部署，而不是报"端口已被占用"让用户无从修复。
CADDY_SERVICE_STOPPED=0
PORT_CONFLICT_8443=true
CADDY_OWNS_PORT_STUB=true
# 部署流程会真实执行 `caddy validate`；用替身可执行文件替代，测试不依赖真实 Caddy。
mkdir -p "$WORK/bin"
cat > "$WORK/bin/caddy" <<'CADDYSTUB'
#!/usr/bin/env bash
case "${1:-}" in
    validate|version) exit 0 ;;
    *) exit 0 ;;
esac
CADDYSTUB
chmod +x "$WORK/bin/caddy"
# 以下替身只在本用例生效：前面已有用例断言过真实的 Caddyfile 生成与状态写入。
_caddy_owns_port() { [ "${CADDY_OWNS_PORT_STUB:-false}" = "true" ]; }
_caddy_service() {
    case "${1:-}" in
        # 部署在 $(...) 子 shell 中运行，用文件标记而不是变量传递
        stop) : > "$WORK/caddy.stopped"; return 0 ;;
        *) return 0 ;;
    esac
}
_camouflage_domain_valid() { [ -n "${1:-}" ]; }
_camouflage_verify_domain_loop() { return 0; }
_caddy_install() { return 0; }
_caddy_installed() { return 0; }
_caddy_write_config() { return 0; }
_caddy_write_index_page() { return 0; }
_caddy_wait_cert() { return 0; }
_caddy_verify_site() { return 0; }
_caddy_cert_file() { printf '%s' "/tmp/vpn.example.com.crt"; }
_camouflage_list_reality_nodes() { return 0; }
_camouflage_state_write() { return 0; }
_output_base64_subscription() { return 0; }
_validate_tls_key_pair() { return 0; }
_caddy_cleanup_partial() { return 0; }
_check_port_conflict() {
    local port="$1"
    case "$port" in
        # 停掉自身服务后端口应被释放；他人占用则停服无效。
        # 部署在 $(...) 子 shell 中运行，只能靠文件标记观察停服动作。
        8443)
            [ "${PORT_CONFLICT_8443:-false}" = "true" ] || return 1
            if [ "${CADDY_OWNS_PORT_STUB:-false}" = "true" ] && [ -f "$WORK/caddy.stopped" ]; then
                return 1
            fi
            return 0
            ;;
        443) [ "${PORT_CONFLICT_443:-false}" = "true" ] && return 0; return 1 ;;
        *) return 1 ;;
    esac
}
rm -f "$WORK/caddy.stopped"
deploy_out=$(printf '%s\n' "speedtest.example.com" | _caddy_camouflage_deploy 2>&1)
deploy_rc=$?
check_true "自身 Caddy 占用 8443 时不再误判为冲突" "$deploy_rc"
case "$deploy_out" in
    *"回环端口 8443 已被占用"*) echo "FAIL  仍提示端口被占用"; fail=$((fail + 1)) ;;
    *) echo "ok    不再提示端口被占用" ;;
esac
case "$deploy_out" in
    *"本脚本自己的 Caddy 占用"*) echo "ok    提示占用者是本脚本自己的 Caddy" ;;
    *) echo "FAIL  未提示自身占用"; fail=$((fail + 1)) ;;
esac
# 只放行、不提前停服：配置写入或 Caddyfile 校验失败时旧站点必须仍然完好
check "放行时不提前停止旧 Caddy 实例" "1" \
    "$([ -f "$WORK/caddy.stopped" ] && echo 0 || echo 1)"

# 占用者是别的程序时必须继续拦截，不能因为放行自身而放宽真实冲突
CADDY_OWNS_PORT_STUB=false
rm -f "$WORK/caddy.stopped"
blocked_out=$(printf '%s\n' "speedtest.example.com" | _caddy_camouflage_deploy 2>&1)
blocked_rc=$?
check_false "其他程序占用 8443 时仍然拒绝部署" "$blocked_rc"
case "$blocked_out" in
    *"回环端口 8443 已被占用"*) echo "ok    非自身占用仍给出冲突提示" ;;
    *) echo "FAIL  非自身占用未给出冲突提示"; fail=$((fail + 1)) ;;
esac
check "非自身占用时不得停止服务" "1" \
    "$([ -f "$WORK/caddy.stopped" ] && echo 0 || echo 1)"
# 恢复真实实现：上一个用例把它替换成空替身了。
_camouflage_list_reality_nodes() {
    local node tag port variant
    while IFS= read -r node; do
        [ -n "$node" ] || continue
        tag=$(printf '%s' "$node" | jq -r '.tag // empty')
        port=$(printf '%s' "$node" | jq -r '.listen_port // empty')
        [ -n "$tag" ] && [ -n "$port" ] || continue
        variant=$(_detect_main_node_variant "$tag")
        case "$variant" in
            vless-reality|any-reality) printf '%s\t%s\t%s\n' "$tag" "$port" "$variant" ;;
        esac
    done <<< "$(_list_main_primary_inbounds)"
}

# --- 443 空闲时仍应对外监听（ACME HTTP-01 依赖公网 :80）------------------
# 不能因为存在 Reality 节点就一律选 loopback：loopback 只绑 127.0.0.1，
# 公网 :80 不可达，HTTP-01 必然失败。证书只能先在 public 范围签发。
cat > "$CONFIG_FILE" <<'JSON'
{"inbounds":[
 {"type":"hysteria2","tag":"hy2-in-10002","listen_port":10002,"users":[{"password":"p"}]}
]}
JSON
PORT_CONFLICT_8443=false
check "443 空闲时默认对外监听（否则 ACME 无法完成）" "public" \
    "$(_camouflage_default_scope)"

if [ "$fail" -eq 0 ]; then
    echo ""
    echo "全部通过。"
    exit 0
fi
echo ""
echo "失败 ${fail} 项。"
exit 1
