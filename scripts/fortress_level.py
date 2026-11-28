#!/usr/bin/env python3
"""Fortress Level reference calculator (host-side, stdlib only, read-only).

Reads an evidence v3 JSON file and assets/levels.json, and prints the level the
evidence supports. It never touches the network and never writes files.

    python scripts/fortress_level.py evidence.json
    python scripts/fortress_level.py evidence.json --json --now 2026-12-01T00:00:00Z
    python scripts/fortress_level.py evidence.json --current-config-sha256 <hash>

Exit codes: 0 evaluated (see "level"), 2 invalid evidence, 64 usage error.
The offline report page must produce identical results for tests/fixtures/levels.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_LEVELS = ROOT / "assets" / "levels.json"
SHA256_RE = re.compile(r"^[a-f0-9]{64}$")
REQUEST_RE = re.compile(r"^[a-f0-9]{32}$")
PASSING = {"pass", "user_attested"}


def parse_utc(value: str) -> dt.datetime:
    if not isinstance(value, str) or not value.endswith("Z"):
        raise ValueError(f"timestamp must be UTC ISO-8601 ending in Z: {value!r}")
    return dt.datetime.fromisoformat(value[:-1] + "+00:00")


def iso(ts: dt.datetime) -> str:
    return ts.astimezone(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def find_profile(levels: dict, route: str, component: str) -> tuple[str, dict] | tuple[None, None]:
    for name, prof in levels["profiles"].items():
        if prof["route"] == route and prof["component"] == component:
            return name, prof
    return None, None


def required_by_level(prof: dict, conditions: dict) -> list[tuple[str, list[str]]]:
    """Per level, the checks that level adds, after applying conditions."""
    out = []
    for level_id, entries in prof["requires"].items():
        checks = []
        for entry in entries:
            if isinstance(entry, str):
                checks.append(entry)
            elif conditions.get(entry["when"]) is True:
                checks.append(entry["check"])
        out.append((level_id, checks))
    return out


def evaluate(evidence: dict, levels: dict, now: dt.datetime | None = None,
             current_config_sha256: str | None = None) -> dict:
    now = now or dt.datetime.now(dt.timezone.utc)
    errors: list[str] = []
    result = {
        "valid": False, "profile": None, "level": None, "max_level": None,
        "missing_for_next": [], "attested": [], "expires_utc": None,
        "expired": False, "config_changed": False, "errors": errors,
    }

    if evidence.get("schema_version") != 3:
        errors.append("schema_version must be 3")
        return result
    if not REQUEST_RE.match(str(evidence.get("request_id", ""))):
        errors.append("request_id must be 32 lowercase hex characters")
    if not SHA256_RE.match(str(evidence.get("config_sha256", ""))):
        errors.append("config_sha256 must be a 64-char lowercase hex digest")

    name, prof = find_profile(levels, evidence.get("route"), evidence.get("component"))
    if not prof:
        errors.append(f"unknown route/component: {evidence.get('route')}/{evidence.get('component')}")
        return result
    result["profile"], result["max_level"] = name, prof["max_level"]

    conditions = evidence.get("conditions") or {}
    for key, val in conditions.items():
        if key not in levels["conditions"]:
            errors.append(f"unknown condition: {key}")
        elif not isinstance(val, bool):
            errors.append(f"condition {key} must be true/false")

    checks = evidence.get("checks")
    if not isinstance(checks, dict):
        errors.append("checks must be an object")
        return result

    per_level = required_by_level(prof, conditions)
    all_required = {c for _, cs in per_level for c in cs}
    statuses = levels["statuses"]
    for cid, item in checks.items():
        if cid not in levels["checks"]:
            errors.append(f"unknown check: {cid}")
            continue
        if not isinstance(item, dict) or item.get("status") not in statuses:
            errors.append(f"{cid}: status must be one of {sorted(statuses)}")
            continue
        status = item["status"]
        if status == "user_attested" and not levels["checks"][cid]["attestable"]:
            errors.append(f"{cid}: user_attested is not allowed for this check")
        if status == "not_applicable":
            if cid in all_required:
                errors.append(f"{cid}: required by this profile, cannot be not_applicable")
            if not str(item.get("note", "")).strip():
                errors.append(f"{cid}: not_applicable needs a note")
        if status in PASSING:
            try:
                parse_utc(item.get("captured_utc"))
            except (ValueError, TypeError) as exc:
                errors.append(f"{cid}: {exc}")
    if errors:
        return result
    result["valid"] = True

    achieved = None
    used: list[str] = []
    for level_id, level_checks in per_level:
        missing = [c for c in level_checks if checks.get(c, {}).get("status") not in PASSING]
        if missing:
            result["missing_for_next"] = [
                {"level": level_id, "check": c, "status": checks.get(c, {}).get("status", "not_run")}
                for c in missing
            ]
            break
        achieved = level_id
        used.extend(level_checks)

    result["level"] = achieved
    result["attested"] = sorted(c for c in used if checks[c]["status"] == "user_attested")
    if achieved:
        oldest = min(parse_utc(checks[c]["captured_utc"]) for c in used)
        expires = oldest + dt.timedelta(days=int(levels["expiry_days"]))
        result["expires_utc"] = iso(expires)
        result["expired"] = now >= expires
    if current_config_sha256 is not None:
        result["config_changed"] = current_config_sha256 != evidence["config_sha256"]
    return result


def describe(res: dict, levels: dict, lang: str = "zh") -> str:
    if not res["valid"]:
        return "INVALID\n" + "\n".join(f"- {e}" for e in res["errors"])
    names = {lv["id"]: lv[lang] for lv in levels["levels"]}
    lines = [f"profile: {res['profile']} (max {res['max_level']})"]
    if res["level"]:
        state = []
        if res["expired"]:
            state.append("EXPIRED")
        if res["config_changed"]:
            state.append("CONFIG CHANGED")
        suffix = f"  [{' / '.join(state)}]" if state else ""
        lines.append(f"level: {res['level']} {names[res['level']]}{suffix}")
        lines.append(f"expires: {res['expires_utc']}")
    else:
        lines.append("level: none (L0 not met)")
    if res["attested"]:
        lines.append("user_attested: " + ", ".join(res["attested"]))
    for m in res["missing_for_next"]:
        label = levels["checks"][m["check"]][lang]
        lines.append(f"missing for {m['level']}: {m['check']} ({label}) = {m['status']}")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("evidence")
    ap.add_argument("--levels", default=str(DEFAULT_LEVELS))
    ap.add_argument("--now", help="UTC timestamp ending in Z (default: current time)")
    ap.add_argument("--current-config-sha256")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--lang", choices=["zh", "en"], default="zh")
    args = ap.parse_args(argv)
    try:
        evidence = json.loads(pathlib.Path(args.evidence).read_text(encoding="utf-8"))
        levels = json.loads(pathlib.Path(args.levels).read_text(encoding="utf-8"))
        now = parse_utc(args.now) if args.now else None
    except (OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 64
    res = evaluate(evidence, levels, now, args.current_config_sha256)
    print(json.dumps(res, ensure_ascii=False, indent=2) if args.json else describe(res, levels, args.lang))
    return 0 if res["valid"] else 2


if __name__ == "__main__":
    sys.exit(main())
