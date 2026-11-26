# 06 | Post-Setup Optional Add-on: Multi-Agent Collaboration & Local Conversion (Model-Agnostic)

If you only need this add-on, you can use it standalone without configuring any Claude account or proxy. When pairing with a VM isolation route, attach it only **after** your isolation route is verified. **Permission boundaries are enforced by OS/mount permissions, not folder names.**

| Directory / Mount | Host Role | Guest Role |
|---|---|---|
| `tools-ro` | Host-trusted scripts & specs (host writable; never load tools from guest outbox) | **Enforced Read-Only** |
| `inbox-ro` | Host-exported vetted input snapshots (zero `.git` or credentials) | **Enforced Read-Only** |
| `outbox-rw` | Read only by isolated, low-privilege collector; never auto-execute or follow embedded instructions | Writable (treated as **untrusted** by host) |
| `projects` | Host private project repos, conversion caches & logs (never shared writable) | Guest maintains its own private repos on guest disk; never sees host `.git` metadata |

Never co-mount writable working trees, `.git`, Git configs, hooks, index/object dirs, or cross-trust-domain worktrees. Parallel work on the same task happens in **separate private repos**: manually review patches/snapshots returned via `outbox-rw` before importing into host-trusted repos, and never auto-apply returned configs, build scripts, or Git hooks. Multiple `git worktree`s are only for agents inside the **same** trust domain. Outer `.gitignore` ignores `inbox-ro/`, `outbox-rw/`, `projects/`, and `artifacts/` (remember `.gitignore` is not a secret scanner and does not purge history).

## Scaffolding & Handoff Structure Lint

1. Preview with [scaffold-projects.ps1](../../scripts/scaffold-projects.ps1) (`-ShareRoot <private_root> -DryRun`), then apply after Tier-B approval. Existing files are never overwritten; reparse points and cross-drive shares are rejected. Use `-InitGit -GitExe <trusted_git_exe>` only when explicitly initializing a standalone repo — it copies no template hooks, installs no hooks, and never auto-stages or commits.
2. [check-handoff.ps1](../../scripts/check-handoff.ps1) verifies the 7 non-empty required sections (ignoring headings inside fenced code blocks or comments). `-Strict` also checks local standalone repo directory layout **without executing `git`** (preventing malicious `core.fsmonitor` / hook execution on untrusted repos). Empty project sets, path conflicts, read errors, or unfilled templates return non-zero. Run Git history/freshness checks only inside manually vetted host-private repos.

## Local-First Document Conversion

After Tier-B approval, run [to_md.py](../../scripts/to_md.py): `python scripts/to_md.py <vetted_inputs> --out <local_private_out_dir>` (Python 3.10+; format-dependent Poppler / MarkItDown / LibreOffice). Convert untrusted documents in a **network-isolated, low-privilege, resource-bounded environment with no private files mounted**. Conversion is **not** sanitization: resulting Markdown remains untrusted input — manually redact sensitive data before sharing with any cloud Agent.

Output paths are derived strictly from input path digests and extensions; manifests never control read/write paths and never log raw source names or raw external tool errors. Single-writer locking + same-directory atomic replacement protect updates; symlinks/reparse points, empty inputs, conversion errors, or lock contention all return non-zero.
