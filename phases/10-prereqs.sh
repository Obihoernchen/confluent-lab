# shellcheck shell=bash disable=SC2034,SC2154
PHASE_DESC="check host prerequisites"

phase_check() { return 1; }  # cheap sanity checks, always re-run

phase_run() {
    explain "Welcome to the confluent quickstart lab" \
        "This builds a small but complete confluent environment on this machine." \
        "First a check that everything needed is here."

    [ -e /dev/kvm ] || die "/dev/kvm is missing -- KVM virtualization is required (enable VT-x/AMD-V, install qemu-kvm)"
    vrsh version >/dev/null 2>&1 || die \
        "cannot reach libvirt at qemu:///system without a password. Install libvirt, then add yourself to the 'libvirt' group and re-login: sudo usermod -aG libvirt $USER"
    vrsh net-info default 2>/dev/null | grep 'Active: *yes' >/dev/null || die \
        "the libvirt 'default' NAT network is not active (sudo virsh net-start default; virsh net-autostart default)"

    local missing=()
    local c
    for c in qemu-img curl openssl tmux python3; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    command -v xorrisofs >/dev/null 2>&1 || command -v genisoimage >/dev/null 2>&1 || \
        missing+=("xorriso/genisoimage")
    python3 -c 'import venv, ensurepip' 2>/dev/null || missing+=("python3-venv")
    if [ ${#missing[@]} -gt 0 ]; then
        die "missing on this host: ${missing[*]}
  Fedora/EL:     sudo dnf install qemu-img curl openssl tmux python3 xorriso
  Debian/Ubuntu: sudo apt install qemu-utils curl openssl tmux python3-venv xorriso"
    fi

    detect_ovmf
    detect_qemu
    collect_pubkeys
    ok "UEFI firmware: $OVMF_CODE"
    ok "qemu: $QEMU_EMULATOR"
    ok "your ssh public key(s): ${PUBKEYS[*]}"

    local cache_avail lab_avail cache_dev lab_dev mem_avail mem_need
    cache_avail=$(df -BG --output=avail "$(dirname "$CACHEDIR")" 2>/dev/null | awk 'NR==2 {print $1+0}')
    lab_avail=$(df -BG --output=avail "$(dirname "$LABDIR")" 2>/dev/null | awk 'NR==2 {print $1+0}')
    cache_dev=$(df --output=source "$(dirname "$CACHEDIR")" 2>/dev/null | tail -n 1)
    lab_dev=$(df --output=source "$(dirname "$LABDIR")" 2>/dev/null | tail -n 1)
    if [ -n "$cache_dev" ] && [ "$cache_dev" = "$lab_dev" ]; then
        if [ "$cache_avail" -lt 25 ]; then
            warn "only $cache_avail GB free on $cache_dev -- downloads (~13 GB) and VM images (~12 GB) need about 25 GB"
        else
            ok "disk: $cache_avail GB free (downloads + VM images need about 25 GB)"
        fi
    else
        [ -n "$cache_avail" ] && [ "$cache_avail" -lt 15 ] && \
            warn "only $cache_avail GB free for the download cache ($CACHEDIR), ~13 GB needed"
        [ -n "$lab_avail" ] && [ "$lab_avail" -lt 15 ] && \
            warn "only $lab_avail GB free for the VM images ($LABDIR), ~12 GB needed"
    fi
    mem_avail=$(awk '/^MemAvailable/ {print int($2/1024)}' /proc/meminfo)
    mem_need=$((SERVER_RAM_MB + 2 * CLIENT_RAM_MB))
    if [ -n "$mem_avail" ] && [ "$mem_avail" -lt "$mem_need" ]; then
        warn "only $mem_avail MB RAM available, the three VMs are sized to $mem_need MB total -- close some applications or reduce the sizes in lab.conf"
    else
        ok "memory: $mem_avail MB available (the three VMs are sized to $mem_need MB)"
    fi

    if [ ! -d "$CONSOLEDIR" ]; then
        explain "Serial console logging" \
            "All lab VMs log their serial console to files in $CONSOLEDIR," \
            "so you can watch boot loaders and installers scroll by." \
            "Creating the directory needs sudo:"
        run_lab sudo mkdir -p "$CONSOLEDIR"
    fi

    explain "Lab topology" "This is what will be built:"
    cat <<EOF

  this notebook (libvirt host)
  |-- virtual BMCs (sushy-emulator, in tmux):
  |     https://192.168.122.1:$SUSHY_PORT_NODE01 = node01, :$SUSHY_PORT_NODE02 = node02
  |-- libvirt network "default" (NAT, 192.168.122.0/24)
  |     \`-- confluent   deployment server VM, $SERVER_MGMT_IP
  |           \`-- libvirt network "$NET_INTERNAL" (isolated, no libvirt DHCP)
  |                 |-- node01  $NODE01_IP  ($NODE01_DISK_GB GB disk -> stateful install)
  |                 \`-- node02  $NODE02_IP  (no disk at all -> stateless RAM boot)
  \`-- caches/state: $CACHEDIR, $BASEDIR/run

  All passwords are "$LABPASSWORD". The nodes reach the internet through NAT on
  the confluent VM; the confluent VM is reachable from here at $SERVER_MGMT_IP.
EOF
    milestone "Environment looks good -- ready to build the lab"
}
