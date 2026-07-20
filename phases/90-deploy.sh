# shellcheck shell=bash disable=SC2034,SC2154
PHASE_DESC="deploy node01 (stateful) and node02 (stateless)"

node01_done() {
    vssh "nodedeploy node01 2>/dev/null | grep -q 'completed:'" 2>/dev/null
}

# a stateless node cannot be judged by its deployment status (see below);
# ask the node itself whether it is up and running from RAM (both tethered
# and untethered boots back the root filesystem with a zram device)
node02_up() {
    vssh "ssh -o BatchMode=yes -o ConnectTimeout=3 node02 test -b /dev/zram0" 2>/dev/null
}

phase_check() {
    node01_done && node02_up
}

watch_deploy() {  # <node> <pattern> <timeout minutes>
    local node=$1 pattern=$2 deadline=$(( $(date +%s) + $3 * 60 ))
    local st last=''
    while :; do
        st=$(vssh "nodedeploy $node" 2>/dev/null || true)
        if [ -n "$st" ] && [ "$st" != "$last" ]; then
            printf '  %s  %s\n' "$(date +%H:%M:%S)" "$st"
            last=$st
        fi
        case $st in *"$pattern"*) return 0 ;; esac
        [ "$(date +%s)" -lt "$deadline" ] || return 1
        sleep 15
    done
}

power_up() {  # <node> -- power on, or reboot if already running
    if vssh "nodepower $1" 2>/dev/null | grep -F ': on' >/dev/null; then
        run_cfl "nodepower $1 boot"
    else
        run_cfl "nodepower $1 on"
    fi
}

phase_run() {
    local profile
    profile=$(stateful_profile)
    [ -n "$profile" ] || die "stateful profile missing (phase import must run first)"

    if node01_done; then
        skip "node01 already deployed"
    else
        explain "Arming the stateful deployment" \
            "'nodedeploy -n -p <node> <profile>' sets the profile the node will get on" \
            "its next network boot; -p means: do not touch the BMC's boot order. The" \
            "lab does not need boot-order overrides at all -- node01 boots disk-first" \
            "and falls through to PXE while its disk is empty."
        run_cfl "nodedeploy -n -p node01 $profile"

        explain "Self-diagnosis before powering on" \
            "With the deployment armed, confluent can check the whole setup itself." \
            "confluent_selfcheck verifies:" \
            "- server side: services, certificates, TFTP, SSH keys and CA" \
            "- per node: attributes, name resolution, DHCP answerability"
        run_cfl "confluent_selfcheck -n node01" || warn "selfcheck reported issues for node01 (see above)"
        explain "Power on" \
            "The BMC starts node01; its empty disk falls through to PXE:"
        power_up node01

        explain "Watching the install" \
            "node01 now PXE-boots into the AlmaLinux installer; the install takes" \
            "5-10 minutes. The view switches to node01's serial console now and" \
            "returns here automatically when the install is done (Ctrl-b + window" \
            "number to move around yourself; 'nodeconsole node01' on the server works" \
            "too). Meanwhile 'nodedeploy node01' status changes are printed here --" \
            "the node reports its progress back to confluent, ending at 'completed:'" \
            "after the installed system's first boot."
        sleep 5
        console_focus con-node01
        watch_deploy node01 'completed:' 40 || {
            console_focus main
            die "node01 did not reach 'completed' within 40 minutes; check the console log and /var/log/confluent/events on the server"
        }
        sleep 5  # leave the console in view a moment before switching back
        console_focus main
        ok "node01 is deployed and booted from its disk"
    fi

    if node02_up; then
        skip "node02 already running the stateless image"
    else
        explain "Arming the stateless deployment" \
            "Same arming as for node01, this time with the alma10-stateless profile:"
        run_cfl "nodedeploy -n -p node02 alma10-stateless"
        explain "Self-diagnosis for node02"
        run_cfl "confluent_selfcheck -n node02" || warn "selfcheck reported issues for node02 (see above)"
        explain "The stateless boot and its status" \
            "The BMC starts node02, which boots the stateless image entirely into RAM." \
            "One thing is different by design: its status stays 'pending: alma10-stateless' forever." \
            "- the profile must remain armed: the node re-downloads the same image on every single boot -- that is what stateless means" \
            "- so instead of a status, the lab asks the node itself: reachable over ssh, root filesystem in RAM?"
        power_up node02
        sleep 5
        console_focus con-node02
        local deadline=$(( $(date +%s) + 30 * 60 ))
        until node02_up; do
            if [ "$(date +%s)" -ge "$deadline" ]; then
                console_focus main
                die "node02 not reachable within 30 minutes; check the console log ($CONSOLEDIR/$NODE02_VM.log) and /var/log/confluent/events on the server"
            fi
            sleep 15
        done
        sleep 5  # leave the console in view a moment before switching back
        console_focus main
        ok "node02 is running the stateless image from RAM"
    fi

    explain "Final verification" "All through the server VM. Power state via the BMCs:"
    run_cfl "nodepower node01,node02"
    explain "Deployment status" "node01 'completed', node02 'pending' by design:"
    run_cfl "nodedeploy node01,node02"
    explain "node01 really runs its installed OS"
    run_cfl "ssh node01 uname -r"
    explain "node02 really runs from RAM"
    run_cfl "ssh node02 'hostname && df -h /'"

    explain "Things to try now" \
        "- ssh into the nodes from this notebook: ssh -J root@$SERVER_MGMT_IP root@$NODE01_IP" \
        "- prove node02 is truly stateless: touch a file on it, then from the server run 'nodepower node02 boot' -- the file is gone after the reboot" \
        "- redeploy node01 from scratch: 'nodedeploy -n -p node01 $profile', then 'nodepower node01 boot'" \
        "- explore: nodeattrib node01 all | less, man nodeattrib, man nodedeploy"
    milestone "Both nodes are deployed -- the lab is complete"
}
