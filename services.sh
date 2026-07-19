#!/usr/bin/env bash
# (Re)start the lab's host-side services.  Nothing of the lab is installed
# as a system service, so this script is the one thing to run after a host
# reboot.  It configures/starts:
#   - the host firewall openings for the BMC ports (firewalld, ufw or plain
#     nftables -- whichever is active is detected and configured)
#   - the two virtual BMCs (sushy-emulator), as background processes of your
#     user; their logs land in run/sushy/node0[12].log
#   - the lab tmux session with the VM console windows
#   - the confluent server VM, if it is defined but powered off
# Usage: ./services.sh [-y|--yes]
set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh

for arg in "$@"; do
    case $arg in
        -y|--yes) ASSUME_YES=1 ;;
        -h|--help) usage ;;
        *) die "unknown option: $arg (try --help)" ;;
    esac
done

# --- firewall ---------------------------------------------------------------
firewall_open || warn "could not configure the host firewall; see the README troubleshooting section"

# --- virtual BMCs -----------------------------------------------------------
if [ -x "$RUNDIR/sushy/venv/bin/sushy-emulator" ]; then
    for node in node01 node02; do
        case $node in
            node01) port=$SUSHY_PORT_NODE01 ;;
            node02) port=$SUSHY_PORT_NODE02 ;;
        esac
        if bmc_alive "$port"; then
            ok "BMC for $node already answering on https://192.168.122.1:$port"
            continue
        fi
        pkill -f "sushy-emulator --config $RUNDIR/sushy/$node.conf" 2>/dev/null || true
        printf '%s\n' "${C_DIM}  [lab] sushy-emulator --config $RUNDIR/sushy/$node.conf (background, log: run/sushy/$node.log)${C_OFF}"
        setsid "$RUNDIR/sushy/venv/bin/sushy-emulator" \
            --config "$RUNDIR/sushy/$node.conf" \
            >>"$RUNDIR/sushy/$node.log" 2>&1 </dev/null &
        for _ in $(seq 20); do
            bmc_alive "$port" && break
            sleep 1
        done
        bmc_alive "$port" || \
            die "BMC for $node did not come up; inspect $RUNDIR/sushy/$node.log"
        ok "BMC for $node listening on https://192.168.122.1:$port (admin/$LABPASSWORD)"
    done
else
    warn "BMCs are not set up yet (run ./setup.sh); skipping them"
fi

# --- lab tmux session with the VM console windows ---------------------------
if command -v tmux >/dev/null 2>&1 && \
        ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    tmux new-session -d -s "$TMUX_SESSION" -n main
fi
ensure_console_windows

# --- server VM --------------------------------------------------------------
if vrsh dominfo "$SERVER_VM" >/dev/null 2>&1 && \
        ! vrsh domstate "$SERVER_VM" 2>/dev/null | grep running >/dev/null; then
    run_lab vrsh start "$SERVER_VM"
fi

printf '%s\n' "VM consoles live in tmux session '$TMUX_SESSION' (tmux attach -t $TMUX_SESSION);"
printf '%s\n' "BMC logs are in run/sushy/. Node VMs are powered via their BMCs (nodepower on the server)."
