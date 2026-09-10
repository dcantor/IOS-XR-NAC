#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Cisco IOS-XRv9000 lab on plain QEMU/KVM: two routers with two links between
# them, plus an out-of-band management network and a Linux management server.
# Usage: ./lab.sh {start|stop|status|console|ssh|clean}   (see usage() below)
# ---------------------------------------------------------------------------
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/topology.env"

DAY0=${DAY0:-1}          # DAY0=0 to boot with no day-0 config (manual setup)

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: ./lab.sh <command>

  start [node...]  Boot the nodes (default: all; idempotent, skips those up)
  stop  [node...]  Shut nodes down, keeping their disks
  status           Show what is running and how to reach it
  console <node>   Attach to a node's serial console (Ctrl-] then 'quit')
  ssh <node>       SSH to a node (routers go via nms as the jump host)
  clean            Stop, then delete overlay disks and seed/day-0 ISOs

Nodes: ${NODES[*]}    (routers: ${XR_NODES[*]})
Env overrides: VM_RAM_MB (=$VM_RAM_MB) VM_VCPUS (=$VM_VCPUS) DAY0 (=$DAY0)
               NMS_RAM_MB (=$NMS_RAM_MB) NMS_VCPUS (=$NMS_VCPUS)
               GOBGP_RAM_MB (=$GOBGP_RAM_MB) GOBGP_VCPUS (=$GOBGP_VCPUS)
EOF
}

# --- helpers ---------------------------------------------------------------

pidfile() { echo "$RUN_DIR/$1.pid"; }

is_running() {
  local pf; pf=$(pidfile "$1")
  [[ -f $pf ]] && kill -0 "$(cat "$pf")" 2>/dev/null
}

valid_node() {
  local n
  for n in "${NODES[@]}"; do [[ $n == "$1" ]] && return 0; done
  return 1
}

preflight() {
  [[ -r $BASE_IMAGE ]] || die "base image not readable: $BASE_IMAGE"
  [[ -r $LINUX_BASE_IMAGE ]] || die \
    "Linux base image not readable: $LINUX_BASE_IMAGE (see README.md)"
  [[ -r $GOBGP_TARBALL ]] || die \
    "gobgpd release not found: $GOBGP_TARBALL -- fetch it with the curl
    command in topology.env"
  [[ -w /dev/kvm ]]    || die "no write access to /dev/kvm (add yourself to the 'kvm' group)"
  command -v qemu-system-x86_64 >/dev/null || die "qemu-system-x86_64 not found"
  command -v genisoimage       >/dev/null || die "genisoimage not found (apt install genisoimage)"
  [[ -r $OVMF_CODE ]]            || die "UEFI firmware not found: $OVMF_CODE (apt install ovmf)"
  [[ -r $OVMF_VARS_TEMPLATE ]]   || die "UEFI variable template not found: $OVMF_VARS_TEMPLATE"

  # A node needs more than 18 GiB or its host OS wedges before XR starts;
  # see the note in topology.env.
  if (( VM_RAM_MB <= 18432 )); then
    warn "VM_RAM_MB=$VM_RAM_MB is at or below 18 GiB. XRv9k will not finish"
    warn "booting: it wedges in 'Spirit early boot setup'. See README.md."
  fi

  local need avail
  need=$(( VM_RAM_MB * ${#XR_NODES[@]} + NMS_RAM_MB + GOBGP_RAM_MB ))
  avail=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
  if (( avail < need )); then
    warn "this lab wants ${need} MiB of RAM but only ${avail} MiB is available."
    warn "the c8000v lab on this host may be running; stop it to free memory."
    warn "continuing in 5s -- Ctrl-C to abort."
    sleep 5
  fi
  mkdir -p "$RUN_DIR"
}

# Thin copy-on-write overlay so the 2 GB base image is never written to.
make_overlay() {
  local node=$1 disk="$RUN_DIR/$1.qcow2"
  if [[ ! -f $disk ]]; then
    log "creating overlay disk for $node"
    qemu-img create -q -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$disk" >/dev/null
  fi
  echo "$disk"
}

# Overlay for a Linux node on top of the Ubuntu cloud image, grown to give
# apt some room.
make_linux_overlay() {
  local node=$1 disk="$RUN_DIR/$1.qcow2"
  if [[ ! -f $disk ]]; then
    log "creating overlay disk for $node"
    qemu-img create -q -f qcow2 -F qcow2 -b "$LINUX_BASE_IMAGE" "$disk" 8G >/dev/null
  fi
  echo "$disk"
}

# NoCloud seed: cloud-init looks for a filesystem labelled CIDATA holding
# user-data, meta-data and (optionally) network-config. gobgp's seed also
# carries the gobgpd release, so that VM needs no network access to install
# it.
make_linux_seed_iso() {
  local node=$1 iso="$RUN_DIR/$1-seed.iso"
  local user="$CFG_DIR/$1-user-data" net="$CFG_DIR/$1-network-config"
  [[ -r $user ]] || die "missing $user"
  [[ -r $net ]]  || die "missing $net"

  local -a extra=()
  [[ $node == gobgp ]] && extra=( "$GOBGP_TARBALL" )

  local stale=0
  [[ ! -f $iso || $user -nt $iso || $net -nt $iso ]] && stale=1
  local f; for f in "${extra[@]}"; do [[ $f -nt $iso ]] && stale=1; done

  if (( stale )); then
    log "building cloud-init seed for $node"
    local tmp; tmp=$(mktemp -d)
    cp "$user" "$tmp/user-data"
    cp "$net" "$tmp/network-config"
    # A changing instance-id makes cloud-init re-run on a rebuilt disk.
    printf 'instance-id: %s-%s\nlocal-hostname: %s\n' \
      "$node" "$(date +%s)" "$node" > "$tmp/meta-data"
    for f in "${extra[@]}"; do cp "$f" "$tmp/gobgp-release.tar.gz"; done
    genisoimage -quiet -output "$iso" -volid CIDATA -joliet -rock "$tmp"
    rm -rf "$tmp"
  fi
  echo "$iso"
}

# Private writable UEFI variable store per node.
make_ovmf_vars() {
  local vars="$RUN_DIR/$1-OVMF_VARS.fd"
  if [[ ! -f $vars ]]; then
    log "creating UEFI variable store for $1"
    cp "$OVMF_VARS_TEMPLATE" "$vars"
  fi
  echo "$vars"
}

# XRv9k applies a config named iosxr_config.txt found on an attached CD-ROM.
make_day0_iso() {
  local node=$1 iso="$RUN_DIR/$1-day0.iso" src="$CFG_DIR/$1.cfg"
  [[ -r $src ]] || die "missing day-0 config: $src"
  if [[ ! -f $iso || $src -nt $iso ]]; then
    log "building day-0 ISO for $node"
    local tmp; tmp=$(mktemp -d)
    cp "$src" "$tmp/iosxr_config.txt"
    genisoimage -quiet -output "$iso" -volid config -joliet -rock "$tmp"
    rm -rf "$tmp"
  fi
  echo "$iso"
}

# --- the QEMU invocation ---------------------------------------------------

start_node() {
  local node=$1
  if is_running "$node"; then log "$node already running (pid $(cat "$(pidfile "$node")"))"; return; fi
  if [[ ${NODE_KIND[$node]} == linux ]]; then start_linux_node "$node"; return; fi

  local disk mac cons idx peer
  disk=$(make_overlay "$node")
  mac=${MAC_PREFIX[$node]}
  cons=${CONSOLE_BASE[$node]}
  idx=${NODE_INDEX[$node]}
  peer=${LINK_PEER[$node]}

  local -a args=(
    -name "xrv9k-$node"
    -machine pc,accel=kvm,usb=off
    # No floppy drive. The "pc" machine would otherwise give the guest an
    # empty floppy controller, which the host OS probes on the way up and
    # logs read errors for. Harmless, but a virtual router has no floppy.
    -global isa-fdc.fallback=none
    -cpu host
    -smp "cores=$VM_VCPUS,threads=1,sockets=1"
    -m "$VM_RAM_MB"
    # UEFI: read-only firmware code plus this node's own variable store.
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE"
    -drive "if=pflash,format=raw,unit=1,file=$(make_ovmf_vars "$node")"
    # XRv9k identifies its platform from SMBIOS; the product string matters.
    -smbios "type=1,manufacturer=cisco,product=Cisco XRv9k Centralized Virtual Router,uuid=$(uuidgen)"
    -drive "if=ide,index=0,media=disk,file=$disk,format=qcow2,cache=writeback"
  )

  if (( DAY0 )); then
    args+=( -drive "if=ide,index=2,media=cdrom,file=$(make_day0_iso "$node"),readonly=on" )
  fi

  # ---- NICs. Order is fixed by the XRv9k image:
  #        1 MgmtEth0/RP0/CPU0/0   2 CtrlEth   3 DevEth
  #        4 Gi0/0/0/0             5 Gi0/0/0/1
  #      CtrlEth and DevEth are internal to a real chassis but the image still
  #      expects the vNICs to exist, so they get dead-end one-port hubs.
  args+=(
    # 1: MgmtEth0/RP0/CPU0/0 on the shared OOB segment with nms. XRv9k has
    #    only this one management port, so it cannot also sit behind a
    #    user-mode NAT: reach it through nms instead.
    -netdev "socket,id=oob,mcast=$OOB_MCAST,localaddr=127.0.0.1"
    -device "virtio-net-pci,netdev=oob,mac=$mac:01"
    # 2: CtrlEth placeholder
    -netdev "hubport,id=ctrl,hubid=$((idx * 10 + 1))"
    -device "virtio-net-pci,netdev=ctrl,mac=$mac:02"
    # 3: DevEth placeholder
    -netdev "hubport,id=dev,hubid=$((idx * 10 + 2))"
    -device "virtio-net-pci,netdev=dev,mac=$mac:03"
    # 4: Gi0/0/0/0 -> link1, point-to-point UDP to the peer's endpoint
    -netdev "socket,id=link1,udp=127.0.0.1:${LINK1_PORT[$peer]},localaddr=127.0.0.1:${LINK1_PORT[$node]}"
    -device "virtio-net-pci,netdev=link1,mac=$mac:04"
    # 5: Gi0/0/0/1 -> link2
    -netdev "socket,id=link2,udp=127.0.0.1:${LINK2_PORT[$peer]},localaddr=127.0.0.1:${LINK2_PORT[$node]}"
    -device "virtio-net-pci,netdev=link2,mac=$mac:05"
  )

  # 6: Gi0/0/0/2 -> the external BGP speaker. Only xr1 has this link, so only
  #    xr1 gets a sixth vNIC. vNIC order fixes interface naming, so adding it
  #    last leaves every other interface exactly where it was.
  if [[ $node == xr1 ]]; then
    args+=(
      -netdev "socket,id=extbgp,udp=127.0.0.1:$GOBGP_LINK_PORT_GOBGP,localaddr=127.0.0.1:$GOBGP_LINK_PORT_XR1"
      -device "virtio-net-pci,netdev=extbgp,mac=$mac:06"
    )
  fi

  # XRv9k wants four serial ports present; the first is the XR console.
  local i
  for i in 0 1 2 3; do
    args+=( -serial "telnet:127.0.0.1:$((cons + i)),server,nowait" )
  done

  args+=(
    -monitor "telnet:127.0.0.1:${MONITOR_PORT[$node]},server,nowait"
    -display none
    -daemonize
    -pidfile "$(pidfile "$node")"
  )

  log "starting $node  (${VM_VCPUS} vCPU, ${VM_RAM_MB} MiB, console 127.0.0.1:$cons)"
  qemu-system-x86_64 "${args[@]}"
}

# The Linux VMs: a plain Ubuntu cloud image with two NICs. The first is
# always user-mode NAT (the host's SSH forward, and apt's route out); the
# second is what the node is actually for.
start_linux_node() {
  local node=$1 disk seed mac
  disk=$(make_linux_overlay "$node")
  seed=$(make_linux_seed_iso "$node")
  mac=${MAC_PREFIX[$node]}

  local -a args=(
    -name "$node"
    -machine pc,accel=kvm,usb=off
    -global isa-fdc.fallback=none
    -cpu host
    -smp "cores=${LINUX_VCPUS[$node]},threads=1,sockets=1"
    -m "${LINUX_RAM[$node]}"
    -drive "if=virtio,file=$disk,format=qcow2,cache=writeback"
    -drive "if=virtio,file=$seed,format=raw,readonly=on"
    # 1: user-mode NAT -- the host's SSH forward.
    -netdev "user,id=nat,hostfwd=tcp:127.0.0.1:${SSH_PORT[$node]}-:22"
    -device "virtio-net-pci,netdev=nat,mac=$mac:01"
  )

  # 2: the lab-facing NIC, which differs per node.
  case $node in
    nms)
      # The shared OOB management segment, with both routers' mgmt ports.
      args+=(
        -netdev "socket,id=lab,mcast=$OOB_MCAST,localaddr=127.0.0.1"
        -device "virtio-net-pci,netdev=lab,mac=$mac:02"
      )
      ;;
    gobgp)
      # Point-to-point to xr1's Gi0/0/0/2, for the eBGP session.
      args+=(
        -netdev "socket,id=lab,udp=127.0.0.1:$GOBGP_LINK_PORT_XR1,localaddr=127.0.0.1:$GOBGP_LINK_PORT_GOBGP"
        -device "virtio-net-pci,netdev=lab,mac=$mac:02"
      )
      ;;
    *) die "no NIC layout defined for Linux node $node" ;;
  esac

  args+=(
    -serial "telnet:127.0.0.1:${CONSOLE_BASE[$node]},server,nowait"
    -monitor "telnet:127.0.0.1:${MONITOR_PORT[$node]},server,nowait"
    -display none
    -daemonize
    -pidfile "$(pidfile "$node")"
  )

  log "starting $node  (${LINUX_VCPUS[$node]} vCPU, ${LINUX_RAM[$node]} MiB, console 127.0.0.1:${CONSOLE_BASE[$node]})"
  qemu-system-x86_64 "${args[@]}"
}

# --- commands --------------------------------------------------------------

# With no arguments every command acts on every node.
selected() {
  if (( $# )); then
    local n; for n in "$@"; do valid_node "$n" || die "unknown node: $n"; done
    printf '%s\n' "$@"
  else
    printf '%s\n' "${NODES[@]}"
  fi
}

cmd_start() {
  preflight
  local node
  for node in $(selected "$@"); do start_node "$node"; done
  echo
  cmd_status
  cat <<EOF

nms is ready in a minute or two; the routers take about 20 minutes. Watch
either with:
  ./lab.sh console nms
  ./lab.sh console xr1

Leave a router console alone until you see %MGBL-CVAC-4-CONFIG_DONE. XR shows
a first-boot "Enter root-system username" prompt shortly before cvac applies
the day-0 config; typing at it takes the config lock and makes cvac fail.
EOF
}

cmd_stop() {
  local node pf pid
  for node in $(selected "$@"); do
    pf=$(pidfile "$node")
    if is_running "$node"; then
      pid=$(cat "$pf")
      log "stopping $node (pid $pid)"
      kill "$pid"
      for _ in $(seq 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
      kill -0 "$pid" 2>/dev/null && { warn "$node ignored SIGTERM, sending SIGKILL"; kill -9 "$pid"; }
    else
      log "$node is not running"
    fi
    rm -f "$pf"
  done
}

cmd_status() {
  printf '%-6s %-7s %-8s %-20s %-22s %s\n' NODE STATE PID CONSOLE SSH MONITOR
  local node state pid ssh
  for node in "${NODES[@]}"; do
    if is_running "$node"; then state=up; pid=$(cat "$(pidfile "$node")"); else state=down; pid=-; fi
    # Only nms has a host SSH forward; a router is reached at its OOB
    # address, through nms. Printing a host port here would be a lie.
    if [[ ${NODE_KIND[$node]} == linux ]]; then
      ssh="127.0.0.1:${SSH_PORT[$node]}"
    else
      ssh="${OOB_IP[$node]} (via nms)"
    fi
    printf '%-6s %-7s %-8s %-20s %-22s %s\n' \
      "$node" "$state" "$pid" \
      "127.0.0.1:${CONSOLE_BASE[$node]}" \
      "$ssh" \
      "127.0.0.1:${MONITOR_PORT[$node]}"
  done
  cat <<EOF

Links   link1  xr1 Gi0/0/0/0 10.1.1.1/30 <-> xr2 Gi0/0/0/0 10.1.1.2/30   (udp ${LINK1_PORT[xr1]}<->${LINK1_PORT[xr2]})
        link2  xr1 Gi0/0/0/1 10.1.2.1/30 <-> xr2 Gi0/0/0/1 10.1.2.2/30   (udp ${LINK2_PORT[xr1]}<->${LINK2_PORT[xr2]})
OOB     $OOB_SUBNET on mcast $OOB_MCAST
        nms ${OOB_IP[nms]}   xr1 ${OOB_IP[xr1]}   xr2 ${OOB_IP[xr2]}
eBGP    xr1 Gi0/0/0/2 $GOBGP_LINK_IP_XR1/30 <-> $GOBGP_LINK_IP_GOBGP/30 gobgp (AS $GOBGP_AS)
        gobgp originates $GOBGP_PREFIX_COUNT prefixes: 10.100.0.0/24 .. 10.139.15.0/24
Login   routers $XR_USER / $XR_PASSWORD      nms $NMS_USER / $NMS_PASSWORD
Access  ./lab.sh ssh nms          (direct, via the SSH forward)
        ./lab.sh ssh gobgp        (direct; then: gobgp neighbor / gobgp global rib)
        ./lab.sh ssh xr1          (through nms -- the routers' management
                                   ports are only on the OOB network)
        on nms: xrssh xr1 show version
EOF
}

cmd_console() {
  local node=${1:-}
  valid_node "$node" || die "usage: ./lab.sh console <${NODES[*]// /|}>"
  is_running "$node" || die "$node is not running"
  log "console for $node -- escape with Ctrl-] then 'quit'"
  telnet 127.0.0.1 "${CONSOLE_BASE[$node]}"
}

cmd_ssh() {
  local node=${1:-}
  valid_node "$node" || die "usage: ./lab.sh ssh <${NODES[*]// /|}>"
  is_running "$node" || die "$node is not running"

  local -a common=( -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null )

  if [[ ${NODE_KIND[$node]} == linux ]]; then
    log "ssh to $node as $NMS_USER (password: $NMS_PASSWORD)"
    ssh -p "${SSH_PORT[$node]}" "${common[@]}" "$NMS_USER@127.0.0.1"
    return
  fi

  # A router's management port exists only on the OOB network, so hop
  # through nms. Two passwords are asked for: nms's, then the router's.
  #
  # ProxyCommand rather than ProxyJump: options given here apply only to the
  # final hop, so with ProxyJump the connection to nms would still do strict
  # host key checking -- and nms gets a new host key every ./lab.sh clean,
  # which means a "REMOTE HOST IDENTIFICATION HAS CHANGED" refusal. Spelling
  # the jump out as a ProxyCommand lets both hops share the settings.
  is_running nms || die "nms is not running, and it is the only way to reach $node"
  log "ssh to $node via nms -- nms password: $NMS_PASSWORD, then $node: $XR_PASSWORD"
  ssh "${common[@]}" \
      -o "ProxyCommand=ssh ${common[*]} -p ${SSH_PORT[nms]} -W %h:%p $NMS_USER@127.0.0.1" \
      "$XR_USER@${OOB_IP[$node]}"
}

cmd_clean() {
  cmd_stop
  log "removing overlay disks, seed/day-0 ISOs and UEFI variable stores"
  rm -f "$RUN_DIR"/*.qcow2 "$RUN_DIR"/*-day0.iso "$RUN_DIR"/*-OVMF_VARS.fd \
        "$RUN_DIR"/nms-seed.iso
}

case "${1:-}" in
  start)   shift; cmd_start "$@" ;;
  stop)    shift; cmd_stop "$@" ;;
  status)  cmd_status ;;
  console) shift; cmd_console "$@" ;;
  ssh)     shift; cmd_ssh "$@" ;;
  clean)   cmd_clean ;;
  ''|-h|--help|help) usage ;;
  *)       usage; exit 1 ;;
esac
