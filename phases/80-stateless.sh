# shellcheck shell=bash disable=SC2034,SC2154
PHASE_DESC="build the stateless (diskless) image"

phase_check() {
    vssh "test -d /var/lib/confluent/public/os/alma10-stateless" 2>/dev/null
}

phase_run() {
    local distro
    distro=$(vssh "ls /var/lib/confluent/distributions | head -n 1")
    [ -n "$distro" ] || die "no imported distribution found (phase import must run first)"

    run_vlab "rm -rf /root/imgbuild"
    explain "The second deployment flavor: a stateless image" \
        "- 'imgutil build' creates a minimal AlmaLinux root tree in a chroot (packages come from the imported distribution)" \
        "- 'imgutil pack' turns it into an encrypted squashfs profile" \
        "- a node booting it runs entirely from RAM; no disk is touched -- node02 does not even have one" \
        "This takes a few minutes ('yes |' feeds the package confirmation):"
    # 'yes |' answers the yum confirmation of imgutil releases that do not
    # yet pass -y themselves; newer imgutil detects the pipe and adds -y
    run_cfl "yes | imgutil build -s $distro /root/imgbuild"
    # imgutil 3.15.6 exits 0 even when the chroot install failed
    vssh "ls /root/imgbuild/boot/vmlinuz-* >/dev/null 2>&1" || die \
        "imgutil build did not produce a bootable tree (no kernel in /root/imgbuild/boot); see the output above"
    explain "Packing the image" \
        "The tree under /root/imgbuild could now be customized freely" \
        "(imgutil exec chroots into it). The lab packs it as it is:"
    run_cfl "imgutil pack /root/imgbuild alma10-stateless"
    run_vlab "rm -rf /root/imgbuild"

    explain "Tethered or untethered?" \
        "A stateless node can run in two modes, chosen by the confluent_imagemethod" \
        "kernel argument in the profile:" \
        "- tethered (the default): the squashfs image stays on the server and is streamed over http on demand; uses the least RAM, but the node depends on the deployment server for as long as it runs" \
        "- untethered: the whole image is copied into RAM at boot; uses more RAM, but afterwards the node runs fully independent of the server" \
        "This lab uses untethered so node02 truly runs from RAM alone. That, plus the" \
        "serial console args and /etc/hosts in syncfiles, goes into the profile:"
    run_vlab "cd /var/lib/confluent/public/os/alma10-stateless
grep -q 'console=ttyS0' profile.yaml || sed -i 's/^kernelargs: quiet/kernelargs: console=ttyS0,115200 confluent_imagemethod=untethered/' profile.yaml
test -f syncfiles || echo '/etc/hosts' > syncfiles
grep -qx '/etc/hosts' syncfiles || echo '/etc/hosts' >> syncfiles
chown confluent: profile.yaml syncfiles 2>/dev/null || true"
    explain "Regenerating boot assets" \
        "After editing boot-relevant profile files, 'osdeploy updateboot' rebuilds" \
        "the boot images:"
    run_cfl "osdeploy updateboot alma10-stateless"

    milestone "Stateless profile 'alma10-stateless' is ready"
}
