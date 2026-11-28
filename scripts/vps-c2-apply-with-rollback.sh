#!/bin/sh
# Apply a rendered C2 rules file whose changes are confined to inet cf_vps_c2.
set -eu

die() {
    printf '%s\n' "$*" >&2
    exit 1
}

rules=
timeout=180s
backup_dir=/var/backups/claude-fortress
dry_run=0
confirmed=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --rules|--timeout|--backup-dir)
            [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 requires a value"
            case "$1" in
                --rules) rules=$2 ;;
                --timeout) timeout=$2 ;;
                --backup-dir) backup_dir=$2 ;;
            esac
            shift 2
            ;;
        --dry-run) dry_run=1; shift ;;
        --confirm-tier-c) confirmed=1; shift ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[ -n "$rules" ] || die "Usage: $0 --rules PATH [--timeout 180s] [--backup-dir DIR] [--dry-run | --confirm-tier-c]"
[ -f "$rules" ] && [ -r "$rules" ] || die "Rules file must be a readable regular file: $rules"
case "$timeout" in
    *s) seconds=${timeout%s} ;;
    *) die "--timeout must be a positive number of seconds followed by s" ;;
esac
case "$seconds" in
    ''|*[!0-9]*) die "--timeout must be a positive number of seconds followed by s" ;;
esac
[ "$seconds" -gt 0 ] 2>/dev/null || die "--timeout must be greater than zero"

if [ "$dry_run" -eq 0 ]; then
    [ "$confirmed" -eq 1 ] || die "Apply requires --confirm-tier-c"
    [ "$(id -u)" -eq 0 ] || die "Apply requires root"
fi

for tool in nft systemd-run systemctl; do
    command -v "$tool" >/dev/null 2>&1 || die "Required command not found: $tool"
done
nft_bin=$(command -v nft)

validate_rules() {
    # Commented examples, such as the optional skuid match, are not active rules.
    if grep -E '^[^#]*<[^<>]+>' < "$1" >/dev/null; then
        die "Unreplaced placeholder in rules: $1"
    else
        [ "$?" -eq 1 ] || die "Could not scan rules: $1"
    fi
    "$nft_bin" -c -f "$1" || die "Rules rejected by nft -c -f: $1"
}

if [ "$dry_run" -eq 1 ]; then
    validate_rules "$rules"
    printf '%s\n' 'Dry run passed (nft -c -f).'
    exit 0
fi

flock_bin=$(command -v flock) || die "Required command not found: flock"
lock=/run/cf-vps-c2.lock
umask 077
exec 9>>"$lock"
"$flock_bin" -x 9

validate_rules "$rules"
case "$backup_dir" in
    /*) ;;
    *) backup_dir=$PWD/$backup_dir ;;
esac
mkdir -p "$backup_dir"
transaction=$(mktemp -d "$backup_dir/cf-vps-c2.XXXXXXXX")
candidate=$transaction/apply.nft
rollback=$transaction/rollback.nft
cat < "$rules" > "$candidate"
validate_rules "$candidate"

tables=$("$nft_bin" list tables) || die "Could not list existing nftables tables"
printf '%s\n' 'add table inet cf_vps_c2' 'delete table inet cf_vps_c2' > "$rollback"
if printf '%s\n' "$tables" | grep -Fx 'table inet cf_vps_c2' >/dev/null; then
    "$nft_bin" -n list table inet cf_vps_c2 >> "$rollback" || die "Could not back up inet cf_vps_c2"
fi
"$nft_bin" -c -f "$rollback" || die "Rollback rules failed validation: $rollback"

unit=cf-vps-c2-rollback
stop_previous_unit() {
    # show may return nonzero for a missing unit while still reporting not-found.
    load_state=$(systemctl show --property=LoadState --value "$1") || {
        [ "$load_state" = not-found ] || die "Could not query $1"
    }
    [ "$load_state" != not-found ] || return 0
    if ! systemctl stop "$1"; then
        load_state=$(systemctl show --property=LoadState --value "$1") || :
        [ "$load_state" = not-found ] || die "Could not stop $1"
    fi
}
stop_previous_unit "$unit.timer"
stop_previous_unit "$unit.service"

# systemd 252 expands dollar expressions in service arguments.
service_rollback=$(printf '%s\n' "$rollback" | sed 's/\$/$$/g')
systemd-run --unit="$unit" --on-active="$timeout" --collect \
    --timer-property=AccuracySec=100ms --timer-property=RemainAfterElapse=no \
    "$flock_bin" -x "$lock" "$nft_bin" -f "$service_rollback" ||
    die "Could not arm automatic rollback"

if ! "$nft_bin" -f "$candidate"; then
    die "Apply failed; automatic rollback remains armed. Backup: $rollback"
fi
printf 'Applied inet cf_vps_c2. Rollback in %s. Backup: %s\n' "$timeout" "$rollback"
printf '%s\n' 'Verify access from a new SSH session, then run:' \
    '  systemctl stop cf-vps-c2-rollback.timer'
