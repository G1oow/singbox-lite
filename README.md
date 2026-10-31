# sing-box + Xray 多协议管理脚本

一套面向 Linux 服务器的 sing-box + Xray 双核心管理脚本，提供节点创建、服务管理、落地/中转、第三方节点导入、端口转发、Argo 隧道和 Clash/Mihomo 配置输出。

当前文档按以下脚本版本整理：`singbox.sh v109`、`advanced_relay.sh v21`、`xray_manager.sh v3.1.5`。

> 脚本需要 root 权限。请仅在拥有管理权或明确授权的服务器和网络中使用。

## 项目组成

| 文件 | 作用 |
| --- | --- |
| `singbox.sh` | 主入口；负责依赖、sing-box、节点、Argo、DNS、服务和子脚本调度 |
| `advanced_relay.sh` | 落地/中转、第三方节点导入、端口转发和规则管理 |
| `parser.sh` | 第三方节点链接的严格解析器，通常由中转脚本调用 |
| `xray_manager.sh` | Xray-core 安装、服务和节点管理，与主脚本共享 `clash.yaml` |
| `AGENTS.md` | 开发约定：测试流程、版本号规则、代码风格、脱敏与危险操作边界 |

## 主要能力

- sing-box 与 Xray 双核心可独立安装、更新和运行。
- 节点创建、查看、删除、端口修改、批量创建和分享链接输出。
- VLESS、Trojan、Hysteria2、TUIC、AnyTLS、Shadowsocks、SOCKS5 等协议管理。
- VLESS-WS / Trojan-WS 的 Argo 临时隧道和固定隧道。
- 支持本机节点 Token 与第三方落地节点两种接入流程，并可选择五种中转入口协议。
- nftables 内核转发与 sing-box 用户态转发双引擎，按实际权限自动选择。
- IPv4/IPv6 地址、域名目标、TCP、UDP、TCP+UDP 端口转发。
- 共享状态锁、原子写入、事务快照和失败回滚，降低跨脚本并发修改造成的配置损坏风险。
- 对配置、元数据、私钥、Token 和临时文件采用收紧的权限与清理策略。

## 系统与环境

### 重点支持

- Debian / Ubuntu：systemd
- Alpine Linux：OpenRC
- 无 systemd/OpenRC 的精简环境：使用 direct 后台模式
- CPU：`x86_64/amd64`、`aarch64/arm64`、`armv7l`

脚本也包含 `yum`/`dnf` 依赖安装路径；主要适配系统为 Debian、Ubuntu 和 Alpine。

### 虚拟化与容器

- KVM、具备 `NET_ADMIN` 的 LXC：优先使用 nftables。
- 无特权 LXC、Docker、Podman：nftables 探测失败时自动降级为 sing-box 用户态转发。
- Docker/Podman 如果不是 host 网络，必须在宿主机预先发布对应的 TCP/UDP 端口；容器内创建监听并不等于宿主机端口已经开放。
- 128 MB Podman Alpine/Debian 的核心安装路径已做低内存优化；sing-box 与 Xray 会按物理内存及 cgroup 上限设置 Go 运行时软内存限制，128 MB 档约为 `40MiB`。实际可用内存仍受宿主机、页缓存和同时运行的服务影响。

## 安装与启动

```bash
(curl -LfsS https://raw.githubusercontent.com/G1oow/singbox-lite/main/singbox.sh -o /usr/local/bin/sb || wget -q https://raw.githubusercontent.com/G1oow/singbox-lite/main/singbox.sh -O /usr/local/bin/sb) && chmod +x /usr/local/bin/sb && sb
```

以后直接运行：

```bash
sb
```

首次启动会安装基础依赖并初始化状态文件，但不会强制同时安装两个核心。请按需要使用主菜单 `[15]` 安装/更新 sing-box，使用 `[16]` 安装/更新 Xray。

`[15]` 进入后可选择：

1. 安装/更新 sing-box 最新稳定版。
2. 安装固定版 `1.13.21`。安装成功后会写入持久版本锁，后续不能再通过脚本升级核心，只能重新安装同一固定版本。

固定版锁定状态会显示在主菜单的 sing-box 版本旁。固定版和最新版都会校验官方发布标签、资产名称、SHA-256 摘要、二进制实际版本以及现有 `config.json + relay.json` 组合配置；任一步失败都不会提交新核心。

子脚本缺失时，主脚本会从同一仓库下载，并在覆盖或执行前检查 HTTPS 来源、非空内容、Bash shebang 和语法。

## 主菜单

| 分类 | 编号 | 功能 |
| --- | ---: | --- |
| 节点管理 | 1 | 添加 sing-box 节点 |
|  | 2 | Argo 隧道节点 |
|  | 3 | 查看节点链接 |
|  | 4 | 删除节点 |
|  | 5 | 修改节点（名称、地址、端口、认证、SNI/证书及协议专属参数） |
| 服务控制 | 6 | 重启 sing-box |
|  | 7 | 停止 sing-box |
|  | 8 | 查看运行状态 |
|  | 9 | 查看实时日志 |
|  | 10 | 定时重启设置 |
|  | 11 | 时间诊断、核心时间补偿及有权限环境的系统校时 |
| 配置与更新 | 12 | 检查配置文件 |
|  | 13 | 更新脚本 |
|  | 14 | DNS 设置 |
| 核心管理 | 15 | 安装/更新 sing-box 核心 |
|  | 16 | 安装/更新 Xray 核心 |
|  | 17 | 卸载脚本 |
| 进阶功能 | 18 | 落地/中转/第三方节点导入/端口转发 |
|  | 19 | Xray 节点管理 |
|  | 20 | 一键更换所有节点 SNI、重签脚本自签证书并输出聚合 Base64 订阅 |
|  | 21 | 一键部署 Caddy 伪装域名（按需安装 Caddy，域名校验通过后托管伪装站；无 Reality 节点时直接对外监听 443，其他 TLS 协议可复用该域名与证书） |
| 退出 | 0 | 退出脚本 |

`[5] 修改节点` 会按实际协议显示可用项目。所有主节点均可修改名称、客户端连接地址、端口和认证信息；Reality 可更新伪装域名并轮换密钥，TLS 类节点可更新 SNI、自签证书或自定义证书，WebSocket/gRPC 可修改传输路径，Hysteria2 还可调整混淆、端口跳跃和客户端带宽。保存时会统一校验 sing-box 配置并同步元数据、分享链接与 Clash/Mihomo 配置，失败则自动回滚。
`[20] 一键更换所有节点 SNI` 把全部可管理主节点的伪装域名统一换成同一个值：Reality 同步 `tls.server_name` 与 `handshake.server`，ShadowTLS 更新 `handshake.server`，TLS 类节点更新 `server_name` 并按需重新签发脚本自管的 RSA 自签证书（`SINGBOX_DIR/<tag>.pem` / `.key`，含同名与泛域名 SAN），Hysteria2 的跳跃子入站会跟随主节点同步。使用自定义证书（含 acme.sh 符号链接与外部路径）的节点整体跳过，避免换 SNI 后证书不匹配；VLESS-TCP、Shadowsocks、SOCKS5 等无 SNI 的节点同样跳过。执行前会列出每个节点的处理方式，执行时持状态锁、创建事务快照、校验 `config.json + relay.json` 组合配置并在失败时自动回滚，成功后重启一次服务，可接着一键输出聚合 Base64 订阅。
`[21] 伪装域名（Caddy）` 把节点伪装成一个真实可访问的 HTTPS 网站：由 Caddy 出示 ACME 真证书并返回伪装页，因此 `https://<你的域名>/` 在浏览器里是一个正常站点。**伪装域名不是 Reality 独属**：没有任何 Reality 节点时同样可以部署，该域名与这张公网可信证书可以直接给 VLESS-WS/gRPC、Trojan-WS、AnyTLS、Hysteria2、TUIC 等 TLS 类节点复用。

前置条件与行为：

- **域名解析**：脚本用 Cloudflare DoH 查询 A/AAAA 记录并与本机公网 IPv4/IPv6 逐一比对，命中任一即通过；不通过会显示"解析结果 / 本机公网地址"对照并允许重试（最多 3 轮）。域名开启了 CDN 加速（如 Cloudflare 橙云）时解析指向边缘节点，比对必然失败，需先关闭加速。
- **监听范围**：443 已被占用（例如已有一个 Reality 节点占用 443）时，Caddy 只监听 `127.0.0.1:8443` 供 Reality 回落，并额外补一个对外监听 `0.0.0.0:80` 的站点只用于 ACME HTTP-01 校验——否则 `bind 127.0.0.1` 会被 Caddy 继承给 challenge 服务器，导致公网校验必然失败；443 空闲时（例如只有 WS/Trojan/HY2 等其他协议），Caddy 直接对外监听公网 443 提供 HTTPS，同时保留 `127.0.0.1:8443` 回环站点，之后接入 Reality 需要 443 时会自动让出。
- **80 端口**：Caddy 通过 ACME HTTP-01 签发并自动续期证书；443 可能归 Reality 或被复用，TLS-ALPN-01 统一不可用。80 端口被占用时会降级为"使用你已有的 fullchain.pem / privkey.pem"，否则取消且不改动任何配置。**80 端口需要长期保持空闲且公网可达**，否则证书会在 90 天后过期，伪装站反而比不伪装更可疑；`[12] 检查配置文件` 会在证书剩余不足 15 天时告警。
- **Caddy 安装**：只在首次使用本功能时询问并安装（GitHub 官方 Release 二进制 + 官方 SHA-256 校验 + 可执行性验证 + 原子替换），不使用系统包管理器，卸载干净。安装后用 `caddy validate` 校验 Caddyfile，再启动服务、等待证书签发，并自检 `https://<域名>:8443/` 返回 200；任一步失败都会拆掉 Caddy 全部产物且 sing-box 配置一行未动。卸载时若仍有 TLS 节点在复用该证书，会提前告警。
- **进程与文件**：Caddy 跟随脚本现有的 `systemd` / `openrc` / `direct` 三种模式运行；站点根目录、Caddyfile、数据目录全部收敛在 `${SINGBOX_DIR}` 下（`www`、`Caddyfile`、`caddy`），状态写入 `${SINGBOX_DIR}/caddy_camouflage.json`，`[17] 卸载脚本` 会一并停止并清理。
- **Reality 迁移**：有 Reality 节点时，确认后会要求选出一个 Reality 节点占用 443（已有 443 就直接复用，未指定默认第一个），其余 Reality 节点保持原端口；若 Caddy 当时占用公网 443，会先让它退回回环模式，失败则整笔回滚。**所有** Reality 节点的 `handshake` 统一改为 `127.0.0.1:8443`、`server_name` 改为该域名——因为域名已指向本机，继续保留 `handshake.server=<域名>` 会让 Reality 回头连接自己的 443 形成自环。改端口沿用现有端口变更流程（快照、冲突复检、失败回滚），节点名称保持不变。
- **与 `[20]` 的关系**：`[20] 一键更换所有节点 SNI` 会检测到伪装站存在；若新 SNI 与该域名不一致，会提示回落证书将不匹配并要求二次确认（默认 N）。切换 SNI 时 Reality 的 `handshake` 指向会保持不变，避免打断已部署的伪装站。

菜单入口另有子菜单支持重新部署、更换域名、重新输出订阅和卸载伪装站。**没有 Reality 节点时**，菜单第 2 项改为"同步其他 TLS 类节点到该域名"：把这些节点的 `server_name` 指向该域名、`certificate_path` / `key_path` 换成伪装站证书，并把客户端 `skip-cert-verify` 关掉（证书公网可信）；Hysteria2 的跳跃子入站会跟随主节点同步。新建或修改 TLS 节点时，若填写的伪装域名与伪装站一致，证书选择菜单会多出"复用伪装站证书"选项。

## 节点命名规则

节点默认名称统一为 `地区旗帜 地区-协议-机器ID`：

| 协议 | 默认名称示例 |
| --- | --- |
| Hysteria2 | `🇭🇰 香港-hy2-ZT7K2M` |
| VLESS + TCP + Reality + Vision | `🇭🇰 香港-Vless-Reality-ZT7K2M` |
| VLESS + WebSocket + TLS | `🇭🇰 香港-Vless-WS-ZT7K2M` |
| VLESS + gRPC + TLS | `🇭🇰 香港-Vless-gRPC-ZT7K2M` |
| Trojan + WebSocket + TLS | `🇭🇰 香港-Trojan-WS-ZT7K2M` |
| TUIC v5 | `🇭🇰 香港-tuic-ZT7K2M` |
| Shadowsocks | `🇭🇰 香港-SS-2022-aes256-ZT7K2M` |
| Argo 临时/固定隧道 | `🇭🇰 香港-Argo-Temp-Vless-8443-ZT7K2M` |
| 批量创建 | `🇭🇰 香港-Vless-WS-8443-ZT7K2M` |
| Xray VLESS + gRPC + Reality | `🇭🇰 香港-Vless-gRPC-Reality-ZT7K2M` |

- 地区：按本机公网 IP 归属地自动识别，结果写入 `/usr/local/etc/sing-box/node-region.cache`；只有首次创建节点时会联网查询，之后直接使用缓存。
- 机器ID：首次创建节点时提示输入，默认自动生成 `ZT` + 4 位大写字母/数字，写入 `/usr/local/etc/sing-box/machine-id` 并在之后复用。
- 端口：普通节点默认不带端口；批量创建、或同一名称已存在时会自动追加端口，避免 `clash.yaml` 出现重名节点。
- 覆盖方式：`NODE_REGION="🇯🇵 日本" sb` 可临时指定地区；删除上述两个缓存文件即可重新识别地区或重新生成机器ID；节点名称仍可在创建时手动修改。
- 归属地查询使用 `ipwho.is`，失败时回退 `ipinfo.io/country`；两者都不可用时显示 `🌐 未知`，不影响节点创建。

## 客户端连接地址（IPv4 / IPv6）

创建节点时不再需要手动输入连接地址，脚本会自动探测本机公网地址：

- 双栈 VPS（同时具备 IPv4 与 IPv6）：列出 `1) IPv4 1.2.3.4`、`2) IPv6 2001:db8::1` 和 `3) 手动输入 IP 或域名`，直接回车默认使用 IPv4。
- 单栈 VPS（只有 IPv4 或只有 IPv6）：自动使用唯一可用地址并直接进入下一步，不再询问。
- 两者都探测失败（无外网、DNS 异常）：回退到启动时检测到的地址，仍不可用时才要求手动输入。
- 需要固定使用域名或其他地址：`NODE_CONNECT_ADDR="vpn.example.com" sb`。
- IPv6 地址在分享链接与客户端配置中自动加 `[]`；写入 `clash.yaml` 的 `server` 字段保持原始地址。
- 探测使用 `icanhazip.com`，失败时回退 `ipinfo.io/ip`；只决定客户端连接地址，不改变服务端 `listen`。

## sing-box 节点协议

| 菜单 | 协议 | 说明 |
| ---: | --- | --- |
| 1 | VLESS + TCP + Reality + Vision | `type=tcp`、`security=reality`、`flow=xtls-rprx-vision` |
| 2 | VLESS + WebSocket + TLS | 支持自签名或自备证书，可输出直连/CF 场景配置 |
| 3 | Trojan + WebSocket + TLS | 支持自签名或自备证书，可输出直连/CF 场景配置 |
| 4 | VLESS + gRPC + TLS | 支持 gRPC TLS 节点创建 |
| 5 | AnyTLS / Any-Reality | 可单独创建或同时创建；Any-Reality 不写入 Mihomo `clash.yaml` |
| 6 | Hysteria2 | 支持 Salamander 混淆和端口跳跃 |
| 7 | TUIC v5 | 使用 QUIC/UDP |
| 8 | Shadowsocks | 经典 SS、SS2022、Padding、SS2022 + ShadowTLS v3 |
| 9 | 纯 VLESS + TCP | 无 TLS/Reality，适合明确知道风险和使用场景的用户 |
| 10 | SOCKS5 | 本机创建的是用户名/密码认证节点 |
| 11 | 批量创建 | 支持多协议组合、端口规划、冲突检查和整批回滚 |

sing-box Shadowsocks 可选项：

- `aes-128-gcm`
- `aes-256-gcm`
- `chacha20-ietf-poly1305`
- `xchacha20-ietf-poly1305`
- `2022-blake3-aes-128-gcm`
- `2022-blake3-aes-256-gcm`
- `2022-blake3-chacha20-poly1305`
- `2022-blake3-aes-256-gcm` + Multiplex/Padding
- `2022-blake3-aes-256-gcm` + ShadowTLS v3

SS2022 会按算法生成严格长度的 Base64 密钥：AES-128 使用 16 字节，AES-256 与 ChaCha20 使用 32 字节。批量创建支持前述七种纯 SS 加密方式及 Padding 组合。

ShadowTLS 组合没有通用的单行分享链接，脚本会给出 Mihomo 配置参考，并把完整配置写入 `clash.yaml`。

## 第三方节点导入

入口：主菜单 `[18]` → 进阶转发菜单 `[3]`。

第三方导入采用“先选协议、再输入对应信息”的严格模式，不会猜测协议或静默降级传输方式。

| 选项 | 支持方式 | 约束 |
| --- | --- | --- |
| VLESS + TCP + Reality + Vision | `vless://` 链接 | 必须是原生 TCP、Reality、`xtls-rprx-vision` |
| VLESS + WebSocket + TLS | `vless://` 链接 | 必须是 WebSocket 传输层与 TLS 加密，支持 Cloudflare CDN/Argo 回源 |
| 纯 VLESS + TCP | `vless://` 链接 | 必须是原生 TCP，不能启用 TLS/Reality |
| Shadowsocks `aes-128-gcm` | `ss://` 链接 | 不接受插件或其他加密方法 |
| Shadowsocks `aes-256-gcm` | `ss://` 链接 | 不接受插件或其他加密方法 |
| Shadowsocks `2022-blake3-aes-128-gcm` | `ss://` 链接 | Base64 密钥解码后须为 16 字节；支持单密钥及服务端密钥:用户密钥 |
| Shadowsocks `2022-blake3-aes-256-gcm` | `ss://` 链接 | Base64 密钥解码后须为 32 字节；支持单密钥及服务端密钥:用户密钥 |
| HTTPS / HTTP 代理 | 链接导入 | 支持 `https://`、`http://` 或 `host:port`（默认 HTTPS），支持 `?sni=` 及 `?insecure=` 参数；选择后显示输入示例 |
| HTTPS / HTTP 代理 | 手动输入 | 显示 HTTPS/HTTP 示例，再输入服务器地址、端口、TLS (HTTPS) 与可选认证 |
| SOCKS5 无认证 | 手动输入 | 输入服务器地址和端口 |
| SOCKS5 用户名/密码认证 | 手动输入 | 输入服务器地址、端口、用户名和密码 |

Hysteria2、TUIC、VMess、Trojan、AnyTLS 等其余第三方分享链接不属于当前导入白名单；解析器会明确拒绝，而不是生成可能错误的配置。

SS2022 可导入 SIP002 明文用户信息链接；为兼容现有分享工具，也接受非标准的 Base64 编码用户信息及旧式整串 Base64 链接。带插件的链接会被拒绝；普通分享链接无法表达落地节点是否要求 ShadowTLS 或 Multiplex/Padding，因此这些附加设置不会自动启用。中转机与第三方落地机需要保持时间准确；导入成功只表示配置通过检查，仍需确认实际连通。

VLESS 导入结果都会显式写入 `network: "tcp"`。Reality 模式严格检查 SNI、公钥、Short ID、uTLS 指纹和 `flow`；WS+TLS 模式严格校验 SNI、Host、Path 与 uTLS 指纹；HTTP/HTTPS 代理作为落地节点时通过 HTTP CONNECT 转发 TCP 流量。

sing-box 中 HTTPS 代理的出站类型仍为 `http`，通过 `tls.enabled: true` 启用 TLS；中转菜单按 TLS 状态显示为 `https`。使用 `https://IP:端口` 导入域名证书代理时，需在链接中加 `?sni=证书域名`，并确保域名与实际证书匹配；`http://` 则不会启用 TLS。

导入 HTTPS 代理时，中转机先严格校验证书；若连接 IP 时只取得域名证书，脚本读取证书中的 DNS SAN 作为候选，逐个带 SNI 重新握手验证。唯一候选通过校验时自动填写 SNI；多个候选或校验失败时可手动填写 SNI 重试。取得 TLS 证书但仍无法严格验证时，用户可以明确选择仅对当前落地节点跳过证书校验（默认否）。若无法取得 TLS 证书，脚本会拒绝把 `insecure=1` 当成连通性修复。显式导入的 `?insecure=1` 保持原意并给出提示。证书探测不等于代理 CONNECT 可用，创建后仍需测试实际中转链路。

## 落地与中转

### 方式一：本机节点 Token

1. 在落地机进入主菜单 `[18]` → `[1]`，选择可导出的本机节点。
2. 脚本生成 `ENC2` 加密 Token 和独立解密口令。
3. 使用不同渠道传递 Token 与口令。
4. 在中转机进入 `[18]` → `[2]`，导入 Token 并输入口令。
5. 选择中转入口协议、监听端口、SNI 和节点名称。

新版 Token 使用 AES-256-CBC + PBKDF2，并把密文与口令分开显示。旧版 `ENC` 和 Base64 Token 仍可兼容导入，但会给出安全警告。

当前文档化的 Token 兼容范围是：原生 TCP/Reality/WS 类型的 VLESS、Trojan-WS、经典 Shadowsocks、Hysteria2、TUIC 和 AnyTLS。SS2022 会从 Token 列表中隐藏；VLESS gRPC、Any-Reality、ShadowTLS 组合和 SOCKS5 不应视为已保证的 Token 导出类型。

### 方式二：第三方落地节点

1. 在中转机进入 `[18]` → `[3]`。
2. 选择第三方节点类型并输入链接或 SOCKS5 信息。
3. 解析器和中转脚本执行双重 schema 校验。
4. 选择本机中转入口协议。
5. 脚本创建入口、落地 outbound、路由、分享链接和客户端配置。

创建中转入口时可以填写客户端实际连接的 IP 或域名；回车使用自动探测的公网 IP。该地址同时写入分享链接和 Clash/Mihomo 配置，不改变第三方落地节点地址或本机监听地址。NAT 若映射了不同的外部端口，还需按实际端口调整客户端配置并确认端口映射可达。

可选中转入口：

- VLESS + TCP + Reality + Vision
- Hysteria2（可选 Salamander QUIC 混淆和端口跳跃；混淆密码会同步写入分享链接与 Clash/Mihomo 配置）
- TUIC v5
- AnyTLS
- Shadowsocks `aes-256-gcm`

创建、删除和修改中转路由都使用事务快照；配置检查或服务重启失败时会尝试恢复原状态。

## 端口转发

入口：主菜单 `[18]` → 进阶转发菜单 `[8]`。

### 自动选择引擎

脚本不是只根据“LXC/KVM/Podman”名称做判断，而是实际尝试创建并删除一条 nftables 测试规则：

- 探测成功：使用 nftables DNAT 内核转发。
- 探测失败或缺少权限：使用 sing-box `direct` 用户态转发。

因此，具备权限的 LXC 和 KVM 可以使用 nftables；常见的无特权 Docker/Podman 会自动降级为 sing-box。规则创建后也可以在菜单中手动切换引擎，切换失败会恢复旧规则。

### 支持能力

- TCP、UDP、TCP+UDP
- IPv4、IPv6、域名目标
- 规则命名、查看、修改、删除、清空
- 主配置、中转配置、Xray、端口转发和 Hysteria2 跳跃范围的冲突检查
- nftables 域名目标每 1 分钟检查一次解析结果并更新规则
- nftables 规则写入独立的 `inet singboxlite` 表，减少对系统其他防火墙规则的干扰

sing-box 用户态 UDP 转发的性能通常低于 nftables，但适合没有 netfilter 权限的容器环境。

## Xray 节点管理

主菜单 `[19]` 进入 Xray 管理；`[16]` 只负责安装/更新 Xray 核心。

| 添加菜单 | Xray 协议 | 客户端提示 |
| ---: | --- | --- |
| 1 | VLESS + TCP + Reality + Vision | 客户端需支持 Reality/Vision |
| 2 | VLESS + gRPC + Reality | 客户端需支持 gRPC Reality |
| 3 | Trojan + XHTTP + Reality | Mihomo/Clash 不支持 XHTTP |
| 4 | Trojan + gRPC + Reality | 客户端需支持 gRPC Reality |
| 5 | VLESS + XHTTP + TLS | 面向 Xray 客户端；可用于 CF H2 回源 |
| 6 | VLESS + gRPC + TLS | 使用 CF 时需开启 gRPC 并正确配置 SSL 模式 |
| 7 | Trojan + gRPC + TLS | 使用 CF 时需开启 gRPC 并正确配置 SSL 模式 |
| 8 | Shadowsocks | AES-128/256-GCM、ChaCha20、XChaCha20、三种 SS2022 及 SS2022 + Padding |

Xray 与 sing-box 使用独立的服务和 JSON 配置，但共享 `/usr/local/etc/sing-box/clash.yaml`。删除和修改节点时只处理归属于目标节点的 YAML 项，避免误删另一核心的同名或相邻配置。
仅安装 Xray 时，Xray 管理器会先初始化这份共享 YAML；以后安装 sing-box 会复用已有的非空文件，并将新节点追加到同一配置中。

## IPv6

- sing-box 和 Xray 入站默认使用 `::` 监听；是否同时接受 IPv4 取决于系统的双栈设置。
- YAML 中保留 IPv6 原始地址，分享链接中的 IPv6 使用 `[地址]` 格式。
- 端口转发可识别 IPv4/IPv6 字面量和域名解析结果。
- 最终可用性仍取决于 VPS 路由、防火墙、容器端口发布、客户端和具体协议实现；不再承诺“所有客户端完美兼容”。

## 配置与数据位置

| 路径 | 内容 |
| --- | --- |
| `/usr/local/bin/sb` | 主脚本快捷命令 |
| `/usr/local/bin/sing-box` | sing-box 核心 |
| `/usr/local/bin/xray` | Xray 核心 |
| `/usr/local/etc/sing-box/config.json` | sing-box 主节点配置 |
| `/usr/local/etc/sing-box/relay.json` | 中转和用户态端口转发配置 |
| `/usr/local/etc/sing-box/clash.yaml` | sing-box/Xray 共享客户端配置 |
| `/usr/local/etc/sing-box/metadata.json` | 主节点元数据和分享链接 |
| `/usr/local/etc/sing-box/node-region.cache` | 节点命名使用的地区旗帜与地区名缓存 |
| `/usr/local/etc/sing-box/machine-id` | 节点命名使用的机器ID |
| `/usr/local/etc/sing-box/core-version.lock` | 固定版 `1.13.21` 的持久升级锁 |
| `/usr/local/etc/sing-box/relay.d/` | 中转、端口转发和辅助状态 |
| `/usr/local/etc/xray/config.json` | Xray 服务端配置 |
| `/var/log/sing-box.log` | sing-box 日志 |
| `/var/log/singbox_argo.log` | Argo 日志 |

状态文件可能包含 UUID、密码、私钥和分享链接，请不要公开上传服务器上的配置目录。

## 安全与可靠性机制

- sing-box 使用每分钟一次的进程内 NTP 时间补偿，不要求 LXC/Podman 修改系统时间；启动前有界探测备用时间源，只迁移脚本管理的默认项并保留用户自定义设置。所有默认时间源不可达时会暂缓启用补偿并告警，下次启动/重启或 `[11]` 修复时重新探测，不把服务运行当作 SS2022 可用证明。
- `[11]` 区分时间诊断、核心补偿修复和系统校时；容器不执行系统校时，不新增常驻校时程序。Xray 仍依赖系统时间，不继承 sing-box 的补偿，创建 SS2022 时会明确提示。SS2022 始终保留 30 秒时间窗口，客户端也需时间准确。
- 所有脚本共享同一把状态锁，避免主脚本、中转脚本和 Xray 脚本并发写配置。
- JSON/YAML 使用同目录临时文件、格式校验和原子替换。
- 节点创建、删除、端口修改和核心更新在关键失败时执行回滚。
- sing-box、Xray 和 yq 下载执行来源约束、SHA-256 校验和可执行性检查。
- 新核心替换前后会检查版本；已有配置存在时还会执行组合配置校验。
- 敏感配置默认按 root-only 权限保存，临时文件和运行目录会限制权限并清理。
- VLESS/Trojan 等可能由 Xray 核心运行的自签 TLS 分享链接优先输出 `pcs` 固定证书，不再同时输出新版 Xray 已拒绝的 `insecure` 参数。普通 AnyTLS 由 sing-box 核心运行；v2rayN 7.24.9 导入分享链接时虽读取 `pcs`，生成 sing-box 出站时却不应用它，因此默认自签证书的 AnyTLS 链接使用 `insecure=1`，与 Clash YAML 的 `skip-cert-verify: true` 一致。该方式会跳过证书身份验证；需要验证身份时请使用自有域名与受信任证书，或继续使用 Any-Reality。
- 第三方解析器只输出最小允许 schema，中转脚本会再次校验字段和值。

## 更新日志

以下记录保留项目历次主要修改。早期条目描述的是当时实现；如果与当前功能不同，应以前文的当前支持范围为准。

### 2025.12.14

- 新增 AnyTLS 节点及 AnyTLS 中转入口；修复生成落地 Token 时重新获取 IP，改为保留节点创建时使用的地址。

### 2026.01.09

- VLESS-WS-TLS、Trojan-WS-TLS 新增自签证书部署；加入 Argo 临时隧道，并针对 128 MB Debian/Alpine 做初步低内存适配。

### 2026.01.13

- 加入 Hysteria2 端口跳跃和应用层多端口监听，改善 LXC/NAT 环境兼容性；同步优化主脚本与子脚本交互。

### 2026.01.19

- 加入定时重启和时区提示；曾加入快速三节点部署，后续已于 2026.03.08 移除。

### 2026.01.25

- 加入 Argo 固定隧道，可直接从 Cloudflare 提供的 Windows/Linux 命令中提取完整 Tunnel Token。

### 2026.01.27

- 优化测速时的内存回收，降低 sing-box 被杀死的概率；简化 Hysteria2 带宽参数；调整 AnyTLS Padding 以兼顾伪装和性能。

### 2026.02.02

- 节点创建成功后直接显示分享链接；当时新增 SS2022 AES-128-GCM + Padding；默认伪装域名由微软域名调整为苹果域名。

### 2026.02.06

- 项目拆分为 `singbox.sh`、`advanced_relay.sh`、`parser.sh`；扩展落地 Token 和第三方节点中转流程；主菜单加入 Argo 状态，Argo 端口支持自定义。

### 2026.02.15

- 完成主脚本、中转脚本和解析器的进一步重构；加入批量节点部署、端口数量计算、连续端口输入及冲突检查。

### 2026.02.21

- 新增 `xray_manager.sh` 和 Xray-core 双核心管理，支持 8 种 Xray 节点；主菜单加入 Xray 状态；增加 XHTTP/gRPC TLS 等 Cloudflare 回源协议。

### 2026.02.24

- 中转脚本加入 sing-box 用户态端口转发；修复第三方域名节点因默认 DNS 选择造成的连通问题，解析 DNS 改用 Cloudflare。

### 2026.03.01

- 适配 sing-box 1.13 DNS 结构并保留逃生环境变量；Alpine 改用 musl 核心；显示 sing-box/Xray 版本；端口转发规则支持命名。

### 2026.03.04

- 修复 Hysteria2 端口跳跃和中转仅监听 IPv4 的问题；sing-box/Xray 统一补充经典 SS、SS2022、Padding 及 Base64 分享链接处理。

### 2026.03.08

- 移除快速三节点部署；核心改为按需手动安装；修复 Argo 隧道小概率未触发进程守护的问题。

### 2026.03.24

- 当时加入 LXC/KVM 环境识别：LXC 使用 sing-box TCP 转发，KVM 使用 iptables TCP+UDP 转发；同时精简交互流程。该引擎策略后续已被 nftables 能力探测替代。

### 2026.04.07

- iptables 转发加入域名目标和定时解析刷新；新增 SS2022 + ShadowTLS v3 组合，并通过 `clash.yaml` 提供客户端配置。

### 2026.04.26

- 完善当时的 iptables 内核转发与 sing-box 用户态转发组合；修复 LXC 环境的 Hysteria2 端口跳跃遗留问题。

### 2026.05.04

- 优化 Docker/Podman Alpine、Debian 安装流程和低内存解压；简化 sing-box/Xray 安装流程；将时间同步拆分为主菜单独立功能。

### 2026.05.24

- 依赖改为首次安装和缺失时检查，减少重复执行包管理器；AnyTLS 增加 Any-Reality 创建选项。

### 2026.05.29

- 端口转发由 iptables 迁移到 nftables；受限 Podman 容器继续使用 sing-box 用户态转发；补充主节点、中转和 Hysteria2 跳跃范围的端口冲突检查。

### 2026.06.11

- Argo 加入 Early Data；sing-box 新增 VLESS + gRPC + TLS；TLS 节点链接加入自签证书 SHA-256 指纹，并分别输出直连与 Cloudflare 场景链接。

### 2026.07.27

- 连接日志加入自动清理，避免小磁盘机器日志占满空间；主菜单加入 sing-box DNS 设置。

### 2026.08

- 增加跨脚本共享锁、原子 JSON/YAML 写入、事务快照和失败回滚；修复 Xray 双栈监听迁移、YAML 精确删除和端口联动更新。
- 加固核心与工具下载校验、候选配置检查、旧核心回滚，以及 PID、日志、证书、Token、元数据、临时文件和运行目录权限。
- 完善主节点、中转、Xray、端口转发和 Hysteria2 跳跃范围之间的冲突识别；nftables 域名目标刷新调整为每分钟执行并支持 IPv4/IPv6。

### 2026.08.31

- 修复 128 MB Podman Alpine 安装 sing-box 时可能被 OOM Kill：跳过容器中无效的可选依赖，改为流式下载、校验和解压，并清理中断安装的临时目录。
- 端口转发改为实际写入测试规则的 nftables 能力探测：LXC/KVM 有权限时使用 nftables，Podman 等受限容器自动降级为 sing-box 用户态转发。

### 2026.09.01

- sing-box 与中转入口统一明确为 `VLESS + TCP + Reality + Vision`，并保留旧内部标签以兼容已有节点。
- 第三方导入收敛为 VLESS Reality Vision、纯 VLESS TCP、SS AES-128/256-GCM 四个链接选项，以及无认证/带认证两类手动 SOCKS5。
- VLESS 解析结果显式写入 `network: "tcp"`；中转 schema 同步拒绝缺少 network、非 TCP 传输及不符合所选类型的节点。

### 2026.09.03

- sing-box 核心安装加入二级选择：可跟随最新稳定版，或安装并永久锁定 `1.13.21` 固定版；锁定后拒绝后续核心升级。
- 固定版与最新版统一校验官方发布状态、精确资产名称、SHA-256 和二进制实际版本，并继续保留组合配置检查、服务启动验证及失败回滚。
- 按 sing-box 1.14 移除项复核配置：保留 1.12+ typed DNS 和 `default_domain_resolver`，清理已失效的旧版 DNS 兼容环境变量。

### 2026.09.04

- 修复 sing-box 1.14 在部分 Linux/systemd-resolved 环境中使用 local DNS 时查询可能阻塞 10 秒的问题；新配置默认启用 `prefer_go`，旧配置启动时自动迁移并保留原 DNS 地址与解析策略。
- 继续收紧 128 MB 容器安装路径：Debian 依赖改为逐包、无 recommends、无 dpkg PTY 安装；Podman 默认配置不再启用容易因 UDP 123 受限而阻塞启动的 NTP。
- 修复服务启动继承共享锁文件描述符、systemd 失败状态未清理，以及 Argo 临时节点空字段错位导致名称和凭据元数据串位的问题。
- Argo 临时隧道改为结合系统解析与 Cloudflare DoH 确认域名已经完成 DNS 发布后才提交；首个域名未发布时会清理并自动重试一次，避免本机负缓存误判或生成表面成功但无法解析的节点。
- 修复主卸载先删元数据后停 Argo、遗留 sing-box/Xray 服务与定时器、以及误删用户 MOTD 分隔行的问题；卸载现在按进程、规则、服务、状态的依赖顺序清理。
- 批量创建进一步校验单一端口范围和 Shadowsocks 选项，避免畸形范围或 Shell 通配符参与拆词；任何非法输入都会在写配置前拒绝。
- 管理脚本更新改为四个组件全部预下载、校验后再统一提交；任一组件失败会保持整组旧文件，并拒绝把较新的本地版本自动降级。
- 修复 Alpine/BusyBox 下 Xray 原子 JSON 临时文件模板不兼容；自签 TLS 链接优先使用证书指纹，兼容已移除 `allowInsecure` 的新版 Xray。
- 修复 Podman 低内存安装跳过 `cron` 后 Argo 节点缺少自动守护的问题：仅在使用 Argo 时按需安装并启动 cron；守护创建失败会回滚节点，避免留下无法自愈的半成品配置。
- sing-box 与 Xray 统一加入基于物理内存、cgroup `memory.max`/`memory.high` 的 `GOMEMLIMIT`；128 MB 档由 `48MiB` 收紧到约 `40MiB`，并覆盖 systemd、OpenRC、direct 三种启动方式。

### 2026.09.05

- 修复 SS2022 在漂移时钟及容器中的时间补偿策略：默认 NTP 从 `30m` 调整为 `1m`，取消按 Podman 名称删除默认 NTP，加入有界探测与备用源、旧默认配置迁移、自定义配置保护及时间诊断；系统校时不再在容器中尝试修改宿主机时间。
- 修复 DDNS 端口转发在 cron 精简环境下找不到 `nft`、导致域名 IP 已变化但规则未同步的问题；已有定时任务更新脚本后即可生效，并补充解析、规则更新、回滚与持久化失败日志及失败退出状态。
- sing-box 与 Xray 的 Shadowsocks 创建菜单统一补齐 `aes-128-gcm`、`aes-256-gcm`、`chacha20-ietf-poly1305`、`xchacha20-ietf-poly1305` 和三种 SS2022 加密方式，并保留原有 Padding、ShadowTLS 组合。
- SS2022 改为按算法生成严格长度的 Base64 密钥：AES-128 使用 16 字节，AES-256 与 ChaCha20 使用 32 字节；sing-box 批量创建同步支持七种纯 SS 加密方式。
- sing-box `[5] 修改节点` 在重新生成 Shadowsocks 认证信息时复用相同的密钥规则，并同步更新服务端配置、元数据、分享链接与 Clash/Mihomo 配置。

### 2026.09.06

- 节点默认命名统一为 `地区旗帜 地区-协议-机器ID`（如 `🇭🇰 香港-hy2-ZT7K2M`）：地区按公网 IP 归属地自动识别并缓存，机器ID 首次生成后持久化复用，sing-box 与 Xray 节点共用同一规则。
- 普通节点默认名称不再携带端口；批量创建或同名节点已存在时自动追加端口，避免共享 `clash.yaml` 重名冲突。
- 一键安装命令与脚本内 `GITHUB_RAW_BASE` 指向 `G1oow/singbox-lite` 仓库。
- 创建节点时的连接地址改为自动探测：双栈 VPS 列出 IPv4 / IPv6 供选择（默认 IPv4），单栈 VPS 自动使用唯一地址并直接进入下一步；探测失败回退已检测地址或手动输入，并支持 `NODE_CONNECT_ADDR` 覆盖。

### 2026.10.22

- PR #18 修复 Argo 节点预览在进入子菜单后分享链接被污染的问题：`_sync_argo_early_data()` 改为逐条紧凑 JSON 读取，避免 VLESS 的空 `password` 字段使后续字段错位；异常 `path` 不再参与链接重生成。旧逻辑持久化的是错误的 `share_link`，元数据 `path` 通常仍保留原值。
- PR #18 为 Alpine 容器中不可用的 OpenRC cron 服务加入直接启动 `crond` 的回退路径。

### 2026.10.24

- 中转入口新增客户端连接地址选择，支持 IPv4、IPv6 和域名；解决出口 IP 与入口 IP 不同或有多个入口地址时，分享链接和 Clash/Mihomo 配置写错地址的问题。
- Argo 元数据同步改为逐条 JSON 读取，避免 VLESS 空密码字段造成错位；根据原始 WS 路径识别并重建已有的异常分享链接。
- Alpine 的 cron 启动在 OpenRC 服务不可用时回退直接运行 `crond`，同时保留正常 OpenRC 环境下的开机启用设置。无 init 的容器仍需在容器启动流程中运行 cron，才能保证容器重启后持续守护。

### 2026.10.29

- 主菜单新增 `[20] 一键更换所有节点 SNI`：一次把全部可管理主节点的伪装域名换成同一个值，Reality 同步 `server_name` 与 `handshake.server`，ShadowTLS 更新 `handshake.server`，TLS 类节点更新 `server_name` 并按需重新签发脚本自管的 RSA 自签证书，Hysteria2 跳跃子入站跟随主节点同步。
- 自定义证书节点（acme.sh 符号链接、外部路径）与无 SNI 的节点（VLESS-TCP、Shadowsocks、SOCKS5）在处理前明确列出并整体跳过，避免换 SNI 后证书不匹配。
- 批量变更沿用状态锁、事务快照、`config.json + relay.json` 组合校验、单次重启和失败自动回滚；确认时会重新比对节点计划，避免确认后状态漂移。
- 聚合 Base64 订阅输出统一为单一实现：主节点与 Argo 节点链接合并编码，`[3] 查看节点链接` 与 `[20]` 共用，并支持直接复用刚生成的链接文件。
- Hysteria2 中转入口新增可选 Salamander QUIC 混淆，自动生成混淆密码，并同步写入服务端入站、分享链接和 Clash/Mihomo 配置；端口跳跃范围也同步写入客户端 YAML 的 `ports` 字段。

### 2026.10.30

- Argo 守护改为识别 `cron` 和 `crond` 两种进程名，避免服务已启动却被误判为失败；隧道创建只在保存节点后检查一次守护，手动重启时先确认守护可用。
- 脚本管理的 NTP 状态仅在首次探测、可达状态变化或配置变化时提示，普通节点操作仍会进行启动前探测，但不会反复打印相同的成功信息。
- 第三方 HTTP/HTTPS 落地节点导入显示具体链接与手动输入示例；HTTPS 在写配置前探测证书、验证可用 SNI，并仅在取得证书且用户明确确认时允许逐节点跳过校验。
- 同步上游脚本：`singbox.sh` v104 → v105、`advanced_relay.sh` v19 → v21，合入上游 Argo 守护进程名识别、NTP 提示降噪、Hysteria2 中转混淆与 HTTPS 落地证书校验；本仓库的节点命名、双栈连接地址、`[20]` 批量换 SNI 与 `[21]` 伪装域名功能保持不变。

### 2026.11.01

- 主菜单新增 `[21] Reality 伪装域名（Caddy）`：Reality 独占 443，未认证连接回落到本机 `127.0.0.1:8443` 上的 Caddy，由它用 ACME 真证书托管伪装页，使伪装域名成为可正常访问的 HTTPS 站点。
- Caddy 按需安装（官方 Release 二进制 + 官方 SHA-256 校验 + 可执行性验证 + 原子替换），仅在首次使用该功能时询问；进程跟随 `systemd`/`openrc`/`direct` 三种模式，产物全部收敛到 `${SINGBOX_DIR}` 并在卸载脚本时清理。
- 域名绑定校验使用 Cloudflare DoH 的 A/AAAA 记录与本机公网 IPv4/IPv6 逐一比对，失败时给出解析对照并允许最多 3 轮重试，同时提示 CDN 橙云场景；80 端口被占用时降级为复用已有证书，否则不产生任何改动。
- 部署分三阶段提交：Caddy 准备阶段失败时整体拆除且不触碰 sing-box；Reality 切换阶段复用状态锁、事务快照、组合配置校验、单次重启与失败回滚；最后由统一实现输出聚合 Base64 订阅。
- 所有 Reality 节点的 `handshake` 统一指向 `127.0.0.1:8443`，避免域名指向本机后自环；`[20]` 与 `[5]` 在改写 SNI 时会保留该指向，并在新 SNI 与伪装域名不一致时二次确认。
- `[12] 检查配置文件` 增加伪装站证书健康检查，剩余不足 15 天时告警（续期依赖 80 端口长期空闲）；新增 `tests/test_caddy_camouflage.sh` 并纳入 CI。

### 2026.11.02

- 主菜单调整分组：`[20] 一键换 SNI/重签证书` 与 `[21] Reality 伪装域名（Caddy）` 从【节点管理】移入【进阶功能】，【节点管理】恢复到只包含 `[1]`-`[5]` 的纯节点操作；菜单编号与 `case` 分支保持不变，功能入口位置调整不影响已有用法。
- `tests/test_caddy_camouflage.sh` 增加菜单分组断言：校验 `[20]`/`[21]` 已归入【进阶功能】且不再出现在【节点管理】，同时确认两个 `case` 分支仍然存在，避免后续移动菜单时漏改调度。

### 2026.11.03

- 伪装域名不再由 Reality 独占：`[21]` 在没有 Reality 节点的场景下同样可以部署，443 空闲时 Caddy 直接对外监听公网 443 提供 HTTPS（同时保留 `127.0.0.1:8443` 回环站点），443 已被占用时才退回纯回落模式；状态文件新增 `listenScope` 记录当前监听范围。
- 其他 TLS 类协议（VLESS-WS/gRPC、Trojan-WS、AnyTLS、Hysteria2、TUIC）可复用伪装域名与 Caddy 的 ACME 证书：`[21]` 菜单第 2 项在无 Reality 节点时改为批量同步这些节点的 `server_name` 与证书路径，并把客户端 `skip-cert-verify` 关闭；Hysteria2 跳跃子入站跟随主节点同步，整个过程仍在状态锁与事务快照下执行。
- 新建节点或 `[5] 修改节点` 时，若填写的伪装域名与伪装站一致，证书菜单多出"复用伪装站证书"选项并默认选中；批量创建模式也会自动复用。
- 若后续需要把 443 交给 Reality，`[21]` 会先让 Caddy 退回回环模式；事务未提交（失败回滚）时自动恢复原有监听范围，避免伪装域名失联。
- Hysteria2 / TUIC 的客户端 `skip-cert-verify` 与分享链接（`insecure` / `allow_insecure` / `pinSHA256`）改为按实际证书来源推导，复用公网可信证书时不再输出跳过验证参数。

### 2026.11.04

- 同步上游 Argo 守护修复：Alpine 自带 BusyBox `crontab`/`crond` 不再被误判为开机自启已就绪。仅在实际运行 OpenRC（`/run/openrc/softlevel` 存在）且 `/etc/init.d/` 下没有 cron 服务时才安装 `dcron`，并按服务名检查 `/etc/init.d/<svc>` 是否存在后再尝试启用。
- OpenRC 分支不再吞掉失败：`rc-update add <svc> default` 必须成功且 `/etc/runlevels/default/<svc>` 为符号链接，`rc-service <svc> start` 与 `status` 都必须通过，否则报错并拒绝创建没有重启自愈能力的 Argo 节点。
- 升级脚本后首次打开主菜单时，若已存在 Argo 元数据，会自动补一次开机守护（失败仅告警，不阻塞进入菜单），避免只有新建节点或手动重启隧道时才修复。无 OpenRC PID 1 的容器仍需在容器启动流程中运行 cron。

### 2026.11.05

- 修复重新部署伪装站时被自己的 Caddy 拦住：上一次部署中断后 Caddy 仍占用 `127.0.0.1:8443`（systemd/OpenRC 托管时没有 PID 文件，状态文件也可能丢失），脚本会误报"回环端口 8443 已被占用"且无法从菜单自救。现在按监听进程的 cmdline 判定占用者是否为 `${CADDY_BIN}`，是自己的实例就放行并交由后续服务重启接管端口；占用者是其他程序时仍照原样拒绝。放行时刻意不提前停服，避免配置写入或 Caddyfile 校验失败时把现有伪装站打死。
- 修复每次进入主菜单都阻塞约 6 秒：`config.json` 的 `ntp` 已是脚本管理的默认值时，`_time_prepare_ntp_config_locked` 会无条件重跑三个 SNTP 探测，而不可达时间源各自要等满超时。现在结论未变化且 `${SINGBOX_DIR}/time-sync.json` 的探测时间在 TTL（默认 6 小时，`TIME_PROBE_CACHE_TTL` 可覆盖，设为 0 关闭）内直接复用，不再重复探测；`[11] 时间诊断/校时` 仍始终强制实测。实测启动耗时从约 6.3 秒降到约 0.25 秒。
- 修复 443 被节点占用时申请证书必然卡住：`_camouflage_default_scope` 在 443 被占用时只能选 loopback，而 loopback 站点的 `bind 127.0.0.1` 会被 Caddy 的 auto_https 继承给 ACME challenge 服务器，实测 `:80` 变成 `127.0.0.1:80`，Let's Encrypt 从公网无法访问，HTTP-01 必然失败并卡满 180 秒超时后回滚。现在 loopback + ACME 模式会额外生成一个 `http://:80 { bind 0.0.0.0 }` 站点，把 challenge 拉回对外监听（实测恢复为 `*:80`），回环站点本身仍只绑 `127.0.0.1`。custom 证书模式与 public 模式不生成该站点。
- `tests/test_caddy_camouflage.sh` 增加回归用例：自身实例占用 8443 时放行且不提前停服，其他程序占用时仍拒绝部署；loopback+ACME 必须生成对外 `:80` challenge 站点而回环站点仍只绑 `127.0.0.1`；custom 与 public 模式不得重复声明 `:80`。
- 修复"切换伪装域名后组合配置校验失败"的误诊与死锁：当节点的 `certificate_path` 指向已不存在的证书（更换/卸载伪装站时删掉了证书，但节点仍引用旧路径）时，`sing-box` 会直接 FATAL，之后每一次伪装域名事务都在预检阶段失败，用户只看到"切换失败"而不知道根因在证书缺失，且无法从菜单自救。现在事务入口先执行 `_camouflage_repair_orphan_certs`，把这类节点指回当前有效的伪装站证书与域名；没有可替代证书时明确提示"请先用 [21] 部署或 [5] 改证书"而不是静默失败。校验失败且输出含 `read certificate` 时追加同样的提示。
- `tests/test_caddy_camouflage.sh` 增加孤儿证书用例：能识别指向缺失证书的节点、可指回现存证书、修复后无残留缺失路径、无可用替代证书时拒绝静默修复。
