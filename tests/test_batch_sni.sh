#!/usr/bin/env bash
# 一键换 SNI / 自签证书重签 / 聚合 Base64 订阅回归测试
# 依赖: bash、jq、yq、openssl
# 用法: bash tests/test_batch_sni.sh
set -uo pipefail
# 任何交互式读取都直接失败而不是挂起 CI
exec < /dev/null

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for bin in jq yq openssl base64 cmp; do
    command -v "$bin" >/dev/null 2>&1 || { echo "缺少依赖: $bin" >&2; exit 1; }
done

export SINGBOX_DIR="$WORK/sing-box"
mkdir -p "$SINGBOX_DIR"
export CONFIG_FILE="$SINGBOX_DIR/config.json"
export CLASH_YAML_FILE="$SINGBOX_DIR/clash.yaml"
export METADATA_FILE="$SINGBOX_DIR/metadata.json"
export ARGO_METADATA_FILE="$SINGBOX_DIR/argo_metadata.json"
export YQ_BINARY="$(command -v yq)"
export DEFAULT_SNI="www.amd.com"
# 关闭颜色，便于断言 Base64 输出
RED='' GREEN='' YELLOW='' CYAN='' NC='' ORANGE=''

# 抽取被测函数块（singbox.sh 会直接执行主菜单，不能 source 整个文件）
sed -n '/^# --- 一键换 SNI 与聚合订阅 ---/,/^# --- 一键换 SNI 与聚合订阅结束 ---/p' \
    "$ROOT/singbox.sh" > "$WORK/sni.sh"
# shellcheck disable=SC1090
. "$WORK/sni.sh"

fail=0
check() { # 描述 期望 实际
    if [ "$2" = "$3" ]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n      期望: %s\n      实际: %s\n' "$1" "$2" "$3"
        fail=$((fail + 1))
    fi
}

# --- 被测函数的轻量替身 -------------------------------------------------
_warn() { printf '[注意] %s\n' "$1" >&2; }
_success() { printf '[成功] %s\n' "$1" >&2; }
_info() { printf '[信息] %s\n' "$1" >&2; }
_error() { printf '[错误] %s\n' "$1" >&2; }
_flock_wait() { return 0; }
_validate_protected_yaml_metadata() { return 0; }
_manage_service() { return 0; }
_atomic_modify_json() {
    local file="$1" filter="$2"; shift 2
    jq "$@" "$filter" "$file" > "$file.new" && mv "$file.new" "$file"
}

# 与被测代码一致的变种识别（仅测试用简化版）
_detect_main_node_variant() {
    jq -r --arg tag "$1" '
        .inbounds[]? | select(.tag == $tag) |
        if .type == "vless" and (.tls.reality.enabled // false) then "vless-reality"
        elif .type == "vless" and .transport.type == "ws" then "vless-ws-tls"
        elif .type == "vless" and .transport.type == "grpc" then "vless-grpc-tls"
        elif .type == "vless" then "vless-tcp"
        elif .type == "trojan" and .transport.type == "ws" then "trojan-ws-tls"
        elif .type == "anytls" and (.tls.reality.enabled // false) then "any-reality"
        elif .type == "anytls" then "anytls"
        elif .type == "hysteria2" then "hysteria2"
        elif .type == "tuic" then "tuic"
        elif .type == "shadowtls" then "shadowsocks-shadowtls"
        elif .type == "shadowsocks" then "shadowsocks"
        elif .type == "socks" then "socks"
        else "unsupported" end
    ' "$CONFIG_FILE" 2>/dev/null | head -n 1

}
_list_main_primary_inbounds() {
    # 与主脚本一致：排除 HY2 跳跃子入站与 ShadowTLS 内层
    local node tag
    while IFS= read -r node; do
        [ -n "$node" ] || continue
        tag=$(printf '%s' "$node" | jq -r '.tag // empty')
        case "$tag" in *-hop-*) continue ;; esac
        if jq -e --arg tag "$tag" \
            '.inbounds[]? | select(.type == "shadowtls" and .detour == $tag)' \
            "$CONFIG_FILE" >/dev/null 2>&1; then
            continue
        fi
        printf '%s\n' "$node"
    done < <(jq -c '.inbounds[]?' "$CONFIG_FILE" 2>/dev/null)
}
_find_proxy_name() { printf '%s' "${3:-}"; }
# 真实签约函数：复用与脚本同源的 openssl 参数，避免依赖 sed 抽取范围
_generate_self_signed_cert() {
    local domain="$1" cert_path="$2" key_path="$3" cfg
    cfg=$(mktemp)
    cat > "$cfg" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no
[req_distinguished_name]
CN = ${domain}
[v3_req]
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = ${domain}
DNS.2 = *.${domain}
EOF
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
        -keyout "$key_path" -out "$cert_path" -config "$cfg" >/dev/null 2>&1
    local rc=$?
    rm -f "$cfg"
    return $rc
}
_check_combined_config_files() {
    jq -e '.inbounds | length > 0' "$CONFIG_FILE" >/dev/null 2>&1
}
_restore_full_transaction_snapshot() {
    _error "回滚被调用: $3"
    return 1
}
_main_create_tx_snapshot() {
    mkdir -p "$1/credentials" || return 1
    : > "$1/nft.unavailable"
    return 0
}
# 重建产物：真实逻辑依赖大量外部状态，这里只做可验证的最小重建
_refresh_modified_node_artifacts() {
    local tag="$1" node sni cert skip
    node=$(jq -c --arg tag "$tag" '.inbounds[] | select(.tag == $tag)' "$CONFIG_FILE") || return 1
    sni=$(printf '%s' "$node" | jq -r '.tls.server_name // .tls.reality.handshake.server // .handshake.server // empty')
    cert=$(printf '%s' "$node" | jq -r '.tls.certificate_path // empty')
    skip="false"
    [ -n "$cert" ] && skip="true"
    jq --arg t "$tag" --arg sni "$sni" --arg skip "$skip" \
        '.[$t] = ((.[$t] // {}) + {
            serverName: $sni,
            skipVerify: ($skip == "true"),
            share_link: ("link-" + $t + "-" + $sni)
        })' "$METADATA_FILE" > "$METADATA_FILE.new" && mv "$METADATA_FILE.new" "$METADATA_FILE"
}

# --- 构造测试数据 -------------------------------------------------------
cat > "$CONFIG_FILE" <<'JSON'
{
  "inbounds": [
    {"type":"vless","tag":"vless-ws-in-20001","listen_port":20001,
     "users":[{"uuid":"11111111-1111-1111-1111-111111111111"}],
     "tls":{"enabled":true,"server_name":"old.example.com",
            "certificate_path":"SINGBOX_DIR_PLACEHOLDER/vless-ws-in-20001.pem",
            "key_path":"SINGBOX_DIR_PLACEHOLDER/vless-ws-in-20001.key"},
     "transport":{"type":"ws","path":"/ws"}},
    {"type":"trojan","tag":"trojan-ws-in-20002","listen_port":20002,
     "users":[{"password":"pw"}],
     "tls":{"enabled":true,"server_name":"old.example.com",
            "certificate_path":"/etc/acme/trojan.fullchain.pem",
            "key_path":"/etc/acme/trojan.key"},
     "transport":{"type":"ws","path":"/tj"}},
    {"type":"hysteria2","tag":"hy2-in-20003","listen_port":20003,
     "users":[{"password":"pw"}],
     "tls":{"enabled":true,"server_name":"old.example.com",
            "certificate_path":"SINGBOX_DIR_PLACEHOLDER/hy2-in-20003.pem",
            "key_path":"SINGBOX_DIR_PLACEHOLDER/hy2-in-20003.key"}},
    {"type":"hysteria2","tag":"hy2-in-20003-hop-20004","listen_port":20004,
     "users":[{"password":"pw"}],
     "tls":{"enabled":true,"server_name":"old.example.com",
            "certificate_path":"SINGBOX_DIR_PLACEHOLDER/hy2-in-20003.pem",
            "key_path":"SINGBOX_DIR_PLACEHOLDER/hy2-in-20003.key"}},
    {"type":"vless","tag":"vless-reality-in-20005","listen_port":20005,
     "users":[{"uuid":"22222222-2222-2222-2222-222222222222","flow":"xtls-rprx-vision"}],
     "tls":{"enabled":true,"server_name":"old.example.com",
            "reality":{"enabled":true,"handshake":{"server":"old.example.com","server_port":443},
                       "private_key":"k","short_id":["ab"]}}},
    {"type":"anytls","tag":"anytls-in-20006","listen_port":20006,
     "users":[{"password":"pw"}],
     "tls":{"enabled":true,"server_name":"old.example.com",
            "certificate_path":"SINGBOX_DIR_PLACEHOLDER/anytls-in-20006.pem",
            "key_path":"SINGBOX_DIR_PLACEHOLDER/anytls-in-20006.key"}},
    {"type":"tuic","tag":"tuic-in-20012","listen_port":20012,
     "users":[{"uuid":"55555555-5555-5555-5555-555555555555","password":"pw"}],
     "tls":{"enabled":true,"server_name":"old.example.com"}},
    {"type":"vless","tag":"vless-tcp-in-20007","listen_port":20007,
     "users":[{"uuid":"33333333-3333-3333-3333-333333333333"}],
     "tls":{"enabled":false}},
    {"type":"shadowsocks","tag":"ss-in-20008","listen_port":20008,
     "method":"aes-128-gcm","password":"pw"},
    {"type":"shadowtls","tag":"stls-in-20009","listen_port":20009,
     "users":[{"password":"pw"}],"handshake":{"server":"old.example.com","server_port":443},
     "detour":"ss-in-20010"},
    {"type":"shadowsocks","tag":"ss-in-20010","listen_port":20010,
     "method":"aes-128-gcm","password":"pw"}
  ]
}
JSON
# 替换占位路径为真实沙箱路径
sed -i.bak "s#SINGBOX_DIR_PLACEHOLDER#$SINGBOX_DIR#g" "$CONFIG_FILE" && rm -f "$CONFIG_FILE.bak"

for t in vless-ws-in-20001 hy2-in-20003 hv-in-20006 anytls-in-20006; do
    _generate_self_signed_cert "old.example.com" "$SINGBOX_DIR/${t}.pem" "$SINGBOX_DIR/${t}.key" || {
        echo "测试证书生成失败" >&2; exit 1; }
done

cat > "$METADATA_FILE" <<'JSON'
{
  "vless-ws-in-20001": {"name":"ws 节点","owner":"singbox-main","yaml":true,
    "share_link":"vless://11111111-1111-1111-1111-111111111111@192.0.2.10:20001?security=tls&sni=old.example.com#ws"},
  "trojan-ws-in-20002": {"name":"trojan 节点","owner":"singbox-main","yaml":true,
    "share_link":"trojan://pw@192.0.2.10:20002?security=tls&sni=old.example.com#trojan"},
  "hy2-in-20003": {"name":"hy2 节点","owner":"singbox-main","yaml":true,
    "share_link":"hysteria2://pw@192.0.2.10:20003?sni=old.example.com#hy2"},
  "vless-reality-in-20005": {"name":"reality 节点","owner":"singbox-main","yaml":true,
    "publicKey":"PUBKEY","shortId":"ab",
    "share_link":"vless://22222222-2222-2222-2222-222222222222@192.0.2.10:20005?security=reality&sni=old.example.com#reality"},
  "anytls-in-20006": {"name":"anytls 节点","owner":"singbox-main","yaml":true,
    "share_link":"anytls://pw@192.0.2.10:20006?security=tls&sni=old.example.com#anytls"},
  "vless-tcp-in-20007": {"name":"tcp 节点","owner":"singbox-main","yaml":true,
    "share_link":"vless://33333333-3333-3333-3333-333333333333@192.0.2.10:20007?encryption=none&type=tcp#tcp"},
  "ss-in-20008": {"name":"ss 节点","owner":"singbox-main","yaml":true,
    "share_link":"ss://YWVzLTEyOC1nY206cHc@192.0.2.10:20008#ss"}
}
JSON
cat > "$ARGO_METADATA_FILE" <<'JSON'
{
  "argo-in-20020": {"name":"argo 节点","protocol":"vless-ws","domain":"random.trycloudflare.com",
    "local_port":20020,"path":"/argo","uuid":"44444444-4444-4444-4444-444444444444",
    "share_link":"vless://44444444-4444-4444-4444-444444444444@random.trycloudflare.com:443?security=tls&type=ws&sni=random.trycloudflare.com#argo"}
}
JSON

# --- 计划分类 -----------------------------------------------------------
echo "== 计划分类 =="
PLAN="$WORK/plan.tsv"
_batch_sni_plan > "$PLAN"
plan_field() { # tag 列号
    awk -F'\t' -v t="$1" -v c="$2" '$1 == t {print $c}' "$PLAN"
}
check "TLS 自签节点识别" "self_signed" "$(plan_field vless-ws-in-20001 5)"
check "TLS 自签节点 SNI 落点" "tls" "$(plan_field vless-ws-in-20001 4)"
check "自定义证书节点识别" "custom" "$(plan_field trojan-ws-in-20002 5)"
check "Reality 节点 SNI 落点" "reality" "$(plan_field vless-reality-in-20005 4)"
check "Reality 节点无需证书" "none" "$(plan_field vless-reality-in-20005 5)"
check "ShadowTLS 节点 SNI 落点" "shadowtls" "$(plan_field stls-in-20009 4)"
check "纯 TCP 无 SNI" "none" "$(plan_field vless-tcp-in-20007 4)"
check "HY2 跳跃子入站不入计划" "" "$(plan_field hy2-in-20003-hop-20004 1)"
check "计划节点总数" "9" "$(awk 'NF {c++} END {print c+0}' "$PLAN")"
check "自定义证书节点动作" "skip-custom-cert" \
    "$(_batch_sni_plan_action "$(plan_field trojan-ws-in-20002 4)" "$(plan_field trojan-ws-in-20002 5)")"
check "纯 TCP 节点动作" "skip-no-sni" \
    "$(_batch_sni_plan_action "$(plan_field vless-tcp-in-20007 4)" "$(plan_field vless-tcp-in-20007 5)")"
check "自签证书节点动作" "apply" \
    "$(_batch_sni_plan_action "$(plan_field vless-ws-in-20001 4)" "$(plan_field vless-ws-in-20001 5)")"

# --- 证书归属判定 -------------------------------------------------------
echo "== 证书归属 =="
_batch_sni_is_script_cert "$SINGBOX_DIR/vless-ws-in-20001.pem" && r=yes || r=no
check "配置目录顶层自签证书" "yes" "$r"
_batch_sni_is_script_cert "/etc/acme/x.pem" && r=yes || r=no
check "外部路径不算自签" "no" "$r"
mkdir -p "$SINGBOX_DIR/sub"
cp "$SINGBOX_DIR/vless-ws-in-20001.pem" "$SINGBOX_DIR/sub/x.pem"
_batch_sni_is_script_cert "$SINGBOX_DIR/sub/x.pem" && r=yes || r=no
check "子目录证书不算自签" "no" "$r"
ln -s "$SINGBOX_DIR/vless-ws-in-20001.pem" "$SINGBOX_DIR/link.pem" 2>/dev/null
if [ -L "$SINGBOX_DIR/link.pem" ]; then
    _batch_sni_is_script_cert "$SINGBOX_DIR/link.pem" && r=yes || r=no
    check "符号链接不算自签" "no" "$r"
else
    echo "skip  符号链接不算自签 (当前环境不支持创建符号链接)"
fi

# --- 应用变更 -----------------------------------------------------------
echo "== 应用变更 =="
OLD_CERT_SHA=$(_cert_sha256_hex "$SINGBOX_DIR/vless-ws-in-20001.pem" 2>/dev/null || openssl x509 -in "$SINGBOX_DIR/vless-ws-in-20001.pem" -noout -fingerprint -sha256 | awk -F= '{gsub(":","",$2); print tolower($2)}')
cp "$PLAN" "$WORK/plan.confirmed"
_batch_sni_apply_config "new.example.org" "true" "$WORK/plan.confirmed"
check "应用返回码" "0" "$?"

NEW_CERT_CN=$(openssl x509 -in "$SINGBOX_DIR/vless-ws-in-20001.pem" -noout -subject | sed -n 's/.*CN *= *//p')
check "自签证书 CN 已更新" "new.example.org" "$NEW_CERT_CN"
NEW_CERT_SAN=$(openssl x509 -in "$SINGBOX_DIR/vless-ws-in-20001.pem" -noout -ext subjectAltName | tail -n1 | tr -d ' ')
check "自签证书 SAN 含通配" "DNS:*.new.example.org" "$(printf '%s' "$NEW_CERT_SAN" | awk -F', *' '{print $2}')"
check "自签证书私钥仍可见" "yes" "$([ -s "$SINGBOX_DIR/vless-ws-in-20001.key" ] && echo yes || echo no)"
NEW_CERT_SHA=$(openssl x509 -in "$SINGBOX_DIR/vless-ws-in-20001.pem" -noout -fingerprint -sha256 | awk -F= '{gsub(":","",$2); print tolower($2)}')
check "自签证书已重新签发" "changed" "$([ "$OLD_CERT_SHA" != "$NEW_CERT_SHA" ] && echo changed || echo same)"

field() { jq -r --arg t "$1" "$2" "$CONFIG_FILE"; }
check "VLESS-WS server_name" "new.example.org" "$(field vless-ws-in-20001 '.inbounds[] | select(.tag == $t) | .tls.server_name')"
check "Reality server_name" "new.example.org" "$(field vless-reality-in-20005 '.inbounds[] | select(.tag == $t) | .tls.server_name')"
check "Reality handshake.server" "new.example.org" "$(field vless-reality-in-20005 '.inbounds[] | select(.tag == $t) | .tls.reality.handshake.server')"
check "Reality 私钥未被改动" "k" "$(field vless-reality-in-20005 '.inbounds[] | select(.tag == $t) | .tls.reality.private_key')"
check "ShadowTLS handshake.server" "new.example.org" "$(field stls-in-20009 '.inbounds[] | select(.tag == $t) | .handshake.server')"
check "HY2 主节点 server_name" "new.example.org" "$(field hy2-in-20003 '.inbounds[] | select(.tag == $t) | .tls.server_name')"
check "HY2 跳跃子入站 server_name" "new.example.org" "$(field hy2-in-20003-hop-20004 '.inbounds[] | select(.tag == $t) | .tls.server_name')"
check "HY2 跳跃子入站证书同步" "sing-box/hy2-in-20003.pem" \
    "$(field hy2-in-20003-hop-20004 '.inbounds[] | select(.tag == $t) | .tls.certificate_path' | sed 's#^.*/\([^/]*/[^/]*\)$#\1#')"
check "自定义证书节点未改 SNI" "old.example.com" "$(field trojan-ws-in-20002 '.inbounds[] | select(.tag == $t) | .tls.server_name')"
check "自定义证书节点证书路径未改" "/etc/acme/trojan.fullchain.pem" "$(field trojan-ws-in-20002 '.inbounds[] | select(.tag == $t) | .tls.certificate_path')"
check "纯 TCP 节点未改动" "false" "$(field vless-tcp-in-20007 '.inbounds[] | select(.tag == $t) | .tls.enabled')"
# 无证书路径的 TLS 节点（如 cert provider/ACME）：只改 SNI，不写入自签证书路径
check "无证书节点 server_name 已更新" "new.example.org" "$(field tuic-in-20012 '.inbounds[] | select(.tag == $t) | .tls.server_name')"
check "无证书节点未被写入证书路径" "" "$(field tuic-in-20012 '.inbounds[] | select(.tag == $t) | .tls.certificate_path // empty')"
check "元数据 serverName 更新" "new.example.org" "$(jq -r '.["vless-ws-in-20001"].serverName' "$METADATA_FILE")"
check "元数据 skipVerify" "true" "$(jq -r '.["vless-ws-in-20001"].skipVerify' "$METADATA_FILE")"
check "元数据 share_link 不含旧 SNI" "no" "$(jq -r '.["vless-ws-in-20001"].share_link' "$METADATA_FILE" | grep -q 'old.example.com' && echo yes || echo no)"

# 陈旧计划必须被拒绝
echo "== 并发保护 =="
cp "$PLAN" "$WORK/plan.stale"
jq '.inbounds += [{"type":"socks","tag":"socks-in-20011","listen_port":20011,"users":[{"username":"u","password":"p"}]}]' \
    "$CONFIG_FILE" > "$CONFIG_FILE.new" && mv "$CONFIG_FILE.new" "$CONFIG_FILE"
_batch_sni_apply_config "another.example.org" "true" "$WORK/plan.stale" 2>/dev/null
check "陈旧计划被拒绝" "1" "$?"
check "陈旧计划未改动 SNI" "new.example.org" "$(field vless-ws-in-20001 '.inbounds[] | select(.tag == $t) | .tls.server_name')"

# 非法 SNI 必须被拒绝
_batch_sni_apply_config "bad sni" "true" "$WORK/plan.stale" 2>/dev/null
check "非法 SNI 被拒绝" "1" "$?"

# --- 聚合 Base64 订阅 ---------------------------------------------------
echo "== 聚合 Base64 订阅 =="
LINKS="$WORK/links.txt"
STATS=$(_collect_share_links "$LINKS")
check "链接统计 总数/缺失" "11	1" "$STATS"
check "链接行数" "10" "$(awk 'NF {c++} END {print c+0}' "$LINKS")"
check "包含 Argo 节点链接" "yes" "$(grep -q 'trycloudflare' "$LINKS" && echo yes || echo no)"
check "每行都是单行链接" "0" "$(grep -c '^[[:space:]]*$' "$LINKS")"

B64=$(_output_base64_subscription 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -E '^[A-Za-z0-9+/]{16,}=*$')
if [ -n "$B64" ]; then
    DECODED=$(printf '%s' "$B64" | base64 -d 2>/dev/null)
else
    DECODED=""
fi
check "Base64 可解码行数" "10" "$(printf '%s\n' "$DECODED" | awk 'NF {c++} END {print c+0}')"
check "Base64 解码含重签后的 SNI" "yes" "$(printf '%s' "$DECODED" | grep -q 'new.example.org' && echo yes || echo no)"
check "Base64 使用标准字符集" "yes" \
    "$(printf '%s' "$B64" | grep -qE '^[A-Za-z0-9+/]+=*$' && echo yes || echo no)"
# 缺失数 = 计划内节点总数(10) - 实际输出链接数(9)，与 _collect_share_links 的统计一致
check "缺失链接计数与实际缺项一致" "1" "$(( 11 - $(grep -c . "$LINKS") ))"

# 传入已有链接文件时应直接复用，且不删除调用方的文件
printf '%s\n' 'vless://only-one@192.0.2.1:443?security=tls&sni=passed.example.com#one' > "$WORK/passed.txt"
PASSED_B64=$(_output_base64_subscription "$WORK/passed.txt" 2>/dev/null | grep -E '^[A-Za-z0-9+/]{16,}=*$')
check "传入链接文件被复用" "yes" "$([ -f "$WORK/passed.txt" ] && echo yes || echo no)"
check "传入链接文件内容参与编码" "yes" \
    "$(printf '%s' "$PASSED_B64" | base64 -d 2>/dev/null | grep -q 'passed.example.com' && echo yes || echo no)"
check "传入链接单行计数" "1" \
    "$(printf '%s' "$PASSED_B64" | base64 -d 2>/dev/null | awk 'NF {c++} END {print c+0}')"
echo ""
if [ "$fail" -eq 0 ]; then
    echo "全部通过"
else
    echo "失败: ${fail}"
fi
exit "$fail"
