#!/bin/sh
# apply-firewall-fix.sh
#
# Add a UCI network (default: wan2) to the firewall zone named "wan" so that
# traffic egressing through it gets masqueraded.
#
# - Zone is located by name, not by index, so it survives zone reordering.
# - Validates that the network exists and is not already in another zone.
# - Backs up the firewall config before changing anything.
# - Warns if masq is off; rolls back automatically if the reload fails.
#
# Usage:  sh apply-firewall-fix.sh [network] [zone-name]
#         sh apply-firewall-fix.sh wan2 wan
#
# Note: pass the UCI network name (wan2), NOT the device name (pppoe-wan2).

set -f   # disable globbing so section names like @zone[1] are never expanded

IFACE="${1:-wan2}"
ZONE_NAME="${2:-wan}"

die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

command -v uci >/dev/null 2>&1 || die "uci not found; this must run on OpenWrt."

# ---------------------------------------------------------------- sanity ----
uci -q get "network.$IFACE" >/dev/null 2>&1 \
    || die "network '$IFACE' is not defined in /etc/config/network
       (use the UCI network name, e.g. wan2, not the device name pppoe-wan2)."

# ------------------------------------------------- list all zone sections ---
# "uci show" emits a type line "firewall.<section>=zone" for every zone.
# Section names never contain '.', so [^.]* is a safe anchor.
ZONES="$(uci show firewall | sed -n 's/^\(firewall\.[^.]*\)=zone$/\1/p')"
[ -n "$ZONES" ] || die "no firewall zones found in /etc/config/firewall."

# ------------------------------------------------- find target zone --------
SECTION=""
for z in $ZONES; do
    if [ "$(uci -q get "$z.name")" = "$ZONE_NAME" ]; then
        SECTION="${z#firewall.}"
        break
    fi
done

[ -n "$SECTION" ] || die "firewall zone '$ZONE_NAME' not found."

# ---------------------------------------------------- already a member? ----
for n in $(uci -q get "firewall.$SECTION.network" 2>/dev/null); do
    if [ "$n" = "$IFACE" ]; then
        printf 'OK: %s is already in zone %s (%s). Nothing to do.\n' \
            "$IFACE" "$ZONE_NAME" "$SECTION"
        exit 0
    fi
done

# ----------------------------------------- member of a different zone? -----
# A network in two zones gives ambiguous behaviour, so refuse and explain.
for z in $ZONES; do
    [ "$z" = "firewall.$SECTION" ] && continue
    for n in $(uci -q get "$z.network" 2>/dev/null); do
        if [ "$n" = "$IFACE" ]; then
            other="$(uci -q get "$z.name")"
            die "'$IFACE' is already in zone '${other:-$z}'. Remove it there first:
    uci del_list $z.network=$IFACE && uci commit firewall"
        fi
    done
done

# ---------------------------------- fw4: raw device listed in the zone? ----
for d in $(uci -q get "firewall.$SECTION.device" 2>/dev/null); do
    if [ "$d" = "pppoe-$IFACE" ] || [ "$d" = "$IFACE" ]; then
        warn "device '$d' is already listed in zone '$ZONE_NAME';"
        warn "adding network '$IFACE' as well (harmless, but redundant)."
    fi
done

# ------------------------------------------------------ masq sanity --------
case "$(uci -q get "firewall.$SECTION.masq" 2>/dev/null || echo 0)" in
    1) : ;;
    *) warn "zone '$ZONE_NAME' does not have masq enabled;"
       warn "traffic will NOT be NATed until you run:"
       warn "    uci set firewall.$SECTION.masq=1 && uci commit firewall" ;;
esac

# ------------------------------------------------------------ backup -------
BACKUP="/tmp/firewall.bak.$(date +%s)"
if uci export firewall > "$BACKUP" 2>/dev/null; then
    printf 'Backup written to %s\n' "$BACKUP"
else
    warn "could not write backup to $BACKUP; continuing."
    BACKUP=""
fi

# ------------------------------------------------------------- apply -------
printf 'Adding %s to zone %s (%s)...\n' "$IFACE" "$ZONE_NAME" "$SECTION"
uci add_list "firewall.$SECTION.network=$IFACE" || die "uci add_list failed."

if ! uci commit firewall; then
    uci revert firewall 2>/dev/null
    die "uci commit failed; staged change reverted."
fi

if ! /etc/init.d/firewall reload; then
    warn "firewall reload failed; rolling back."
    uci del_list "firewall.$SECTION.network=$IFACE"
    uci commit firewall
    /etc/init.d/firewall reload >/dev/null 2>&1
    die "reload failed, change rolled back.${BACKUP:+ Backup kept at $BACKUP.}"
fi

# ------------------------------------------------------------ report -------
echo
echo "Result:"
uci show "firewall.$SECTION"

echo
echo "Verify masquerading with one of:"
echo "    nft list ruleset | grep -i masquerade     # fw4 (OpenWrt 22.03+)"
echo "    iptables -t nat -S | grep -i masq         # fw3 (older)"
