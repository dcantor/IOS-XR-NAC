#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Run Terraform (Cisco Network as Code) against the lab's IOS-XR routers.
#
#   ./nac.sh init
#   ./nac.sh plan
#   ./nac.sh apply -auto-approve
#   ./nac.sh output
#
# Any terraform subcommand is passed straight through.
#
# Two things this wrapper exists to handle:
#
#   * Reachability. The provider speaks gNMI to the routers' management
#     ports, which live only on the OOB network -- there is no route to them
#     from this host. So an SSH tunnel is opened through nms for the duration
#     of the command, giving each router a 127.0.0.1 port (the same shape the
#     c8000v lab uses for its NETCONF forwards). iosxr.nac.yaml points at
#     those local ports.
#
#   * Credentials. The provider takes them from IOSXR_* environment
#     variables; they are read from ../topology.env so there is one source of
#     truth for the lab's passwords.
# ---------------------------------------------------------------------------
set -euo pipefail

NAC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$NAC_DIR/../topology.env"

TERRAFORM="${TERRAFORM:-$(command -v terraform || echo "$HOME/bin/terraform")}"

# Local port -> router. Keep in step with the `host:` fields in
# iosxr.nac.yaml.
declare -A GNMI_LOCAL_PORT=( [xr1]=57411 [xr2]=57412 )
GNMI_PORT=57400

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }

[[ -x $TERRAFORM ]] || die "terraform not found (tried $TERRAFORM; set TERRAFORM=/path/to/terraform)"

# --- the tunnel ------------------------------------------------------------

TUNNEL_PID=""
ASKPASS=""

cleanup() {
  [[ -n $TUNNEL_PID ]] && kill "$TUNNEL_PID" 2>/dev/null || true
  [[ -n $ASKPASS ]] && rm -f "$ASKPASS" || true
}
trap cleanup EXIT

open_tunnel() {
  local -a forwards=()
  local node
  for node in "${!GNMI_LOCAL_PORT[@]}"; do
    forwards+=( -L "127.0.0.1:${GNMI_LOCAL_PORT[$node]}:${OOB_IP[$node]}:$GNMI_PORT" )
  done

  # ssh needs nms's password without a tty. SSH_ASKPASS_REQUIRE=force makes
  # OpenSSH use the helper even when a terminal is attached.
  ASKPASS=$(mktemp)
  printf '#!/bin/sh\nprintf %%s %q\n' "$NMS_PASSWORD" > "$ASKPASS"
  chmod 0700 "$ASKPASS"

  log "opening gNMI tunnel through nms ($(
    for node in "${!GNMI_LOCAL_PORT[@]}"; do
      printf '%s->127.0.0.1:%s ' "$node" "${GNMI_LOCAL_PORT[$node]}"
    done))"

  SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force setsid ssh -N -T \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR -o ExitOnForwardFailure=yes \
      -p "${SSH_PORT[nms]}" "${forwards[@]}" \
      "$NMS_USER@127.0.0.1" &
  TUNNEL_PID=$!

  # Wait for the forwards to accept connections rather than sleeping blind.
  local node port waited=0
  for node in "${!GNMI_LOCAL_PORT[@]}"; do
    port=${GNMI_LOCAL_PORT[$node]}
    until (exec 3<>/dev/tcp/127.0.0.1/"$port") 2>/dev/null; do
      kill -0 "$TUNNEL_PID" 2>/dev/null \
        || die "the tunnel to nms died -- is nms up? (./lab.sh status)"
      (( waited++ < 100 )) || die "gNMI port $port ($node) never opened"
      sleep 0.2
    done
    exec 3>&- 2>/dev/null || true
  done
}

# --- run -------------------------------------------------------------------

open_tunnel

export IOSXR_USERNAME="$XR_USER"
export IOSXR_PASSWORD="$XR_PASSWORD"
# The routers run `grpc ... no-tls`, so the provider must not try TLS.
export IOSXR_TLS=false

cd "$NAC_DIR"
log "terraform $*"
"$TERRAFORM" "$@"
