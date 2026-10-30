# AGENTS.md — 本仓库的 agent 工作约定

面向在本仓库执行任务的 AI agent（以及新加入的人）。规则是**约束**，不是建议；与本文件冲突的临时指令，以用户当次明确指令为准，但「必须执行完整测试」与「公开输出脱敏」两条不可豁免。

## 仓库概览

单仓库、纯 Bash、无构建步骤：

| 文件 | 作用 |
| --- | --- |
| `singbox.sh` | 主脚本：主菜单、节点创建/修改/删除、服务控制、`[20]` 批量换 SNI、`[21]` 伪装域名（Caddy） |
| `advanced_relay.sh` | 落地/中转/第三方节点导入/端口转发（自身菜单标注 `v19`） |
| `parser.sh` | 分享链接解析，被主脚本 sourcing |
| `xray_manager.sh` | Xray 核心与节点管理 |
| `tests/test_*.sh` | 回归测试，CI 逐个执行 |
| `web/` | Caddy 伪装站页面与静态资源 |
| `.github/workflows/verify.yml` | 唯一的 CI：`bash -n` + 三个测试脚本 |

## 每次任务完成后的固定流程

任务指用户提出的一次修改请求。**只有全部检查通过才提交 PR**；任何一项失败就先修复，不要带着失败提交。

1. **语法检查**（与 CI 完全一致）
   ```bash
   for f in singbox.sh advanced_relay.sh parser.sh xray_manager.sh \
            tests/test_node_naming.sh tests/test_batch_sni.sh tests/test_caddy_camouflage.sh; do
       bash -n "$f"
   done
   ```
2. **运行全部测试**
   ```bash
   bash tests/test_node_naming.sh
   bash tests/test_batch_sni.sh
   bash tests/test_caddy_camouflage.sh
   ```
   Windows 下用 Git Bash；测试会拦截交互式读取（`exec < /dev/null`），卡住即视为失败。
3. **全部通过 → 直接提交并开 PR**，不要停下来问「要不要提交」。
4. **有失败 → 不提交**，修复后回到第 1 步；确实无法在本机修复时，向用户说明失败项与原因。

### 提交与 PR 的具体做法

- 从最新 `origin/main` 拉分支：`git checkout -b <type>/<short-slug> origin/main`。
- 分支名用 `feat|fix|chore|refactor|docs` 前缀加短横线小写描述。
- 一个 PR 一件事；不要把无关重构混进同一个 PR。
- commit message 与 PR 标题用中文、`type: 摘要` 形式（仓库现有历史即此风格）。
- PR 正文包含：背景/问题、改动要点、测试结果（列出实际跑过的命令）、未覆盖项。
- **不要**自行合并 PR、不要自行打 tag、不要自行 push 到 `upstream`（`0xdabiaoge/singbox-lite`）。只 push 到 `origin` 的功能分支。

## 版本号

`singbox.sh` 顶部的 `export SCRIPT_VERSION="<纯数字>"` 参与两件事：自动更新的**防降级比较**（低于本地版本会被拒绝）与主菜单标题显示。

规则：

- **任何对外行为变化（新功能、行为修正）都必须递增版本号**，整数 +1。
- README 第 5 行的 `singbox.sh v<数字>` 必须与脚本一致；`tests/test_caddy_camouflage.sh` 已断言二者相等。
- 只改文档/注释/测试时可不递增，但**同一 PR 内有功能改动就必须递增**。
- 版本号只在确认状态的文件里写一次，不要在多个位置重复定义。

## 代码约定

### 文件与函数

- 保持现有结构：`# --- 功能块名 ---` / `# --- 功能块名结束 ---` 作为锚点。**测试会用这些锚点 `sed` 抽取函数块**（例如伪装域名块的抽取），改动锚点文字会直接打断测试。
- 新增可复用逻辑优先抽函数；同一段证书选择、事务流程出现第二次就抽象，不要复制粘贴（仓库已有 `_camouflage_tx`、`_choose_tls_material` 这类先例）。
- 修改配置一律走 `_atomic_modify_json` / `_atomic_modify_yaml`；涉及多文件改写必须放在事务封装里（状态锁 + 快照 + 组合校验 + 单次重启 + 失败回滚）。
- `config.json` 与 `relay.json` 始终一起校验：`_check_combined_config_files`，不要只验主配置。

### 风格

- 中文注释解释**为什么**，不写「这里遍历数组」这类复述代码的注释。
- 变量一律 `local`；外部可见的用 `export` 并在顶部集中声明。
- 用户可见输出走 `_info` / `_success` / `_warn` / `_error`，不要裸 `echo` 做提示（菜单与表格除外）。
- 菜单编号、`case` 分支、菜单标题三处必须同步改；`tests/test_caddy_camouflage.sh` 有对应断言。
- 面向用户文本用中文，标识符/路径/命令保留英文。

### 新增测试

- 新增功能要同步扩写对应 `tests/test_*.sh`，断言实际行为而不是复制实现。
- 测试里不得依赖外网（DoH、GitHub 等一律用替身函数），不得依赖真实端口占用状态（用变量开关替代）。
- 测试文件同样要能通过 `bash -n`，且被加入 CI 的 `for f in ...` 列表。

### 平台注意

- 仓库脚本面向 **Linux** 运行；agent 可能在 Windows + Git Bash 下验证。写测试时避免依赖 POSIX 权限语义与 `-subj "/CN=..."` 这类会被 MSYS 路径转换破坏的参数，必要时按 `uname -s` 分支或改用配置文件。
- 路径比较在 MSYS 下不可靠（`/tmp/...` 与 `C:/...` 混用），断言路径时比对 `basename` 或固定后缀。

## 公开输出必须脱敏

会进入 commit message、PR 标题/正文、Issue、README、测试样例、CI 日志的内容，**写入前就用占位符**，不要先写真实值再回头改。

- 禁止：真实公网 IP/IPv6 段、真实域名、ASN、服务商名称、主机名、面板地址、Token、密码、私钥、Cookie、连接串。
- 测试与示例数据只用保留地址：IPv4 用 `192.0.2.0/24`、`198.51.100.0/24`、`203.0.113.0/24`；IPv6 用 `2001:db8::/32`；域名用 `example.com` / `example.org`。`127.0.0.1` 属正常回环引用，可用。
- 提交前用实际值扫一遍改动：
  ```bash
  git diff origin/main | grep -nE '(\d{1,3}\.){3}\d{1,3}|[A-Za-z0-9.-]+\.(com|net|org|cn|io|dev|xyz)'
  git log -1 --format=%B | grep -nE '<真实值>'
  ```
- 一旦发现已泄露：立即告知用户确切位置与内容，不要淡化，并提示旧提交/PR 正文历史不会因删除分支而消失。

## 危险操作

以下操作即使技术上可执行也**必须先获得用户明确确认**，并在执行前复述准确目标与影响：

- Git：`push --force`、`reset --hard`、`clean -fd`、`branch -D`、`commit --amend`、`rebase`、删除远程分支、丢弃未提交改动。
- 合并 PR、打 tag、推送 `upstream`、修改 CI/CD 配置。
- 递归删除、批量覆盖、删除配置/证书/密钥、数据库操作。
- 修改 systemd/OpenRC 服务、防火墙、计划任务、注册表。

只读检查、测试、lint、局部代码修改、加测试、更新文档不需要额外确认。

## 常见坑

- `singbox.sh` 会直接执行主菜单，**不能 `source` 整个文件**；测试必须按注释锚点抽取函数块。
- 证书续期后 sing-box 需要一次服务重启才会加载新证书；不要假设「写入证书路径 = 立即生效」。
- `443` 可能归 Reality、可能归 Caddy、也可能两者交替占用；涉及 443 的改动必须同时考虑配置侧冲突与系统监听，并保证失败时回滚到原状态。
- 复用伪装站的 ACME 证书时，客户端 `skip-cert-verify` / `insecure` / `allow_insecure` / `pinSHA256` 必须按证书来源推导，否则反而连不上。
