# 07 | Incident Timeline, Common Troubleshooting, Line Optimization & Recoverable Cleanup

> Covers the unified-timestamp incident timeline template, battle-tested fixes, single-variable line measurement, and the 5-step verifiable local cleanup protocol.

---

## 1. Unified-Timestamp Incident Timeline (Always First)

Whenever login fails, an account is restricted, or traffic drops, **build a timeline before touching IPs or reinstalling**:

| UTC / Local Time | Category (Account Notice / Client Error / Network Change / Service Status) | Raw Evidence (Status Code / Request ID / Desensitized Log) | Type (Fact / Inference / Unknown) |
|---|---|---|---|
| `YYYY-MM-DD HH:MM` | e.g. Client HTTP `403` | `error.type`, desensitized payload | Fact |
| `YYYY-MM-DD HH:MM` | e.g. Upstream entry change or host TUN toggle | Gateway / client log | Fact |

### Objective Status-Code Triage (Never State Inference as Fact)

| Code / Symptom | Possible Causes (Verify With Evidence) | Next Action |
|---|---|---|
| Redirect to `/restricted` or official email | Account restricted or suspended | Stop all retries immediately, preserve evidence, use Anthropic's official appeal flow |
| `403 permission_error` | In the API, indicates permission/resource scope denial; Web HTTP 403 is separate evidence | For API, audit permissions & Request ID; for Web, distinguish official page vs proxy/upstream response — do not blindly infer IP or account ban |
| `429 rate_limit_error` | RPM/TPM rate limit, high concurrency, or quota exhaustion | Check `retry-after` header, lower concurrency, wait for reset |
| `529 overloaded_error` / `5xx` | Upstream service overload or outage | Check official status page and wait; do not churn local network |

---

## 2. Battle-Tested Troubleshooting Cases

1. **Host Clash TUN Causes VM Timeouts or Fake ~2 ms Latency**:
   - **Root Cause**: Host TUN hijacks VMware's `vmnat.exe`, creating double-proxy nesting and `198.18.0.0/16` Fake-IP collisions.
   - **Fix (audit impact first; Tier-C if it alters isolation or other NAT guests)**: Confirm no other NAT guests rely on host TUN, then prepend [host-clash-vmnat-bypass.yaml](../../assets/host-clash-vmnat-bypass.yaml) (**without `MATCH`**) in rule mode and retest both host routing and VM paths.
2. **Missing OpenWrt Gateway Descriptor Files Cut VM Network**:
   - **Fix**: Power off out-of-band; verify target disk, snapshot chain, descriptor & backing files, parent/child links, capacity, and known-good SHA-256 (matching byte size alone is insufficient). Restore only verified descriptors without overwriting data disks; keep an independent rollback copy and re-verify boot & gateway boundaries.
3. **Egress IP Matches but DNS Path / Connectivity Looks Broken**:
   - **Fix**: `scripts/claude-env-check.ps1` only performs HTTP functional observations and never proves the DNS path. Inspect resolver logs and WAN egress captures; treat `unknown` as blocked.

---

## 3. Single-Variable Line Optimization (Optional, P2)

When diagnosing peak-hour slowness, **change only one variable at a time**:
1. Measure each hop separately (`Guest → Gateway`, `Host → Upstream Entry`, `Via Proxy → Neutral Target`).
2. Compare handshake time, packet loss, retransmits, and throughput in the same time window against the same neutral target.
3. After any transport or routing change, re-run **S1 neutral verification + negative Fail-Closed drills**.

---

## 4. 5-Step Verifiable Local Data Quarantine Cleanup (Tier-C)

> **Principle**: Always **back up and move to private quarantine (recoverable)** instead of permanent deletion. Source code, uncommitted Git work, other Agents, user `settings.json` / `skills/` / `plugins/`, and forensic logs are always protected.

1. **Preconditions**: Fully exit all Claude desktop apps (including Windows MSIX / classic installs) and CLI processes; confirm active user account and directory ownership.
2. **Read-Only Inventory (Tier-A)**: Enumerate exact candidate cache files, sizes, and counts; **ask separately** whether to archive local conversation history.
3. **Private Backup & SHA-256 Manifest (Tier-B)**: Copy candidates to a private non-synced backup directory and record paths, sizes, and SHA-256 hashes.
4. **Tier-C Explicit Quarantine**: Move **only** the reviewed, backed-up individual cache files — never move entire installation, config, browser Profile, or parent session directories. Audit ownership, symlinks/reparse points, exclusions, and backup hashes; archive logs as forensics first; obtain separate confirmation for session data and target site data; never wildcard-delete or touch other accounts.
5. **Post-Move Verification**: Confirm all protected directories and source repos remain intact and hand the user the exact restore path.
