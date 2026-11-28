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

## Optional Add-on: Guest → Host Agent Dispatch (Host Dispatch)

> **Trust Boundary Notice (Tier-C Informed Consent)**: This add-on lets a VM-isolated Claude dispatch structured tasks to whitelisted host agents (`codex` / `agy` / `dsh`). Enabling it widens the guest's influence over the designated shared collaboration root — enable it **only after your isolation route is verified and the user explicitly accepts that shared workspace boundary**. Never expose arbitrary host shell execution to the guest.

### 1. Architecture: Zero-Port Shared-Folder Queue + Guest MCP

Zero network ports are opened between guest and host (preserving VM firewall/proxy isolation). All traffic flows through `<SHARE_ROOT>/dispatch/{pending,running,done,logs,cancel}`:

- **Host Dispatcher Daemon**: [host-dispatcher.mjs](../../scripts/host-dispatcher.mjs) (`node scripts/host-dispatcher.mjs --share-root <HOST_SHARE_ROOT>`). Pure local file polling (zero token cost when idle). Prefer hooking it into your VM launcher so it starts **alongside VM power-on** instead of running continuously when the VM is off.
- **Guest Zero-Dependency MCP Server**: [guest-host-dispatch-mcp.mjs](../../scripts/guest-host-dispatch-mcp.mjs) (sample config: [host-dispatch-mcp.example.json](../../assets/host-dispatch-mcp.example.json)). Exposes 5 tools to guest Claude: `host_health`, `host_dispatch`, `host_task_status`, `host_list_tasks`, and `host_cancel_task`.
- **Whitelisted Host CLI Mapping** (long prompts pass via stdin or prompt files to avoid shell escaping/length limits):
  - `codex` → `codex exec --skip-git-repo-check -C <cwd> --approve-for-me -o <last_msg> -` (`-s read-only` for read-only mode)
  - `agy` (Antigravity) → `agy -p <prompt> --output-format json --mode auto --add-dir <cwd>` (`--mode plan` for read-only mode)
  - `dsh` → `dsh --profile headless -` (ensure the `headless` profile's provider credentials or default model are configured)

### 2. Mandatory Guardrails

1. **Agent Whitelist & Structured Args**: Only `dsh`, `agy`, and `codex` are accepted; arbitrary shell commands are rejected. High-risk `mode="full"` is disabled by default unless `DISPATCH_ALLOW_FULL=1` is explicitly set on the host.
2. **Path Containment & Symlink Escape Rejection**: Every task `cwd` is resolved with `realpath` and must stay strictly inside `--share-root`, otherwise the task is immediately `rejected`.
3. **Per-Directory Write Lock, Concurrency & Timeout**: At most one write task runs per target directory at a time (different project directories can run concurrently up to `MAX_CONC`, default `2`). Default timeout is 600s (max 1800s); timeout or `host_cancel_task` kills the entire process tree.
4. **Loop Prevention**: The dispatcher prepends a context guard forbidding host agents from dispatching back into `dispatch/` or the guest VM, and forbidding remote `git push`.
5. **MCP Call Timeout Safety**: `host_dispatch` defaults to `wait_sec=55` so long tasks return `status: "running"` plus a log tail cleanly instead of triggering client MCP timeouts; the guest agent continues polling via `host_task_status`.

### 3. Reverse Dispatch (Host → Guest Claude) Trade-Offs

- If the guest runs **Claude Desktop** only (GUI), there is no official headless CLI; use read-only `inbox-ro/` snapshots with manual or scheduled pickup rather than fragile UI automation.
- If host-initiated guest invocation is required, install the official **Claude Code CLI** inside the guest and invoke `claude -p` over a controlled management channel (e.g. host-initiated SSH) with single concurrency and `max_depth=1` loop prevention.
