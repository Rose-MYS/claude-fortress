# 03 | Route B: Windows VM + Dedicated OpenWrt Gateway (Parameterized Reference)

Design goal: **in-guest Windows GPO + out-of-guest OpenWrt default-deny gateway**. Targets **VMware Workstation + dedicated OpenWrt + Windows 11**. Keep an independent host console, gateway serial console, and offline rollback copies. All Tier A/B/C rules follow real consequences in [SKILL.md](../../SKILL.md). **Every deployment must pass cold boot, warm reboot/reload, and entry-block self-verification on your own machine before attaching any production account.**

## 1. Close the Gate First, Then Attach the Guest (Tier-C)

1. Keep the guest offline and gateway WAN disconnected from production networks during build. Create a dedicated VMware LAN Segment connecting **only** the gateway LAN NIC and the guest's **single** virtual NIC. Connect the gateway WAN NIC to VMnet8. No bridging; no second guest NIC. Install Windows, Clash, and OpenSSH from signature/hash-verified offline media.
2. Plan non-overlapping private subnets: WAN (`<HOST_MGMT_IP>`, `<GATEWAY_WAN_IP>`) and LAN (`<GATEWAY_LAN_IP>`, `<GUEST_LAN_IP>`). Serve a single static DHCP lease to the guest MAC, disable gateway DNS forwarding and unused local listeners, use a static WAN IP, forward management SSH via DNAT with pinned guest host keys, and manage the gateway itself over serial console.
3. **Only the dedicated persistent loader below is supported.** With out-of-band console verified, back up original rules, sysctl, network configs, and init scripts; disable IPv4/IPv6 forwarding; stop and disable `firewall` (`fw4`) on the dedicated gateway; verify no other firewall, hotplug, flow-offload, container, or init script re-enables forwarding. Never apply this template to a shared production router.
4. Install [openwrt-claude-fortress.sysctl.conf](../../assets/openwrt-claude-fortress.sysctl.conf) to `/etc/sysctl.d/99-claude-fortress.conf` and verify your firmware applies it before interfaces come up. Expand [openwrt-vm-gateway.nft.tmpl](../../assets/openwrt-vm-gateway.nft.tmpl) into `/etc/claude-fortress/gateway.nft` replacing all placeholders (LAN and WAN interfaces must differ; root-only write permissions).
5. Install [openwrt-claude-fortress.init](../../assets/openwrt-claude-fortress.init) to `/etc/init.d/claude-fortress` (root-owned, executable). Confirm `/usr/sbin/nft` and `flock` exist, then enable the service. Always start, reload, and stop via this service: it disables forwarding first, validates syntax, atomically replaces only its own table, verifies table presence, and only then enables IPv4 forwarding. Any validation/load failure keeps forwarding OFF.
6. Before attaching production WAN, test **cold reboot, missing rule file, syntax error, and repeated reload** (must remain zero-forwarding on failure while out-of-band recovery works). After Tier-C approval to connect WAN, inspect named counters via `nft list counters inet vm_gate` **and** cross-check with WAN packet captures (empty counters alone never prove zero traffic).

## 2. In-Guest GPO & Unified Config (Tier-C)

Configure Windows Local GPO so Domain, Private, and Public profiles are Enabled, DefaultInbound=Block, DefaultOutbound=Block, local firewall & IPsec rule merge disabled, zero disabled interfaces, and zero extra enabled Allow rules (even on inactive profiles). Create rules using the exact internal **Name** (not just DisplayName), `GroupPolicy` store, `Any` profile, `Edge=Block`, no override-block:

| Rule Name | Direction | Scope |
|---|---|---|
| `CG-Managed-Node` | Outbound | LAN NIC, trusted proxy core absolute path, entry IPv4/TCP port |
| `CG-Managed-Tun` | Outbound | TUN NIC, local Fake-IP source subnet (verify actual source address) |
| `CG-Managed-Loop` | Outbound | Remote IPv4 loopback `/8` (`127.0.0.0/255.0.0.0`) |
| `CG-Managed-DhcpOut` | Outbound | LAN NIC, `Dhcp` service, UDP 68→67, gateway or broadcast |
| `CG-Managed-DhcpIn` | Inbound | LAN NIC, `Dhcp` service, UDP dst 68 / src 67, gateway |
| `CG-Managed-Ssh` | Inbound | LAN NIC, trusted `sshd` absolute path, host mgmt IPv4, TCP dst 22 |

Copy [route-b-config.example.json](../../assets/route-b-config.example.json) to the guest's protected directory and fill private values (never commit real values). Deploy scripts and ACLs per [Route B Windows Operations](route-b-windows-operations.md). The read-only Guard neither installs GPO nor blocks drift — if filters mismatch, audit real policies instead of loosening rules.

If the host runs Clash TUN, evaluate [host-clash-vmnat-bypass.yaml](../../assets/host-clash-vmnat-bypass.yaml) first. **If the rule can affect isolation boundaries or other NAT guests on `vmnat.exe`, treat it as Tier-C**, verify the merged ruleset, and retest all affected guests and host routing. Never prepend `MATCH`.

## 3. Independent Evidence, Anti-Mislaunch & Recovery

Use [01 Preflight Contract](01-route-selection-and-preflight.md) and [Windows Operations](route-b-windows-operations.md). Before touching any real account, personally verify on your machine: **cold boot, warm reboot / reload failure, entry-block negative drill (Tier-C, auto-expiring, verified with a brand-new SSH session — never by stopping `clash_verge_service`), DNS, IPv6, UDP/QUIC, second NIC absence, PMTU/ICMP, and target browser WebRTC**.

For upstream entry rotation: freeze launches with a single-writer lock, validate the new entry in a separate isolated staging environment without widening production whitelists, record local hashes/generations/receipts of gateway rules + GPO + proxy config, and roll back config-by-config over out-of-band management on failure (never overwrite active project work with whole-VM snapshots).
