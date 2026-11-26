**English** | [简体中文](README.zh-CN.md)

# Claude Fortress (Public Templates · Self-Verify On Your Own Machine)

> **Upfront note**: There is no silver bullet that guarantees avoiding account bans — all you can do is reduce controllable risks through disciplined engineering isolation and respond calmly to issues as they arise.
>
> **Verifiable isolation design + handoff-ready local collaboration.** This repository is an open-source Agent Skill and parameterized engineering template set — **not** a "skip-verification, one-click magic box." Every user's OS build, NIC layout, gateway firmware, and network provider differ. The Skill actively reminds and walks you through verifying **cold boot, warm reboot / reload, and fail-closed entry blocking** on **your own machine** before you ever attach a production account.

## Routes & Scope

| Entry | Goal | Status |
|---|---|---|
| **Route A1: Local Fingerprint Profile + CLI** | App-level traffic separation (not OS Fail-Closed) | Generic template — read [Local Routes](references/en/02-route-a-local-and-fingerprint.md) |
| **Route A2: Local Whole-Machine** | Whole-machine TUN + OS outbound firewall | Cross-platform reference design (self-verify on target host) |
| **Route B: VMware + Dedicated OpenWrt (Flagship)** | Out-of-guest default-deny gateway + in-guest GPO + anti-mislaunch helper | [Parameterized reference implementation](references/en/03-route-b-vm-openwrt-fortress.md) (requires local cold/warm boot self-verification) |
| **Route C: Linux VPS Devbox** | C1 native egress / C2 proxy default-deny | [Two separate contracts](references/en/04-route-c-vps-devbox.md); no Windows Desktop |
| **Post-Setup Optional Add-on (Model-Agnostic)** | Host/guest permission separation, isolated private Git repos, handoff lint & local-first `to_md.py` | [Usable standalone](references/en/06-multi-agent-and-local-first.md) — no account or proxy needed |

**Trust boundary**: You still trust the host OS, hypervisor, gateway firmware, guest administrator, and upstream network operator. Other processes running under the same desktop account cannot be constrained by an anti-mislaunch helper. See [SKILL.md](SKILL.md) ([中文版](SKILL.zh-CN.md)) for the S0–S4 stage gates and A/B/C authorization tiers, and [01 Preflight & Evidence Contract](references/en/01-route-selection-and-preflight.md) for pass/fail/stop criteria.

## 5-Minute Offline Start (Read-Only Inventory, Zero Deployment)

1. Open the zero-dependency interactive flowchart directly from disk: [Interactive Guide (EN)](assets/interactive-guide.en.html) | [中文交互向导](assets/interactive-guide.html) (or preview via GitHub Pages once enabled). **Only opening the local file is offline**; hosted web access uses the network. Copying a prompt is **not** approval, and checking a box is **not** security evidence.
2. To install the Skill, copy **only** the `claude-fortress/` directory:
   - **Claude Code**: `~/.claude/skills/claude-fortress/` (user-level) or `<project>/.claude/skills/claude-fortress/` (project-level)
   - **Codex / Antigravity / other hosts**: your host's enabled skills directory (e.g. `~/.agents/skills/claude-fortress/`)
   - Use an already available host first — you do **not** need to install or open the target client before verification.
3. Send your Agent:
   > *"Please read the `claude-fortress` Skill and give me a Tier-A offline, read-only inventory checklist and route comparison; do not write files, access the network, modify NICs, install software, or launch apps."*
   *(Note: Installing Skill files itself is not Tier-A, and offline inventory does not imply the host Agent has no background network activity of its own.)*

## Route B First-Deployment Self-Verification (Mandatory On Your Machine)

- Configure private copies of [route-b-config.example.json](assets/route-b-config.example.json) and [route-b-evidence.example.json](assets/route-b-evidence.example.json) following [Windows Deployment & Operations](references/en/route-b-windows-operations.md). The bundled examples are intentionally non-runnable; never commit real IPs, configs, probe receipts, or evidence bundles. `scripts/claude-env-check.ps1` provides neutral functional observations only and does not replace boundary verification.
- On OpenWrt, use **only** the [dedicated persistent boot flow](references/en/03-route-b-vm-openwrt-fortress.md) — never import it onto a shared production router. Keep sysctl/rule backups, VM backups, and an out-of-band recovery console. Every action that can cut connectivity or alter isolation boundaries requires explicit **Tier-C** confirmation.
- **Before attaching any real account, verify these 4 checks on your own machine**:
  1. **Cold Boot Check**: Fully power off and cold-boot both gateway and VM; verify default forwarding stays off and zero unauthorized WAN egress occurs before the proxy/TUN comes up.
  2. **Warm Reboot / Reload Check**: Test gateway reboot, rule reload failure, host TUN/system-proxy toggle, and guest sleep/resume; verify boundaries remain closed and a **brand-new management SSH connection** succeeds.
  3. **Negative Entry-Block Drill**: Temporarily block the upstream entry at the gateway (Tier-C, auto-expiring); verify both guest paths lose connectivity with no stale session or direct fallback, then recover after expiry.
  4. **Leak & Boundary Audit**: Independently verify DNS path, IPv6 binding/routing, UDP/QUIC, browser WebRTC, and absence of a second guest NIC.

## Directory Layout

```text
claude-fortress/
├── LICENSE                                # MIT License
├── README.md / README.zh-CN.md            # Bilingual repository guides
├── SKILL.md / SKILL.zh-CN.md              # Bilingual Agent Skill entry points
├── index.html                             # Zero-dependency GitHub Pages landing portal
├── assets/
│   ├── interactive-guide.en.html          # Offline English interactive flowchart
│   ├── interactive-guide.html             # Offline Chinese interactive flowchart
│   ├── openwrt-vm-gateway.nft.tmpl        # Dedicated OpenWrt nftables template (input/output/forward + counters)
│   ├── openwrt-claude-fortress.init       # Persistent OpenWrt init loader (default zero-forward)
│   ├── openwrt-claude-fortress.sysctl.conf# Zero-forwarding sysctl baseline
│   ├── host-clash-vmnat-bypass.yaml       # Host Clash TUN vmnat.exe exception snippet (no MATCH)
│   ├── route-b-config.example.json        # Unified Route B config schema (non-runnable placeholders)
│   ├── route-b-evidence.example.json      # Independent boundary evidence schema
│   └── session-state.example.json         # Desensitized cross-session fact state example
├── references/                            # Chinese reference playbooks (9 docs)
├── references/en/                         # English reference playbooks (9 docs)
└── scripts/                               # 7 hardened, parameterized scripts (PowerShell 5.1 & Python 3.10+)
```

## Publishing & License

Original code and documentation in this directory are licensed under the [MIT License](LICENSE). See [Release & Attribution Checklist](references/en/release-review.md). Never commit real values, credentials, personal identifiers, logs, or unvetted third-party archives. Always comply with your actual jurisdiction's laws and official service terms; login, payment, and appeals must be performed directly by the user.
