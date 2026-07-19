#!/usr/bin/env bash
# One-screen overview of the lab state: VMs, virtual BMCs, confluent service,
# deployment and power state of the nodes, and how to get into everything.
# Usage: ./status.sh
set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh

for arg in "$@"; do
    case $arg in
        -h|--help) usage ;;
        *) die "unknown option: $arg (try --help)" ;;
    esac
done

printf '%s\n' "${C_BOLD}--- virtual machines${C_OFF}"
for dom in "$SERVER_VM" "$NODE01_VM" "$NODE02_VM"; do
    printf '  %-18s %s\n' "$dom" "$(vrsh domstate "$dom" 2>/dev/null || echo 'not defined')"
done

printf '\n%s\n' "${C_BOLD}--- virtual BMCs (background processes, logs in run/sushy/)${C_OFF}"
for node in node01 node02; do
    case $node in
        node01) port=$SUSHY_PORT_NODE01 ;;
        node02) port=$SUSHY_PORT_NODE02 ;;
    esac
    if bmc_alive "$port"; then
        printf '%s\n' "  $node: up   https://192.168.122.1:$port (admin/$LABPASSWORD)"
    else
        printf '%s\n' "  $node: ${C_RED}down${C_OFF} (run ./services.sh)"
    fi
done

printf '\n%s\n' "${C_BOLD}--- confluent server ($SERVER_MGMT_IP)${C_OFF}"
if vssh true 2>/dev/null; then
    printf '%s\n' "  confluent service: $(vssh 'systemctl is-active confluent' 2>/dev/null || true)"
    printf '%s\n' "  deployment state:"
    vssh "nodedeploy node01,node02" 2>/dev/null | sed 's/^/    /' || true
    printf '%s\n' "  power state:"
    vssh "nodepower node01,node02" 2>/dev/null | sed 's/^/    /' || true
else
    printf '%s\n' "  ${C_RED}unreachable over ssh${C_OFF} (VM off? run ./services.sh)"
fi

printf '\n%s\n' "${C_BOLD}--- getting in${C_OFF}"
cat <<EOF
  server:   ssh root@$SERVER_MGMT_IP          (password: $LABPASSWORD, or your ssh key)
  nodes:    ssh -J root@$SERVER_MGMT_IP root@$NODE01_IP   (node01; node02 = $NODE02_IP)
  consoles: sudo tail -f $CONSOLEDIR/confluent-node01.log
            or, from the server VM:  nodeconsole node01
  tmux:     tmux attach -t $TMUX_SESSION   (setup + VM console windows)
EOF
