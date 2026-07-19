# shellcheck shell=bash disable=SC2034,SC2154
PHASE_DESC="import the AlmaLinux DVD (stateful deployment profile)"

phase_check() {
    [ -n "$(stateful_profile)" ]
}

phase_run() {
    local iso profile
    iso=$(basename "$DVDISO_URL")

    explain "Importing the install media" \
        "'osdeploy import' unpacks an install ISO into confluent's distribution" \
        "store and creates a deployment profile from it:" \
        "- kickstart and package list for an unattended install" \
        "- boot files (kernel, initramfs, bootloader)" \
        "- a profile directory meant to be customized"

    if ! vssh "ls /var/lib/confluent/distributions 2>/dev/null | grep -q ." 2>/dev/null; then
        explain "Getting the ISO into the VM" \
            "The ISO is copied from the download cache with scp -- lab plumbing," \
            "a real deployment server would just have the ISO on disk."
        [ -f "$CACHEDIR/$iso" ] || die \
            "$CACHEDIR/$iso is missing; run ./setup.sh downloads first"
        printf '%s\n' "${C_DIM}[lab] scp $CACHEDIR/$iso root@$SERVER_MGMT_IP:/root/$iso${C_OFF}"
        scp "${SSH_OPTS[@]}" "$CACHEDIR/$iso" "root@$SERVER_MGMT_IP:/root/$iso"
        explain "Running the import" \
            "The ISO is unpacked into /var/lib/confluent/distributions and the" \
            "deployment profile is generated; this takes a few minutes:"
        run_cfl "osdeploy import /root/$iso"
        run_vlab "rm -f /root/$iso"
    fi

    profile=$(stateful_profile)
    [ -n "$profile" ] || die "osdeploy import did not produce a profile"
    ok "deployment profile created: $profile"

    explain "Profile customization" \
        "Profiles are plain directories under /var/lib/confluent/public/os/. Two" \
        "small customizations here:" \
        "- kernel arguments: installer and installed OS talk to the serial console (that is what fills the console logs on this notebook)" \
        "- syncfiles: /etc/hosts is added, so every node receives the server-maintained hosts file"
    run_vlab "cd /var/lib/confluent/public/os/$profile
grep -q 'console=ttyS0' profile.yaml || sed -i 's/^kernelargs: quiet/kernelargs: console=ttyS0,115200/' profile.yaml
grep -q '^installedargs:' profile.yaml || echo 'installedargs: console=ttyS0,115200' >> profile.yaml
grep -qx '/etc/hosts' syncfiles || sed -i '/^MERGE:/i /etc/hosts' syncfiles
chown confluent: profile.yaml syncfiles 2>/dev/null || true"
    explain "Regenerating boot assets" \
        "After editing boot-relevant profile files, 'osdeploy updateboot' rebuilds" \
        "the boot images:"
    run_cfl "osdeploy updateboot $profile"

    milestone "Stateful profile '$profile' is ready"
}
