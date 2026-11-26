# 01 | Route Selection, S0 Offline Inventory & S1 Neutral Evidence Contract

> Used with the five-stage gates in `SKILL.md`: this playbook covers **S0 (Offline Inventory)** and **S1 (Authorized Neutral Preflight)** only. **Never touch any Claude / Anthropic endpoint during preflight.**

---

## 1. Four-Route Comparison & Boundary Positioning

| Dimension | A1: Fingerprint Browser + CLI | A2: Local Whole-Machine | B: VM + Dedicated OpenWrt (Flagship) | C: Linux VPS Devbox |
|---|---|---|---|---|
| **Isolation Model** | **App-level separation (not Fail-Closed)** | System-level TUN + OS firewall | **Out-of-guest gateway + in-guest GPO (self-verify locally)** | Remote Linux isolation |
| **Maturity** | Generic template | Reference design | Parameterized reference (requires local cold/warm boot verification) | Reference design |
| **Local Overhead** | Very low | Low | Medium-High (recommend ≥16 GB RAM, ≥80 GB free disk) | Zero local overhead |
| **Claude Web / Code** | Yes / Yes | Yes / Yes | Yes / Yes | Limited / Yes |
| **Claude Desktop** | Not recommended on host | Higher risk | Contained inside VM | Not recommended |
| **Host Disk Protection** | None (same OS permissions) | None | **High (explicit read-only / scoped shares only)** | **High** |

---

## 2. S0: Tier-A Pure Offline Inventory (Zero Network Requests)

The Agent collects facts using local read-only commands and prints a desensitized summary in chat only. Writing a state file to disk requires separate **Tier-B** approval (see [../../assets/session-state.example.json](../../assets/session-state.example.json)):
1. **OS & Hardware**: OS version, virtualization support, available RAM and disk space.
2. **Network Topology**: Physical/virtual NIC aliases, IPv6 status, current default gateway, running proxy client paths.
3. **Hypervisor** (Route B): VMware Workstation version, VMnet8 subnet, and whether other NAT guests exist.
4. **Toolchain**: Availability of Python (3.10+), Git, and OpenSSH client/server.

---

## 3. S1: Tier-B Neutral Preflight Evidence Contract (Zero Claude Contact)

> **Important**: Probing neutral third-party endpoints exposes your source IP and requires explicit Tier-B approval. **Do not** probe `claude.ai` or `anthropic.com` here. Every item must be recorded as `pass`, `fail`, `unknown`, or `not_run`. Missing evidence stays `unknown` or `not_run` — **never mark green without evidence**.

### 3.1 Functional Checks (Collected Inside Target Environment)

| Evidence Item | Neutral Collection Method | Pass Criteria |
|---|---|---|
| **IPv4 Egress Consistency** | Query at least two independent neutral endpoints (e.g. `api.ipify.org`, `ifconfig.me/ip`) via both TUN and explicit local proxy port | All return the identical expected `<RESIDENTIAL_EGRESS_IP>` |
| **IPv6 Blocking** | `curl -6 --max-time 4 https://api64.ipify.org` plus NIC IPv6 binding & route inspection | Timeout/failure is only a hint; combine with IPv6 binding/routes and negative WAN evidence; otherwise `unknown` |
| **DNS Path & No Leak** | Inspect proxy DNS logs, actual resolver behavior on target, and gateway WAN capture | Zero unauthorized direct DNS egress; HTTP IP/country echoes never prove the DNS path |
| **Browser WebRTC Probe** | Test inside the target browser Profile with a local or neutral WebRTC probe | Does not reveal host LAN or real public IP |
| **Multi-Window Stability** | Record egress IP across morning, evening peak, and late night under the same config generation | Identical across all 3 windows |

### 3.2 Negative Boundary Self-Verification (Mandatory Before Production Use)

"It can reach the internet" does not prove Fail-Closed enforcement. Routes **A2 / B / C2** (proxy default-deny) must pass negative tests on your own machine (Route **C1** is verified under its native egress contract and makes no proxy fail-closed claim):
1. **Cold Boot Test**: Power off and cold-boot the gateway/VM; verify via WAN capture and counters that zero unauthorized outbound traffic leaves before the proxy/TUN starts.
2. **Warm Reboot / Reload & Entry-Block Drill**: Test gateway reboot, reload failure, sleep/resume, and a time-limited upstream entry block (**Tier-C**, preserving and verifying a **brand-new management SSH connection**); confirm no fallback to direct egress and full recovery on expiry.

> **S2 Transition**: Only when all applicable S1 positive and negative evidence items are `pass` (never `unknown` or `not_run`) should the Agent present a **Tier-C confirmation card** for the user to decide whether to enter S2 (first contact with official services).
