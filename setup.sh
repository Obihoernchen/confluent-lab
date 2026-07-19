#!/usr/bin/env bash
# Guided setup of the confluent quickstart lab.  Run ./setup.sh to execute
# all phases in order (finished phases are skipped, re-running is always
# safe), or name phases to run only those, e.g.: ./setup.sh sushy deploy
# Options: -y/--yes  run non-interactively (no milestone pauses)
set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh

args=("$@")
only=()
for arg in "$@"; do
    case $arg in
        -y|--yes) ASSUME_YES=1 ;;
        -h|--help) usage ;;
        *) only+=("$arg") ;;
    esac
done

# Run inside the lab tmux session: setup in the 'main' window, one console
# window per VM alongside (Ctrl-b + window number to look around).
if [ -t 0 ] && [ -z "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
    tmux has-session -t "$TMUX_SESSION" 2>/dev/null || \
        tmux new-session -d -s "$TMUX_SESSION" -n main
    tmux list-windows -t "$TMUX_SESSION" -F '#W' | grep -qx main || \
        tmux new-window -d -t "$TMUX_SESSION" -n main
    ensure_console_windows
    tmux select-window -t "$TMUX_SESSION:main"
    tmux send-keys -t "$TMUX_SESSION:main" \
        "cd $(printf %q "$BASEDIR") && ./setup.sh ${args[*]}" C-m
    exec tmux attach -t "$TMUX_SESSION"
fi
ensure_console_windows

mkdir -p "$RUNDIR"

phasefiles=(phases/[0-9][0-9]-*.sh)
total=${#phasefiles[@]}
num=0
for phasefile in "${phasefiles[@]}"; do
    num=$((num + 1))
    phasename=${phasefile##*/}
    phasename=${phasename%.sh}
    phasename=${phasename#[0-9][0-9]-}
    if [ ${#only[@]} -gt 0 ]; then
        keep=0
        for o in "${only[@]}"; do
            [ "$o" = "$phasename" ] && keep=1
        done
        [ $keep = 1 ] || continue
    fi
    PHASE_DESC=$phasename
    unset -f phase_check phase_run 2>/dev/null || true
    . "$phasefile"
    section "$num/$total" "$phasename" "$PHASE_DESC"
    if phase_check 2>/dev/null; then
        skip "$PHASE_DESC"
        continue
    fi
    phase_run
done

printf '\n%s\n' "${C_GREEN}${C_BOLD}All requested phases finished.${C_OFF}"
explain "Good to know" \
    "- The BMC processes and the tmux session do not survive a host reboot: run ./services.sh afterwards to restart everything (it also starts the server VM again)." \
    "- ./destroy.sh removes the whole lab from this machine again; with --keep-cache it keeps the downloads, making the next setup much faster."
explain "Current lab state" "(./status.sh shows this any time)"
printf '\n'
./status.sh
