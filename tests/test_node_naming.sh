#!/usr/bin/env bash
# 节点命名规则回归测试
# 依赖: bash、jq、yq (mikefarah v4)
# 用法: bash tests/test_node_naming.sh
set -uo pipefail
# 任何交互式读取都直接失败而不是挂起 CI
exec < /dev/null

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for bin in jq yq; do
    command -v "$bin" >/dev/null 2>&1 || { echo "缺少依赖: $bin" >&2; exit 1; }
done

export SINGBOX_DIR="$WORK/sing-box"
mkdir -p "$SINGBOX_DIR"
export CLASH_YAML_FILE="$SINGBOX_DIR/clash.yaml"
export METADATA_FILE="$SINGBOX_DIR/metadata.json"
export ARGO_METADATA_FILE="$SINGBOX_DIR/argo_metadata.json"
export XRAY_METADATA="$WORK/xray/metadata.json"
export YQ_BINARY="$(command -v yq)"
export BATCH_MODE=false
export NODE_REGION=""

# 预置地区与机器ID缓存，测试不依赖网络
printf '%s\n' '🇭🇰 香港' > "$SINGBOX_DIR/node-region.cache"
printf '%s\n' 'ZT7K2M' > "$SINGBOX_DIR/machine-id"

_warn() { printf '[注意] %s\n' "$1" >&2; }

# 抽取被测函数（singbox.sh 会直接执行主菜单，不能 source 整个文件）
sed -n '/^# --- 节点命名规则/,/^# 系统环境检测/{/^# 系统环境检测/d;p}' \
    "$ROOT/singbox.sh" > "$WORK/naming.sh"
sed -n '/^# --- 节点命名规则/,/^_xray_flock_wait() {/{/^_xray_flock_wait() {/d;p}' \
    "$ROOT/xray_manager.sh" > "$WORK/xray_naming.sh"
# shellcheck disable=SC1090
. "$WORK/naming.sh"

fail=0
check() { # 描述 期望 实际
    if [ "$2" = "$3" ]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n      期望: %s\n      实际: %s\n' "$1" "$2" "$3"
        fail=$((fail + 1))
    fi
}

echo "== 地区与旗帜 =="
check "HK 旗帜字节" "🇭🇰" "$(_node_cc_flag HK)"
check "JP 旗帜字节(小写输入)" "🇯🇵" "$(_node_cc_flag jp)"
check "US 旗帜字节" "🇺🇸" "$(_node_cc_flag US)"
check "非法代码回退地球" "🌐" "$(_node_cc_flag 1x)"
check "HK 中文名" "香港" "$(_node_cc_name HK)"
check "未收录代码返回空" "" "$(_node_cc_name ZZ)"
check "缓存命中地区" "🇭🇰 香港" "$(_node_region)"

echo "== 默认节点名 =="
check "普通节点不带端口" "🇭🇰 香港-hy2-ZT7K2M" "$(_node_default_name hy2 8443)"
check "无端口参数" "🇭🇰 香港-Vless-Reality-ZT7K2M" "$(_node_default_name Vless-Reality)"
check "批量模式强制带端口" "🇭🇰 香港-Vless-WS-2053-ZT7K2M" "$(_node_default_name Vless-WS 2053 true)"
check "NODE_REGION 覆盖" "🇯🇵 日本-tuic-ZT7K2M" "$(NODE_REGION='🇯🇵 日本' _node_default_name tuic)"
check "Argo 标签" "🇭🇰 香港-Argo-Temp-Vless-8443-ZT7K2M" \
    "$(_node_default_name "Argo-Temp-Vless" 8443 true)"

echo "== 机器ID =="
check "机器ID 复用缓存" "ZT7K2M" "$(_node_machine_id)"
printf '%s\n' 'bad id!' > "$SINGBOX_DIR/machine-id"
generated=$(_node_machine_id)
case "$generated" in
    ZT[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]) printf 'ok    非法机器ID 自动重生成: %s\n' "$generated" ;;
    *) printf 'FAIL  非法机器ID 未重生成: %s\n' "$generated"; fail=$((fail + 1)) ;;
esac
printf '%s\n' 'ZT7K2M' > "$SINGBOX_DIR/machine-id"

echo "== 重名检测 (jq: 元数据) =="
_node_name_taken "🇭🇰 香港-hy2-ZT7K2M" && r=taken || r=free
check "元数据为空时判定未占用" free "$r"
printf '%s' '{"vless-in-8443":{"name":"🇭🇰 香港-hy2-ZT7K2M"}}' > "$METADATA_FILE"
_node_name_taken "🇭🇰 香港-hy2-ZT7K2M" && r=taken || r=free
check "元数据命中判定占用" taken "$r"
_node_name_taken "🇭🇰 香港-tuic-ZT7K2M" && r=taken || r=free
check "元数据未命中判定空闲" free "$r"
check "同名时自动追加端口" "🇭🇰 香港-hy2-8443-ZT7K2M" "$(_node_default_name hy2 8443)"

echo "== 重名检测 (yq: clash.yaml) =="
cat > "$CLASH_YAML_FILE" <<'YAML'
proxies:
  - name: "🇭🇰 香港-tuic-ZT7K2M"
    type: socks5
    server: 127.0.0.1
    port: 1080
proxy-groups:
  - name: 节点选择
    type: select
    proxies:
      - "🇭🇰 香港-tuic-ZT7K2M"
YAML
_node_name_taken "🇭🇰 香港-tuic-ZT7K2M" && r=taken || r=free
check "clash.yaml 命中判定占用" taken "$r"
check "clash.yaml 同名时追加端口" "🇭🇰 香港-tuic-2053-ZT7K2M" "$(_node_default_name tuic 2053)"

echo "== 改端口只替换独立端口段 =="
check "新格式端口段替换" "🇭🇰 香港-hy2-9000-ZT7K2M" \
    "$(_node_name_replace_port "🇭🇰 香港-hy2-8443-ZT7K2M" 8443 9000)"
check "机器ID 中的数字不被改写" "🇭🇰 香港-hy2-ZT8443" \
    "$(_node_name_replace_port "🇭🇰 香港-hy2-ZT8443" 8443 9000)"
check "旧格式结尾端口替换" "VLESS-WS-9000" \
    "$(_node_name_replace_port "VLESS-WS-8443" 8443 9000)"
check "Argo 名称端口段替换" "🇭🇰 香港-Argo-Temp-Vless-9000-ZT8443" \
    "$(_node_name_replace_port "🇭🇰 香港-Argo-Temp-Vless-8443-ZT8443" 8443 9000)"

echo "== Xray 单独运行兜底 =="
standalone=$(bash -c '. "$1"; _node_default_name "Vless-Reality" 443' _ "$WORK/xray_naming.sh")
check "缓存齐全时与菜单入口一致" "🇭🇰 香港-Vless-Reality-ZT7K2M" "$standalone"
standalone_empty=$(SINGBOX_DIR="$WORK/empty" bash -c '. "$1"; _node_default_name "Vless-Reality" 443' _ "$WORK/xray_naming.sh")
check "缓存缺失时退化为旧式名称" "X-Vless-Reality-443" "$standalone_empty"

echo
if [ "$fail" -ne 0 ]; then
    echo "失败 ${fail} 项"
    exit 1
fi
echo "全部通过"
