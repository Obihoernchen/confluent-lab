#!/usr/bin/env bash
# Tear the lab down again: the lab's VMs, network, storage pool, the
# BMC processes and run/.  The download cache is removed too unless
# --keep-cache is given (keeping it makes the next setup much faster).
# Options: -y/--yes  no confirmation, --keep-cache  keep $CACHEDIR
set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh

KEEP_CACHE=0
for arg in "$@"; do
    case $arg in
        -y|--yes) ASSUME_YES=1 ;;
        --keep-cache) KEEP_CACHE=1 ;;
        -h|--help) usage ;;
        *) die "unknown option: $arg (try --help)" ;;
    esac
done

doms=''
for dom in "$SERVER_VM" "$NODE01_VM" "$NODE02_VM"; do
    vrsh dominfo "$dom" >/dev/null 2>&1 && doms="$doms $dom"
done
doms=${doms# }
printf '%s\n' "This removes everything the lab created on this machine:"
printf '%s\n' "  - VMs: ${doms:-none} (and their UEFI nvram)"
printf '%s\n' "  - libvirt network $NET_INTERNAL and storage pool $POOL ($LABDIR)"
printf '%s\n' "  - tmux session $TMUX_SESSION, the BMC processes and $RUNDIR"
printf '%s\n' "  - console logs $CONSOLEDIR/confluent*.log (needs sudo)"
if [ $KEEP_CACHE = 0 ]; then
    printf '%s\n' "  - download cache $CACHEDIR (~12 GB; use --keep-cache to keep it)"
fi
milestone "Destroy the lab?"

tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
pkill -f "sushy-emulator --config $RUNDIR/sushy/" 2>/dev/null || true

for dom in $doms; do
    vrsh destroy "$dom" >/dev/null 2>&1 || true
    run_lab vrsh undefine "$dom" --nvram >/dev/null
done

if vrsh net-info "$NET_INTERNAL" >/dev/null 2>&1; then
    vrsh net-destroy "$NET_INTERNAL" >/dev/null 2>&1 || true
    run_lab vrsh net-undefine "$NET_INTERNAL" >/dev/null
fi

if vrsh pool-info "$POOL" >/dev/null 2>&1; then
    vrsh pool-start "$POOL" >/dev/null 2>&1 || true
    for vol in $(vrsh vol-list "$POOL" 2>/dev/null | awk 'NR>2 && $1 {print $1}'); do
        run_lab vrsh vol-delete "$vol" --pool "$POOL" >/dev/null
    done
    vrsh pool-destroy "$POOL" >/dev/null 2>&1 || true
    run_lab vrsh pool-undefine "$POOL" >/dev/null
    sudo rmdir "$LABDIR" 2>/dev/null || true
fi

if ls "$CONSOLEDIR"/confluent*.log >/dev/null 2>&1; then
    run_lab sudo rm -f "$CONSOLEDIR"/confluent*.log
fi

firewall_close

rm -rf "$RUNDIR"
if [ $KEEP_CACHE = 0 ]; then
    rm -rf "$CACHEDIR"
fi

printf '%s\n' "${C_GREEN}Lab destroyed.${C_OFF}"
