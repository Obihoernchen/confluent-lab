# shellcheck shell=bash disable=SC2034,SC2154
PHASE_DESC="define the nodes: group attributes, DNS, BMC access, NAT gateway"

phase_check() {
    vssh "test -f /root/.confluent-lab/nodes-done" 2>/dev/null
}

phase_run() {
    local fp pwhash
    fp=$(openssl x509 -in "$RUNDIR/sushy/sushy.pem" -outform DER | sha256sum | cut -d ' ' -f 1)
    pwhash=$(openssl passwd -6 "$LABPASSWORD")

    explain "The attribute model: nodegroups and expressions" \
        "Nodes in confluent are configured through attributes, and attributes are" \
        "best set once on a node group instead of per node. Everything both lab nodes" \
        "share goes onto a group called 'node'. Some attributes use confluent's" \
        "expression syntax -- {n1} is the first number in the node's name:" \
        "- '$INTERNAL_NET.{10+n1}/24' computes .11 for node01, .12 for node02" \
        "- the BMC address '$BMC_ADDR_NET.{$BMC_ADDR_OCTET+n1}' computes $BMC_IP_NODE01/$BMC_IP_NODE02" \
        "- '{node}-bmc' computes node01-bmc/node02-bmc" \
        "One group definition, any number of nodes."
    if ! vssh "nodegrouplist 2>/dev/null | grep -qx node"; then
        run_cfl "nodegroupdefine node"
    fi
    explain "Everything shared, in one command" \
        "All of it lands on the group; every member node inherits it:"
    run_cfl "nodegroupattrib node \\
    net.ipv4_method=static \\
    net.ipv4_gateway=$SERVER_INTERNAL_IP \\
    net.ipv4_address='$INTERNAL_NET.{10+n1}/24' \\
    dns.domain=$DNS_DOMAIN \\
    dns.servers=$SERVER_INTERNAL_IP \\
    hardwaremanagement.method=redfish \\
    net.bmc.hostname='{node}-bmc' \\
    net.bmc.ipv4_address='$BMC_ADDR_NET.{$BMC_ADDR_OCTET+n1}' \\
    hardwaremanagement.manager='{node}-bmc' \\
    secret.hardwaremanagementuser=admin \\
    secret.hardwaremanagementpassword=$LABPASSWORD \\
    pubkeys.tls_hardwaremanager='sha256\$$fp' \\
    deployment.useinsecureprotocols=firmware \\
    deployment.apiarmed=continuous \\
    crypted.rootpassword='$pwhash'"

    explain "What these attributes do" \
        "- net.bmc.*: each BMC is modelled like real hardware -- its own hostname" \
        "  ({node}-bmc) and address on the management network. hardwaremanagement.manager" \
        "  refers to the BMC by that name; confluent2hosts will make it resolvable." \
        "- secret.*: BMC credentials (stored encrypted); pubkeys.tls_hardwaremanager" \
        "  pins the BMC's self-signed TLS certificate by its sha256 fingerprint" \
        "- deployment.useinsecureprotocols=firmware: allow plain PXE/HTTP for the" \
        "  firmware boot stage (UEFI http-boot without signed certs)" \
        "- deployment.apiarmed=continuous: nodes may fetch a deployment API token on" \
        "  every boot. The diskless node02 needs this -- it has no disk to keep its" \
        "  token. Production would use 'once' per deployment, or TPM-sealed tokens." \
        "- crypted.rootpassword: root password hash for deployed nodes ('$LABPASSWORD')"

    explain "Defining the nodes" \
        "nodedefine creates them as members of the group 'node' (ours, with all the" \
        "shared attributes) and 'everything' (built-in, holds all nodes):"
    if ! vssh "nodelist node01 2>/dev/null | grep -q node01"; then
        run_cfl "nodedefine node01,node02 groups=node,everything"
    fi
    explain "The MAC addresses" \
        "The only truly per-node attribute in this lab; confluent recognizes a" \
        "node's DHCP/PXE requests by its MAC:"
    run_cfl "nodeattrib node01 net.hwaddr=$MAC_NODE01 && nodeattrib node02 net.hwaddr=$MAC_NODE02"
    explain "Expressions, resolved" "See how the group expressions resolved per node:"
    run_cfl "nodeattrib node01,node02 \\
    net.ipv4_address \\
    net.bmc.hostname \\
    net.bmc.ipv4_address \\
    hardwaremanagement.manager"

    explain "Name resolution from the attribute database" \
        "confluent answers a node's PXE request only if the node's name resolves to" \
        "its deployment address on this server. confluent2hosts generates /etc/hosts" \
        "entries straight from the database ('everything' is the built-in group" \
        "holding all nodes):" \
        "- node names -> deployment addresses (the PXE prerequisite)" \
        "- BMC names -> node01-bmc/node02-bmc become resolvable" \
        "- the same file is in the profiles' syncfiles list, so nodes receive it too"
    run_cfl "confluent2hosts -a -f everything"

    if ! vssh "command -v confluent2dnsmasq" >/dev/null 2>&1; then
        # newer than the released packages; take it from this repo checkout
        [ -f "$BASEDIR/../confluent_client/bin/confluent2dnsmasq" ] || die \
            "the installed confluent has no confluent2dnsmasq and this checkout does not provide one either"
        run_lab vscp "$BASEDIR/../confluent_client/bin/confluent2dnsmasq" \
            "root@$SERVER_MGMT_IP:/opt/confluent/bin/confluent2dnsmasq"
        run_vlab "chmod 755 /opt/confluent/bin/confluent2dnsmasq"
    fi
    explain "DNS and DHCP data from the same database" \
        "confluent2dnsmasq generates a dnsmasq config from the attribute database:" \
        "- one static DHCP reservation per node network with a MAC" \
        "- with --all-options: gateway/DNS/domain/NTP/MTU reply data from the attributes" \
        "- dnsmasq also serves DNS for $DNS_DOMAIN from /etc/hosts and forwards everything else upstream ($DNS_UPSTREAM)" \
        "The nodes' dns.servers attribute points at this server."
    run_cfl "confluent2dnsmasq everything --all-options -y"
    explain "Enabling dnsmasq" \
        "It reads the generated reservations plus /etc/hosts and starts serving:"
    run_cfl "systemctl enable --now dnsmasq"

    explain "BMC addresses like real hardware" \
        "A real BMC is a separate box with its own address on the management network," \
        "listening on the standard Redfish port 443. The lab mimics that:" \
        "- $BMC_IP_NODE01 and $BMC_IP_NODE02 are the nodes' BMC addresses" \
        "- the server VM maps them to the emulator ports on this host [lab plumbing]:"
    run_vlab "mkdir -p /etc/nftables
printf 'table ip confluentbmc {\n  chain output {\n    type nat hook output priority -100; policy accept;\n    ip daddr $BMC_IP_NODE01 tcp dport 443 dnat to 192.168.122.1:$SUSHY_PORT_NODE01\n    ip daddr $BMC_IP_NODE02 tcp dport 443 dnat to 192.168.122.1:$SUSHY_PORT_NODE02\n  }\n}\n' > /etc/nftables/confluent-bmc.nft
grep -q confluent-bmc /etc/sysconfig/nftables.conf 2>/dev/null || echo 'include \"/etc/nftables/confluent-bmc.nft\"' >> /etc/sysconfig/nftables.conf
systemctl enable --now nftables >/dev/null 2>&1
nft list table ip confluentbmc >/dev/null 2>&1 || nft -f /etc/nftables/confluent-bmc.nft"

    explain "First contact with the BMCs" \
        "nodepower asks each node's Redfish BMC for the power state. Both nodes are" \
        "still off -- but it is confluent talking to two 'real' management" \
        "controllers now."
    run_cfl "nodepower node01,node02"
    milestone "You just queried two BMCs through confluent"

    explain "NAT gateway for the nodes" \
        "Finally the server becomes the nodes' internet gateway, so deployed nodes" \
        "can reach online repositories: IP forwarding plus one nftables masquerade" \
        "rule for $INTERNAL_NET.0/24 [lab plumbing]."
    run_vlab "echo net.ipv4.ip_forward=1 > /etc/sysctl.d/90-confluent-lab-gw.conf
sysctl -q -p /etc/sysctl.d/90-confluent-lab-gw.conf
mkdir -p /etc/nftables
printf 'table ip confluentgw {\n  chain postrouting {\n    type nat hook postrouting priority srcnat; policy accept;\n    ip saddr $INTERNAL_NET.0/24 ip daddr != $INTERNAL_NET.0/24 masquerade\n  }\n}\n' > /etc/nftables/confluent-gw.nft
grep -q confluent-gw /etc/sysconfig/nftables.conf 2>/dev/null || echo 'include \"/etc/nftables/confluent-gw.nft\"' >> /etc/sysconfig/nftables.conf
systemctl enable --now nftables >/dev/null 2>&1
nft list table ip confluentgw >/dev/null 2>&1 || nft -f /etc/nftables/confluent-gw.nft"

    run_vlab "touch /root/.confluent-lab/nodes-done"
}
