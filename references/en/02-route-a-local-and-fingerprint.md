# 02 | Route A: App-Level Separation (A1) & Local Whole-Machine Protection (A2)

> This playbook clearly separates two local approaches: **A1 is app-level separation (NOT OS Fail-Closed)**; **A2 relies on OS firewall whole-machine protection**.

---

## Route A1: Dedicated Fingerprint Browser + Clean CLI Subprocess (App-Level Separation)

### 1. Explicit Capability Boundary
- **What it achieves**: Separates Claude Web cookies, profile, and proxy egress from your daily browser, and binds Claude Code CLI to a dedicated HTTP/mixed proxy and isolated config directory.
- **What it does NOT achieve**: It is **not OS-level Fail-Closed**. It cannot stop already-running processes, browser extensions, or CLI child processes from bypassing proxy env vars on proxy failure, nor does it isolate the host filesystem.
- **Recommendation**: **Do not** install Claude Desktop bare-metal on the host under A1. If you need Desktop or OS/out-of-guest Fail-Closed boundaries, use [Route B (VM + OpenWrt Fortress)](03-route-b-vm-openwrt-fortress.md).

### 2. Web Side: Dedicated Fingerprint Browser Profile (Tier-B)
1. **Dedicated Proxy Binding**: Bind the isolated Profile to your fixed residential local proxy port and **disable automatic fallback to direct connection**.
2. **Leak Hygiene**: Disable or proxy WebRTC, enforce remote DNS resolution, and align timezone and locale with the egress region.
3. **Pre-Launch Check**: Verify the proxy port returns `<RESIDENTIAL_EGRESS_IP>` before opening the Profile.

#### 2.1 Advanced Practice: Per-Node Isolated Browser (Per-Node Auto-Match)
For users building or wrapping an open-source fingerprint browser launcher:
- **One Node = One Data Directory (Strict Cookie Isolation)**: Assign each proxy node its own `user-data-dir` (cookies, LocalStorage, IndexedDB, cache never shared) — conceptually one standalone browser per node.
- **Auto-Align Environment to Active Node**: Before launching, probe neutral egress metadata (region, timezone) via that node's proxy port and auto-align:
  - **Locale & Language** (e.g., US node → `en-US`, TW node → Traditional Chinese/TW region);
  - **Timezone & Browser Parameters** matching the egress location;
  - **Remote DNS** routed through the active node.
- **Boundary Reminder**: Even with per-node auto-match, this remains **app-level isolation (not OS Fail-Closed)**. Always refuse to launch if the probe fails or the egress drifts — never fall back to direct egress.

> **Author's Tip**: For early setup tasks like building a fingerprint browser launcher or proxy wrapper, prefer using **GPT / Codex** so you never need to touch or rely on Claude before your isolated environment is verified.

### 3. CLI Side: Split Neutral Preflight and Approved Launch (Never Chain Together)

The local proxy must expose an **HTTP or mixed port** — do not pass a raw SOCKS URL directly to Claude Code CLI. Verify the local listener and trusted executable path first. The snippets below are **templates**; never treat Stage S1 exit code 0 as launch authorization.

#### S1: Neutral Functional Check Only (Tier-B)

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

*(PowerShell 5.1 drops empty string arguments like `--noproxy ''`, so we pass the reserved non-matching domain `no-proxy.invalid`.)*

```bash
proxy='http://127.0.0.1:<HTTP_PORT>'
expected='<EXPECTED_IPV4>'
for site in https://api.ipify.org https://ifconfig.me/ip; do
    observed=$(env -i PATH=/usr/bin:/bin /usr/bin/curl -q -4 -fsS --proto '=https' --max-time 6 --noproxy no-proxy.invalid --proxy "$proxy" "$site") || exit 2
    [ "$observed" = "$expected" ] || exit 2
done
```

Separately inspect DNS path, WebRTC, and proxy-failure behavior in the target browser (CLI has no WebRTC check). Do not treat locale/language alignment as a security control.

#### S2/S3: Separate User-Approved Launch (Tier-C)

Run under a dedicated, restricted user account and audited project directory with an explicit private config directory. **Do not auto-chain this after S1**, and do not inherit credentials.

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

```bash
env -i HOME="<PRIVATE_HOME>" PATH=/usr/bin:/bin TERM="${TERM:-dumb}" \
  HTTP_PROXY='http://127.0.0.1:<HTTP_PORT>' HTTPS_PROXY='http://127.0.0.1:<HTTP_PORT>' \
  NO_PROXY=localhost,127.0.0.1 CLAUDE_CONFIG_DIR='<PRECREATED_PRIVATE_CONFIG_DIR>' \
  '<ABSOLUTE_TRUSTED_CLI>'
```

This strips `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, custom base URLs, and inherited proxy vars. Note that env cleanup does not override project-level settings, managed policies, OS credential stores, or child-process sockets — audit those separately.

---

## Route A2: Local Whole-Machine Protection (Reference Design, Verify Per Platform)

Requires **TUN capture + IPv4-only + OS firewall outbound default-deny**. Untested platforms stay `unknown`:

| Platform | Firewall Mechanism | Mandatory Checks (Keep Rollback Before Tier-C) | Status in Repo |
|---|---|---|---|
| **Windows** | Local GPO (Domain/Private/Public default-block inbound & outbound, local rule merge disabled) | Allow trusted proxy binary path, TUN interface, loopback `/8`, exact DHCP/mgmt exceptions; disable NIC IPv6 | Can reuse `guest-egress-guard.ps1` verification pattern |
| **macOS** | Dedicated `pf` anchor (do not overwrite global `pf.conf`) | Verify dynamic `utun` interface name, DNS/mDNS handling, post-sleep rule persistence | Reference design (no bundled installer) |
| **Linux** | `nftables` (match proxy UID/cgroup) + policy routing | Verify `systemd-resolved`, IPv6 disablement, reboot persistence | Reference design (no bundled installer) |

**A2 Negative Requirement**: Switching Wi-Fi, sleep/resume, or blocking the upstream proxy entry must never cause ordinary processes to fall back to direct egress.
