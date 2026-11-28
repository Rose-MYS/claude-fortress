# Guest Claude → Host Multi-Agent Orchestration Rules (Advanced Template)

> Usage: Append this file to `~/.claude/CLAUDE.md` for guest Claude Code, or paste into Claude Desktop Project Instructions / Profile preferences.

You run inside an isolated VM connected via the `host-dispatch` MCP server to whitelisted host agents (`codex`, `agy`, `autoclaw`, `qoder`, `workbuddy`, `dsh`).

## 1. Do Regular Work Yourself (Anti-Over-Delegation)
- Handle routine coding, debugging, editing, documentation, and analysis yourself by default. Do not push ordinary tasks to host agents.
- **Only autonomous delegation trigger**: **host-only capabilities** (tasks strictly requiring host-native tools, software, or environment unavailable inside the guest).
- Do **not** autonomously propose delegation for parallel speedup, cross-model reviews, or bulk work — wait until the user explicitly asks.

## 2. Check the Overview Board First
Before dispatching (whether for an approved host-only proposal or an explicit user request), call `host_agents_overview` to inspect dispatcher health, agent tiers (`high` / `medium` / `low`), strengths, live status (`ready` / `busy` / `rate_limited` / `needs_login`), 5h/today/7d usage, and `quota_hint`. Never dispatch to `enabled=false`, `needs_login`, or cooled-down `rate_limited` agents.

## 3. Explicit Confirmation Gate
- **User explicitly names an agent**: call `host_dispatch` directly.
- **You autonomously propose a host-only task**: before calling `host_dispatch`, **present a brief dispatch plan and pause for explicit user approval** (state why the host is required, exact subtask & target directory, chosen agent with current status/usage, and `read-only` vs `auto` mode).

## 4. No Relaying (Spec & Verification Ownership)
- **Before dispatch**: analyze the problem yourself and write a precise spec (goals, scope, constraints, acceptance criteria). Never forward the user's raw message verbatim.
- **After completion**: inspect the returned summary, modified files/diff, or logs yourself before reporting final results to the user.

## 5. Explicit Fallback on Rate-Limit or Failure
If a host agent returns `rate_limited`, `needs_login`, offline, or failed, **stop and report the reason to the user** with two options — switch to a backup agent or take over yourself — and wait for their decision. Never silently failover. When the user updates quota status or finishes logging in, call `host_update_agent_note` to refresh the board.
