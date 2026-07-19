# shellcheck shell=bash disable=SC2034,SC2154
PHASE_DESC="install confluent on the server VM"

phase_check() {
    vssh "test -f /root/.confluent-lab/initialized" 2>/dev/null
}

phase_run() {
    collect_pubkeys
    explain "From here on: inside the server VM" \
        "Everything now happens in the server VM over ssh. Watch the colors:"
    printf '%s\n' \
        "${C_TXT}  - ${C_OFF}${C_CMD}[root@confluent ~]# the real confluent workflow${C_OFF}${C_TXT} -- exactly what you would type on a" \
        "    production deployment server; in interactive mode, Enter confirms each command before it runs" \
        "  - ${C_OFF}${C_DIM}[lab@confluent ~]# lab plumbing${C_OFF}${C_TXT} -- needed by this lab only, safe to ignore" \
        "  - green text: explanations like this one${C_OFF}"

    explain "Installing confluent" \
        "confluent comes from the official Lenovo HPC yum repository (latest release" \
        "for el10). The lab writes the repository file and re-enables man pages first:"
    run_vlab "printf '[lenovo-hpc]\nname=lenovo-hpc\nbaseurl=$LENOVO_REPO_BASEURL\ngpgcheck=0\nenabled=1\n' > /etc/yum.repos.d/lenovo-hpc.repo"
    run_vlab "sed -i '/tsflags=nodocs/d' /etc/dnf/dnf.conf"  # cloud image default; we want man pages
    if ! vssh "rpm -q lenovo-confluent" >/dev/null 2>&1; then
        explain "EPEL first" \
            "Extra Packages for Enterprise Linux provides confluent's python dependencies:"
        run_cfl "dnf -y install epel-release"
        explain "Then confluent and friends" \
            "- lenovo-confluent: the confluent server and client packages" \
            "- tftp-server + httpd: network boot and deployment content serving" \
            "- dnsmasq + nftables: DNS for the lab and the NAT gateway set up later" \
            "- man-db, man-pages, vim-enhanced, bash-completion: comfortable exploring"
        run_cfl "dnf -y install lenovo-confluent tftp-server httpd dnsmasq nftables man-db man-pages vim-enhanced bash-completion"
    else
        skip "lenovo-confluent already installed"
    fi

    explain "SELinux and firewall: off (lab shortcut)" \
        "Both are disabled here so nothing gets in the way of learning the actual" \
        "product. On a production server you would keep both and instead allow the" \
        "deployment services (https, tftp, dhcp) on the deployment-facing interface."
    run_vlab "setenforce 0 2>/dev/null || true
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
systemctl disable --now firewalld >/dev/null 2>&1 || true"

    explain "Starting the services" \
        "- confluent: the management daemon itself" \
        "- httpd: serves boot files and profile content over http(s)" \
        "- tftp.socket: the first PXE stage for firmware that needs tftp"
    run_cfl "systemctl enable --now confluent httpd tftp.socket"

    explain "SSH keys for node access" \
        "confluent pushes every /root/.ssh/*.pub found on the deployment server into" \
        "root's authorized_keys on each deployed node:" \
        "- the server gets its own key generated" \
        "- your public key(s) are added too, so you can later ssh into the nodes directly from this notebook"
    run_vlab "test -f /root/.ssh/id_ed25519 || ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/id_ed25519"
    local i=0 k
    for k in "${PUBKEYS[@]}"; do
        i=$((i + 1))
        run_lab vscp "$k" "root@$SERVER_MGMT_IP:/root/.ssh/labuser$i.pub"
    done

    explain "The first big confluent command: osdeploy initialize" \
        "It prepares the server for OS deployment; each flag enables one piece:" \
        "- -u  authorize the root user's ssh keys on deployed nodes" \
        "- -s  create an SSH certificate authority (nodes trust each other + known_hosts)" \
        "- -a  create an automation key (used for e.g. ansible plays from confluent)" \
        "- -k  add the confluent CA to this server's known_hosts" \
        "- -t  generate the TLS certificate for the deployment HTTPS service" \
        "- -p  copy PXE boot binaries into the tftp directory"
    run_cfl "osdeploy initialize -a -u -s -k -t -p"

    run_vlab "mkdir -p /root/.confluent-lab && touch /root/.confluent-lab/initialized"
    milestone "confluent $(vssh "rpm -q --qf %{VERSION} confluent_server" 2>/dev/null || echo '') is installed and initialized"
}
