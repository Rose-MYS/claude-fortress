# 05 | Account Stability, Incident Stop-Loss SOP & Billing Reference

> **Compliance & Authorization**: Follow the laws of your actual jurisdiction and Anthropic's official Terms of Service and eligibility requirements. This playbook focuses strictly on **reducing avoidable environment churn, disciplined incident stop-loss, and official appeals**. All login, billing, subscription, and appeal actions are **Tier-C and user-only** — the Agent never acts on accounts or requests credentials.

---

## 1. Real Incident Lesson (Separating Fact from Inference)

- **Observed fact**: A restriction occurred under a shared egress environment; repeated switching across networks and browsers then introduced multiple extra variables during troubleshooting. This was not a controlled single-variable experiment.
- **Strict attribution boundary**: Because egress and identity changed simultaneously, that single case cannot prove one factor alone caused the restriction. What **is** clear is that **blindly retrying across ASNs and browsers before checking account status rapidly widens the blast radius and contaminates multiple environments**.

---

## 2. Login / Auth Failure Stop-Loss SOP

> Any step involving visiting `claude.ai` is **Tier-C and user-initiated** — never automated during S0/S1.

```text
Login or auth error encountered
  ↓
[Step 1] Stop retrying immediately; start an Incident Timeline per Playbook 07 (timestamps, raw error, recent network/config changes)
  ↓
[Step 2] Run offline / neutral checks locally (did proxy drop, did egress IP / DNS / IPv6 drift?)
  ↓
[Step 3] User decides whether to check official account status and official email notices in the target browser
  ├─ If account is clearly restricted/suspended -> STOP all login attempts, preserve evidence, use Anthropic's official appeal flow
  └─ If account is active and local issue is fixed -> Try once carefully; if it still fails, stop and follow official error guidance
```

---

## 3. Daily Environment Consistency Hygiene

- **Keep egress stable**: Once using a clean, stable egress in a supported region, avoid frequent node hopping or cross-region drift.
- **Avoid mixing host & isolated environments**: Do not bounce the same account between host datacenter proxies and your isolated environment.
- **Moderate concurrency & clean tooling**: Keep concurrency reasonable (remember subagent calls count too) and avoid unauthorized reverse proxies, jailbreak plugins, or unvetted third-party MCPs.
- **Ramp up naturally**: Verify stability under normal light usage first without inventing arbitrary "anti-ban quota numbers."

---

## 4. Billing & Subscription Notes (Official Checkout Is Authoritative)

1. **Pricing & Channels**: Pricing, taxes, and eligibility across Web Checkout, Apple App Store, and Google Play change over time. **Always rely on the official checkout screen for your actual jurisdiction**, and avoid gray-market gift cards or unofficial top-up services.
2. **Mobile Is an Independent Target**: Passing verification on desktop does **not** mean your phone passes; treat mobile network egress, region settings, and app state as a separate target.
3. **Entitlements & Cancellations**: If app-store subscription sync with CLI looks delayed, check official account status pages and docs rather than repeatedly unlinking/re-logging; check official cancellation/re-subscription terms before making changes.
