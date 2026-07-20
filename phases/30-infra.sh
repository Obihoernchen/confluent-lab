# shellcheck shell=bash disable=SC2034,SC2154
PHASE_DESC="create the libvirt network, storage and the three VMs"

phase_check() {
    vrsh dominfo "$SERVER_VM" >/dev/null 2>&1 && \
    vrsh dominfo "$NODE01_VM" >/dev/null 2>&1 && \
    vrsh dominfo "$NODE02_VM" >/dev/null 2>&1 && \
    vssh true 2>/dev/null
}

phase_run() {
    detect_ovmf
    detect_qemu
    collect_pubkeys
    local cloudimg=$CACHEDIR/$(basename "$CLOUDIMG_URL")

    # --- storage pool -------------------------------------------------------
    explain "Storage pool" \
        "All lab disk images live in a libvirt storage pool named $POOL" \
        "($LABDIR), so they are easy to list and to clean up."
    if ! vrsh pool-info "$POOL" >/dev/null 2>&1; then
        run_lab vrsh pool-define-as "$POOL" dir --target "$LABDIR" >/dev/null
        run_lab vrsh pool-build "$POOL" >/dev/null
        vrsh pool-autostart "$POOL" >/dev/null
        vrsh pool-start "$POOL" >/dev/null 2>&1 || true
    fi

    # --- isolated network ---------------------------------------------------
    explain "The isolated deployment network" \
        "$NET_INTERNAL is deliberately defined with no <ip> and no <forward> element:" \
        "- libvirt attaches no dnsmasq and no NAT to it" \
        "- confluent itself answers DHCP/PXE on this wire; a second DHCP server would fight it" \
        "- the nodes' only way out is the confluent VM"
    if ! vrsh net-info "$NET_INTERNAL" >/dev/null 2>&1; then
        run_lab vrsh net-define /dev/stdin >/dev/null <<EOF
<network>
  <name>$NET_INTERNAL</name>
  <bridge name='$NET_BRIDGE' stp='on' delay='0'/>
</network>
EOF
        vrsh net-autostart "$NET_INTERNAL" >/dev/null
        vrsh net-start "$NET_INTERNAL" >/dev/null
    fi

    # --- volumes ------------------------------------------------------------
    explain "Disks" \
        "- confluent: the AlmaLinux cloud image via a copy-on-write overlay (the cached base image stays pristine)" \
        "- node01: an empty $NODE01_DISK_GB GB disk, target of the stateful install" \
        "- node02: no disk at all"
    if ! vrsh vol-info confluent-base.qcow2 --pool "$POOL" >/dev/null 2>&1; then
        run_lab vrsh vol-create-as "$POOL" confluent-base.qcow2 \
            "$(stat -c %s "$cloudimg")" --format qcow2 >/dev/null
        run_lab vrsh vol-upload confluent-base.qcow2 "$cloudimg" --pool "$POOL"
    fi
    if ! vrsh vol-info confluent.qcow2 --pool "$POOL" >/dev/null 2>&1; then
        run_lab vrsh vol-create-as "$POOL" confluent.qcow2 "${SERVER_DISK_GB}G" \
            --format qcow2 --backing-vol confluent-base.qcow2 \
            --backing-vol-format qcow2 >/dev/null
    fi
    if ! vrsh vol-info confluent-node01.qcow2 --pool "$POOL" >/dev/null 2>&1; then
        run_lab vrsh vol-create-as "$POOL" confluent-node01.qcow2 \
            "${NODE01_DISK_GB}G" --format qcow2 >/dev/null
    fi

    # --- cloud-init seed for the server VM ----------------------------------
    explain "Cloud-init seed for the server VM" \
        "A small seed ISO gives the server VM:" \
        "- its two static IPs, pinned to the NIC MAC addresses" \
        "- your ssh public key(s) for root" \
        "- the root password '$LABPASSWORD'" \
        "- a fixed ssh host key (kept in cache/), so rebuilding the lab never triggers a changed-host-key warning" \
        "The client VMs get nothing -- they are bare PXE targets that confluent will" \
        "discover and install."
    mkdir -p "$CACHEDIR"
    if [ ! -f "$CACHEDIR/confluent-hostkey" ]; then
        run_lab ssh-keygen -q -t ed25519 -N '' -C confluent-lab-hostkey \
            -f "$CACHEDIR/confluent-hostkey"
    fi
    if ! vrsh vol-info confluent-seed.iso --pool "$POOL" >/dev/null 2>&1; then
        local seeddir=$RUNDIR/seed
        mkdir -p "$seeddir"
        cat > "$seeddir/meta-data" <<EOF
instance-id: confluent-quickstart
local-hostname: confluent
EOF
        {
            cat <<EOF
#cloud-config
disable_root: false
ssh_pwauth: true
ssh_deletekeys: true
ssh_keys:
  ed25519_private: |
$(sed 's/^/    /' "$CACHEDIR/confluent-hostkey")
  ed25519_public: $(cat "$CACHEDIR/confluent-hostkey.pub")
chpasswd:
  expire: false
  users:
    - name: root
      password: $LABPASSWORD
      type: text
users:
  - name: root
    ssh_authorized_keys:
EOF
            local k
            for k in "${PUBKEYS[@]}"; do
                printf '      - %s\n' "$(cat "$k")"
            done
        } > "$seeddir/user-data"
        cat > "$seeddir/network-config" <<EOF
version: 1
config:
  - type: physical
    name: eth0
    mac_address: "$MAC_MGMT"
    subnets:
      - type: static
        address: $SERVER_MGMT_IP/24
        gateway: 192.168.122.1
        dns_nameservers:
          - $DNS_UPSTREAM
  - type: physical
    name: eth1
    mac_address: "$MAC_INTERNAL"
    subnets:
      - type: static
        address: $SERVER_INTERNAL_IP/24
EOF
        run_lab mkcidata "$RUNDIR/confluent-seed.iso" "$seeddir"
        run_lab vrsh vol-create-as "$POOL" confluent-seed.iso \
            "$(stat -c %s "$RUNDIR/confluent-seed.iso")" --format raw >/dev/null
        run_lab vrsh vol-upload confluent-seed.iso "$RUNDIR/confluent-seed.iso" \
            --pool "$POOL"
    fi

    # --- domains ------------------------------------------------------------
    explain "The three virtual machines" \
        "All are UEFI (OVMF), fully headless, serial console logged under $CONSOLEDIR." \
        "- clients boot disk-first/network-second: an empty disk falls through to PXE, an installed disk boots the OS -- no BMC boot-order fiddling is ever needed" \
        "- node02 simply has no disk: it can only ever PXE"

    domain_common() {  # <name> <ram_mb> <vcpus>
        cat <<EOF
  <name>$1</name>
  <memory unit='MiB'>$2</memory>
  <vcpu>$3</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <loader readonly='yes' type='pflash'>$OVMF_CODE</loader>
    <nvram template='$OVMF_VARS_TEMPLATE'>/var/lib/libvirt/qemu/nvram/${1}_VARS.fd</nvram>
  </os>
  <cpu mode='host-passthrough'/>
  <features><acpi/><apic/></features>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
EOF
    }
    domain_tail() {  # <name>
        cat <<EOF
    <serial type='pty'>
      <log file='$CONSOLEDIR/$1.log' append='on'/>
      <target port='0'/>
    </serial>
    <console type='pty'><target type='serial' port='0'/></console>
    <channel type='unix'><target type='virtio' name='org.qemu.guest_agent.0'/></channel>
    <rng model='virtio'><backend model='random'>/dev/urandom</backend></rng>
    <memballoon model='virtio'/>
  </devices>
</domain>
EOF
    }

    if ! vrsh dominfo "$SERVER_VM" >/dev/null 2>&1; then
        run_lab vrsh define /dev/stdin >/dev/null <<EOF
<domain type='kvm'>
$(domain_common "$SERVER_VM" "$SERVER_RAM_MB" "$SERVER_VCPUS")
  <devices>
    <emulator>$QEMU_EMULATOR</emulator>
    <disk type='volume' device='disk'>
      <driver name='qemu' type='qcow2' discard='unmap'/>
      <source pool='$POOL' volume='confluent.qcow2'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <disk type='volume' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source pool='$POOL' volume='confluent-seed.iso'/>
      <target dev='sda' bus='sata'/>
      <readonly/>
    </disk>
    <interface type='network'>
      <source network='default'/>
      <mac address='$MAC_MGMT'/>
      <model type='virtio'/>
    </interface>
    <interface type='network'>
      <source network='$NET_INTERNAL'/>
      <mac address='$MAC_INTERNAL'/>
      <model type='virtio'/>
    </interface>
$(domain_tail "$SERVER_VM")
EOF
    fi

    if ! vrsh dominfo "$NODE01_VM" >/dev/null 2>&1; then
        run_lab vrsh define /dev/stdin >/dev/null <<EOF
<domain type='kvm'>
$(domain_common "$NODE01_VM" "$CLIENT_RAM_MB" "$CLIENT_VCPUS")
  <devices>
    <emulator>$QEMU_EMULATOR</emulator>
    <disk type='volume' device='disk'>
      <driver name='qemu' type='qcow2' cache='unsafe' discard='unmap'/>
      <source pool='$POOL' volume='confluent-node01.qcow2'/>
      <target dev='vda' bus='virtio'/>
      <boot order='1'/>
    </disk>
    <interface type='network'>
      <source network='$NET_INTERNAL'/>
      <mac address='$MAC_NODE01'/>
      <model type='virtio'/>
      <boot order='2'/>
    </interface>
$(domain_tail "$NODE01_VM")
EOF
    fi

    if ! vrsh dominfo "$NODE02_VM" >/dev/null 2>&1; then
        run_lab vrsh define /dev/stdin >/dev/null <<EOF
<domain type='kvm'>
$(domain_common "$NODE02_VM" "$CLIENT_RAM_MB" "$CLIENT_VCPUS")
  <devices>
    <emulator>$QEMU_EMULATOR</emulator>
    <interface type='network'>
      <source network='$NET_INTERNAL'/>
      <mac address='$MAC_NODE02'/>
      <model type='virtio'/>
      <boot order='1'/>
    </interface>
$(domain_tail "$NODE02_VM")
EOF
    fi

    # --- boot the server ----------------------------------------------------
    if ! vrsh domstate "$SERVER_VM" 2>/dev/null | grep running >/dev/null; then
        run_lab vrsh start "$SERVER_VM" >/dev/null
    fi
    if ! grep -q "^$SERVER_MGMT_IP " "$RUNDIR/known_hosts" 2>/dev/null; then
        printf '%s %s\n' "$SERVER_MGMT_IP" \
            "$(cut -d' ' -f1,2 "$CACHEDIR/confluent-hostkey.pub")" \
            >> "$RUNDIR/known_hosts"
    fi
    explain "First boot" \
        "Waiting for the server VM to finish its first boot (cloud-init applies the" \
        "network config and your ssh key; typically under two minutes). The view" \
        "switches to the server's serial console meanwhile."
    sleep 5
    console_focus con-confluent
    local i
    for i in $(seq 60); do
        vssh true 2>/dev/null && break
        sleep 5
    done
    if ! vssh true 2>/dev/null; then
        console_focus main
        die "server VM not reachable at $SERVER_MGMT_IP after 5 minutes; check: sudo tail $CONSOLEDIR/$SERVER_VM.log"
    fi
    sleep 5  # leave the console in view a moment before switching back
    console_focus main
    ok "server VM is up: ssh root@$SERVER_MGMT_IP"
    milestone "Infrastructure is in place: 1 network, 3 VMs, BMCs come next"
}
