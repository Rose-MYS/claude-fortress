# 04 | Route C: Remote Linux VPS Devbox (Reference Design)

> For users who prefer pure Linux SSH terminal development (Claude Code CLI). **Pick your egress mode first, and always verify out-of-band console access (VNC / Web Console) plus an auto-rollback timer before touching firewall rules.**

---

## 1. Choose One of Two Distinct Egress Contracts

| Mode | Prerequisite | Firewall Goal |
|---|---|---|
| **Mode C1: Native Clean Egress** | VPS itself has a clean static ISP / residential IP in a supported region | Minimal inbound exposure + disable IPv6 leak (if IPv4-only) + standard hardening; makes no proxy fail-closed claim |
| **Mode C2: Compute VPS + Proxy Egress (Default-Deny)** | Standard datacenter VPS used for compute only; must never reach target services from native datacenter IP | **Outbound default-deny (`nftables`)**: allow only management SSH, fixed upstream proxy entry IP:Port, and explicit DNS/update exceptions |

---

## 2. Anti-Lockout Prechecks & Hardening (Tier-B / C)

1. **Out-of-Band Recovery First (Mandatory Tier-C)**: Confirm your provider's Web Console / VNC works. Before loading new outbound `nftables` rules, verify the backup ruleset loads cleanly and arm a timed rollback (e.g., `systemd-run --on-active=3m nft -f /etc/nftables.backup.conf` on systemd hosts). Keep your old session open, open a **brand-new SSH connection** to verify key auth, permissions, and egress/negative checks, and only then cancel the rollback timer.
2. **SSH & OS Hardening**: Key-only SSH, disable password auth, `MaxAuthTries 3`, `fail2ban`, and unattended security updates.
3. **IPv6 & Timezone**: Disable IPv6 egress in both kernel and proxy if using IPv4-only; align timezone with the egress region (`timedatectl set-timezone <TZ>`).

---

## 3. S1 Neutral Verification & Remote IDE Boundaries

1. **Egress & DNS Evidence**:
   - **C1**: Baseline the native egress IP without claiming proxy disconnect blocking.
   - **C2**: Verify proxy egress via two independent neutral endpoints, then run a Tier-C time-limited entry block to prove zero fallback to native datacenter IP.
   - **IPv6 & DNS**: Inspect bindings, routes, resolver logs, and egress captures — never treat a single `curl -6` failure as proof of blocking, and document any update/DNS exceptions explicitly.
2. **Remote IDE / Container Boundaries**: When using VS Code / Cursor Remote-SSH or Docker:
   - Separate local host extensions from remote VPS extensions so local extensions never send Claude requests from the host;
   - Audit SSH port forwarding, Agent Forwarding, and Docker `host` networking so containers cannot bypass outbound rules.

---

## 4. Community GUI Deployment Tools & Caveats

If you prefer a GUI helper for Ubuntu VPS setup (such as community open-source tools like `safe-code` that wrap VPS provisioning, SSH tunnels, XFCE remote desktop, and directory mounts), audit two critical boundaries first:
1. **A GUI installer does not fix datacenter ASN risk**: You must still pick Mode C1 or C2 above — do not blindly use a bare datacenter IP.
2. **Avoid high-risk extensions**: Do not bridge personal subscriptions/CLI through self-hosted API gateway proxies for local desktop apps, and think twice before enabling reverse-SSH host shell control from a cloud VPS (cloud compromise or prompt injection would reach your host account).
