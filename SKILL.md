---
name: claude-fortress
description: Plan, run read-only inventories, build, and maintain isolated Claude environments and optional model-agnostic multi-agent local collaboration workspaces. Covers four routes — lightweight app-level separation (fingerprint browser + clean CLI subprocess), local whole-machine protection, VMware + dedicated OpenWrt reference implementation, and Linux VPS devboxes — plus neutral preflight scripts, unified-timestamp incident timelines, recoverable local cleanup, and local-first Markdown conversion. Strictly enforces S0-S4 stage gates and consequence-based Tier A/B/C authorization.
---

# Claude Fortress (v1.2 · Bilingual)

> **Upfront note**: There is no silver bullet that guarantees avoiding account bans — all you can do is reduce controllable risks through disciplined engineering isolation and respond calmly to issues as they arise.
>
> **Language rule**: Reply in the user's language (English or Simplified Chinese). Read English playbooks under `references/en/` (or Chinese playbooks under `references/`; full Chinese Skill entry is also at [SKILL.zh-CN.md](SKILL.zh-CN.md)).

---

## 1. Communication & Execution Rules

1. **Short 3-Part Status**: `Confirmed` / `Not Yet Checked` / `Next Step (Owner)`.
2. **Evidence-Driven**: Report observed facts directly; mark unchecked items `unknown` or `not_run`. Never inflate a single command success into a whole-machine pass.
3. **Low Friction**:
   - Inspect facts that offline read-only commands can answer (OS build, NIC names, paths) instead of asking the user.
   - Batch missing decisions (≤ 3 questions per turn).
   - **Delegated Replies Never Bind a Route**: Replies like *"up to you"*, *"whatever is easiest"*, or *"you decide"* are **neither an explicit route choice nor acceptance of a default**. Keep the route unconfirmed, present one concrete recommendation, and require explicit user acceptance/rejection before binding a route.
   - Advance Tier-A offline checks and approved Tier-B plans continuously; pause only when **a key decision is missing**, **a Tier-C gate is reached**, or **the user must act in a browser/official page**.
4. **Cross-Session State Reuse**: Tier-A outputs desensitized summaries in chat only. After Tier-B approval, long tasks may persist desensitized facts using [assets/session-state.example.json](assets/session-state.example.json) — **reuse facts and evidence pointers only, NEVER auto-reuse prior Tier-B/C approvals**. Re-verify actual state after any device, network, config-generation, or reconnect change.
5. **Interactive Flowchart Guidance for Beginners**: When the user says they are new to Agents, want an overview, or don't know what to ask next, point them to open [assets/interactive-guide.en.html](assets/interactive-guide.en.html) (or [assets/interactive-guide.html](assets/interactive-guide.html) for Chinese) directly in a local browser (offline only when opened locally; copied prompts are preparation requests, not approvals, and checkboxes are not evidence), while guiding them in plain language in chat.
6. **Mandatory On-Machine Self-Verification Rule (Hard Requirement)**: Scripts and rules in this Skill are generic parameterized templates and **cannot vouch for any user's specific machine**. Before any route advances to S2 (first contact with Claude), the Agent **must actively remind and walk the user through personally verifying on their own machine** (scoped to the route's actual boundary; see `references/en/01-route-selection-and-preflight.md` for route applicability):
   - **Cold Boot Check (Routes A2/B/C2)**: Power off and cold-boot the gateway/VM/host; confirm default-deny holds with zero direct leak before the proxy/TUN starts. (Route A1 has no OS Fail-Closed; verify the launcher refuses to start when the proxy port is down.)
   - **Warm Reboot & Reload Check (Routes A2/B/C2)**: Test gateway reboot, rule reload failure, host TUN/proxy toggles, or sleep/resume; confirm boundaries hold and a **brand-new management connection (e.g. new SSH)** succeeds.
   - **Negative Fail-Closed Drill**: Block the upstream entry (Routes B/A2/C2) or pass a mismatched expected IP / stop the local proxy listener (Route A1) to verify no direct fallback occurs.
   - **Leak & Config Audit**: Independently verify DNS path, IPv6, WebRTC (browser only — you can open the bundled offline [assets/webrtc-probe.html](assets/webrtc-probe.html) inside the target browser profile), and config consistency. **Field tests in this repo are reference samples, not universal certification across all OS/proxy/browser builds — explicitly warn the user not to attach a production account until these local checks pass.**

---

## 2. Five-Stage Gate (S0–S4, Breaking the PC0 Loop)

| Stage | Name | Permitted Actions | Prohibited Actions |
|---|---|---|---|
| **S0** | **Offline Inventory (PC0)** | Local read-only inspection of OS, NICs, hypervisor, firewall, proxy structure | **Zero external network probes; zero contact with Claude/Anthropic endpoints** |
| **S1** | **Authorized Neutral Preflight** | With explicit user approval, run neutral functional probes (e.g. `api.ipify.org`, `ifconfig.me`); collect independent DNS/IPv6/failure-mode evidence; any active traffic block or policy edit requires separate Tier-C approval | **Still zero contact with Claude/Anthropic** (including DNS, installers, IDE extensions, auto-updaters, `claude --version`) |
| **S2** | **Separate First-Contact Approval (Tier-C)** | Only after all applicable S1 evidence items are `pass`, present a Tier-C confirmation card; once approved, the **user** opens official pages or installs clients | Never auto-launch clients without explicit confirmation |
| **S3** | **Client & Workspace Verification** | After separate Tier-C confirmation, the target desktop user runs the local anti-mislaunch helper and verifies workspace boundaries | Never bypass gates or loosen whitelists |
| **S4** | **Account & Payment (User Only)** | User completes login, billing, or appeals directly on official pages in compliance with actual jurisdiction | Agent never acts on accounts or requests credentials |

> **Incident Fast-Path**: If the user reports an existing account login failure or restriction, skip new-setup intake and go straight to [references/en/07-troubleshooting-and-cleanup.md](references/en/07-troubleshooting-and-cleanup.md) to build a unified-timestamp incident timeline. Opening `claude.ai` remains **Tier-C and user-initiated**.

---

## 3. Consequence-Based Tier A / B / C Authorization

**Classify by real-world consequence, not section title.** Present an execution card before acting (target, action, external destinations, data exposure, backup, disconnect recovery, scope):

| Tier | Real Consequence | Typical Examples | Approval |
|---|---|---|---|
| **Tier A (Offline Read-Only)** | Modifies no files, makes zero network calls, touches no credentials | Inspect OS/NIC/process/firewall state, `check-handoff.ps1`, read local config structure | Run once scope is confirmed |
| **Tier B (Reversible Local Write / Authorized Neutral Probe)** | Writes reversible local files or sends neutral probes (exposes source IP to neutral third party) | `scaffold-projects.ps1`, `to_md.py`, neutral IPv4 functional probe | Present card + backup plan; one approval covers the batch |
| **Tier C (High-Risk / Irreversible / Service Contact)** | Can cut connectivity, alter default-deny firewall/gateway, switch VM NICs, quarantine local data, launch Claude, touch accounts/billing/appeals | Load OpenWrt `nftables`, modify Windows GPO, host NAT rules affecting other guests or isolation, active entry-block drills, first app launch, local data quarantine | **Must pause with explicit Tier-C confirmation card**; if Agent runs on the machine whose network is being modified, **verify an independent out-of-band console and auto-rollback first** |

**Zero-Credentials & Zero-PII Hard Rule**: Never solicit or write real passwords, subscription tokens, UUIDs, private keys, card numbers, personal emails, KYC documents, or **any personal real names, handles, or chat nicknames** into files or repositories.

---

## 4. Route & On-Demand Reference Navigation

Load only the references needed for the current task:

| Task / Route | Read Order (EN / ZH) | Scripts & Assets | Completion / Stop Condition |
|---|---|---|---|
| **Selection & Preflight** | [en/01](references/en/01-route-selection-and-preflight.md) / [01](references/01-route-selection-and-preflight.md) | `assets/session-state.example.json` | Route chosen & S0 offline inventory complete |
| **Route A1 / A2 (Local)** | `01` → [en/02](references/en/02-route-a-local-and-fingerprint.md) / [02](references/02-route-a-local-and-fingerprint.md) | `scripts/route-a1-browser-launcher.py`, `scripts/route-a1-browser-session.mjs`, `assets/route-a1-nodes.example.json` | A1 explicitly labeled app-level separation (verify browser/CLI components separately); A2 requires negative disconnect test |
| **Route B (VM + OpenWrt, Flagship)** | `01` → [en/03](references/en/03-route-b-vm-openwrt-fortress.md) / [03](references/03-route-b-vm-openwrt-fortress.md) → [en/route-b-win](references/en/route-b-windows-operations.md) | `assets/openwrt-vm-gateway.nft.tmpl`, `assets/openwrt-claude-fortress.init`, `assets/openwrt-claude-fortress.sysctl.conf`, `assets/host-clash-vmnat-bypass.yaml`, `assets/route-b-config.example.json`, `assets/route-b-evidence.example.json`, `scripts/route-b-common.ps1`, `scripts/guest-gpo-setup.ps1`, `scripts/guest-egress-guard.ps1`, `scripts/claude-env-check.ps1`, `scripts/guest-claude-gate.ps1` | Generic templates — user must complete on-machine cold boot, warm reboot/reload & entry-block self-verification; scripts never guarantee enforcement |
| **Route C (Linux VPS)** | `01` → [en/04](references/en/04-route-c-vps-devbox.md) / [04](references/04-route-c-vps-devbox.md) | `assets/vps-c2-egress.nft.tmpl`, `scripts/vps-c2-apply-with-rollback.sh` | Separate C1 native vs C2 proxy default-deny; verify out-of-band console, brand-new SSH & independent egress evidence |
| **Fortress Level Self-Assessment** | `01` → [en/08](references/en/08-fortress-levels.md) / [08](references/08-fortress-levels.md) | `assets/levels.json`, `assets/evidence-v3.example.json`, `scripts/fortress_level.py` (run on the host, never install Python inside the isolated environment) | Report the computed level with date and config hash; it is a self-assessment, never a certification, and changes no gate |
| **Account, Billing & Appeals** | [en/05](references/en/05-account-payment-and-sop.md) / [05](references/05-account-payment-and-sop.md) | — | Enter only on explicit user request; user executes all official actions |
| **Troubleshooting & Cleanup** | [en/07](references/en/07-troubleshooting-and-cleanup.md) / [07](references/07-troubleshooting-and-cleanup.md) | — | Build unified-timestamp incident timeline; cleanup requires backup + hash verification first |
| **Post-Setup Add-on: Multi-Agent Collab** | [en/06](references/en/06-multi-agent-and-local-first.md) / [06](references/06-multi-agent-and-local-first.md) | `scripts/local-safe-path.ps1`, `scripts/scaffold-projects.ps1`, `scripts/check-handoff.ps1`, `scripts/to_md.py` | **Model-agnostic; optional after setup (or usable standalone)** — verify host/guest permission separation & lint pass |

Whenever a flow claims prior checks passed, verify provenance and timestamps first; clipboard prompts, UI checkboxes, script exit codes, and historical approvals never grant authorization. This version does not deploy remote auto-launch tasks.
