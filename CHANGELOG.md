# Changelog

All notable changes to **Claude Fortress** are documented in this file.

## [Unreleased]

### Added
- **Offline evidence report page** (`assets/evidence-report.html`): drag in evidence v3 (plus an optional WebRTC probe JSON, merged into `browser_webrtc`) to see the level, per-level checks, what is missing, expiry / config-change / user-attested flags, and export a redacted Markdown summary. Bilingual, zero network; embeds `levels.json`, and CI runs its JS engine with Node against the shared vectors to match `scripts/fortress_level.py`.
- **Fortress Level self-assessment standard** (`references/08-fortress-levels.md`, `references/en/08-fortress-levels.md`, `assets/levels.json`): four cumulative levels (L0 egress verified → L3 out-of-guest gateway, two layers), rated per route component, 30-day expiry, config-generation invalidation, and `user_attested` allowed only for negative drills. A self-assessment, never a certification; changes no gate.
- **Evidence format v3** (`assets/evidence-v3.example.json`): per-check objects with status, method, UTC capture time, tool and raw-evidence hash; adds route/component, conditions and `user_attested` / `not_applicable` rules.
- **Host-side reference level calculator** (`scripts/fortress_level.py`): stdlib-only, read-only, offline; UTC timestamps validated with the same pattern as the report page; shared test vectors in `tests/fixtures/levels/cases.json` that the future offline report page must also pass.
- **Tests**: `levels.json` self-consistency, drift check against the 01 S1→S2 applicability matrix (ZH and EN), shared level vectors, and calculator CLI exit codes.
- **Offline WebRTC & Browser Hygiene Probe** (`assets/webrtc-probe.html`): zero-network single-file HTML probe for S1 browser verification (local ICE candidates, timezone, `navigator.language`, `navigator.webdriver`, copyable desensitized JSON).
- **Automated Regression Test Suite & CI** (`tests/test_fortress.py` + `.github/workflows/ci.yml`): stdlib-only cross-platform test suite covering JSON, Python/Node/PowerShell AST, Markdown relative links, EN/ZH parity, zero-PII scan, fail-closed script guards, and Extension 06 boundaries.
- **Repository Governance** (`AGENTS.md`, `CHANGELOG.md`): unified contributor/coding-agent rules, including *"field verification is a sample, not certification"*.

### Changed
- **Delegated-Reply Route Gate** (`SKILL.md`, `SKILL.zh-CN.md`): explicitly clarify that replies like *"up to you"* or *"whatever works"* never bind a route automatically — the Agent must propose one concrete option and wait for explicit user acceptance.

---

## [1.3.0] — 2026-11-28

### Added
- **Route A1 Lightweight Per-Node Browser Launcher** (`scripts/route-a1-browser-launcher.py`, `scripts/route-a1-browser-session.mjs`, `assets/route-a1-nodes.example.json`): live-tested on System Chrome 158 and Edge 158 (full CDP timezone + cross-site iframe, WebRTC dual-lock, per-node `user-data-dir` + 3 exclusive locks, Windows Job Object teardown, proxy-outage refusal).
- **Route B Windows Guest GPO Setup & Rollback** (`scripts/guest-gpo-setup.ps1`): `DryRun` / `Apply -ConfirmTierC` / `Rollback` with automatic localhost GPO backup, field-matched to `guest-egress-guard.ps1`.
- **Route C2 Linux VPS Egress Template & Anti-Lockout Loader** (`assets/vps-c2-egress.nft.tmpl`, `scripts/vps-c2-apply-with-rollback.sh`): atomic `inet cf_vps_c2` table with `flock` and `systemd-run` timed auto-rollback, live-tested on Debian 12.
- **Route & Component S1→S2 Applicability Matrix** in `references/01` (ZH & EN).

### Changed
- Refactored bilingual `references/03` (Route B) into a modular **5-Step MVP + Last-Mile Command Cards + Optional Add-Ons + Troubleshooting Quick Reference**, incorporating live OpenWrt 24.10.0 findings (fixing `nft list counters table inet vm_gate` syntax, `fw4 stop` table flush order, `br-lan` unbridging, `fwtool` trailer decompression).
- Updated bilingual `references/02` (Route A) with 6 Windows Chrome/Edge gotchas, Camoufox comparison, and hardened Bash/PowerShell CLI templates.
- Synced bilingual `assets/interactive-guide.html` and `assets/interactive-guide.en.html`.

---

## [1.2.0] — 2026-11-26

### Added
- GitHub Pages interactive visual guide (`index.html`, `assets/interactive-guide.html`, `assets/interactive-guide.en.html`) with `#install` modal and step-by-step prompts.
- Claude Code plugin marketplace manifests (`.claude-plugin/marketplace.json`, `.claude-plugin/plugin.json`) and automated `claude-fortress.zip` release packaging.
- Bilingual Skill release (`SKILL.md`, `SKILL.zh-CN.md`, `README.md`, `README.zh-CN.md`, full `references/en/` parity).
