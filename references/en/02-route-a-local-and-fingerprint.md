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
For users building or wrapping a lightweight Chrome/Edge launcher (see bundled reference scripts [../../scripts/route-a1-browser-launcher.py](../../scripts/route-a1-browser-launcher.py), [../../scripts/route-a1-browser-session.mjs](../../scripts/route-a1-browser-session.mjs), and [../../assets/route-a1-nodes.example.json](../../assets/route-a1-nodes.example.json)):
- **One Stable Node ID = One Dedicated `user-data-dir` + Dedicated Proxy Port**: Persist node identity and exclusive locks per profile/node/port so cookies, LocalStorage, IndexedDB, and caches are never shared across nodes. **Do not share one mixed port across multiple nodes and switch upstream nodes mid-session**, or an existing profile will silently egress through the new node.
- **Verify & Align Environment to Active Node**: Before launching, verify the node's proxy port matches your known `<RESIDENTIAL_EGRESS_IP>` (never treat an unverified first echo as the baseline), then inject/verify:
  - **Locale & Language** (e.g., US node → `en-US`, TW node → `zh-TW`);
  - **Timezone** (on Windows Chrome, inject via CDP `Emulation.setTimezoneOverride` and read back from the page — `TZ` env vars alone do not override Windows Chrome page timezone);
  - **Remote DNS** (`--host-resolver-rules="MAP * ~NOTFOUND, EXCLUDE 127.0.0.1"` plus independent proxy DNS log verification — geo metadata alone never proves DNS path).
- **Boundary Reminder**: Even with per-node auto-match, this remains **app-level isolation (not OS Fail-Closed)** and is not kernel-level Canvas/WebGL spoofing. Always refuse to launch on probe failure, IP drift, or profile identity mismatch — never fall back to direct egress.

#### 2.2 Six Field-Tested Windows Chrome / Edge Gotchas
1. **Chrome 136+ / Edge 136+ CDP Default-Dir Check vs. `clean_env`**: When stripping proxy/credential env vars before spawning Chrome/Edge, **keep the real OS user's `USERPROFILE`, `LOCALAPPDATA`, and `APPDATA`** (isolate only `--user-data-dir`, `HOME`, and `TEMP`/`TMP`). Overwriting `LOCALAPPDATA` breaks Chromium `PathService`, causing a fail-closed `DevTools remote debugging requires a non-default data directory` error even with `--user-data-dir`.
2. **Windows Chrome Ignores `TZ`**: Inject timezone via CDP `Emulation.setTimezoneOverride`, read it back on the initial tab, and enable `Target.setAutoAttach` (including `iframe` targets) so cross-site iframes align too (audit Workers/Service Workers separately).
3. **WebRTC Requires Both Flag & Profile Prefs**: Use `--webrtc-ip-handling-policy=disable_non_proxied_udp` (not the commonly mistyped `--force-webrtc-ip-handling-policy`), write `webrtc.ip_handling_policy` in `Default/Preferences`, verify no URL exceptions exist, and confirm zero ICE candidates in-page.
4. **Windows Registry External Extensions & Process Trees**: Even a fresh `--user-data-dir` reads `Software\Google\Chrome\Extensions\`; pass `--disable-extensions`, `--disable-sync`, and `--disable-background-networking`, and pair profile/node/port locks with a Windows Job Object to prevent profile reuse and orphan child processes.
5. **Loopback Proxy Bypass (`<-loopback>`)**: Chromium bypasses proxies for loopback by default; pass `--proxy-bypass-list=<-loopback>` when verifying local proxy-outage canaries.
6. **Kernel-Level IPv6 Reachability Probes**: Chrome issues internal `UDP_CONNECT` route checks to `[2001:4860:4860::8888]:443` and Edge to `[2603:1020:201:10::10f]:443` (zero UDP payload bytes sent) — another reminder that A1 is app-level only, not OS Fail-Closed.

> **Why Route A1 Prefers Local Chrome/Edge Over Heavy Open-Source Anti-Detect Kernels (e.g. Camoufox)**: Field testing showed Camoufox's Windows package is ~1.3 GB with a non-resumable GitHub Releases fetcher plus Playwright and 40+ Python dependencies, making it brittle on slow or throttled links. The bundled Chrome/Edge launcher requires 0 MB extra browser download while covering per-node profile isolation, CDP timezone, WebRTC dual-lock, and proxy-outage refusal. If you need stronger isolation than app-level separation, upgrade to [Route B (VM + OpenWrt Fortress)](03-route-b-vm-openwrt-fortress.md).

> **Author's Tip**: For early setup tasks like building a fingerprint browser launcher or proxy wrapper, prefer using **GPT / Codex** so you never need to touch or rely on Claude before your isolated environment is verified.

### 3. CLI Side: Split Neutral Preflight and Approved Launch (Never Chain Together)

The local proxy must expose an **HTTP or mixed port** — do not pass a raw SOCKS URL directly to Claude Code CLI. In S0, verify local listener status, declared protocol, and trusted executable path offline (print env var names and desensitized status only, never values that may contain proxy credentials). The snippets below are **templates**; never treat Stage S1 exit code 0 as launch authorization, and never let Web S1 pass authorize CLI launch.

#### S1: Neutral Functional Check Only (Tier-B)

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

*(PowerShell 5.1 drops empty string arguments like `--noproxy ''`, so we pass the reserved non-matching domain `no-proxy.invalid`. The Bash template runs inside a subshell `( ... )` so `exit 2` does not close an interactive terminal if pasted directly.)*

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

Note: `curl -4` to `127.0.0.1` only constrains loopback address family and does not prove upstream IPv6 blocking or app compliance. Separately inspect DNS path, WebRTC, and proxy-failure behavior in the target browser (CLI has no WebRTC check). Do not treat locale/language alignment as a security control.

#### S2/S3: Separate User-Approved Launch (Tier-C)

Run under a dedicated, restricted OS user account and audited project directory with an explicit private config directory (cleaning env vars does **not** switch OS users). **Do not auto-chain this after S1**, and do not inherit credentials.

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

```bash
(
  cd -- '<AUDITED_PROJECT_DIR>' || exit 2
  env -i HOME='<PRIVATE_HOME>' PATH=/usr/bin:/bin TERM="${TERM:-dumb}" \
    HTTP_PROXY='http://127.0.0.1:<HTTP_PORT>' HTTPS_PROXY='http://127.0.0.1:<HTTP_PORT>' \
    NO_PROXY=localhost,127.0.0.1 CLAUDE_CONFIG_DIR='<PRECREATED_PRIVATE_CONFIG_DIR>' \
    '<ABSOLUTE_TRUSTED_CLI>'
)
```

This strips `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, custom base URLs, and inherited proxy vars. Note that env cleanup does not override project-level settings, managed policies, OS credential stores, or child-process sockets — audit those separately. The Windows example supports trusted native `.exe` binaries only (never implicit PATH lookup or `.bat`/`.cmd`), and a minimal `PATH` may require explicit verification if your workflow invokes tools such as `git`.

---

## Route A2: Local Whole-Machine Protection (Reference Design, Verify Per Platform)

Requires **TUN capture + IPv4-only + OS firewall outbound default-deny**. Untested platforms stay `unknown`:

| Platform | Firewall Mechanism | Mandatory Checks (Keep Rollback Before Tier-C) | Status in Repo |
|---|---|---|---|
| **Windows** | Local GPO (Domain/Private/Public default-block inbound & outbound, local rule merge disabled) | Allow trusted proxy binary path, TUN interface, loopback `/8`, exact DHCP/mgmt exceptions; disable NIC IPv6 | Can reuse `guest-egress-guard.ps1` verification pattern |
| **macOS** | Dedicated `pf` anchor (do not overwrite global `pf.conf`) | Verify dynamic `utun` interface name, DNS/mDNS handling, post-sleep rule persistence | Reference design (no bundled installer) |
| **Linux** | `nftables` (match proxy UID/cgroup) + policy routing | Verify `systemd-resolved`, IPv6 disablement, reboot persistence | Reference design (no bundled installer) |

**A2 Negative Requirement**: Switching Wi-Fi, sleep/resume, or blocking the upstream proxy entry must never cause ordinary processes to fall back to direct egress.
