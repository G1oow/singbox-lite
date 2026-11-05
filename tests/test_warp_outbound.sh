#!/usr/bin/env bash
# WARP 出口回归测试
# 覆盖点：endpoint 结构与地址族（不得出现已废弃的 domain_strategy）；
#         规则顺序（节点规则优先于域名规则）；
#         与中转链路的冲突拒绝；卸载只摘除 warp 归属对象；
#         注册凭据落盘权限与菜单输出脱敏；事务失败整体回滚。
# 依赖: bash、jq、sed、grep
# 用法: bash tests/test_warp_outbound.sh
set -uo pipefail
# 任何交互式读取都直接失败而不是挂起 CI
exec < /dev/null

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
# Windows 上的 jq 是原生程序，无法解析 MSYS 的 /tmp/... 路径；
# 转成 C:/... 形式才能让 bash 与原生程序同时读写同一目录。
if command -v cygpath >/dev/null 2>&1; then
    WORK="$(cygpath -m "$WORK")"
fi
trap 'rm -rf "$WORK"' EXIT

for bin in bash jq sed grep od base64 mktemp; do
    command -v "$bin" >/dev/null 2>&1 || { echo "缺少依赖: $bin" >&2; exit 1; }
done

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
    if { [ "$2" -eq 0 ] && [ "$3" -eq 0 ]; } || { [ "$2" -ne 0 ] && [ "$3" -ne 0 ]; }; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n      期望返回: %s  实际返回: %s\n' "$1" "$2" "$3"
        fail=$((fail + 1))
    fi
}

# --- 抽取被测代码 -------------------------------------------------------
# singbox.sh / advanced_relay.sh 都不能整体 source，按注释锚点抽取 WARP 块。
awk '/^# --- WARP 出口 ---$/,/^# --- WARP 出口结束 ---$/' "$ROOT/advanced_relay.sh" > "$WORK/warp_block.sh"
[ -s "$WORK/warp_block.sh" ] || { echo "抽取 WARP 出口块失败" >&2; exit 1; }

# 这些基础设施是被测代码的真实依赖（原子写、事务快照），必须用真实实现。
for fn in _make_same_dir_tmp _atomic_modify_json _atomic_write_json \
          _restart_checked; do
    sed -n "/^${fn}() {$/,/^}$/p" "$ROOT/advanced_relay.sh" > "$WORK/${fn}.sh"
    [ -s "$WORK/${fn}.sh" ] || { echo "抽取 ${fn} 失败" >&2; exit 1; }
done
awk '/^# --- 中转持久事务 ---$/,/^# --- 中转持久事务结束 ---$/' "$ROOT/advanced_relay.sh" > "$WORK/transactions.sh"
[ -s "$WORK/transactions.sh" ] || { echo "抽取中转事务块失败" >&2; exit 1; }

SINGBOX_DIR="$WORK/etc"
RELAY_CONFIG_FILE="$WORK/etc/relay.json"
MAIN_CONFIG_FILE="$WORK/etc/config.json"
mkdir -p "$SINGBOX_DIR"

# 被测块内的函数依赖这些消息函数与锁封装；锁在测试里无需真实竞争。
_info() { printf '[信息] %s\n' "$1" >&2; }
# 被测块沿用主脚本的颜色变量；测试里置空，但必须已定义（测试开启了 set -u）。
RED='' GREEN='' YELLOW='' CYAN='' NC=''
_error() { printf '[错误] %s\n' "$1" >&2; }
_success() { printf '[成功] %s\n' "$1" >&2; }
_warn() { printf '[注意] %s\n' "$1" >&2; }
_state_lock_acquire() { return 0; }
_state_lock_release() { return 0; }

# shellcheck disable=SC1090
for f in _make_same_dir_tmp _atomic_modify_json _atomic_write_json \
         _restart_checked transactions warp_block; do
    . "$WORK/${f}.sh"
done

# --- 替身：测试不得依赖外网、真实服务与真实端口 -------------------------
export STUB_SB_VERSION="1.13.21"
export STUB_PRIV="cHJpdmF0ZWtleS1tdXN0LW5vdC1sZWFr"
export STUB_PUB="cHVibGlja2V5"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/sing-box" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in
    version)
        echo "sing-box version ${STUB_SB_VERSION}"
        echo ""
        echo "Environment: go1.26 linux/amd64"
        ;;
    generate)
        case "${2:-}" in
            wg-keypair)
                echo "PrivateKey: ${STUB_PRIV}"
                echo "PublicKey: ${STUB_PUB}"
                ;;
            *) exit 1 ;;
        esac
        ;;
    *) exit 1 ;;
esac
EOS
chmod 755 "$WORK/bin/sing-box"
SINGBOX_BIN="$WORK/bin/sing-box"

_manage_service() { echo "service:$1" >> "$WORK/service_calls"; return 0; }
_check_combined_config() { return 0; }
WARP_REAL_SELFCHECK=$(declare -f _warp_selfcheck)
_warp_selfcheck() { return 0; }
_warp_api_register() {
    cat <<'EOJ'
{"id":"device-0001","token":"token-must-not-leak","warp_enabled":true,
 "account":{"account_type":"free","quota":0,"warp_plus":false},
 "config":{"client_id":"BHMB",
   "interface":{"addresses":{"v4":"172.16.0.2","v6":"2606:4700:110:8d18:f000:5dee:af9f:fe17"}},
   "peers":[{"public_key":"peer-public-key-value",
             "endpoint":{"host":"engage.cloudflareclient.com:2408","ports":[2408]}}]}}
EOJ
}

reset_relay() { # [额外 jq 过滤器]
    printf '%s' '{"inbounds":[],"outbounds":[],"route":{"rules":[]}}' > "$RELAY_CONFIG_FILE"
    if [ -n "${1:-}" ]; then
        jq "$1" "$RELAY_CONFIG_FILE" > "$WORK/tmp.json" && mv "$WORK/tmp.json" "$RELAY_CONFIG_FILE"
    fi
}
reset_main() { # 入站 tag 列表
    local tags="$1"
    printf '%s' "{\"inbounds\": $tags}" > "$MAIN_CONFIG_FILE"
}
reset_state() {
    RELAY_TX_ACTIVE="" RELAY_TX_BLOCKED=0 RELAY_TX_RECOVERING=0
    rm -rf "$SINGBOX_DIR"
    mkdir -p "$SINGBOX_DIR"
    reset_relay
    reset_main '[{"type":"vless","tag":"vless-reality-in-1"},{"type":"hysteria2","tag":"hysteria2-in-2"},{"type":"socks","tag":"pf-in-30000"},{"type":"vless","tag":"argo-ws-1"}]'
    rm -f "$WORK/service_calls"
}

# --- 版本门槛 -----------------------------------------------------------
reset_state
STUB_SB_VERSION="1.10.0"
_warp_require_core >/dev/null 2>&1
check_rc "sing-box 1.10 被拒绝进入 WARP" 1 "$?"
STUB_SB_VERSION="1.13.21"
_warp_require_core >/dev/null 2>&1
check_rc "sing-box 1.13 允许进入 WARP" 0 "$?"
STUB_SB_VERSION="1.11.0"
_warp_require_core >/dev/null 2>&1
check_rc "边界版本 1.11.0 允许进入 WARP" 0 "$?"
STUB_SB_VERSION="1.13.21"

# --- 注册与凭据落盘 -----------------------------------------------------
reset_state
_warp_register_device >/dev/null 2>&1
check_rc "注册流程返回成功" 0 "$?"
check "私钥已保存" "$STUB_PRIV" "$(jq -r '.private_key' "$WARP_REG_FILE")"
check "peer 公钥取自注册响应" "peer-public-key-value" "$(jq -r '.peer_public_key' "$WARP_REG_FILE")"
check "默认地址族为双栈" "both" "$(jq -r '.address_family' "$WARP_REG_FILE")"
check "peer 端点使用字面 IP（不依赖 DNS）" "162.159.192.1" "$(jq -r '.peer_address' "$WARP_REG_FILE")"
check "peer 端口为 2408" "2408" "$(jq -r '.peer_port' "$WARP_REG_FILE")"
check "设备身份已保存" "device-0001" "$(jq -r '.device_id' "$WARP_REG_FILE")"

cid_expected=$(printf '%s' 'BHMB' | base64 -d | od -An -tu1 | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//' | tr ' ' ',')
check "reserved 与 client_id 解码一致" "[$cid_expected]" "$(jq -c '.reserved' "$WARP_REG_FILE")"
check "reserved 为 3 个字节" "3" "$(jq -r '.reserved | length' "$WARP_REG_FILE")"

# MSYS/Cygwin 没有真实 POSIX 权限模型，chmod 不会反映到 stat，
# 因此只在类 Unix 环境下断言权限；Windows 上改断言「文件确实由脚本写出」。
case "$(uname -s)" in
    MSYS*|CYGWIN*|MINGW*)
        if [ -s "$WARP_REG_FILE" ]; then
            printf 'ok    %s\n' "注册文件已写出（Windows 不校验 POSIX 权限）"
        else
            printf 'FAIL  %s\n' "注册文件未写出"
            fail=$((fail + 1))
        fi
        ;;
    *)
        mode=$(stat -c '%a' "$WARP_REG_FILE" 2>/dev/null || stat -f '%Lp' "$WARP_REG_FILE" 2>/dev/null)
        check "注册文件权限为 600" "600" "$mode"
        ;;
esac

# --- endpoint 结构 ------------------------------------------------------
ep=$(_warp_build_endpoint_json)
check "endpoint 类型为 wireguard" "wireguard" "$(printf '%s' "$ep" | jq -r '.type')"
check "endpoint tag 为 warp" "warp" "$(printf '%s' "$ep" | jq -r '.tag')"
check "endpoint 使用 1.11+ 的 endpoints 语法而非 outbound" "0" "$(printf '%s' "$ep" | jq -r 'has("server") | if . then 1 else 0 end')"
check "MTU 为 1280" "1280" "$(printf '%s' "$ep" | jq -r '.mtu')"
check "双栈时含 IPv4 地址" "172.16.0.2/32" "$(printf '%s' "$ep" | jq -r '.address[] | select(test("\\."))')"
check "双栈时含 IPv6 地址" "2606:4700:110:8d18:f000:5dee:af9f:fe17/128" "$(printf '%s' "$ep" | jq -r '.address[] | select(test(":"))')"
check "双栈时 allowed_ips 含 v4 与 v6" "2" "$(printf '%s' "$ep" | jq -r '.peers[0].allowed_ips | length')"
# domain_strategy 在 1.12 废弃、1.13 直接 FATAL，绝不能出现在生成的 endpoint 里
check "endpoint 不含废弃的 domain_strategy" "0" "$(printf '%s' "$ep" | grep -c 'domain_strategy')"

# 地址族切换只改 address 与 allowed_ips
jq '.address_family = "ipv4"' "$WARP_REG_FILE" > "$WORK/t.json" && mv "$WORK/t.json" "$WARP_REG_FILE"
ep=$(_warp_build_endpoint_json)
check "仅 IPv4 时只有 v4 地址" "1" "$(printf '%s' "$ep" | jq -r '.address | length')"
check "仅 IPv4 时 allowed_ips 只有 0.0.0.0/0" "0.0.0.0/0" "$(printf '%s' "$ep" | jq -r '.peers[0].allowed_ips | join(",")')"
jq '.address_family = "ipv6"' "$WARP_REG_FILE" > "$WORK/t.json" && mv "$WORK/t.json" "$WARP_REG_FILE"
ep=$(_warp_build_endpoint_json)
check "仅 IPv6 时 allowed_ips 只有 ::/0" "::/0" "$(printf '%s' "$ep" | jq -r '.peers[0].allowed_ips | join(",")')"
check "仅 IPv6 时 address 只留 v6" "1" "$(printf '%s' "$ep" | jq -r '.address | length')"
jq '.address_family = "both"' "$WARP_REG_FILE" > "$WORK/t.json" && mv "$WORK/t.json" "$WARP_REG_FILE"

# --- 规则顺序与分流 -----------------------------------------------------
reset_state
_warp_register_device >/dev/null 2>&1
jq '.domain_suffix = ["openai.com"]' "$WARP_RULES_FILE" > "$WORK/t.json" && mv "$WORK/t.json" "$WARP_RULES_FILE"
jq '.ip_cidr = ["203.0.113.0/24"]' "$WARP_RULES_FILE" > "$WORK/t.json" && mv "$WORK/t.json" "$WARP_RULES_FILE"
jq '. = ["vless-reality-in-1"]' "$WARP_NODES_FILE" > "$WORK/t.json" && mv "$WORK/t.json" "$WARP_NODES_FILE"
# 预先放一条中转链路规则：WARP 不得覆盖它
jq '.route.rules = [{"inbound":["hysteria2-in-2"],"outbound":"relay-out-20000"}]' \
    "$RELAY_CONFIG_FILE" > "$WORK/t.json" && mv "$WORK/t.json" "$RELAY_CONFIG_FILE"

_warp_sync_relay >/dev/null 2>&1
check_rc "同步 relay.json 成功" 0 "$?"
check "relay.json 出现 warp endpoint" "1" "$(jq '[.endpoints[] | select(.tag == "warp")] | length' "$RELAY_CONFIG_FILE")"
check "中转链路规则被保留" "1" "$(jq '[.route.rules[] | select(.outbound == "relay-out-20000")] | length' "$RELAY_CONFIG_FILE")"
check "规则总数为 4（中转 + 节点 + 域名 + IP）" "4" "$(jq '.route.rules | length' "$RELAY_CONFIG_FILE")"

node_idx=$(jq -r '[.route.rules[] | select(.outbound == "warp" and (.inbound != null))][0] | .inbound[0]' "$RELAY_CONFIG_FILE")
check "节点规则绑定到指定入站" "vless-reality-in-1" "$node_idx"

idx_node=$(jq -r '[.route.rules | to_entries[] | select(.value.outbound == "warp" and (.value.inbound != null))][0].key' "$RELAY_CONFIG_FILE")
idx_dom=$(jq -r '[.route.rules | to_entries[] | select(.value.outbound == "warp" and (.value.domain_suffix != null))][0].key' "$RELAY_CONFIG_FILE")
idx_ip=$(jq -r '[.route.rules | to_entries[] | select(.value.outbound == "warp" and (.value.ip_cidr != null))][0].key' "$RELAY_CONFIG_FILE")
if [ "$idx_node" -lt "$idx_dom" ] && [ "$idx_dom" -lt "$idx_ip" ]; then
    printf 'ok    %s\n' "节点规则优先于域名规则，域名规则优先于 IP 规则"
else
    printf 'FAIL  %s\n      实际顺序: 节点=%s 域名=%s IP=%s\n' "规则顺序错误" "$idx_node" "$idx_dom" "$idx_ip"
    fail=$((fail + 1))
fi

domain_rule=$(jq -c '[.route.rules[] | select(.outbound == "warp" and (.domain_suffix != null))][0]' "$RELAY_CONFIG_FILE")
check "域名规则内容" '{"domain_suffix":["openai.com"],"outbound":"warp"}' "$domain_rule"

# 重复同步必须幂等
_warp_sync_relay >/dev/null 2>&1
check "重复同步后规则数不变" "4" "$(jq '.route.rules | length' "$RELAY_CONFIG_FILE")"
check "重复同步后 endpoint 不重复" "1" "$(jq '.endpoints | length' "$RELAY_CONFIG_FILE")"

# 已删除的入站不再保留节点规则
reset_main '[{"type":"hysteria2","tag":"hysteria2-in-2"}]'
_warp_sync_relay >/dev/null 2>&1
check "入站删除后节点规则不再生成" "0" "$(jq '[.route.rules[] | select(.outbound == "warp" and (.inbound != null))] | length' "$RELAY_CONFIG_FILE")"

# --- 与中转链路的冲突 ---------------------------------------------------
reset_state
_warp_register_device >/dev/null 2>&1
jq '.route.rules = [{"inbound":["vless-reality-in-1"],"outbound":"relay-out-20000"}]' \
    "$RELAY_CONFIG_FILE" > "$WORK/t.json" && mv "$WORK/t.json" "$RELAY_CONFIG_FILE"
_warp_inbound_bound_to_relay "vless-reality-in-1"
check_rc "识别出该入站已属中转链路" 0 "$?"
_warp_inbound_bound_to_relay "hysteria2-in-2"
check_rc "未占用的入站不判为冲突" 1 "$?"

# 节点菜单按字典序列出候选，必须按实际序号选择冲突入站
conflict_idx=$(_warp_candidate_inbounds | grep -nx 'vless-reality-in-1' | cut -d: -f1)
printf '%s\n' "$conflict_idx" | _warp_node_menu >/dev/null 2>&1
check_rc "冲突入站被节点分流拒绝" 1 "$?"
check "冲突入站未被写入绑定" "[]" "$(jq -c '.' "$WARP_NODES_FILE")"

# --- 卸载只摘除 warp 归属对象 -------------------------------------------
reset_state
_warp_register_device >/dev/null 2>&1
jq '.domain_suffix = ["openai.com"]' "$WARP_RULES_FILE" > "$WORK/t.json" && mv "$WORK/t.json" "$WARP_RULES_FILE"
jq '.route.rules = [{"inbound":["hysteria2-in-2"],"outbound":"relay-out-20000"}]' \
    "$RELAY_CONFIG_FILE" > "$WORK/t.json" && mv "$WORK/t.json" "$RELAY_CONFIG_FILE"
_warp_sync_relay >/dev/null 2>&1
_warp_sync_relay drop >/dev/null 2>&1
check_rc "摘除出口成功" 0 "$?"
check "endpoint 已移除" "0" "$(jq '.endpoints | length' "$RELAY_CONFIG_FILE")"
check "warp 规则已全部移除" "0" "$(jq '[.route.rules[] | select(.outbound == "warp")] | length' "$RELAY_CONFIG_FILE")"
check "中转链路规则仍在" "1" "$(jq '[.route.rules[] | select(.outbound == "relay-out-20000")] | length' "$RELAY_CONFIG_FILE")"
if [ -s "$WARP_REG_FILE" ]; then
    printf 'ok    %s\n' "卸载后注册信息被保留"
else
    printf 'FAIL  %s\n' "卸载误删了注册信息"
    fail=$((fail + 1))
fi
check "分流清单在卸载后保留" "openai.com" "$(jq -r '.domain_suffix[0]' "$WARP_RULES_FILE")"

# --- 菜单输出脱敏 -------------------------------------------------------
reset_state
_warp_register_device >/dev/null 2>&1
_warp_sync_relay >/dev/null 2>&1
status_out=$(_warp_status 2>&1)
if printf '%s' "$status_out" | grep -qF "$STUB_PRIV"; then
    printf 'FAIL  %s\n' "查看状态泄露了设备私钥"
    fail=$((fail + 1))
else
    printf 'ok    %s\n' "查看状态不泄露设备私钥"
fi
if printf '%s' "$status_out" | grep -q '已隐藏'; then
    printf 'ok    %s\n' "查看状态显式标注凭据已隐藏"
else
    printf 'FAIL  %s\n' "查看状态缺少凭据隐藏提示"
    fail=$((fail + 1))
fi

# --- 事务失败回滚 -------------------------------------------------------
reset_state
_warp_register_device >/dev/null 2>&1
before=$(jq -c '.' "$RELAY_CONFIG_FILE")
_check_combined_config() {
    if [ ! -f "$WORK/check-failed" ]; then
        : > "$WORK/check-failed"
        return 1
    fi
    return 0
}
_warp_commit yes >/dev/null 2>&1
check_rc "组合校验失败时事务返回失败" 1 "$?"
check "relay.json 已回滚到操作前" "$before" "$(jq -c '.' "$RELAY_CONFIG_FILE")"
_check_combined_config() { return 0; }

# 菜单操作失败后，状态文件和运行配置必须一起恢复，后续操作不能重放失败的解绑。
reset_state
_warp_register_device >/dev/null 2>&1
printf '%s\n' '["vless-reality-in-1"]' > "$WARP_NODES_FILE"
_warp_sync_relay >/dev/null 2>&1
before=$(jq -c '.' "$RELAY_CONFIG_FILE")
_manage_service() {
    [ "$1" != status ] || return 0
    if [ ! -f "$WORK/restart-failed" ]; then
        : > "$WORK/restart-failed"
        return 1
    fi
    return 0
}
node_choice=$(_warp_candidate_inbounds | grep -nx 'vless-reality-in-1' | cut -d: -f1)
printf '%s\n' "$node_choice" | _warp_node_menu >/dev/null 2>&1
check_rc "解绑重启失败返回非零" 1 "$?"
check "失败解绑恢复节点绑定清单" '["vless-reality-in-1"]' "$(jq -c '.' "$WARP_NODES_FILE")"
check "失败解绑恢复运行配置" "$before" "$(jq -c '.' "$RELAY_CONFIG_FILE")"
_warp_commit no >/dev/null 2>&1
check_rc "恢复后下一次提交可成功" 0 "$?"
check "下一次提交不会重放失败的解绑" "1" "$(jq '[.route.rules[] | select(.outbound == "warp" and .inbound == ["vless-reality-in-1"])] | length' "$RELAY_CONFIG_FILE")"
_manage_service() { echo "service:$1" >> "$WORK/service_calls"; return 0; }

# 分流与地址族菜单必须在改写源状态之前取得整组快照。
reset_state
_warp_register_device >/dev/null 2>&1
_warp_sync_relay >/dev/null 2>&1
rules_before=$(jq -c '.' "$WARP_RULES_FILE")
reg_before=$(jq -c '.' "$WARP_REG_FILE")
_warp_selfcheck() { return 1; }
_warp_domain_menu <<< $'1\nexample.org\n' >/dev/null 2>&1
check_rc "域名菜单自检失败返回非零" 1 "$?"
check "域名菜单失败恢复分流清单" "$rules_before" "$(jq -c '.' "$WARP_RULES_FILE")"
_warp_family_menu <<< '2' >/dev/null 2>&1
check_rc "地址族菜单自检失败返回非零" 1 "$?"
check "地址族菜单失败恢复注册状态" "$reg_before" "$(jq -c '.' "$WARP_REG_FILE")"
_warp_selfcheck() { return 0; }

# 读取失败不能被当作空清单提交，否则已有节点会静默退回原出口。
reset_state
_warp_register_device >/dev/null 2>&1
printf '%s\n' '["vless-reality-in-1"]' > "$WARP_NODES_FILE"
_warp_sync_relay >/dev/null 2>&1
before=$(jq -c '.' "$RELAY_CONFIG_FILE")
printf 'invalid-json\n' > "$WARP_NODES_FILE"
_warp_commit no >/dev/null 2>&1
check_rc "状态清单损坏时拒绝提交" 1 "$?"
check "读取失败不会清空已有节点路由" "$before" "$(jq -c '.' "$RELAY_CONFIG_FILE")"

# 进程内中断要先恢复整组状态，再释放锁退出。
reset_state
_warp_register_device >/dev/null 2>&1
printf '%s\n' '["vless-reality-in-1"]' > "$WARP_NODES_FILE"
_warp_sync_relay >/dev/null 2>&1
before=$(jq -c '.' "$RELAY_CONFIG_FILE")
node_choice=$(_warp_candidate_inbounds | grep -nx 'vless-reality-in-1' | cut -d: -f1)
(
    trap '_relay_exit "$?"' EXIT
    trap '_relay_exit 143' TERM
    _manage_service() {
        [ "$1" != status ] || return 0
        if [ ! -f "$WORK/warp-signal-fired" ]; then
            : > "$WORK/warp-signal-fired"
            kill -TERM "$BASHPID"
        fi
        cp "$RELAY_CONFIG_FILE" "$WORK/warp-running"
    }
    _warp_node_menu <<< "$node_choice"
) >/dev/null 2>&1
check_rc "解绑期间 TERM 返回非零" 1 "$?"
check "TERM 后恢复节点清单" '["vless-reality-in-1"]' "$(jq -c '.' "$WARP_NODES_FILE")"
check "TERM 后恢复配置" "$before" "$(jq -c '.' "$RELAY_CONFIG_FILE")"
check "TERM 后服务加载原配置" "$before" "$(jq -c '.' "$WORK/warp-running")"

# 使用真实自检启动逻辑；只有探测核心和 curl 是替身，中断不能留下后台进程。
cat > "$WORK/bin/probe-core" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in
    check) exit 0 ;;
    run) printf '%s\n' "$$" > "$PROBE_PID_FILE"; exec sleep 60 ;;
    *) exit 1 ;;
esac
EOS
chmod 755 "$WORK/bin/probe-core"
export PROBE_PID_FILE="$WORK/probe.pid"
(
    trap '_relay_exit "$?"' EXIT
    trap '_relay_exit 143' TERM
    eval "$WARP_REAL_SELFCHECK"
    SINGBOX_BIN="$WORK/bin/probe-core"
    _warp_pick_free_port() { printf '48000\n'; }
    probe_owner="$BASHPID"
    curl() { kill -TERM "$probe_owner"; }
    _warp_selfcheck
) >/dev/null 2>&1
check_rc "自检期间 TERM 返回非零" 1 "$?"
probe_pid=$(cat "$PROBE_PID_FILE")
check "自检中断清理后台核心" "stopped" "$(kill -0 "$probe_pid" 2>/dev/null && echo running || echo stopped)"
kill "$probe_pid" 2>/dev/null || true

# 恢复本身失败时不得清掉最后一份快照或继续接受写入；新进程可重试恢复。
reset_state
_warp_register_device >/dev/null 2>&1
printf '%s\n' '["vless-reality-in-1"]' > "$WARP_NODES_FILE"
_warp_sync_relay >/dev/null 2>&1
before=$(jq -c '.' "$RELAY_CONFIG_FILE")
cp() {
    [ "${RESTORE_FAIL:-0}" = 1 ] && [[ "${2:-}" == */relay ]] && return 1
    command cp "$@"
}
RESTORE_FAIL=1
_warp_selfcheck() { return 1; }
_warp_commit yes keep _warp_change_node vless-reality-in-1 >/dev/null 2>&1
check_rc "恢复失败返回非零" 1 "$?"
check "恢复失败阻止后续写入" "1" "${RELAY_TX_BLOCKED:-0}"
retained="$RELAY_TX_ACTIVE"
check "恢复失败保留完整快照" "yes" "$([ -f "$retained/complete" ] && echo yes || echo no)"
after_failure=$(jq -c '.' "$RELAY_CONFIG_FILE")
_warp_commit no keep _warp_change_node vless-reality-in-1 >/dev/null 2>&1
check_rc "恢复失败后新的变更被拒绝" 1 "$?"
check "拒绝变更不会改写配置" "$after_failure" "$(jq -c '.' "$RELAY_CONFIG_FILE")"
unset RESTORE_FAIL
unset -f cp
_warp_selfcheck() { return 0; }
RELAY_TX_ACTIVE="" RELAY_TX_BLOCKED=0
_relay_recover_pending >/dev/null 2>&1
check_rc "重新启动后可恢复持久快照" 0 "$?"
check "持久恢复还原原配置" "$before" "$(jq -c '.' "$RELAY_CONFIG_FILE")"
check "持久恢复成功后清理事务" "no" "$([ -d "$retained" ] && echo yes || echo no)"

# --- 校验函数 -----------------------------------------------------------
_warp_valid_domain "openai.com"
check_rc "合法域名通过校验" 0 "$?"
_warp_valid_domain "not a domain"
check_rc "含空格域名被拒绝" 1 "$?"
_warp_valid_domain "localhost"
check_rc "无点号主机名被拒绝" 1 "$?"
_warp_valid_cidr "203.0.113.0/24"
check_rc "合法 CIDR 通过校验" 0 "$?"
_warp_valid_cidr "2001:db8::/32"
check_rc "合法 IPv6 段通过校验" 0 "$?"
_warp_valid_cidr "999.1.1.1"
check_rc "越界 IPv4 被拒绝" 1 "$?"
_warp_valid_cidr "hello"
check_rc "非 IP 文本被拒绝" 1 "$?"

# --- 入口线路选择（地址族 × 端口）---------------------------------------
# 纯 IPv6 与 CGNAT 主机的 IPv4 可能连不通，且有主机只丢某个端口，
# 入口候选必须同时覆盖地址族与端口两个维度。
STUB_V4=""
STUB_V6=""
_warp_global_ipv4() { [ -n "$STUB_V4" ] && printf '%s\n' "$STUB_V4"; }
_warp_global_ipv6() { [ -n "$STUB_V6" ] && printf '%s\n' "$STUB_V6"; }

STUB_V4=""; STUB_V6="2602:db8:1::1"
check "纯 IPv6 主机只用 IPv6 入口" "2606:4700:d0::a29f:c001 2408" \
    "$(_warp_peer_candidates | head -n 1)"
check "纯 IPv6 主机候选覆盖全部端口" "6" "$(_warp_peer_candidates | wc -l | tr -d ' ')"

STUB_V4="100.64.16.7"; STUB_V6="2602:db8:1::1"
check "CGNAT + 原生 IPv6 时优先 IPv6 入口" "2606:4700:d0::a29f:c001 2408" \
    "$(_warp_peer_candidates | head -n 1)"

STUB_V4="198.51.100.7"; STUB_V6="2602:db8:1::1"
check "公网 IPv4 + IPv6 时优先 IPv4 入口" "162.159.192.1 2408" \
    "$(_warp_peer_candidates | head -n 1)"

STUB_V4="198.51.100.7"; STUB_V6=""
check "只有公网 IPv4 时不试 IPv6 入口" "9" "$(_warp_peer_candidates | wc -l | tr -d ' ')"

# 端口维度：2408 被丢时仍应落到 4500/500
check "候选按 2408→4500→500 排序" "2408 4500 500" \
    "$(_warp_peer_candidates | awk '{print $2}' | head -n 3 | tr '\n' ' ' | sed 's/ $//')"
check "同一地址的端口候选连续" "162.159.192.1 162.159.192.1 162.159.192.1" \
    "$(STUB_V4=198.51.100.7; STUB_V6=''; _warp_peer_candidates | awk '{print $1}' | head -n 3 | tr '\n' ' ' | sed 's/ $//')"

check_rc "IPv4 私网判定 - 10/8" 0 "$(_warp_ipv4_is_private '10.1.2.3'; echo $?)"
check_rc "IPv4 私网判定 - 192.168" 0 "$(_warp_ipv4_is_private '192.168.1.1'; echo $?)"
check_rc "IPv4 私网判定 - CGNAT 100.64" 0 "$(_warp_ipv4_is_private '100.64.0.1'; echo $?)"
check_rc "IPv4 私网判定 - 公网地址" 1 "$(_warp_ipv4_is_private '198.51.100.1'; echo $?)"

# 前几个入口不通时必须继续换，并把能通的「地址 + 端口」写回注册信息
reset_state
_warp_register_device >/dev/null 2>&1
STUB_V4=""; STUB_V6="2602:db8:1::1"
WARP_SELECT_LOG="$WORK/select.log"
_warp_selfcheck() {
    printf '%s:%s\n' "$(jq -r '.peer_address' "$WARP_REG_FILE")" "$(jq -r '.peer_port' "$WARP_REG_FILE")" >> "$WARP_SELECT_LOG"
    WARP_TRACE_MS=50
    # 只让第 3 个候选（2408 之外的第一个端口）成功
    [ "$(jq -r '.peer_port' "$WARP_REG_FILE")" = "500" ]
}
_warp_select_peer >/dev/null 2>&1
check_rc "逐个尝试入口直到握手成功" 0 "$?"
check "不可达入口会被跳过" "2606:4700:d0::a29f:c001:2408" "$(sed -n '1p' "$WARP_SELECT_LOG")"
check "端口候选被实际尝试" "2606:4700:d0::a29f:c001:4500" "$(sed -n '2p' "$WARP_SELECT_LOG")"
check "地址与端口一起写回注册信息" "2606:4700:d0::a29f:c001:500" \
    "$(jq -r '.peer_address' "$WARP_REG_FILE"):$(jq -r '.peer_port' "$WARP_REG_FILE")"


# 已记录且仍在候选中的组合必须排在最前，避免每次重探都从头扫
reset_state
_warp_register_device >/dev/null 2>&1
STUB_V4=""; STUB_V6="2602:db8:1::1"
_warp_set_peer "2606:4700:d1::a29f:c001" 4500
rm -f "$WARP_SELECT_LOG"
_warp_selfcheck() {
    printf '%s:%s\n' "$(jq -r '.peer_address' "$WARP_REG_FILE")" "$(jq -r '.peer_port' "$WARP_REG_FILE")" >> "$WARP_SELECT_LOG"
    WARP_TRACE_MS=40
    return 0
}
_warp_select_peer >/dev/null 2>&1
check "已记录的入口优先探测" "2606:4700:d1::a29f:c001:4500" "$(sed -n '1p' "$WARP_SELECT_LOG")"
check "优先命中时只探测一次" "1" "$(wc -l < "$WARP_SELECT_LOG" | tr -d ' ')"
_warp_selfcheck() { return 0; }

# 但当前记录属于非首选地址族时不得提前复用，否则会被一次异常探测粘住
reset_state
_warp_register_device >/dev/null 2>&1
STUB_V4="100.64.16.7"; STUB_V6="2602:db8:1::1"
_warp_set_peer "162.159.192.1" 4500
rm -f "$WARP_SELECT_LOG"
_warp_selfcheck() {
    printf '%s:%s\n' "$(jq -r '.peer_address' "$WARP_REG_FILE")" "$(jq -r '.peer_port' "$WARP_REG_FILE")" >> "$WARP_SELECT_LOG"
    WARP_TRACE_MS=40
    return 0
}
_warp_select_peer >/dev/null 2>&1
check "非首选地址族的记录不提前复用" "2606:4700:d0::a29f:c001:2408" "$(sed -n '1p' "$WARP_SELECT_LOG")"
STUB_V4=""; STUB_V6="2602:db8:1::1"

# 能握手但转发极慢的入口应被跳过，改用后续更快的入口
reset_state
_warp_register_device >/dev/null 2>&1
rm -f "$WARP_SELECT_LOG"
_warp_selfcheck() {
    local host port
    host=$(jq -r '.peer_address' "$WARP_REG_FILE"); port=$(jq -r '.peer_port' "$WARP_REG_FILE")
    printf '%s:%s\n' "$host" "$port" >> "$WARP_SELECT_LOG"
    WARP_TRACE_MS=3000
    # 第一个入口极慢，第二个入口正常
    [ "$port" = "4500" ] && WARP_TRACE_MS=80
    return 0
}
_warp_select_peer >/dev/null 2>&1
check_rc "慢入口不会导致失败" 0 "$?"
check "慢入口被跳过并选中下一个" "2606:4700:d0::a29f:c001:4500" \
    "$(jq -r '.peer_address' "$WARP_REG_FILE"):$(jq -r '.peer_port' "$WARP_REG_FILE")"
check "慢入口确实被探测过" "2606:4700:d0::a29f:c001:2408" "$(sed -n '1p' "$WARP_SELECT_LOG")"

# 全部入口不通时必须失败并恢复原值，不能留下不可用的配置
reset_state
_warp_register_device >/dev/null 2>&1
orig_addr=$(jq -r '.peer_address' "$WARP_REG_FILE")
orig_port=$(jq -r '.peer_port' "$WARP_REG_FILE")
_warp_selfcheck() { return 1; }
_warp_select_peer >/dev/null 2>&1
check_rc "所有入口不可达时返回失败" 1 "$?"
check "失败后恢复原入口地址" "$orig_addr:$orig_port" \
    "$(jq -r '.peer_address' "$WARP_REG_FILE"):$(jq -r '.peer_port' "$WARP_REG_FILE")"
_warp_selfcheck() { return 0; }

# --- 主脚本接线 ---------------------------------------------------------
grep -q '22) _require_singbox && _warp_features ;;' "$ROOT/singbox.sh"
check_rc "主菜单 [22] 已接线" 0 "$?"
grep -q '请输入选项 \[0-22\]' "$ROOT/singbox.sh"
check_rc "主菜单提示范围已放宽到 22" 0 "$?"
grep -q '_warp_features()' "$ROOT/singbox.sh"
check_rc "主脚本存在 WARP 入口函数" 0 "$?"
grep -q 'bash "\$script_path" warp-menu' "$ROOT/singbox.sh"
check_rc "WARP 入口调用 advanced_relay.sh 的 warp-menu 子命令" 0 "$?"
grep -q '^\s*warp-menu)' "$ROOT/advanced_relay.sh"
check_rc "advanced_relay.sh 存在 warp-menu 子命令" 0 "$?"
grep -q 'WARP 出口（分流/出口 IP）' "$ROOT/singbox.sh"
check_rc "主菜单显示 WARP 出口项" 0 "$?"

# 中转侧必须拦截与 WARP 绑定的入站，避免两条规则静默并存
grep -q '_warp_inbound_bound_to_warp "\$inbound_tag"' "$ROOT/advanced_relay.sh"
check_rc "创建中转入口前会检测 WARP 绑定冲突" 0 "$?"

# 版本号与 README 必须同步（README 断言在伪装域名测试里，这里只保证递增过）
script_version=$(sed -n 's/^export SCRIPT_VERSION="\([^"]*\)".*/\1/p' "$ROOT/singbox.sh" | head -n 1)
if [ "${script_version:-0}" -ge 117 ]; then
    printf 'ok    %s\n' "WARP 功能已递增 SCRIPT_VERSION（当前 ${script_version}）"
else
    printf 'FAIL  %s\n' "SCRIPT_VERSION 未递增（当前 ${script_version}）"
    fail=$((fail + 1))
fi

echo ""
if [ "$fail" -eq 0 ]; then
    echo "全部通过"
    exit 0
fi
echo "失败 ${fail} 项"
exit 1
