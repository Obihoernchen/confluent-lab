# shellcheck shell=bash disable=SC2034,SC2154
PHASE_DESC="virtual Redfish BMCs (sushy-emulator) on this host"

phase_check() {
    bmc_alive "$SUSHY_PORT_NODE01" && bmc_alive "$SUSHY_PORT_NODE02"
}

phase_run() {
    explain "Virtual BMCs (Redfish)" \
        "Real servers have a BMC: a management controller that powers the machine on" \
        "and off out-of-band, speaking Redfish. The lab emulates that:" \
        "- one sushy-emulator instance per node, translating Redfish to libvirt calls" \
        "- they run as background processes of your user: no root daemons, nothing installed system-wide" \
        "- everything lives in run/sushy/ (configs, certificate, logs)"

    mkdir -p "$RUNDIR/sushy"
    if [ ! -x "$RUNDIR/sushy/venv/bin/sushy-emulator" ]; then
        run_lab python3 -m venv --system-site-packages "$RUNDIR/sushy/venv"
        run_lab "$RUNDIR/sushy/venv/bin/pip" install --disable-pip-version-check --quiet sushy-tools bcrypt
    fi
    if ! "$RUNDIR/sushy/venv/bin/python" -c 'import libvirt' 2>/dev/null; then
        run_lab "$RUNDIR/sushy/venv/bin/pip" install --disable-pip-version-check --quiet libvirt-python || die \
            "python libvirt bindings unavailable; install python3-libvirt and re-run"
    fi

    if [ ! -f "$RUNDIR/sushy/sushy.pem" ]; then
        explain "TLS and authentication" \
            "The BMCs speak TLS with a self-signed certificate and require basic auth" \
            "(admin/$LABPASSWORD). confluent will later be told to trust exactly this" \
            "certificate by its fingerprint -- the same pinning you would do for a real" \
            "BMC's certificate."
        run_lab openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -keyout "$RUNDIR/sushy/sushy.key" -out "$RUNDIR/sushy/sushy.pem" \
            -subj '/CN=confluent-lab-bmc' -addext 'subjectAltName=IP:192.168.122.1' \
            2>/dev/null
    fi
    if [ ! -f "$RUNDIR/sushy/htpasswd" ]; then
        "$RUNDIR/sushy/venv/bin/python" - > "$RUNDIR/sushy/htpasswd" <<EOF
import bcrypt
print('admin:' + bcrypt.hashpw('$LABPASSWORD'.encode(), bcrypt.gensalt()).decode())
EOF
    fi

    explain "One BMC per node" \
        "Each emulator instance is locked to exactly one VM by its libvirt UUID" \
        "(SUSHY_EMULATOR_ALLOWED_INSTANCES) -- so 'the BMC of node01' can only ever" \
        "see and control node01, like a real BMC soldered to one board."
    local node port vm uuid
    for node in node01 node02; do
        case $node in
            node01) port=$SUSHY_PORT_NODE01 vm=$NODE01_VM ;;
            node02) port=$SUSHY_PORT_NODE02 vm=$NODE02_VM ;;
        esac
        uuid=$(vrsh domuuid "$vm" | head -n 1)
        cat > "$RUNDIR/sushy/$node.conf" <<EOF
SUSHY_EMULATOR_LISTEN_IP = '192.168.122.1'
SUSHY_EMULATOR_LISTEN_PORT = $port
SUSHY_EMULATOR_SSL_CERT = '$RUNDIR/sushy/sushy.pem'
SUSHY_EMULATOR_SSL_KEY = '$RUNDIR/sushy/sushy.key'
SUSHY_EMULATOR_AUTH_FILE = '$RUNDIR/sushy/htpasswd'
SUSHY_EMULATOR_LIBVIRT_URI = 'qemu:///system'
SUSHY_EMULATOR_ALLOWED_INSTANCES = ['$uuid']
EOF
    done

    explain "Starting the host services" \
        "services.sh starts everything the lab runs on this notebook and configures" \
        "the host firewall; it is also the one script to run again after a host reboot:" \
        "- firewall openings for the BMC ports (firewalld, ufw or nftables -- whichever is active)" \
        "- the two BMC emulators" \
        "- the confluent server VM, if it is powered off"
    ASSUME_YES=$ASSUME_YES ./services.sh

    local node port count
    for node in node01 node02; do
        case $node in
            node01) port=$SUSHY_PORT_NODE01 ;;
            node02) port=$SUSHY_PORT_NODE02 ;;
        esac
        count=$(curl -skfm 5 -u "admin:$LABPASSWORD" \
            "https://192.168.122.1:$port/redfish/v1/Systems" \
            | grep -o '"Members@odata.count": *[0-9]*' | grep -o '[0-9]*$' || echo 0)
        [ "$count" = 1 ] || die "BMC on port $port exposes $count systems instead of exactly 1"
        ok "BMC $node exposes exactly one system"
    done
    explain "Try it yourself any time" \
        "curl -sk -u admin:$LABPASSWORD https://192.168.122.1:$SUSHY_PORT_NODE01/redfish/v1/Systems"
    milestone "Two Redfish BMCs are listening on 192.168.122.1:$SUSHY_PORT_NODE01/$SUSHY_PORT_NODE02"
}
