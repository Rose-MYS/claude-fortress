# AGENTS.md — Claude Fortress Contributor & Coding-Agent Guidelines

This file defines repository-wide engineering rules for coding agents (Codex, Claude, Antigravity, etc.) and human maintainers working on `claude-fortress`.

## 1. Core Principles

- **Evidence Over Assumptions**: Distinguish clearly between *documented design*, *offline/synthetic test*, *CI test*, and *single-machine live test*. Never present a single command exit code as a whole-machine security guarantee.
- **Field Verification Is a Sample, Not Certification**: Live tests performed on one Windows/OpenWrt/Debian machine are reference samples, not universal certification across all OS builds, proxies, or browsers. Untested combinations remain `unknown` and gates stay fail-closed.
- **Delegated Replies Never Bind Decisions**: If a user replies *"up to you"* or *"whatever works"* when choosing a route or high-risk action, propose one concrete option and wait for explicit confirmation before binding it.
- **Zero Credentials & Zero PII**: Never commit real emails, public/residential IPs, passwords, tokens, subscription URLs, UUIDs, private keys, personal real names, or local personal paths (`C:\Users\<name>`, `<LOCAL_WORKSPACE_PATH>`, etc.). Use RFC 5737 test IPv4 ranges (`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`) and explicit `<PLACEHOLDER>` tokens.

## 2. Bilingual & Structure Discipline

- Keep `SKILL.md` / `SKILL.zh-CN.md`, `references/*.md` / `references/en/*.md`, and `assets/interactive-guide.html` / `assets/interactive-guide.en.html` in sync.
- Keep scripts dependency-free (Python 3.10+ standard library, PowerShell 5.1+, POSIX `sh`, Node.js built-in `WebSocket`) so users can run them without heavy package installs.
- Update `CHANGELOG.md` for every user-facing release or behavioral change.

## 3. Verification Before Pushing

Run the stdlib regression suite before every commit or PR:

```bash
python -m unittest discover -s tests -v
```

The suite verifies JSON schemas, Python/Node/PowerShell syntax, Markdown relative links, EN/ZH file parity, PII/secret redlines, and offline fail-closed behavior of the bundled scripts. Do not weaken assertions or delete tests to make CI green.
