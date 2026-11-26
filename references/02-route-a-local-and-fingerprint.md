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
对于基于开源方案自建或二次封装指纹浏览器启动器的用户，可以采用**「节点绑定 + 启动时自动对齐环境」**模式：
- **一节点一数据目录（Cookie 完全隔离）**：每个代理节点对应独立的 `user-data-dir`（Cookie、LocalStorage、IndexedDB、缓存互不共享），逻辑上等价于“每个节点一个独立浏览器”，彻底避免跨节点混用同一份会话与 Cookie。
- **按当前节点自动联动属性**：启动器先经当前代理端口探测中性出口信息（地区、时区），自动为该节点对应的浏览器实例匹配并注入一致的：
  - **语言与区域设置**（如台湾节点匹配台湾区域与语言，美国节点匹配美区 `en-US`）；
  - **时区与浏览器环境参数**（与出口所在地保持一致）；
  - **DNS 解析路径**（强制经该节点远程解析，避免本地 DNS 泄露）。
- **边界提醒**：即便做了“一节点一环境 + 自动对齐”，该方案本质仍属于**应用层隔离（非 OS 级 Fail-Closed）**；启动器务必在探测失败或出口偏离预期时**拒绝拉起浏览器**，绝不静默回退直连。

> **作者建议**：搭建指纹浏览器及配套代理封装等前期环境搭建工作，首选使用 **GPT / Codex** 协助完成（在正式隔离环境验收通过前，无需动用或接触 Claude）。

### 3. CLI：分成中性预检与获批后启动（两段不得串联）

本地代理监听必须是 HTTP/mixed，不把纯 SOCKS 地址直接传给 CLI。先核对代理监听和可信程序绝对路径。以下示例均为**模板**，不依赖真实服务做预检；不要把第一段的退出码当作启用授权。

#### S1：只运行中性检查（B 档）

```powershell
$proxy = 'http://127.0.0.1:<HTTP_PORT>'
$expected = '<EXPECTED_IPV4>'
$curl = Join-Path ([Environment]::SystemDirectory) 'curl.exe'
if ($proxy -notmatch '^http://127[.]0[.]0[.]1:[0-9]{1,5}$' -or $expected -notmatch '^[0-9.]+$') { throw 'Set private values first' }
foreach ($site in 'https://api.ipify.org','https://ifconfig.me/ip') {
    $observed = & $curl -q -4 -fsS --proto '=https' --max-time 6 --noproxy no-proxy.invalid --proxy $proxy $site
    if ($LASTEXITCODE -ne 0 -or ($observed -join '').Trim() -ne $expected) { throw 'Neutral IPv4 observation failed' }
}
```

PowerShell 5.1 不传空字符串给原生命令的 `--noproxy`；使用不匹配这些固定端点的保留域。若系统配置了用户 TLS/代理环境，先用专用干净账户再测试。Bash 示例用同样的限定，无 Claude 调用：

```bash
proxy='http://127.0.0.1:<HTTP_PORT>'
expected='<EXPECTED_IPV4>'
for site in https://api.ipify.org https://ifconfig.me/ip; do
    observed=$(env -i PATH=/usr/bin:/bin /usr/bin/curl -q -4 -fsS --proto '=https' --max-time 6 --noproxy no-proxy.invalid --proxy "$proxy" "$site") || exit 2
    [ "$observed" = "$expected" ] || exit 2
done
```

还要在目标浏览器中分别核验 DNS 路径、WebRTC、代理失效行为；CLI 无 WebRTC 验收项。不要把地区/语言对齐当作安全控制。

#### S2/S3：用户独立批准后，才由本人启动（C 档）

在独立、受限的用户和已审计项目目录中，显式使用不是从日常环境继承的配置目录。确认首次接触的目标、网络和安装来源。下例**不得接在 S1 末尾自动执行**，也不传凭据或从旧配置复制认证态。

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
if ($start.FileName -match '[<>]' -or $start.WorkingDirectory -match '[<>]' -or
    $start.EnvironmentVariables['HTTPS_PROXY'] -match '[<>]' -or $start.EnvironmentVariables['CLAUDE_CONFIG_DIR'] -match '[<>]') { throw 'Set vetted local paths and proxy first' }
[Diagnostics.Process]::Start($start) | Out-Null
```

Bash 用干净环境白名单（只允许核验过的本机绝对路径）：

```bash
env -i HOME="<PRIVATE_HOME>" PATH=/usr/bin:/bin TERM="${TERM:-dumb}"   HTTP_PROXY='http://127.0.0.1:<HTTP_PORT>' HTTPS_PROXY='http://127.0.0.1:<HTTP_PORT>'   NO_PROXY=localhost,127.0.0.1 CLAUDE_CONFIG_DIR='<PRECREATED_PRIVATE_CONFIG_DIR>'   '<ABSOLUTE_TRUSTED_CLI>'
```

不继承 `ANTHROPIC_API_KEY`、`ANTHROPIC_AUTH_TOKEN`、自定义服务基址或其他凭据变量。环境清理不阻止项目设置、组织托管配置、系统凭据存储或子进程联网，必须另行核对；这依然不是 OS 级隔离。Windows 示例仅支持可信的原生 EXE，不从 PATH 取程序或隐式执行批处理。

---

## 方案 A2：本机整机防护（参考设计，按平台核验）

当整台本机统一走单一固定出口时，必须同时满足 **TUN 接管 + IPv4 Only + OS 防火墙出站默认阻断**。不同平台能力差异大，未验证平台一律标 `unknown`：

| 平台 | 防火墙机制 | 必核项（C 档改动前留回滚脚本） | 当前包内状态 |
|---|---|---|---|
| **Windows** | 本地组策略（GPO）三配置文件默认阻断入/出站 + 关闭本地规则合并 | 放行指定代理核心（带完整路径）、TUN 接口、回环 `/8`、精确 DHCP/管理例外；禁用网卡 IPv6 绑定 | 可复用路线 B 的 `guest-egress-guard.ps1` 校验思路 |
| **macOS** | `pf` 锚点规则（独立 anchor，不覆盖系统全局 pf.conf） | 核对 utun 动态接口名、mDNS/DNS 接管、睡眠唤醒后规则是否失效 | 参考设计（无内置安装器） |
| **Linux** | `nftables`（按代理用户 UID/cgroup 放行出站）+ 策略路由 | 核对 `systemd-resolved` DNS 接管、IPv6 禁用、重启持久化 | 参考设计（无内置安装器） |

**A2 负向验收硬要求**：切换 Wi-Fi / 休眠唤醒 / 临时阻断上游代理入口后，本机任何普通进程均不得回退直连公网，否则不通过。
