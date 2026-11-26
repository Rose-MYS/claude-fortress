# Release Gate, Whitelist & Source Attribution Checklist

This directory contains parameterized security templates and engineering playbooks designed for **public distribution with mandatory on-machine self-verification**. Always export releases strictly from an explicit whitelist of vetted files: `README.md`, `README.zh-CN.md`, `SKILL.md`, `SKILL.zh-CN.md`, `index.html`, `LICENSE`, `.gitattributes`, and vetted `assets/`, `scripts/`, `references/`, and `references/en/` files. Never run blind recursive exports that pull in outer workspace history, raw PDFs, third-party reference bundles, real topologies/accounts, runtime reports, manifests, logs, or personal photos.

The MIT License covers original code and documentation authored for this project. Referencing product names implies no affiliation or endorsement. Any third-party material must be audited separately for redistribution rights.

## On-Machine Self-Verification Checklist (Required Before Attaching Production Accounts)

- Verify firmware sysctl order, init service start/reload failure behavior, NIC/subnet alignment, `nft -c` syntax, zero-forwarding failure state, and out-of-band recovery.
- Capture desensitized WAN/local evidence covering **cold boot, warm reboot / reload failure, entry-block negative drill, stale-session revocation, second-NIC absence, DNS, IPv6, UDP/QUIC, browser WebRTC, and PMTU**, preserving timestamps, config hashes, and test directions.
- Verify Windows ACLs, actual three-profile GPO filter values, restricted desktop user Read/Execute permissions, Inspect task exit codes, MSIX publisher/identity matching, confirmation timeout, `BUSY` concurrency handling, request expiry, and missing-evidence rejection.
- Verify C1 vs C2 acceptance separation, brand-new SSH verification before canceling rollback timers, and explicit A1 vs A2 boundaries.
- Test the 5-minute offline quickstart on a clean machine with zero personal scripts or mounts, verifying `file://` clipboard behavior, storage fallback, and manual copy UX in the target browser.
