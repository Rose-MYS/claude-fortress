# 02｜路线 A：应用层轻量分流（A1）与本机整机防护（A2）

> 本手册明确区分两种本机方案的安全等级：**A1 是应用层分流（非 Fail-Closed）**；**A2 是依赖 OS 防火墙的本机整机防护**。

---

## 方案 A1：独立指纹浏览器 + Claude Code 干净子进程隔离（应用层分流）

### 1. 明确的能力边界（先讲清楚）
- **它能做到什么**：把 Claude Web 流量与日常浏览器在 Cookie、Profile、出口代理上分开；把 Claude Code CLI 绑定到指定 HTTP/mixed 代理与独立配置目录。
- **它做不到什么**：**不是 OS 级 Fail-Closed**。它无法阻止已启动程序、浏览器插件或 CLI 派生的子进程在代理失效后绕过环境变量直连公网，也无法隔离宿主机本地文件系统。
- **结论**：本路线**不建议在宿主机安装 Claude Desktop**；如需 OS/物理级防直连或防扫描宿主机，请选 [路线 B（VM 隔离堡垒）](03-route-b-vm-openwrt-fortress.md)。

### 2. Web 端：独立指纹浏览器配置要点（B 档）
1. **独占代理绑定**：在独立 Profile 中绑定固定住宅本地代理端口，**禁用“代理不可用时回退直连”**。
2. **泄露防护**：禁用或代理化 WebRTC；启用远程 DNS 解析；对齐与出口一致的时区与语言。
3. **启动前先过门控**：先验证代理端口返回预期 `<RESIDENTIAL_EGRESS_IP>` 再打开该 Profile。

#### 2.1 进阶实践：一节点一独立浏览器环境（Per-Node Auto-Match）
对于基于本机 Chrome/Edge 自建或二次封装轻量启动器的用户（可参考本包内置通用脚本 [../scripts/route-a1-browser-launcher.py](../scripts/route-a1-browser-launcher.py)、[../scripts/route-a1-browser-session.mjs](../scripts/route-a1-browser-session.mjs) 与示例配置 [../assets/route-a1-nodes.example.json](../assets/route-a1-nodes.example.json)），建议采用**「稳定节点 ID 绑定 + 启动时校验对齐」**模式：
- **一节点一独占数据目录 + 独占代理端口**：每个稳定节点 ID 绑定独立 `user-data-dir` 与独占本地代理端口（Cookie、LocalStorage、IndexedDB、缓存互不共享），并在目录内持久记录节点身份与锁文件；**不要让多个节点共用同一个混合端口并在运行时随意切节点**，否则旧目录会经新节点继续联网。
- **按当前节点校验并对齐属性**：启动器先经该节点代理端口探测中性出口信息（IPv4 必须严格匹配已知的 `<RESIDENTIAL_EGRESS_IP>`，绝不用待验回显给自己设基准），再为该实例注入/校验一致的：
  - **语言与区域设置**（如台湾节点匹配 `zh-TW`，美国节点匹配 `en-US`）；
  - **时区**（Windows Chrome 需通过 CDP `Emulation.setTimezoneOverride` 实际注入并在页面读回，不能只靠环境变量）；
  - **远程 DNS 解析路径**（`--host-resolver-rules="MAP * ~NOTFOUND, EXCLUDE 127.0.0.1"` + 代理侧远程 DNS 日志单独核验，不能由地区元数据反推）。
- **边界提醒**：即便做了“一节点一环境 + 自动对齐”，该方案本质仍属于**应用层隔离（非 OS 级 Fail-Closed）**，且并非内核级 Canvas/WebGL 指纹伪装；启动器务必在探测失败、出口偏离预期或目录错绑时**拒绝拉起浏览器**，绝不静默回退直连。

#### 2.2 Windows Chrome / Edge 实机必避 6 坑（已实测验证）
1. **Chrome 136+ / Edge 136+ 的 CDP 默认目录校验与 `clean_env` 冲突**：清理浏览器子进程环境变量（清除代理/凭据变量）时，**必须保留真实 OS 用户的 `USERPROFILE`、`LOCALAPPDATA`、`APPDATA`**（仅隔离 `--user-data-dir`、`HOME`、`TEMP`/`TMP`）。若覆写 `LOCALAPPDATA`，Chromium `PathService` 会获取失败并 fail-closed 报错 `DevTools remote debugging requires a non-default data directory`。
2. **Windows Chrome 不吃 `TZ` 环境变量**：必须经 CDP `Emulation.setTimezoneOverride` 注入并在首标签页读回校验，同时对新标签页与跨站 `iframe` 开启 `Target.setAutoAttach`（Worker / Service Worker 仍需另行核验）。
3. **WebRTC 必须命令行 + Profile 偏好双锁**：使用 `--webrtc-ip-handling-policy=disable_non_proxied_udp`（注意不是容易写错的 `--force-webrtc-ip-handling-policy`），同时写入隔离 Profile `Default/Preferences` 的 `webrtc.ip_handling_policy` 并核对无 URL 例外，再在页面实测 ICE 候选为空。
4. **独立 `user-data-dir` 挡不住 Windows 注册表外部扩展**：启动时务必加 `--disable-extensions`、`--disable-sync`、`--disable-background-networking`，并用目录/节点/端口锁 + Windows Job Object 防止进程复用与关闭后残留子进程。
5. **本地断线验收须防回环绕过**：Chromium 默认对回环地址绕过代理，测试代理断线哨兵时必须显式加 `--proxy-bypass-list=<-loopback>`。
6. **内核级 IPv6 路由探测边界**：Chrome 内部会向 `[2001:4860:4860::8888]:443`、Edge 会向 `[2603:1020:201:10::10f]:443` 发起底层 `UDP_CONNECT` 路由可达性检查（无 UDP 发送字节），再次说明 A1 不替代 OS/网关级 Fail-Closed。

> **为什么路线 A1 优先推荐本机 Chrome/Edge 启动器而非重型开源反检测内核（如 Camoufox）**：实测 Camoufox Windows 内核包约 1.3 GB 且自带下载器不支持断点续传，还依赖 Playwright 与 40+ Python 包，在弱网或 GitHub Releases 限速环境下极易断连失败；而本机 Chrome/Edge 轻量启动器 0 MB 额外下载、仅用系统标准工具即可完成一节点一目录 + CDP 时区 + WebRTC 双锁 + 断代理拒直连。若确实需要更强隔离，建议直接升级 [路线 B（VM 隔离堡垒）](03-route-b-vm-openwrt-fortress.md)。

> **作者建议**：搭建指纹浏览器及配套代理封装等前期环境搭建工作，首选使用 **GPT / Codex** 协助完成（在正式隔离环境验收通过前，无需动用或接触 Claude）。

### 3. CLI：分成中性预检与获批后启动（两段不得串联）

本地代理监听必须是 HTTP/mixed，不把纯 SOCKS 地址直接传给 CLI。先在 S0 离线核对代理监听与配置声明协议，以及可信程序绝对路径（仅展示环境变量名和脱敏状态，不打印可能含凭据的值）。以下示例均为**模板**，不依赖真实服务做预检；不要把第一段的退出码当作启用授权，也不要将 Web 验收通过当作 CLI 放行依据。

#### S1：只运行中性检查（B 档）

```powershell
$proxy = 'http://127.0.0.1:<HTTP_PORT>'
$expected = '<RESIDENTIAL_EGRESS_IP>'
$curl = Join-Path ([Environment]::SystemDirectory) 'curl.exe'
if ($proxy -notmatch '^http://127[.]0[.]0[.]1:[0-9]{1,5}$' -or $expected -notmatch '^[0-9.]+$') { throw 'Set private values first' }
foreach ($site in 'https://api.ipify.org','https://ifconfig.me/ip') {
    $observed = & $curl -q -4 -fsS --proto '=https' --max-time 6 --noproxy no-proxy.invalid --proxy $proxy $site
    if ($LASTEXITCODE -ne 0 -or ($observed -join '').Trim() -ne $expected) { throw 'Neutral IPv4 observation failed' }
}
```

PowerShell 5.1 不传空字符串给原生命令的 `--noproxy`；使用不匹配这些固定端点的保留域。若系统配置了用户 TLS/代理环境，先用专用干净账户再测试。Bash 示例用同样的参数校验与子 shell 包裹（直接粘贴到交互式终端时避免 `exit 2` 关闭当前 shell），无 Claude 调用：

```bash
(
  proxy='http://127.0.0.1:<HTTP_PORT>'
  expected='<RESIDENTIAL_EGRESS_IP>'
  printf '%s' "$proxy" | grep -Eq '^http://127\.0\.0\.1:[0-9]{1,5}$' || { echo 'Invalid proxy'; exit 2; }
  printf '%s' "$expected" | grep -Eq '^[0-9.]+$' || { echo 'Invalid expected IPv4'; exit 2; }
  for site in https://api.ipify.org https://ifconfig.me/ip; do
    observed=$(env -i PATH=/usr/bin:/bin /usr/bin/curl -q -4 -fsS --proto '=https' --max-time 6 --noproxy no-proxy.invalid --proxy "$proxy" "$site") || exit 2
    [ "$observed" = "$expected" ] || exit 2
  done
)
```

注意：对 `127.0.0.1` 跑 `curl -4` 只能约束本地回环地址族，无法证明代理上游未走 IPv6 或应用本身遵守代理；还要在目标浏览器中分别核验 DNS 路径、WebRTC、代理失效行为（CLI 无 WebRTC 验收项）。不要把地区/语言对齐当作安全控制。

#### S2/S3：用户独立批准后，才由本人启动（C 档）

在独立、受限的 OS 用户和已审计项目目录中，显式使用不是从日常环境继承的配置目录（注意：清理环境变量本身**不能切换 OS 用户**）。确认首次接触的目标、网络和安装来源。下例**不得接在 S1 末尾自动执行**，也不传凭据或从旧配置复制认证态。

```powershell
$start = New-Object Diagnostics.ProcessStartInfo
$start.FileName = '<ABSOLUTE_TRUSTED_NATIVE_CLI_EXE>'
$start.WorkingDirectory = '<AUDITED_PROJECT_DIR>'
$start.UseShellExecute = $false
$start.EnvironmentVariables.Clear()
foreach ($name in 'SystemRoot','WINDIR','USERPROFILE','LOCALAPPDATA','APPDATA','TEMP','TMP') {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ($value) { $start.EnvironmentVariables[$name] = $value }
}
$start.EnvironmentVariables['PATH'] = [Environment]::SystemDirectory
$start.EnvironmentVariables['HTTP_PROXY'] = 'http://127.0.0.1:<HTTP_PORT>'
$start.EnvironmentVariables['HTTPS_PROXY'] = 'http://127.0.0.1:<HTTP_PORT>'
$start.EnvironmentVariables['NO_PROXY'] = 'localhost,127.0.0.1'
$start.EnvironmentVariables['CLAUDE_CONFIG_DIR'] = '<PRECREATED_PRIVATE_CONFIG_DIR>'
if ($start.FileName -match '[<>]' -or !(Test-Path -LiteralPath $start.FileName -PathType Leaf) -or
    !(Test-Path -LiteralPath $start.WorkingDirectory -PathType Container) -or
    !(Test-Path -LiteralPath $start.EnvironmentVariables['CLAUDE_CONFIG_DIR'] -PathType Container) -or
    $start.EnvironmentVariables['HTTPS_PROXY'] -notmatch '^http://127[.]0[.]0[.]1:[0-9]{1,5}$') { throw 'Set vetted local paths and proxy first' }
[Diagnostics.Process]::Start($start) | Out-Null
```

Bash 用干净环境白名单（先校验绝对路径并显式进入已审核项目目录）：

```bash
(
  cd -- '<AUDITED_PROJECT_DIR>' || exit 2
  env -i HOME='<PRIVATE_HOME>' PATH=/usr/bin:/bin TERM="${TERM:-dumb}" \
    HTTP_PROXY='http://127.0.0.1:<HTTP_PORT>' HTTPS_PROXY='http://127.0.0.1:<HTTP_PORT>' \
    NO_PROXY=localhost,127.0.0.1 CLAUDE_CONFIG_DIR='<PRECREATED_PRIVATE_CONFIG_DIR>' \
    '<ABSOLUTE_TRUSTED_CLI>'
)
```

不继承 `ANTHROPIC_API_KEY`、`ANTHROPIC_AUTH_TOKEN`、自定义服务基址或其他凭据变量。环境清理不阻止项目设置、组织托管配置、系统凭据存储或子进程联网，必须另行核对；这依然不是 OS 级隔离。Windows 示例仅支持可信的原生 EXE，不从 PATH 取程序或隐式执行批处理；另注意最小 `PATH` 可能影响 CLI 调用 `git` 等子工具，须按需显式核验。

---

## 方案 A2：本机整机防护（参考设计，按平台核验）

当整台本机统一走单一固定出口时，必须同时满足 **TUN 接管 + IPv4 Only + OS 防火墙出站默认阻断**。不同平台能力差异大，未验证平台一律标 `unknown`：

| 平台 | 防火墙机制 | 必核项（C 档改动前留回滚脚本） | 当前包内状态 |
|---|---|---|---|
| **Windows** | 本地组策略（GPO）三配置文件默认阻断入/出站 + 关闭本地规则合并 | 放行指定代理核心（带完整路径）、TUN 接口、回环 `/8`、精确 DHCP/管理例外；禁用网卡 IPv6 绑定 | 可复用路线 B 的 `guest-egress-guard.ps1` 校验思路 |
| **macOS** | `pf` 锚点规则（独立 anchor，不覆盖系统全局 pf.conf） | 核对 utun 动态接口名、mDNS/DNS 接管、睡眠唤醒后规则是否失效 | 参考设计（无内置安装器） |
| **Linux** | `nftables`（按代理用户 UID/cgroup 放行出站）+ 策略路由 | 核对 `systemd-resolved` DNS 接管、IPv6 禁用、重启持久化 | 参考设计（无内置安装器） |

**A2 负向验收硬要求**：切换 Wi-Fi / 休眠唤醒 / 临时阻断上游代理入口后，本机任何普通进程均不得回退直连公网，否则不通过。
