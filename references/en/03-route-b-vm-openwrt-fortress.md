# 03 | Route B: Windows VM + Dedicated OpenWrt Isolated Gateway (Full Field Blueprint · Modular)

> **How to use this playbook**: Distilled and desensitized from the author's long-running production **VM + dedicated OpenWrt gateway + Windows guest GPO** setup, split into **Part 1: Minimal Viable Core (5-Step Beginner Walkthrough)** and **Part 2: Optional Advanced Add-Ons**.
> - **Beginners** can follow the 5 MVP steps directly using the parameterized examples;
> - **Experienced users** can keep the two-layer Fail-Closed core and swap in their own proxy protocol, subnets, or automation.
> - **Boundary reminder**: Scripts and templates are generic parameterized references and **cannot vouch for any user's specific machine**; you must personally complete cold boot, reload failure, and entry-block self-verification (Step 5) before production use. Apply Tier A/B/C authorization from [SKILL](../../SKILL.md) by real-world consequence.

---

## 0. Architecture Overview (Why In-Guest Firewall Alone Is Not Enough)

An in-guest Windows firewall or watchdog alone still leaves a cold-boot window before services/GPO settle and is vulnerable to policy drift. Route B locks egress with **two independent layers** (an out-of-guest OpenWrt gateway + in-guest Windows GPO):

```text
Windows 11 Guest (e.g. 192.168.242.129, single virtual NIC Ethernet0)
  │ Dedicated VMware LAN Segment (e.g. VM-Egress-Isolated)
  ▼
Dedicated OpenWrt Gateway VM (LAN: 192.168.242.1 / WAN: 192.168.125.3)
  │ nftables default-deny forwarding + IPv6 forwarding disabled
  │ Public forward whitelist allows ONLY <ENTRY_IP>:<ENTRY_PORT>/TCP
  ▼
VMware VMnet8 NAT → Host Physical Network (bypass host TUN via vmnat.exe if needed, Step 4)
  ▼
Upstream Residential Proxy Node → Fixed Residential Egress <RESIDENTIAL_EGRESS_IP>
```

**Prerequisites (VMware Workstation + Dedicated OpenWrt + Windows 11 only)**:
- Recommended host: ≥ 16 GB RAM, ≥ 80 GB free disk;
- Verify offline media with official signatures / SHA-256 beforehand: Windows 11 ISO, OpenWrt x86-64 image (`combined-ext4.img.gz`), proxy core, and OpenSSH;
- Keep **independent out-of-band consoles**: VMware host console + OpenWrt virtual Serial Port, plus offline rollback backups before every Tier-C change.

---

## Part 1: Minimal Viable Core (MVP · 5-Step Walkthrough)

> Complete these 5 steps in order; each step is independently verifiable.

### Step 1: Close the Gate Before Attaching the Guest — VMware Topology (Tier-C)

1. **Create an isolated LAN Segment**: In VMware Workstation, open VM Settings → Network Adapter → **LAN Segments** → create a dedicated segment (e.g. `VM-Egress-Isolated`).
2. **Configure the OpenWrt Gateway VM (2 NICs + Serial Port, zero `qemu-img` required)**:
   - **Disk conversion without `qemu-img`**: Verify official `openwrt-*-x86-64-generic-ext4-combined.img.gz` against `sha256sums`. Note that OpenWrt 24.10.x `.img.gz` appends a 34-byte `fwtool` metadata trailer that makes Python's `gzip.open()` fail; stream-decompress with `zlib.decompressobj(16 + zlib.MAX_WBITS)` to `openwrt-flat.vmdk`, then write a plain-text `monolithicFlat` descriptor `openwrt.vmdk` using exact sector count (`bytes / 512`) to attach directly in VMware;
   - **NIC 1 (LAN)**: Attach to `VM-Egress-Isolated` (record both NIC MAC addresses so you can match LAN vs. WAN inside OpenWrt);
   - **NIC 2 (WAN — keep disconnected initially)**: Attach to `NAT (VMnet8)` and **uncheck both "Connected" and "Connect at power on"** until Step 2's offline failure drills pass;
   - **Serial Port**: Add a named-pipe serial port (e.g. `\\.\pipe\cf-openwrt-serial`, "This end is the server", "The other end is an application") for out-of-band management even if firewall rules lock out the network.
3. **Configure the Windows 11 Guest with a single NIC**:
   - Keep only one virtual NIC (e.g. `Ethernet0`) attached to `VM-Egress-Isolated`;
   - **Hard rule**: Never use Bridged networking and never add a second guest NIC. When the gateway is off, the guest has zero L2 path to the internet.
4. **Plan non-overlapping subnets** (use the examples or substitute your own):
   - WAN (`VMnet8`): Check actual subnet prefix, NAT gateway IP, and host management IP `<HOST_MGMT_IP>` (e.g. `192.168.125.1`) in VMware **Edit → Virtual Network Editor → VMnet8 → NAT Settings**; assign a static gateway WAN IP `<GATEWAY_WAN_IP>` (e.g. `192.168.125.3/24`, default gateway = VMnet8 NAT gateway);
   - LAN (isolated segment): Gateway LAN `<GATEWAY_LAN_IP>` (e.g. `192.168.242.1/24`), guest static lease `<GUEST_LAN_IP>` (e.g. `192.168.242.129`).

---

### Step 2: Configure the Dedicated OpenWrt Default-Deny Gateway (Tier-C)

> **Only the persistent loader below is supported.** Never apply this template to a shared production router.

1. **Disable the built-in firewall FIRST (order matters)**: Connect over Serial while WAN is disconnected, back up existing configs, close forwarding, and stop/disable `firewall` (`fw4`).
   - **Field-tested OpenWrt 24.10 gotcha**: `/etc/init.d/firewall stop` flushes **all** `nft` tables including `inet vm_gate`, so you **must stop and disable `fw4` before loading `claude-fortress`**.
2. **Configure dual NICs & static DHCP lease via UCI (live-tested on OpenWrt 24.10.0)**:
   - **Field-tested OpenWrt 24.10 gotcha**: By default `eth0` is enslaved to `br-lan`; if `<LAN_IF>` is `eth0`, you must unbridge it (`network.lan.device='eth0'`) or packets will enter on `br-lan` and miss `eth0` rules:
   ```sh
   uci batch <<'EOF'
   set network.lan=interface
   set network.lan.device='eth0'
   set network.lan.proto='static'
   set network.lan.ipaddr='192.168.242.1'
   set network.lan.netmask='255.255.255.0'
   set network.lan.ip6assign='0'
   set network.lan.force_link='1'
   set network.wan=interface
   set network.wan.device='eth1'
   set network.wan.proto='static'
   set network.wan.ipaddr='192.168.125.3'
   set network.wan.netmask='255.255.255.0'
   set network.wan.gateway='<VMNET8_NAT_GW_IP>'
   set network.wan.peerdns='0'
   set network.wan6.auto='0'
   set dhcp.lan.force='1'
   set dhcp.lan.ra='disabled'
   set dhcp.lan.dhcpv6='disabled'
   set dhcp.lan.ndp='disabled'
   set dhcp.fortress_guest=host
   set dhcp.fortress_guest.name='fortress-guest'
   set dhcp.fortress_guest.mac='<GUEST_NIC_MAC>'
   set dhcp.fortress_guest.ip='192.168.242.129'
   set dhcp.@dnsmasq[0].port='0'
   set dhcp.@dnsmasq[0].noresolv='1'
   set dhcp.@dnsmasq[0].localuse='0'
   commit network
   commit dhcp
   EOF
   /etc/init.d/network reload
   /etc/init.d/dnsmasq restart
   /etc/init.d/firewall disable && /etc/init.d/firewall stop
   ```
   - Host-to-guest management SSH uses DNAT on gateway WAN port `22` → guest `22` (with pinned host key on the host); manage the gateway itself over Serial only.
3. **Transfer & install the 3 templates offline (root-writable only)**:
   - **Field-tested OpenWrt 24.10 gotcha**: Stock OpenWrt 24.10.0 includes `/usr/sbin/nft`, `flock`, `sha256sum`, and `awk`, but **not `base64` or `stat`**. Over an offline serial link, send chunked Base64 and decode with `awk` (or mount a temporary read-only ISO), verify every file with `sha256sum -c`, and check permissions with `ls -l`:
   - [openwrt-claude-fortress.sysctl.conf](../../assets/openwrt-claude-fortress.sysctl.conf) → `/etc/sysctl.d/99-claude-fortress.conf` (note: stock `10-default.conf` sets `ip_forward=1` before `99-claude-fortress.conf` overrides it back to `0`);
   - [openwrt-vm-gateway.nft.tmpl](../../assets/openwrt-vm-gateway.nft.tmpl) with all placeholders replaced (LAN and WAN interface names must differ) → `/etc/claude-fortress/gateway.nft`;
   - [openwrt-claude-fortress.init](../../assets/openwrt-claude-fortress.init) → `/etc/init.d/claude-fortress` (`chmod 700`), then run `/etc/init.d/claude-fortress enable && /etc/init.d/claude-fortress start`. Manage start/reload/stop **only** via this init script (closes forwarding → validates syntax → atomically replaces `inet vm_gate` → verifies table exists before enabling IPv4 forwarding; any failure keeps forwarding closed, never global flush).
4. **Run offline failure & reboot drills before reconnecting WAN**: While WAN is still disconnected, test reboot (note: serial login opens around ~7s before `procd` finishes `S25claude-fortress`, so wait for `S25` before checking the table), deliberately corrupt `gateway.nft` syntax and run `reload` (verify non-zero exit and `/proc/sys/net/ipv4/ip_forward == 0`), restore and `reload` back to `1`. Inspect named counters with **`nft list counters table inet vm_gate`** (the `table` keyword is required in `nftables v1.1+`; zero counters never prove zero traffic — cross-check with WAN capture). Only after this passes, approve Tier-C and re-enable NIC 2 (`VMnet8`).

---

### Step 3: Windows 11 Guest Protected Config & One-Shot GPO Setup/Rollback (Tier-C)

1. **Install guest core binaries first, then write private config**:
   - See [Windows Guest Operations](route-b-windows-operations.md) for ACL details: install your offline-verified proxy core (note its exact path and TUN adapter name, e.g. `Mihomo`) and Windows OpenSSH Server (`sshd.exe` path & service ready) *before* locking down GPO;
   - As Administrator in the guest, create `%ProgramData%\ClaudeFortress` (writable only by Administrators/SYSTEM, Read/Execute for the non-admin desktop user, zero reparse points) and copy in `route-b-common.ps1`, `guest-egress-guard.ps1`, `guest-gpo-setup.ps1`, `claude-env-check.ps1`, `guest-claude-gate.ps1`;
   - Copy [route-b-config.example.json](../../assets/route-b-config.example.json) to `C:\ProgramData\ClaudeFortress\config.json` and fill in your private values (never commit or share). Use these 3 offline read-only commands to look up the trickiest fields:
     ```powershell
     # 1) Look up desktop_sid under the non-admin desktop account
     whoami /user /fo list
     # 2) Look up MSIX PackageFamilyName and app_publisher
     Get-AppxPackage | Where-Object { $_.Name -like '*Claude*' } | Select-Object Name, PackageFamilyName, Publisher
     # 3) Look up exact app_id (AUMID)
     Get-StartApps | Where-Object { $_.Name -like '*Claude*' } | Format-Table -AutoSize
     ```
2. **Preview with `guest-gpo-setup.ps1 -Mode DryRun`, then apply with automatic backup & rollback**:
   - Verify you have local VMware console access for recovery, preview first, then apply (sets Domain/Private/Public GPO profiles to default-block inbound & outbound, disables local rule merging, and creates the 6 exact internal-`Name` rules expected by `guest-egress-guard.ps1`):
   ```powershell
   # 1) Offline read-only preview (Tier-A, makes no changes)
   powershell -NoProfile -File "C:\ProgramData\ClaudeFortress\guest-gpo-setup.ps1" -ConfigPath "C:\ProgramData\ClaudeFortress\config.json" -Mode DryRun

   # 2) Tier-C approved apply (admin shell in guest; exports timestamped localhost GPO backup first)
   powershell -NoProfile -File "C:\ProgramData\ClaudeFortress\guest-gpo-setup.ps1" -ConfigPath "C:\ProgramData\ClaudeFortress\config.json" -Mode Apply -ConfirmTierC -BackupDir "C:\ProgramData\ClaudeFortress\backups"

   # 3) Rollback if needed (use the exact backup path printed by Apply)
   powershell -NoProfile -File "C:\ProgramData\ClaudeFortress\guest-gpo-setup.ps1" -ConfigPath "C:\ProgramData\ClaudeFortress\config.json" -Mode Rollback -BackupPath "<BACKUP_PATH>"
   ```

   **The 6 Managed GPO Allow Rules** (`PolicyStore=localhost`, `Profile=Any`, `Action=Allow`, `Edge=Block`, `OverrideBlock=False`):

   | Internal Name | Direction | Scope |
   |---|---|---|
   | `CG-Managed-Node` | Outbound | LAN adapter, trusted proxy core path, `<ENTRY_IP>:<ENTRY_PORT>` TCP |
   | `CG-Managed-Tun` | Outbound | TUN adapter, local Fake-IP source CIDR (e.g. `198.18.0.0/16`, verify locally) |
   | `CG-Managed-Loop` | Outbound | Remote IPv4 loopback `127.0.0.0/8` |
   | `CG-Managed-DhcpOut` | Outbound | LAN adapter, `Dhcp` service, UDP 68→67, gateway IP & `255.255.255.255` (**keep broadcast for lease renewal**) |
   | `CG-Managed-DhcpIn` | Inbound | LAN adapter, `Dhcp` service, UDP local 68 / remote 67, gateway IP |
   | `CG-Managed-Ssh` | Inbound | LAN adapter, trusted `sshd.exe` path, `<HOST_MGMT_IP>`, TCP local 22 |

3. **Verify GPO policy offline**: Run `guest-egress-guard.ps1 -ConfigPath <private_config> -Status -PolicyOnly` and confirm `policy_ok: true`. Never loosen rules just to make a check pass.

---

### Step 4: Host Clash TUN Conflict Prevention (Only If Host Uses TUN)

If your host proxy runs in **TUN mode**, it can hijack VMware NAT (`vmnat.exe`), causing double-proxy nesting, fake 2 ms latency, or timeouts:
- **Assess impact first (Tier-C if it affects other NAT guests or isolation boundaries)**: Verify no other NAT guests rely on host TUN;
- Prepend [host-clash-vmnat-bypass.yaml](../../assets/host-clash-vmnat-bypass.yaml) in host rule mode (**never include `MATCH`**), then re-test both host routing and guest dual paths.

---

### Step 5: S1 Independent Evidence & Negative Drills → S2/S3 Manual Launch

1. **Dual-path neutral probes (Tier-B, zero Claude contact)**:
   - Follow [01 Route Applicability](01-route-selection-and-preflight.md) and [Windows Operations](route-b-windows-operations.md) to run `claude-env-check.ps1 -ConfigPath <private_config> -RequestId <32-hex-id> -AuthorizedNeutralProbe`, or verify both production paths return `<RESIDENTIAL_EGRESS_IP>`:
     ```powershell
     # Path 1: Direct via TUN adapter
     curl.exe -q -4 -fsS --max-time 8 --noproxy '*' https://api.ipify.org
     # Path 2: Via explicit local HTTP/mixed proxy port
     curl.exe -q -4 -fsS --max-time 8 --noproxy no-proxy.invalid --proxy http://127.0.0.1:7897 https://api.ipify.org
     ```
2. **Negative drills & independent evidence (hard gate)**:
   - Personally verify on your machine: cold-boot zero WAN leak capture, reload-failure stays blocked, Tier-C time-limited upstream entry block (preserving & testing a **brand-new management SSH connection** — **never test disconnect by stopping `clash_verge_service`**), IPv6 binding/routes, proxy DNS logs, and target browser WebRTC;
   - Record SHA-256 digests in protected `evidence\` per [route-b-evidence.example.json](../../assets/route-b-evidence.example.json).
3. **S2/S3 manual launch (Tier-C)**:
   - Once all applicable S1 checks are `pass`, the non-admin guest desktop user runs `guest-claude-gate.ps1 -Mode Launch -ConfigPath <private_config> -RequestId <ID>` with live interactive confirmation (anti-mislaunch helper only; isolation is enforced by network/GPO layers).

---

## Part 2: Optional Advanced Add-Ons (Adopt Only If Needed)

> Each add-on below is optional — skip, adopt selectively, or build your own equivalent:

### Add-On A | Host Read-Only Preflight & Ordered Startup (Optional)
- Verify OpenWrt disk chain & descriptor SHA-256 on the host (never overwrite newer data disks), power on OpenWrt first then the Windows guest, and use pinned-host-key SSH to run **`guest-claude-gate.ps1 -Mode Inspect` only** (this release never deploys remote auto-launch tasks).

### Add-On B | Transactional Upstream Entry Updater (Optional)
- For residential nodes whose exit IP stays fixed while upstream entry IP/port rotates: store subscription URLs only in local host DPAPI / protected private storage (never in Git or shares); pre-verify the new entry in an **isolated staging environment**; freeze guest launches, back up OpenWrt/GPO/proxy hashes, update atomically while **keeping egress blocked during the swap until all 3 layers re-verify**, and roll back out-of-band on any failure (never revert a whole-VM snapshot that would wipe project files; desensitize logs/evidence before sharing).

### Add-On C | Multi-Agent Permission-Separated Local Collaboration (Optional)
- Attach only after Route B isolation is verified; see [06-multi-agent-and-local-first.md](06-multi-agent-and-local-first.md).

---

## Part 3: Field Troubleshooting Quick Reference (Top 3)

See [07-troubleshooting-and-cleanup.md](07-troubleshooting-and-cleanup.md) for full timelines and cleanup:

1. **Fake 2 ms latency / timeouts when host enables TUN**: Host TUN captures `vmnat.exe` → see Step 4 (`vmnat.exe` bypass without `MATCH`, after auditing other NAT guests).
2. **Guest loses all network after moving gateway `.vmx` / `.vmdk` descriptors**: Confirms Fail-Closed works; power off out-of-band, verify backing disk size & SHA-256, restore only verified descriptors.
3. **Guest DHCP lease renewal fails**: Confirm `CG-Managed-DhcpOut` includes broadcast `255.255.255.255` and OpenWrt `input`/`output` allow UDP 68↔67.
