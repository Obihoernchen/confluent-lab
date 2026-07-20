# Confluent Quickstart Lab

A guided, self-contained learning environment for new confluent users. One
script builds a complete deployment setup in VMs on your Linux notebook or server:

- a **confluent server VM** (AlmaLinux 10 with Confluent),
- **node01**, a client VM with a disk, deployed **stateful** (unattended
  AlmaLinux install to disk),
- **node02**, a client VM with **no disk at all**, booted **stateless** (an
  image built with imgutil, running entirely from RAM),
- one emulated **Redfish BMC per node** (sushy-emulator), so confluent's
  hardware management (`nodepower`, ...) works like against real servers.
- Everthing in less than 15 minutes

Every step prints what it does and why: green descriptions with bold
headings, blue `[root@confluent ~]#` commands — the actual confluent
workflow, the same commands you would use on a real deployment server — and
dim `[lab]` lines that are only plumbing for the lab itself. In interactive
mode every confluent command is shown first and runs only after you confirm
it with Enter; `--yes` runs everything unattended.

```
  your notebook (libvirt host)
  |-- virtual BMCs (sushy-emulator, background processes):
  |     https://192.168.122.1:8441 = node01, :8442 = node02
  |-- libvirt network "default" (NAT, 192.168.122.0/24)
  |     `-- confluent   deployment server VM, 192.168.122.180
  |           `-- libvirt network "confluent-internal" (isolated, no libvirt DHCP)
  |                 |-- node01  172.31.0.11  (20 GB disk -> stateful install)
  |                 `-- node02  172.31.0.12  (no disk    -> stateless RAM boot)
```

The nodes' only connection is the isolated network; they reach the internet
through NAT on the confluent VM and use it as their DNS server (dnsmasq,
domain `confluent.lab`). **Every password in the lab is `confluent`** (BMC
admin, root on the server, root on the nodes) — deliberately trivial.

## Demo

[![asciicast](https://asciinema.org/a/1261184.svg)](https://asciinema.org/a/1261184)

## Requirements

- Linux with KVM and libvirt (`qemu:///system` usable without a password —
  be in the `libvirt` group), the `default` libvirt network active.
- Tools: `qemu-img curl openssl tmux python3` (+venv) and `xorriso` or
  `genisoimage`. The first phase checks and prints per-distro install hints.
- An ssh keypair (`~/.ssh/id_*.pub`) — your key is placed on all lab hosts.
- ~10 GB free RAM while all three VMs run (6 GB server + 4 GB per node —
  tune in `lab.conf`), ~25 GB free disk (12 GB download cache + sparse
  images), and sudo for two small host tasks (console-log directory,
  firewall openings for the lab ports — firewalld, ufw and plain nftables
  are detected and configured automatically).

## Usage

```sh
./setup.sh               # guided build, pauses at milestones
./setup.sh --yes         # same, fully unattended
./setup.sh sushy deploy  # run only the named phases
./status.sh              # one-screen state overview
./services.sh            # after a host reboot: firewall, BMC processes, server VM
./destroy.sh --keep-cache   # remove the lab, keep the 12 GB of downloads
./destroy.sh             # remove everything
```

Setup is idempotent: re-run it any time, finished phases are skipped.
`./setup.sh` runs inside the tmux session `confluent-lab` (mouse support on):
the guided setup lives in the `main` window and each VM's serial console is
tailed in its own window (`con-confluent`, `con-node01`, `con-node02`).
During the node deployments the view switches to the node's console
automatically and returns to `main` when done; `Ctrl-b` + window number
moves around manually. The BMC emulators run as plain background processes
(logs in `run/sushy/`). Nothing is installed on your machine system-wide —
all lab state lives in `run/`, `cache/` and the libvirt pool.

## The phases

1. **prereqs** — host sanity checks, shows the topology.
2. **downloads** — AlmaLinux cloud image (~600 MB) + DVD ISO (~11 GB), cached
   and resumable; a close mirror is picked automatically from the geo-sorted
   AlmaLinux mirror list (override the URLs or `MIRRORLIST_URL` in `lab.conf`).
3. **infra** — storage pool, the isolated network (deliberately without any
   libvirt DHCP — confluent must own that wire), the three UEFI VMs. Clients
   boot disk-first/network-second: an empty disk falls through to PXE, an
   installed disk boots the OS, so no boot-order overrides are ever needed.
4. **sushy** — two Redfish BMCs on 192.168.122.1:8441/8442, TLS + basic auth,
   each locked to exactly one VM by libvirt UUID. Confluent addresses them
   by name — `node01-bmc`/`node02-bmc` (`net.bmc.hostname`), resolving to
   192.168.122.201/.202 on the standard port 443 (one BMC per address, like
   real hardware); the server VM maps those addresses to the emulator ports.
5. **server** — confluent from the Lenovo el10 repo (+ EPEL, man pages, vim,
   bash-completion), SELinux/firewalld off (lab shortcut!), then
   `osdeploy initialize -a -u -s -k -t -p`. Your ssh public keys are added to
   the set confluent authorizes on every deployed node.
6. **import** — `osdeploy import` of the DVD ISO → stateful profile
   (`alma-10.x-x86_64-default`); profile customization: serial-console kernel
   args, `/etc/hosts` in syncfiles, `osdeploy updateboot`.
7. **nodes** — the attribute model: a nodegroup `node` carries everything both
   nodes share, including expression attributes (`net.ipv4_address=`
   `172.31.0.{10+n1}/24`, BMC port `{8440+n1}`); per node only the MAC.
   `confluent2hosts -a -f everything` generates /etc/hosts from the database
   (confluent only answers PXE for resolvable nodes), `confluent2dnsmasq
   everything --all-options -y` generates the dnsmasq DHCP/DNS config, first
   `nodepower` against the BMCs, NAT gateway.
8. **stateless** — `imgutil build` + `imgutil pack` → profile
   `alma10-stateless` (encrypted squashfs, copied fully into RAM at boot:
   `confluent_imagemethod=untethered`; the tethered default would stream it
   from the server on demand instead).
9. **deploy** — `confluent_selfcheck -n <node>`, then
   `nodedeploy -n -p <node> <profile>` + `nodepower ... on` for both nodes,
   live progress, end-to-end verification (ssh, DNS, internet).

## Good to know

- **node02 never shows `completed:`** — a stateless node stays at
  `pending: alma10-stateless` and that is correct: the pending profile must
  stay armed because the node re-downloads the same RAM image on every boot.
  Check the node itself instead (ssh, `overlay` root in /proc/mounts).
  Power-cycle it and it comes back identical; nothing it writes survives
  (try it: `touch /root/x; nodepower node02 boot`).
- **Consoles**: `sudo tail -f /var/log/libvirt/consoles/confluent-node01.log`
  on the notebook, or `nodeconsole node01` on the server VM.
- **Getting in**: `ssh root@192.168.122.180` (server), nodes via jump host:
  `ssh -J root@192.168.122.180 root@172.31.0.11`. The server's ssh host key
  is fixed (generated once into `cache/`), so rebuilding the lab does not
  trigger changed-host-key warnings.
- **First place to look when a PXE boot goes unanswered**:
  `/var/log/confluent/events` on the server (e.g. "no deployment profile
  specified"), then `confluent_selfcheck -n <node>`.
- **Why is SELinux/firewalld off?** Lab shortcut to keep the focus on
  confluent. Production keeps both; confluent documents the needed openings
  (https/tftp/dhcp on the deploy interface, `httpd_can_network_connect`).
- **Redeploy node01**: `nodedeploy -n -p node01 <profile>; nodepower node01
  boot` reinstalls it (the installer overwrites the disk).

## Troubleshooting

- *No DHCP answer for a node*: name must resolve on the server
  (`getent hosts node01` there — rerun `confluent2hosts -a -f everything`)
  and `net.hwaddr` must match the VM's MAC.
- *192.168.122.180 collides* with something in your network: change
  `SERVER_MGMT_IP` in `lab.conf` before setup.
- *Different OVMF paths* on your distro: set `OVMF_CODE` /
  `OVMF_VARS_TEMPLATE` in `lab.conf`.
- *node02 runs out of memory*: raise `CLIENT_RAM_MB` (the RAM holds the
  image overlay).
- *`nodepower` cannot reach the BMCs*: `./services.sh` configures firewalld,
  ufw or a plain nftables ruleset automatically; with a different/custom
  firewall, allow TCP 8441 and 8442 from 192.168.122.0/24 to this host
  yourself.
- *BMCs down after reboot*: `./services.sh`.
