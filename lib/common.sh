# shellcheck shell=bash disable=SC2034,SC2154
# Shared helpers for the confluent quickstart lab.  Sourced by setup.sh,
# destroy.sh, status.sh and services.sh -- not meant to be executed directly.

BASEDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RUNDIR=$BASEDIR/run
. "$BASEDIR/lab.conf"

SERVER_VM=confluent
NODE01_VM=confluent-node01
NODE02_VM=confluent-node02
NET_INTERNAL=confluent-internal
NET_BRIDGE=cflqs0
POOL=confluent-lab
SERVER_INTERNAL_IP=$INTERNAL_NET.1
NODE01_IP=$INTERNAL_NET.11
NODE02_IP=$INTERNAL_NET.12
MAC_MGMT=$MAC_PREFIX:01
MAC_INTERNAL=$MAC_PREFIX:02
MAC_NODE01=$MAC_PREFIX:11
MAC_NODE02=$MAC_PREFIX:12
SUSHY_PORT_NODE01=$((SUSHY_PORT_BASE + 1))
SUSHY_PORT_NODE02=$((SUSHY_PORT_BASE + 2))
BMC_ADDR_NET=${BMC_ADDR_BASE%.*}
BMC_ADDR_OCTET=${BMC_ADDR_BASE##*.}
BMC_IP_NODE01=$BMC_ADDR_NET.$((BMC_ADDR_OCTET + 1))
BMC_IP_NODE02=$BMC_ADDR_NET.$((BMC_ADDR_OCTET + 2))
ASSUME_YES=${ASSUME_YES:-0}

vrsh() { virsh -c qemu:///system "$@"; }

if [ -t 1 ]; then
    C_DIM=$'\e[2m' C_BOLD=$'\e[1m' C_CMD=$'\e[1;34m' C_GREEN=$'\e[32m'
    C_YELLOW=$'\e[33m' C_RED=$'\e[1;31m' C_OFF=$'\e[0m' C_TXT=$'\e[32m'
else
    C_DIM='' C_BOLD='' C_CMD='' C_GREEN='' C_YELLOW='' C_RED='' C_OFF='' C_TXT=''
fi

explain() {  # <bold heading> [body...]; body args flow as one paragraph,
             # args starting with '- ' or indentation begin a new line (lists).
             # The body is indented two spaces under the heading, wrapped list
             # lines get an additional hanging indent, max width 100 columns.
    local head=$1 out='' a line prevlist=0
    shift
    printf '\n%s\n' "${C_BOLD}${C_TXT}${head}${C_OFF}"
    [ $# -gt 0 ] || return 0
    for a in "$@"; do
        case $a in
            '- '*|' '*)
                out="$out"$'\n'"$a"
                prevlist=1 ;;
            *)
                if [ -z "$out" ]; then
                    out=$a
                elif [ "$prevlist" = 1 ]; then
                    out="$out"$'\n'"$a"
                else
                    out="$out $a"
                fi
                prevlist=0 ;;
        esac
    done
    printf '%s' "$C_TXT"
    while IFS= read -r line; do
        case $line in
            '- '*|' '*) printf '%s\n' "$line" | fold -s -w 96 | sed -e '1s/^/  /' -e '2,$s/^/    /' ;;
            *) printf '%s\n' "$line" | fold -s -w 98 | sed 's/^/  /' ;;
        esac
    done <<EOF
$out
EOF
    printf '%s' "$C_OFF"
}

section() {  # <n/m> <name> <description> -- big banner between main sections
    local bar
    bar=$(printf '%100s' '' | tr ' ' '#')
    printf '\n%s\n' "${C_BOLD}$bar${C_OFF}"
    printf '%s\n'   "${C_BOLD}##${C_OFF}"
    printf '%s\n'   "${C_BOLD}##   [$1]  ${2^^}${C_OFF}"
    printf '%s\n'   "${C_BOLD}##   $3${C_OFF}"
    printf '%s\n'   "${C_BOLD}##${C_OFF}"
    printf '%s\n' "${C_BOLD}$bar${C_OFF}"
}

usage() {  # print the header comment block of the calling script and exit
    sed -n '2,/^[^#]/p' "$0" | sed -n 's/^# \{0,1\}//p'
    exit 0
}
skip()      { printf '%s\n' "${C_DIM}  SKIP: $* (already done)${C_OFF}"; }
ok()        { printf '%s\n' "  ${C_GREEN}OK:${C_OFF} $*"; }
warn()      { printf '%s\n' "  ${C_YELLOW}WARNING:${C_OFF} $*"; }
die()       { printf '%s\n' "${C_RED}ERROR:${C_OFF} $*" >&2; exit 1; }

# Lab plumbing on this host: dim echo of the command, then run it.
run_lab() { printf '%s\n' "${C_DIM}  [lab] $*${C_OFF}"; "$@"; }

milestone() {
    printf '\n%s\n' "${C_BOLD}==> $*${C_OFF}"
    if [ "$ASSUME_YES" != 1 ] && [ -t 0 ]; then
        read -r -p '    Press Enter to continue (Ctrl-C to abort)... '
    fi
}

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new
          -o UserKnownHostsFile="$RUNDIR/known_hosts" -o LogLevel=ERROR)

# Quiet remote execution on the server VM (lab plumbing between the visible
# commands).  Multi-line command strings are fine.
vssh() { ssh "${SSH_OPTS[@]}" "root@$SERVER_MGMT_IP" "export PATH=/opt/confluent/bin:\$PATH; $*"; }
vscp() { scp -q "${SSH_OPTS[@]}" "$@"; }

# Lab plumbing that runs inside the server VM: dim echo, quiet execution.
run_vlab() { printf '%s\n' "${C_DIM}[lab@confluent ~]# $*${C_OFF}"; vssh "$*"; }

# A command worth learning, run on the confluent server VM: the command line
# is highlighted and its output streams live to the terminal.  This marker
# separates the actual confluent workflow from lab plumbing.  In interactive
# mode the shown command runs only after Enter confirms it.
run_cfl() {
    printf '\n%s\n' "${C_CMD}[root@confluent ~]# $*${C_OFF}"
    if [ "$ASSUME_YES" != 1 ] && [ -t 0 ]; then
        read -r -p "[Enter to run] "
    fi
    ssh -t "${SSH_OPTS[@]}" "root@$SERVER_MGMT_IP" \
        "export PATH=/opt/confluent/bin:\$PATH; $*"
}

stateful_profile() {
    vssh "ls /var/lib/confluent/public/os 2>/dev/null | grep -- '-default\$' | head -n 1" 2>/dev/null || true
}

bmc_alive() {  # <port>
    curl -skfm 5 -u "admin:$LABPASSWORD" "https://192.168.122.1:$1/redfish/v1" >/dev/null 2>&1
}

collect_pubkeys() {
    PUBKEYS=()
    local k
    for k in "$HOME"/.ssh/id_*.pub; do
        [ -f "$k" ] && PUBKEYS+=("$k")
    done
    [ ${#PUBKEYS[@]} -gt 0 ] || die \
        "no ssh public key found (~/.ssh/id_*.pub); create one with: ssh-keygen -t ed25519"
}

detect_ovmf() {
    if [ -n "${OVMF_CODE:-}" ] && [ -n "${OVMF_VARS_TEMPLATE:-}" ]; then
        return 0
    fi
    local pair
    for pair in \
        '/usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_VARS.fd' \
        '/usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_VARS_4M.fd' \
        '/usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_VARS.fd' \
        '/usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_VARS.4m.fd'; do
        set -- $pair
        if [ -f "$1" ] && [ -f "$2" ]; then
            OVMF_CODE=$1 OVMF_VARS_TEMPLATE=$2
            return 0
        fi
    done
    die "no OVMF UEFI firmware found; install edk2-ovmf (Fedora/EL) or ovmf (Debian/Ubuntu), or set OVMF_CODE / OVMF_VARS_TEMPLATE in lab.conf"
}

detect_qemu() {
    [ -n "${QEMU_EMULATOR:-}" ] && return 0
    for QEMU_EMULATOR in /usr/libexec/qemu-kvm /usr/bin/qemu-system-x86_64; do
        [ -x "$QEMU_EMULATOR" ] && return 0
    done
    die "no qemu binary found; install qemu-kvm"
}

mkcidata() {  # <output.iso> <directory with user-data meta-data network-config>
    if command -v xorrisofs >/dev/null 2>&1; then
        xorrisofs -quiet -output "$1" -volid cidata -joliet -rock "$2" >/dev/null 2>&1
    else
        genisoimage -quiet -output "$1" -volid cidata -joliet -rock "$2" >/dev/null 2>&1
    fi
}

# --- lab tmux session helpers -----------------------------------------------

# One window per VM tailing its serial console log; created in the lab
# session so installs can be watched live (windows con-confluent,
# con-node01, con-node02).
ensure_console_windows() {
    command -v tmux >/dev/null 2>&1 || return 0
    tmux has-session -t "$TMUX_SESSION" 2>/dev/null || return 0
    tmux set-option -t "$TMUX_SESSION" mouse on 2>/dev/null || true
    local vm name
    for vm in "$SERVER_VM" "$NODE01_VM" "$NODE02_VM"; do
        name=con-${vm#confluent-}
        tmux list-windows -t "$TMUX_SESSION" -F '#W' 2>/dev/null \
            | grep -qx "$name" && continue
        tmux new-window -d -t "$TMUX_SESSION" -n "$name" \
            "sudo tail -F $CONSOLEDIR/$vm.log"
    done
}

# Switch the lab session to the given window -- only when this script runs
# attached to the lab session itself, so it never yanks around other sessions.
console_focus() {  # <window name, e.g. con-node01 or main>
    [ -n "${TMUX:-}" ] || return 0
    [ "$(tmux display-message -p '#S' 2>/dev/null)" = "$TMUX_SESSION" ] || return 0
    tmux select-window -t "$TMUX_SESSION:$1" 2>/dev/null || true
}

# --- host firewall: allow VM-to-host traffic to the BMC emulators -----------
# firewalld, ufw and plain nftables rulesets are supported, whichever is
# active is configured (runtime only; services.sh runs after every reboot).

nft_input_chain() {  # prints "<family> <table> <chain>" of the first input filter hook
    sudo nft list chains 2>/dev/null | awk '
        /^table/ {fam=$2; tab=$3}
        /^[[:space:]]*chain/ {chain=$2}
        /hook input/ {print fam, tab, chain; exit}'
}

firewall_kind() {
    if systemctl is-active firewalld >/dev/null 2>&1; then
        echo firewalld
    elif command -v ufw >/dev/null 2>&1 && \
            sudo ufw status 2>/dev/null | grep -q '^Status: active'; then
        echo ufw
    elif command -v nft >/dev/null 2>&1 && [ -n "$(nft_input_chain)" ]; then
        echo nftables
    else
        echo none
    fi
}

firewall_open() {
    local fam tab chain
    case $(firewall_kind) in
        firewalld)
            # runtime only: services.sh runs after every reboot anyway
            sudo firewall-cmd --quiet --zone=libvirt \
                --add-port="$SUSHY_PORT_NODE01/tcp" \
                --add-port="$SUSHY_PORT_NODE02/tcp" || return 1
            ok "firewalld: BMC ports opened in the 'libvirt' zone (runtime)"
            ;;
        ufw)
            sudo ufw allow proto tcp from 192.168.122.0/24 to any \
                port "$SUSHY_PORT_NODE01,$SUSHY_PORT_NODE02" \
                comment confluent-quickstart-lab >/dev/null || return 1
            ok "ufw: BMC ports allowed from 192.168.122.0/24"
            ;;
        nftables)
            if ! sudo nft list ruleset 2>/dev/null | grep -q confluent-quickstart-lab; then
                read -r fam tab chain <<<"$(nft_input_chain)"
                sudo nft insert rule "$fam" "$tab" "$chain" \
                    ip saddr 192.168.122.0/24 \
                    tcp dport "{ $SUSHY_PORT_NODE01, $SUSHY_PORT_NODE02 }" \
                    accept comment '"confluent-quickstart-lab"' || return 1
            fi
            ok "nftables: BMC ports accepted for 192.168.122.0/24 (runtime rule)"
            ;;
        none)
            ;;
    esac
}

firewall_close() {
    local fam tab chain handle
    case $(firewall_kind) in
        firewalld)
            sudo firewall-cmd --quiet --zone=libvirt \
                --remove-port="$SUSHY_PORT_NODE01/tcp" \
                --remove-port="$SUSHY_PORT_NODE02/tcp" 2>/dev/null || true
            ;;
        ufw)
            sudo ufw delete allow proto tcp from 192.168.122.0/24 to any \
                port "$SUSHY_PORT_NODE01,$SUSHY_PORT_NODE02" \
                >/dev/null 2>&1 || true
            ;;
        nftables)
            read -r fam tab chain <<<"$(nft_input_chain)"
            [ -n "${chain:-}" ] || return 0
            handle=$(sudo nft -a list chain "$fam" "$tab" "$chain" 2>/dev/null \
                | awk '/confluent-quickstart-lab/ {print $NF}')
            [ -n "$handle" ] && \
                sudo nft delete rule "$fam" "$tab" "$chain" handle "$handle" 2>/dev/null || true
            ;;
    esac
}
