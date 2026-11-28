# 08 | Fortress Level: Isolation Self-Assessment Standard

> In one line: turn the pile of S1 checks into a level a user can actually say out loud — "my environment self-tested at Fortress L2 on my own machine".
>
> Machine-readable definition: [assets/levels.json](../../assets/levels.json) | Offline report page: [assets/evidence-report.html](../../assets/evidence-report.html) | Evidence example: [assets/evidence-v3.example.json](../../assets/evidence-v3.example.json) | Reference calculator: [scripts/fortress_level.py](../../scripts/fortress_level.py)

---

## 1. What It Is — and Is Not

- **It is** a **self-assessed** level computed from evidence collected on **your machine, for this configuration generation**, following the [S1 evidence contract in 01](01-route-selection-and-preflight.md).
- **It is not** a certification, a guarantee, or proof that a route is safe in general. It only states what was tested once, on that machine; a new machine, a changed configuration or an expired result means re-testing.
- A level **changes no gate**: entering S2 still requires every applicable item in the 01 matrix to be `pass`, followed by the user's own Tier-C confirmation. The level is a human-readable summary, not a new switch.

## 2. The Four Levels

Each level includes everything below it (cumulative).

| Level | Name | Checks added at this level | Highest level per route |
|---|---|---|---|
| **L0** | Egress verified | Dual neutral IPv4 egress, remote DNS / no direct leak, multi-window egress stability | C1 (native VPS egress) |
| **L1** | Leak surfaces closed | **A1**: app-level refuse-on-proxy-down, plus WebRTC no-leak for Web; **system routes**: IPv6 blocking, plus WebRTC no-leak when a browser is used | A1 (Web and CLI rated separately) |
| **L2** | System-level fail-closed | Cold boot, reload failure and upstream entry loss drills never fall back to direct egress; plus "brand-new management SSH reachable during drills" when managed remotely | A2, C2 |
| **L3** | Out-of-guest gateway, two layers | No unauthorized egress on the gateway WAN, in-guest policy and launch gate active, UDP does not bypass the gateway, no second-NIC bypass, no lingering direct connections after switch | B |

- For Route B, "brand-new management SSH" is always required (the gateway is managed over SSH); same for C2. A2 only requires it when `remote_management` is `true`.
- WebRTC is only required when `browser_used` is `true` (always required for A1 Web).

## 3. Rules

1. **Rate per component**: each evidence file covers exactly one "route + component", e.g. one for `A1/web` and one for `A1/cli`. As in 01, Web passing never clears CLI, and vice versa.
2. **Only `pass` and `user_attested` count.** `unknown`, `not_run` and `fail` do not.
3. **`user_attested` is only allowed for negative-drill checks** (`attestable: true` in `levels.json`: app-level refuse-on-proxy-down, cold boot, reload failure, entry loss, brand-new management SSH, WAN capture, lingering connections). These drills are Tier C and performed by the user, who records the outcome; the report must list which checks are user-attested.
4. **`not_applicable` is only allowed for checks the component does not require** (e.g. WebRTC for CLI, or a conditional check whose condition is `false`), and must carry a note. Marking a required check `not_applicable` makes the whole evidence **invalid** rather than skipped.
5. **Evaluate level by level and stop at the first gap**: if one L1 check is missing, the result is L0 even if every L2 drill passed.
6. **Expiry**: 30 days after the **oldest** capture time among the checks that count towards the level, the result is marked "expired".
7. **Configuration generation**: if the evidence `config_sha256` differs from the current configuration hash, the result is marked "config changed" and must be re-tested.
8. **Invalid evidence gets no level**: malformed files, unknown checks or missing timestamps yield errors only.

## 4. Evidence Format v3

Extends v2 ([route-b-evidence.example.json](../../assets/route-b-evidence.example.json)). Main changes:

| Field | Meaning |
|---|---|
| `schema_version` | Always `3` |
| `request_id` | 32 lowercase hex characters, freshly generated per collection |
| `route` / `component` | e.g. `B` / `system`, `A1` / `web`; must match one profile in `levels.json` |
| `config_sha256` | SHA-256 of the tested configuration (64 lowercase hex), used to detect configuration changes |
| `conditions` | `browser_used`, `remote_management`: `true` / `false` |
| `checks.<id>` | One object per check: `status`, `method` (how it was collected), `captured_utc` (UTC ending in `Z`; required for `pass` / `user_attested`), `tool` (tool and version), `raw_sha256` (hash of the private raw evidence), `note` (reason, required for `not_applicable`) |
| `private_evidence_reference` | Where the private raw evidence lives — a placeholder or local alias only; raw logs never go into the evidence file |

**Redaction** (same zero-PII redline as the rest of the repo): no plaintext public IPs, subscription URLs, accounts or personal paths in evidence files; egress consistency is recorded only as "consistent or not" plus a salted hash, and hosts and NICs use aliases.

**Migrating from v2**: v2 stores a bare status string per check with no timestamp, so it cannot be converted to a level; collect again in v3. The v2 checks `dns`, `ipv6`, `cold_boot`, `reload_failure`, `entry_loss`, `management_ssh`, `udp`, `second_nic`, `existing_connections` and `browser_webrtc` keep the same names in v3, so their collection methods carry over.

## 5. How to Compute

Run on the **host or any trusted machine** (read-only, no network, writes nothing; do not install Python inside the isolated environment for this):

```bash
python scripts/fortress_level.py <evidence>.json
python scripts/fortress_level.py <evidence>.json --json --current-config-sha256 <current-config-hash>
```

Exit codes: `0` evaluated (see the level in the output), `2` invalid evidence, `64` usage error.

You can also open the offline [assets/evidence-report.html](../../assets/evidence-report.html) in a browser: drop in an evidence v3 file (optionally together with the JSON exported by the [WebRTC probe](../../assets/webrtc-probe.html), which is merged into `browser_webrtc`), and the page shows the level, every check per level, what is missing, and exports a redacted Markdown summary. It embeds the same `levels.json`, and CI verifies it matches the Python calculator on every case in [tests/fixtures/levels/cases.json](../../tests/fixtures/levels/cases.json). It also flags likely public IPs, emails, subscription links and personal paths in the evidence — a reminder only; still review before sharing.

## 6. How to Talk About It

- ✅ "Self-tested at **Fortress L2** on my machine (2026-11-28, config `a1b2c3d4…`)"
- ✅ "Route B can reach L3; I'm at L2 and only UDP is missing for L3"
- ❌ "Certified Fortress L3", "this route is L3, so it is safe"
- When user-attested checks are involved, add: "cold boot and entry loss were user-attested".

## 7. Changing the Standard

When editing `levels.json`, also review the [01 applicability matrix](01-route-selection-and-preflight.md) (both languages), the expected results in `tests/fixtures/levels/cases.json`, and the table in section 2 of this file. CI checks that `levels.json` matches the 01 matrix and that the calculator passes every shared case; never weaken assertions to turn CI green.
