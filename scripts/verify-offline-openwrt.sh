#!/bin/sh
# Pure offline read-only Route B OpenWrt gateway collector (POSIX ash/sh, zero new runtime).
# Emits Fortress Level evidence v3 JSON (desensitized, no level calculation).
set -eu

TOOL_NAME="verify-offline-openwrt.sh/1.0"
RULES_PATH="/etc/claude-fortress/gateway.nft"
TARGET_ALIAS="openwrt-gateway"
REQUEST_ID=""
OUT_PATH=""
FIXTURE_DIR=""

die() {
    printf '%s\n' "$*" >&2
    exit 2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --rules|--target-alias|--request-id|--out|--fixture-dir)
            [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 requires a value"
            case "$1" in
                --rules) RULES_PATH="$2" ;;
                --target-alias) TARGET_ALIAS="$2" ;;
                --request-id) REQUEST_ID="$2" ;;
                --out) OUT_PATH="$2" ;;
                --fixture-dir) FIXTURE_DIR="$2" ;;
            esac
            shift 2
            ;;
        -h|--help)
            printf '%s\n' "Usage: $0 [--rules PATH] [--target-alias ALIAS] [--request-id 32HEX] [--out PATH] [--fixture-dir DIR]"
            exit 0
            ;;
        *) die "Unknown argument: $1" ;;
    esac
done

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n\r\t' '   '
}

sha256_text() {
    printf '%s' "$1" | sha256sum | awk '{print tolower($1)}'
}

if [ -z "$REQUEST_ID" ]; then
    if [ -r /proc/sys/kernel/random/uuid ]; then
        REQUEST_ID=$(tr -d '-' < /proc/sys/kernel/random/uuid | tr 'A-Z' 'a-z' | cut -c1-32)
    else
        REQUEST_ID=$(sha256_text "$(date -u +%s)-$$-$TARGET_ALIAS" | cut -c1-32)
    fi
fi

if ! printf '%s' "$REQUEST_ID" | grep -Eq '^[a-f0-9]{32}$'; then
    die "request_id must be 32 lowercase hex characters"
fi

NOW_UTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# Collect raw offline facts (either from fixture dir or live OpenWrt)
if [ -n "$FIXTURE_DIR" ]; then
    [ -d "$FIXTURE_DIR" ] || die "Fixture directory not found: $FIXTURE_DIR"
    RULES_FILE="$FIXTURE_DIR/gateway.nft"
    IP4_FWD=$(tr -d '\r\n ' < "$FIXTURE_DIR/ip_forward")
    IP6_ALL=$(tr -d '\r\n ' < "$FIXTURE_DIR/ip6_all_fwd")
    IP6_DEF=$(tr -d '\r\n ' < "$FIXTURE_DIR/ip6_def_fwd")
    NFT_TABLES=$(cat "$FIXTURE_DIR/nft_tables")
    NFT_VM_GATE=$(cat "$FIXTURE_DIR/nft_vm_gate")
    FW4_ENABLED=$(tr -d '\r\n ' < "$FIXTURE_DIR/fw4_enabled")
    FORTRESS_ENABLED=$(tr -d '\r\n ' < "$FIXTURE_DIR/fortress_enabled")
else
    RULES_FILE="$RULES_PATH"
    IP4_FWD=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || printf 'unknown')
    IP6_ALL=$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || printf 'absent')
    IP6_DEF=$(cat /proc/sys/net/ipv6/conf/default/forwarding 2>/dev/null || printf 'absent')
    NFT_TABLES=$(/usr/sbin/nft list tables 2>/dev/null || nft list tables 2>/dev/null || printf '')
    NFT_VM_GATE=$(/usr/sbin/nft list table inet vm_gate 2>/dev/null || nft list table inet vm_gate 2>/dev/null || printf '')
    if [ -x /etc/init.d/firewall ] && /etc/init.d/firewall enabled 2>/dev/null; then
        FW4_ENABLED="1"
    else
        FW4_ENABLED="0"
    fi
    if [ -x /etc/init.d/claude-fortress ] && /etc/init.d/claude-fortress enabled 2>/dev/null; then
        FORTRESS_ENABLED="1"
    else
        FORTRESS_ENABLED="0"
    fi
fi

if [ -f "$RULES_FILE" ]; then
    CONFIG_SHA256=$(sha256sum "$RULES_FILE" | awk '{print tolower($1)}')
else
    CONFIG_SHA256="0000000000000000000000000000000000000000000000000000000000000000"
fi

# Evaluate desensitized offline invariants
HAS_VM_GATE=0
if printf '%s\n' "$NFT_TABLES" | grep -Eq '^[[:space:]]*table inet vm_gate[[:space:]]*$'; then
    HAS_VM_GATE=1
fi
HAS_FW4_TABLE=0
if printf '%s\n' "$NFT_TABLES" | grep -Eq '^[[:space:]]*table inet fw4[[:space:]]*$'; then
    HAS_FW4_TABLE=1
fi

DROP_CHAINS=$(printf '%s\n' "$NFT_VM_GATE" | grep -Ec 'type filter hook (input|output|forward) .*policy drop;') || true
IPV6_DROPS=$(printf '%s\n' "$NFT_VM_GATE" | grep -Ec 'meta nfproto ipv6 .*drop') || true

# Check forward chain for any unexpected UDP accept rule
FWD_UDP_ALLOW=$(printf '%s\n' "$NFT_VM_GATE" | awk '
    /chain forward[[:space:]]*\{/ { in_fwd=1; next }
    in_fwd && /^[[:space:]]*\}/ { in_fwd=0; next }
    in_fwd && /udp/ && /accept/ { count++ }
    END { print count+0 }
')

RAW_SUMMARY="vm_gate=${HAS_VM_GATE};fw4_table=${HAS_FW4_TABLE};fw4_enabled=${FW4_ENABLED};fortress_enabled=${FORTRESS_ENABLED};ip4_fwd=${IP4_FWD};ip6_all=${IP6_ALL};ip6_def=${IP6_DEF};drop_chains=${DROP_CHAINS};ipv6_drops=${IPV6_DROPS};fwd_udp_allow=${FWD_UDP_ALLOW}"
RAW_SHA256=$(sha256_text "$RAW_SUMMARY")

# 1. IPv6 offline check (fail if leaking/missing drop; unknown if offline clean — WAN capture still required for pass)
IPV6_OK=1
IPV6_REASONS=""
if [ "$IP6_ALL" != "0" ] && [ "$IP6_ALL" != "absent" ]; then
    IPV6_OK=0; IPV6_REASONS="${IPV6_REASONS}ip6_all_fwd=${IP6_ALL} "
fi
if [ "$IP6_DEF" != "0" ] && [ "$IP6_DEF" != "absent" ]; then
    IPV6_OK=0; IPV6_REASONS="${IPV6_REASONS}ip6_def_fwd=${IP6_DEF} "
fi
if [ "$HAS_VM_GATE" -ne 1 ] || [ "$IPV6_DROPS" -lt 3 ]; then
    IPV6_OK=0; IPV6_REASONS="${IPV6_REASONS}vm_gate_ipv6_drops=${IPV6_DROPS} "
fi
if [ "$IPV6_OK" -eq 1 ]; then
    IPV6_STATUS="unknown"
    IPV6_NOTE="Offline OpenWrt IPv6 forwarding=0 and 3 nft ipv6 drop rules present; combine with guest NIC check and WAN capture for pass"
else
    IPV6_STATUS="fail"
    IPV6_NOTE="OpenWrt IPv6 offline check failed: ${IPV6_REASONS}"
fi

# 2. UDP forward offline check (fail if forward chain lacks policy drop or allows UDP; unknown if offline clean)
if [ "$HAS_VM_GATE" -eq 1 ] && [ "$DROP_CHAINS" -ge 3 ] && [ "$FWD_UDP_ALLOW" -eq 0 ] && [ "$HAS_FW4_TABLE" -eq 0 ] && [ "$FW4_ENABLED" = "0" ]; then
    UDP_STATUS="unknown"
    UDP_NOTE="Offline OpenWrt forward chain has policy drop, zero UDP forward allow rules, and fw4 disabled; confirm with live UDP probe for pass"
else
    UDP_STATUS="fail"
    UDP_NOTE="OpenWrt UDP/forward invariant failed: vm_gate=${HAS_VM_GATE} drop_chains=${DROP_CHAINS} fwd_udp_allow=${FWD_UDP_ALLOW} fw4_table=${HAS_FW4_TABLE} fw4_enabled=${FW4_ENABLED}"
fi

# 3. Gateway baseline summary attached as note on wan_capture (kept not_run since WAN capture is Tier-C)
GW_NOTE="Offline gateway summary: ${RAW_SUMMARY} (WAN capture itself requires Tier-C live verification)"

emit_check() {
    c_status="$1"
    c_method="$2"
    c_time="$3"
    c_tool="$4"
    c_hash="$5"
    c_note=$(json_escape "$6")
    if [ "$c_time" = "null" ]; then t_val="null"; else t_val="\"$c_time\""; fi
    if [ "$c_hash" = "null" ]; then h_val="null"; else h_val="\"$c_hash\""; fi
    printf '{"status":"%s","method":"%s","captured_utc":%s,"tool":"%s","raw_sha256":%s,"note":"%s"}' \
        "$c_status" "$c_method" "$t_val" "$c_tool" "$h_val" "$c_note"
}

NOT_RUN='{"status":"not_run","method":"","captured_utc":null,"tool":"","raw_sha256":null,"note":""}'
ALIAS_ESC=$(json_escape "$TARGET_ALIAS")

JSON_OUT=$(cat <<EOF
{
  "schema_version": 3,
  "request_id": "$REQUEST_ID",
  "route": "B",
  "component": "system",
  "target_alias": "$ALIAS_ESC",
  "config_sha256": "$CONFIG_SHA256",
  "conditions": {
    "browser_used": true,
    "remote_management": true
  },
  "level_claimed": null,
  "captured_utc": "$NOW_UTC",
  "checks": {
    "egress_dual": $NOT_RUN,
    "ipv6": $(emit_check "$IPV6_STATUS" "offline_openwrt_sysctl_and_nft" "$NOW_UTC" "$TOOL_NAME" "$RAW_SHA256" "$IPV6_NOTE"),
    "dns": $NOT_RUN,
    "browser_webrtc": $NOT_RUN,
    "cold_boot": $NOT_RUN,
    "reload_failure": $NOT_RUN,
    "entry_loss": $NOT_RUN,
    "management_ssh": $NOT_RUN,
    "stability": $NOT_RUN,
    "wan_capture": $(emit_check "not_run" "" "null" "" "null" "$GW_NOTE"),
    "guest_policy": $NOT_RUN,
    "udp": $(emit_check "$UDP_STATUS" "offline_openwrt_forward_policy" "$NOW_UTC" "$TOOL_NAME" "$RAW_SHA256" "$UDP_NOTE"),
    "second_nic": $NOT_RUN,
    "existing_connections": $NOT_RUN,
    "app_fail_closed": $(emit_check "not_applicable" "" "null" "" "null" "Route B is system-level; app-level launcher check does not apply")
  },
  "private_evidence_reference": "<PRIVATE_EVIDENCE_PATH>"
}
EOF
)

if [ -n "$OUT_PATH" ]; then
    printf '%s\n' "$JSON_OUT" > "$OUT_PATH"
else
    printf '%s\n' "$JSON_OUT"
fi
exit 0
