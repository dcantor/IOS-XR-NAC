# IOS-XRv9000 lab on QEMU/KVM

Two Cisco IOS-XRv9000 (26.1.1) routers wired to each other with two
point-to-point links, an out-of-band management network with a Linux
management server, and an external GoBGP speaker injecting 10000 prefixes --
all as plain QEMU/KVM guests, no root required. Part of the routers'
configuration is managed with Cisco Network as Code (Terraform over gNMI).

> **This is a lab.** Credentials are committed in plaintext and transport
> security is switched off throughout, deliberately. See
> [This is a lab. Do not use any of it in production.](#this-is-a-lab-do-not-use-any-of-it-in-production)

```
                 Gi0/0/0/0 .1 ──── link1  10.1.1.0/30 ──── .2 Gi0/0/0/0
      ┌───────┐                                                        ┌───────┐
      │  xr1  │                                                        │  xr2  │
      │1.1.1.1│                                                        │2.2.2.2│
      └───────┘                                                        └───────┘
                 Gi0/0/0/1 .1 ──── link2  10.1.2.0/30 ──── .2 Gi0/0/0/1
          │      │                                                │
          │      └ Gi0/0/0/2 .1 ── 10.2.1.0/30 ── .2 ┐            │
          │                                    ┌───────────┐      │
          │                                    │   gobgp   │ AS 65100
          │                                    └───────────┘      │
          │                                    10000 prefixes     │
          │ MgmtEth0/RP0/CPU0/0               MgmtEth0/RP0/CPU0/0 │
          │ 10.99.0.11                                 10.99.0.12 │
          └──────────────┐                    ┌───────────────────┘
                         │                    │
                   ═══════ OOB  10.99.0.0/24 ═══════
                                  │
                            ┌───────────┐
                            │    nms    │ 10.99.0.10
                            └───────────┘
                                  │ QEMU user-mode NAT + SSH forward
                                host
```

CDP is enabled globally and on both data interfaces.

`Loopback0` (`1.1.1.1/32` on xr1, `2.2.2.2/32` on xr2) is each router's stable
identity. OSPF (`router ospf CORE`, area 0) runs over both links and
advertises the loopbacks as passive, so each router learns the other's /32
over **both** links as an equal-cost pair:

```
RP/0/RP0/CPU0:xr1#show route 2.2.2.2
  Known via "ospf CORE", distance 110, metric 2, type intra area
  Routing Descriptor Blocks
    10.1.1.2, from 2.2.2.2, via GigabitEthernet0/0/0/0
    10.1.2.2, from 2.2.2.2, via GigabitEthernet0/0/0/1
```

Both links authenticate with OSPF MD5 (key id 1), and every session is
protected by **BFD** at 300 ms x 3 -- see **OSPF, authentication and BFD**
below.

On top of that, the two routers run **iBGP in AS 65000, peering
loopback-to-loopback** (`update-source Loopback0`). Because the session rides
on an OSPF-learned /32 with two paths, it survives either link failing --
which the test suite demonstrates.

`nms` is a small Ubuntu VM on the out-of-band network. It receives syslog from
both routers (rsyslog, UDP 514, filed per router under `/var/log/routers/`),
polls them and receives their traps over **SNMPv3 in authPriv mode**
(snmptrapd on UDP 162, filed under `/var/log/snmp/`), can log in to either
over SSH, and is the way in from the host -- see **The out-of-band network**
below.

`gobgp` is a second small Ubuntu VM running GoBGP as an **external** speaker:
eBGP in AS 65100 over a dedicated link to xr1, originating 10000 prefixes
(`10.100.0.0/24` … `10.139.15.0/24`). xr1 passes them to xr2 over iBGP with
`next-hop-self` -- see **The external BGP speaker** below.

## What you need first

Three files are not in this repository and have to be present before
`./lab.sh start` will run. `lab.sh` checks for them and says which is missing.

| File | Where from |
| --- | --- |
| `xrv9k-fullk9-x-26.1.1.qcow2` | Cisco (software.cisco.com). Licensed, ~2 GB, not redistributable. |
| `images/ubuntu-24.04-minimal-cloudimg-amd64.img` | `curl -sSLo images/ubuntu-24.04-minimal-cloudimg-amd64.img https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-amd64.img` |
| `images/gobgp_4.9.0_linux_amd64.tar.gz` | `curl -sSLo images/gobgp_4.9.0_linux_amd64.tar.gz https://github.com/osrg/gobgp/releases/download/v4.9.0/gobgp_4.9.0_linux_amd64.tar.gz` |

Host packages: `qemu-system-x86`, `qemu-utils`, `ovmf`, `genisoimage`,
`python3-venv`, and `terraform` on `PATH` (or `TERRAFORM=/path/to/terraform`)
if you want the Network as Code part. Access to `/dev/kvm` is required;
nothing else needs root.

Sizing: about 42 GiB of RAM for the four VMs, and roughly 15 GiB of disk for
the overlays. The 20 GiB per router is not negotiable -- see
**Two things this image needs that are easy to get wrong**.

### This is a lab. Do not use any of it in production.

Everything here optimises for a lab that comes up identically every time on
one machine, which is the opposite of what a production network wants:

**Credentials are in the repository, in plaintext, on purpose.**
`admin`/`Admin@12345` on the routers and `lab`/`Lab_123!` on the Linux VMs
appear in `topology.env`, `configs/` and `tests/XrCli.py`. They are throwaway
values for throwaway VMs on a loopback network, committed so that
`./lab.sh start` needs no secret handling. **Do not reuse them, or this
pattern of committing them, anywhere real.**

**Other things that are fine here and not fine in production:**

| | Here | Production would |
| --- | --- | --- |
| gNMI transport | `no-tls`, with `IOSXR_TLS=false` | TLS with a real certificate, and `verify_certificate` on |
| Router login | password auth, one shared `admin` | per-user accounts, SSH keys or TACACS+/RADIUS |
| SSH host keys | `StrictHostKeyChecking=no` everywhere | known hosts, or certificates |
| `sshpass`/`SSH_ASKPASS` | used to script logins | key-based auth, an agent, or a secrets manager |
| eBGP policy | one `PASS` from day-0 as a bootstrap | no permissive default, ever |
| Terraform state | a local file | remote state with locking |

The network design itself -- loopback-based iBGP, OSPF advertising the
loopbacks, `next-hop-self`, BFD, AS-path validation on what a peer sends -- is
ordinary good practice and does translate. It is the *access* and *secret*
handling that does not.

## Quick start

```bash
./lab.sh start
```

First boot takes about 20 minutes: the host OS comes up, XR "bakes" its image,
and the day-0 configuration is applied. Watch it happen:

```bash
./lab.sh console xr1
```

**Leave the console alone until you see `%MGBL-CVAC-4-CONFIG_DONE`.** XR offers
a first-boot "Enter root-system username" prompt a couple of minutes before
`cvac` applies the day-0 config; typing at that prompt takes the configuration
lock and makes `cvac` fail with `TARGET_CFG_LOCKERR`.

| Command | What it does |
| --- | --- |
| `./lab.sh start [node...]` | Boot nodes (default all; idempotent, skips those up) |
| `./lab.sh stop [node...]` | Shut nodes down, keeping their disks |
| `./lab.sh status` | What is running, and how to reach it |
| `./lab.sh console <node>` | Attach to the XR serial console |
| `./lab.sh ssh <node>` | SSH to the node's management interface |
| `./lab.sh clean` | Stop and delete overlays, day-0 ISOs, UEFI vars |

Login is `admin` / `Admin@12345`. Escape the console with `Ctrl-]` then `quit`.

Login is `lab` / `Lab_123!` on nms and gobgp.

### Host access

| | nms | gobgp | xr1 | xr2 |
| --- | --- | --- | --- | --- |
| serial console (telnet) | 127.0.0.1:5121 | 127.0.0.1:5131 | 127.0.0.1:5101 | 127.0.0.1:5111 |
| SSH from the host | 127.0.0.1:2261 | 127.0.0.1:2262 | via nms | via nms |
| QEMU monitor | 127.0.0.1:4121 | 127.0.0.1:4131 | 127.0.0.1:4101 | 127.0.0.1:4111 |
| OOB address | 10.99.0.10 | — | 10.99.0.11 | 10.99.0.12 |

Both Linux VMs have a host SSH forward; neither router does. The routers'
management ports are on the OOB network and nothing else, so
`./lab.sh ssh xr1` hops through nms (it asks for nms's password, then the
router's). Ports were chosen to stay clear of the
c8000v labs that also live on this host (2221-2223, 2231-2233, 2241,
5001-5003, 5011-5013, 5021).

### Verifying the topology

From `./lab.sh console xr1`, this is what a healthy lab looks like:

```
RP/0/RP0/CPU0:xr1#show ospf neighbor
Neighbor ID     Pri   State           Dead Time   Address         Interface
2.2.2.2         1     FULL/  -        00:00:33    10.1.1.2        GigabitEthernet0/0/0/0
2.2.2.2         1     FULL/  -        00:00:33    10.1.2.2        GigabitEthernet0/0/0/1
Total neighbor count: 2

RP/0/RP0/CPU0:xr1#show bfd session
Interface     Dest Addr    Local det time(int*mult)   State
Gi0/0/0/0     10.1.1.2     900ms(300ms*3)             UP
Gi0/0/0/1     10.1.2.2     900ms(300ms*3)             UP
Src Addr      Dest Addr    VRF Name
1.1.1.1       2.2.2.2      default   900ms(300ms*3)   UP

RP/0/RP0/CPU0:xr1#ping 10.1.1.2
Success rate is 100 percent (5/5), round-trip min/avg/max = 4/7/19 ms

RP/0/RP0/CPU0:xr1#ping 10.1.2.2
Success rate is 100 percent (5/5), round-trip min/avg/max = 4/4/6 ms

RP/0/RP0/CPU0:xr1#show cdp neighbors
Device ID       Local Intrfce    Holdtme Capability Platform  Port ID
xr2             Gi0/0/0/0        156     R          IOS-XRv 9 Gi0/0/0/0
xr2             Gi0/0/0/1        159     R          IOS-XRv 9 Gi0/0/0/1

RP/0/RP0/CPU0:xr1#show route 2.2.2.2
Routing entry for 2.2.2.2/32
  Known via "ospf CORE", distance 110, metric 2, type intra area
  Routing Descriptor Blocks
    10.1.1.2, from 2.2.2.2, via GigabitEthernet0/0/0/0
    10.1.2.2, from 2.2.2.2, via GigabitEthernet0/0/0/1

RP/0/RP0/CPU0:xr1#show bgp summary
BGP router identifier 1.1.1.1, local AS number 65000
Neighbor        Spk    AS MsgRcvd MsgSent   TblVer  InQ OutQ  Up/Down  St/PfxRcd
2.2.2.2           0 65000       2       2        0    0    0 00:03:41          0

RP/0/RP0/CPU0:xr1#show bgp neighbor 2.2.2.2
BGP neighbor is 2.2.2.2
 Remote AS 65000, local AS 65000, internal link
  BGP state = Established, up for 00:03:41
  Local host: 1.1.1.1, Local port: 56022
  Foreign host: 2.2.2.2, Foreign port: 179
```

Two adjacencies, one per link; three BFD sessions up; each node's only CDP
neighbour on a link is its peer; the remote loopback is reached over both
links; and the iBGP session is Established between the two loopbacks.
`./run_tests.sh` asserts all of this.

Note the BGP session carries no prefixes (`St/PfxRcd` is 0): nothing is
advertised into BGP, since the lab is about the peering itself. Add `network`
statements or a redistribute policy under `router bgp 65000` if you want
prefixes to look at.

## Files

| Path | Purpose |
| --- | --- |
| `xrv9k-fullk9-x-26.1.1.qcow2` | The base image. Never written to. |
| `topology.env` | Node list, resources, ports, link definitions |
| `lab.sh` | Start/stop/inspect the lab |
| `images/ubuntu-24.04-minimal-cloudimg-amd64.img` | nms base image. Never written to. |
| `configs/xr1.cfg`, `configs/xr2.cfg` | Day-0 XR configuration per node |
| `configs/nms-user-data` | nms cloud-init: users, rsyslog, snmptrapd, `xrssh`, `xrsnmp` |
| `configs/nms-network-config` | nms interfaces, matched by MAC |
| `configs/gobgp-user-data` | gobgp cloud-init: gobgpd, prefix injection |
| `configs/gobgp-network-config` | gobgp interfaces, matched by MAC |
| `nac/` | Cisco Network as Code (Terraform) -- see below |
| `docs/IOS-XR-NAC-topology.pdf` | Three-page topology and testbed reference (source: `docs/topology.html`) |
| `images/gobgp_4.9.0_linux_amd64.tar.gz` | gobgpd release, baked into gobgp's seed |
| `run_tests.sh` | Run the Robot Framework suite against the running lab |
| `nac/nac.sh` | Run Terraform against the routers (tunnels gNMI through nms) |
| `nac/iosxr.nac.yaml` | The Network as Code data model |
| `tests/` | The test suite (see below) |
| `tools/conmux.py` | Keep a console logged to a file, drive it from a FIFO |
| `tools/qmon.py` | Send commands to a node's QEMU monitor |
| `run/` | Overlay disks, day-0 ISOs, UEFI variable stores, pidfiles |
| `test_results/` | One timestamped directory per run, plus a `latest` symlink |
| `.venv/` | Test dependencies, created on first `./run_tests.sh` |

## OSPF, authentication and BFD

The IGP is OSPF, area 0, with both links as `network point-to-point` and
`Loopback0` passive so the /32 is advertised without running OSPF on it.

**Authentication.** Both links require MD5 (`authentication message-digest`,
key id 1). A router with no key, or the wrong one, cannot form an adjacency.
The key is a lab value in `configs/<node>.cfg`; the device stores it
encrypted on commit, so it does not appear in `show running-config` as
plaintext even though it is plaintext in the day-0 file.

**BFD** gives sub-second failure detection -- 300 ms x 3 = 900 ms, against
OSPF's own 40 s dead interval -- on three sessions per router:

| Session | Type | Client |
| --- | --- | --- |
| `Gi0/0/0/0` -> peer | single-hop | OSPF |
| `Gi0/0/0/1` -> peer | single-hop | OSPF |
| loopback -> peer loopback | **multihop** | BGP |

The multihop one is the awkward one and worth knowing about:

> The iBGP session peers loopback-to-loopback, so its BFD session is not
> attached to an interface -- it is multihop, and IOS-XR needs a line card
> nominated to host it:
>
> ```
> bfd
>  multipath include location 0/0/CPU0
> ```
>
> Without that the session sits at `MP download state:
> BFD_MP_DOWNLOAD_NO_LC` and never comes up, while `show bfd session`
> reports it plainly `DOWN` and `show bgp neighbor` says *"BFD not configured
> on remote neighbor"* -- which points at the wrong end entirely. The BGP
> session itself stays perfectly happy throughout, so nothing looks broken
> unless you go looking. `0/RP0/CPU0` is **not** accepted for this: the
> commit is rejected with *"Location is not a valid MH node"*. It has to be
> the line card.

**Not on the eBGP session.** BFD is deliberately absent from the peering with
`gobgp`: GoBGP has no BFD implementation, so the session could never come up,
and the config would be permanently misleading.

## The out-of-band network

The OOB network is one shared segment carrying all three nodes' management
interfaces: `10.99.0.0/24`, built from a QEMU multicast socket
(`230.31.0.1:11099`). Both routers' `MgmtEth0/RP0/CPU0/0` and nms's second NIC
sit on it.

**The routers are not reachable from the host.** XRv9k has exactly one
management port, so it cannot be on the OOB network *and* behind a QEMU
user-mode NAT with a port forward. Putting it where the task wants it means
the host has no route to it. nms bridges that gap: it has a NAT interface with
an SSH forward, so it is reachable from the host, and it is on the OOB network,
so it can reach the routers. Everything that needs a router goes through it:

```bash
./lab.sh ssh nms            # direct
./lab.sh ssh xr1            # through nms: nms's password, then the router's
```

On nms itself, `xrssh` (installed by cloud-init) wraps the password handling:

```bash
lab@nms:~$ xrssh xr1 show version
lab@nms:~$ xrssh xr2                  # interactive
```

`tests/XrCli.py` does the same thing programmatically: it connects to nms and
opens a `direct-tcpip` channel to the router's OOB address, so the suite drives
the routers over exactly the path an operator would use.

Two details worth knowing:

**Multicast, unlike the router-to-router links.** A shared segment is what
multicast sockets are for, and the loopback problem that ruled them out for
the point-to-point links does not bite here: no link-layer neighbour protocol
runs on the OOB segment (CDP is enabled only on the data interfaces), and a
node ignores IP frames carrying its own source MAC. It is visible if you go
looking, though -- `tcpdump -ni oob` on nms shows each frame nms sends a
second time, because it receives its own multicast.

**`ProxyCommand`, not `ProxyJump`.** `ssh -o StrictHostKeyChecking=no -J ...`
applies that option to the *final* hop only, so the connection to nms still
does strict host key checking -- and nms gets a fresh host key on every
`./lab.sh clean`, which turns into a "REMOTE HOST IDENTIFICATION HAS CHANGED"
refusal. `lab.sh` spells the jump out as a `ProxyCommand` so both hops share
the settings.

## The external BGP speaker

`gobgp` peers eBGP with xr1 over a dedicated point-to-point link
(`10.2.1.0/30`), deliberately separate from the OOB network and from the
router-to-router links:

```
xr1 Gi0/0/0/2 10.2.1.1/30  <--- eBGP --->  10.2.1.2/30 gobgp (AS 65100)
```

Only xr1 has that link, so only xr1 gets a sixth vNIC. Because vNIC order is
what fixes XRv9k interface naming, the link is added *last* -- every other
interface stays exactly where it was.

The 10000 prefixes are originated through gobgpd's API rather than listed in
`gobgpd.toml`, by `/usr/local/bin/inject-prefixes` (run by
`gobgp-prefixes.service`, so they come back after a reboot):

```bash
lab@gobgp:~$ gobgp global rib summary
Table afi:AFI_IP  safi:SAFI_UNICAST
Destination: 10000, Path: 10000

lab@gobgp:~$ gobgp neighbor
Peer        AS  Up/Down State       |#Received  Accepted
10.2.1.1 65000 00:03:47 Establ      |        0         0
```

Prefix *n* is `10.<100 + n/256>.<n % 256>.0/24`, so the count is not capped at
256 and the range stays clear of the lab's own 10.1/10.2/10.99 networks.

To change the count, edit the `ExecStart` in `gobgp-prefixes.service` (or run
`inject-prefixes <n>` by hand) and update `${GOBGP_PREFIX_COUNT}` and
`${GOBGP_LAST_PREFIX}` in `tests/topology.resource`.

The gobgp CLI takes one prefix per invocation -- there is no stdin batch mode,
despite what `--batch-size` on `gobgp global rib add` suggests -- but it
manages roughly 100 adds/second, so 10000 takes about 100 seconds after boot.
`gobgp-prefixes.service` therefore sets `TimeoutStartSec=600`; on systemd's
default 90 s it would be killed part-way through. Parallelising with
`xargs -P` buys nothing: the VM has one vCPU and the calls are already cheap.

gobgpd itself comes off the seed ISO rather than being downloaded at boot, so
the VM is useful without internet access. `lab.sh` refuses to start if the
tarball is missing and prints the `curl` command; it is also in `topology.env`.

### Two things IOS-XR needs here

**An eBGP neighbour needs an explicit route-policy.** IOS-XR applies no
default policy to eBGP, so without one the session comes up looking healthy
and every prefix is silently discarded -- `show bgp summary` shows `0` in
`St/PfxRcd`. Hence the `PASS` policy in `configs/xr1.cfg`:

```
route-policy PASS
  pass
end-policy
!
 neighbor 10.2.1.2
  address-family ipv4 unicast
   route-policy PASS in
   route-policy PASS out
```

**`next-hop-self` on the iBGP session.** xr2 has no route to `10.2.1.0/30`, so
prefixes relayed from xr1 would arrive with an unresolvable next hop and sit
inactive -- present in `show bgp` but never installed. xr1 rewrites the next
hop to its own loopback, which xr2 reaches over both links:

```
RP/0/RP0/CPU0:xr2#show route 10.100.0.0/24
  Known via "bgp 65000", distance 200, metric 0
  Routing Descriptor Blocks
    1.1.1.1, from 1.1.1.1          <- xr1's loopback, not 10.2.1.2
```

## Network as Code

The routers' configuration comes from two places, and the split matters:

| | Owns | Delivered by |
| --- | --- | --- |
| **Day-0** (`configs/<node>.cfg`) | Bootstrap: hostname, credentials, management address, ssh, **grpc**, **bfd**; plus the interfaces, OSPF and iBGP the lab is built on | `cvac`, from a CD-ROM at first boot |
| **Network as Code** (`nac/`) | A labelled slice: `Loopback98`, the login banner, the AS-path and prefix sets, the route-policies, and which policies each BGP neighbour uses | Terraform over gNMI |

Day-0 has to exist first: it is what makes a router reachable by automation at
all. Network as Code then reconciles the parts it owns, and can be re-run at
any time.

```bash
cd nac
./nac.sh init
./nac.sh plan
./nac.sh apply -auto-approve
```

`nac.sh` wraps `terraform` and handles the two things that are specific to
this lab:

**Reachability.** The provider speaks gNMI to the routers' management ports,
which exist only on the OOB network -- there is no route to them from the
host. `nac.sh` opens an SSH tunnel through nms for the life of the command,
giving each router a `127.0.0.1` port (`57411` for xr1, `57412` for xr2), and
tears it down on exit. `iosxr.nac.yaml` points `host:` at those local ports,
the same shape the c8000v lab uses for its NETCONF forwards.

**Credentials.** The module declares the `iosxr` provider itself from the
YAML's `devices` list, and the provider reads credentials from `IOSXR_*`
environment variables. `nac.sh` sets them from `topology.env`, including
`IOSXR_TLS=false` to match the routers' `grpc ... no-tls`.

The stack is `netascode/nac-iosxr/iosxr` (0.1.1) over the
`CiscoDevNet/iosxr` provider (0.7.1) -- the same pattern as the c8000v lab's
`nac-iosxe`, with `main.tf` doing nothing but pointing the module at the data
model.

### The data model

`nac/iosxr.nac.yaml` is the whole of it. Everything the routers get is data:

```yaml
iosxr:
  devices:
    - name: xr1
      host: 127.0.0.1:57411
      configuration:
        hostname: xr1
        interfaces:
          loopbacks:
            - id: 98
              description: Managed by Network as Code
              ipv4: { address: 10.98.1.1, mask: 255.255.255.255 }
        route_policies:
          - name: NAC-GOBGP-IN
            rpl: |
              route-policy NAC-GOBGP-IN
                if destination in (10.96.0.0/11 ge 24 le 24, ...) then
                  pass
                else
                  drop
                endif
              end-policy
        routing:
          bgp:
            - as_number: 65000
              neighbors:
                - address: 10.2.1.2
                  address_family:
                    - name: ipv4-unicast
                      route_policy_in: NAC-GOBGP-IN
                      route_policy_out: NAC-GOBGP-OUT
```

`hostname` is deliberately what day-0 already set, so it converges to a no-op:
the model becomes the source of truth for identity without changing anything.
The eBGP policy is the opposite -- day-0 applies a permissive `PASS` in both
directions purely so the session accepts anything at all, and Network as Code
replaces the inbound half with one that only accepts the /24 range gobgp is
supposed to originate. All 10000 prefixes still arrive, but now because they
match a policy rather than because nothing is being checked.

### AS-path validation

The inbound policy on the eBGP session checks two independent things, each
against a named set, and a prefix has to satisfy both:

```
prefix-set NAC-GOBGP-PREFIXES        as-path-set NAC-GOBGP-ASPATH
  10.100.0.0/14 ge 24 le 24,           ios-regex '^65100$'
  10.104.0.0/13 ge 24 le 24,         end-set
  10.112.0.0/12 ge 24 le 24,
  10.128.0.0/13 ge 24 le 24,
  10.136.0.0/14 ge 24 le 24
end-set
!
route-policy NAC-GOBGP-IN
  if destination in NAC-GOBGP-PREFIXES and as-path in NAC-GOBGP-ASPATH then
    pass
  else
    drop
  endif
end-policy
```

The five ranges cover second octets 100-139 and nothing else, which is
exactly the block gobgp generates (`10.100.0.0/24` … `10.139.15.0/24`).
`ge 24 le 24` pins the length to /24, so a **more specific** announcement
inside the range -- the usual shape of a hijack or a leak -- does not match
either.

This replaced an inline `destination in (...)` match on `10.96.0.0/11` and
`10.128.0.0/12`, which also quietly accepted second octets 96-99 and
140-143. A named set is both tighter and visible in one place:
`show running-config prefix-set NAC-GOBGP-PREFIXES`.

`^65100$` is an AS path of exactly one hop, AS 65100: gobgp originated the
prefix and nothing else has touched it. An eBGP peer can advertise any AS
path it likes, so this is the check that catches a prefix which has transited
somewhere it should not have, or which claims an origin it does not have --
regardless of whether the prefix itself looks plausible.

xr2 applies both checks a second time, inbound on the **iBGP** session from
xr1 (`NAC-IBGP-IN`). Neither the prefix nor the AS path is rewritten inside an
AS, so both are still checkable there. xr1 already filters, so this is
defence in depth: if xr1's policy were removed or mis-edited, xr2 would still
refuse a prefix outside the expected block or carrying an AS path it should
never see.

To watch it work, originate two prefixes from gobgp that differ only in AS
path -- both inside the policy's destination range, so the AS path is the only
thing separating them:

```bash
lab@gobgp:~$ gobgp global rib add 10.140.0.0/24 -a ipv4                  # path: 65100
lab@gobgp:~$ gobgp global rib add 10.140.1.0/24 -a ipv4 aspath 65200     # path: 65100 65200
```

```
RP/0/RP0/CPU0:xr1#show bgp ipv4 unicast 10.140.0.0/24
BGP routing table entry for 10.140.0.0/24      <- accepted

RP/0/RP0/CPU0:xr1#show bgp ipv4 unicast 10.140.1.0/24
%% Network not in table                        <- denied by NAC-GOBGP-IN
```

`Prefix With The Wrong AS Path Is Denied` automates exactly that, and cleans
the probe prefixes up in its teardown. One trap worth knowing if you probe by
hand: pick prefixes **outside** the injected range (which stops at
`10.139.15.0/24`). A probe at, say, `10.101.201.0/24` is already one of the
10000, so originating it with a different AS path silently *replaces* a real
prefix rather than adding a new one -- the accepted count goes *down* by one
instead of up, which is a confusing way to read a passing policy.

### The login banner

The banner is Network as Code's, not day-0's -- `configs/<node>.cfg` has no
banner at all -- so it is a clean demonstration of the split:

```yaml
banners:
  - type: login
    banner: |-
      #

        xr1 -- Cisco IOS-XRv9000 lab

        Authorized access only. Activity may be logged and monitored.
        Configuration is managed by Cisco Network as Code: changes
        made by hand are reverted on the next apply.

      #
```

`banner` is the whole delimited string, **opening and closing delimiter
included** -- the same shape as `rpl` below, and for the same reason: the
device stores and returns it that way (`banner login #...#` in the running
config). The delimiter here is `#`, so the text must not contain one.
Deleting the banner by hand and running `./nac.sh plan` shows `1 to add` for
that router alone; `apply` puts it back, which is precisely what the banner
claims will happen.

Two things about *seeing* it, both of which made it look briefly as though
the banner had not applied:

* **`xrssh` hides it.** The wrapper runs with `-o LogLevel=ERROR` to keep the
  known-hosts warning out of command output, and OpenSSH prints the banner
  only at `INFO` or above. `ssh` without that option shows it.
* **paramiko never sees it.** IOS-XR sends the banner in reply to the `none`
  authentication probe OpenSSH opens with; paramiko, given a password, goes
  straight to password authentication, so `transport.get_banner()` returns
  `None`. The banner test therefore logs in with a real SSH client from nms
  and reads stderr, rather than reusing the suite's own sessions.

### Drift detection

This is the part worth trying. Change something by hand on the router:

```
RP/0/RP0/CPU0:xr1(config)#interface Loopback98
RP/0/RP0/CPU0:xr1(config-if)#description changed by hand
```

```
$ ./nac.sh plan
  ~ description = "changed by hand" -> "Managed by Network as Code"
Plan: 0 to add, 1 to change, 0 to destroy.
```

`./run_tests.sh --include nac` fails on it too, and `./nac.sh apply` puts it
back. That round trip -- drift, detect, reconcile -- is verified in the
project history and is what the `nac` tagged tests are for.

### Three things that bit, in case they bite you

**`rpl` is the whole policy, not the body.** The `iosxr_route_policy`
resource wants the text including the `route-policy NAME` / `end-policy`
wrapper; the device stores and returns it that way. A bare body is rejected
with `'Policy Repository' detected the 'warning' condition 'There is a parse
error in the policy.'` -- and worse, the provider surfaces nothing at all on
stdout: `terraform apply` just exits 1 after printing `Creating...`. The error
is only visible with `TF_LOG=DEBUG TF_LOG_PATH=...`. Reading an existing
policy back through the `iosxr_route_policy` *data source* is the quickest way
to see the format the device expects.

**Managing part of `router bgp` does not prune the rest.** The plan for the
`iosxr_router_bgp` resource shows only `neighbors = [{ address = "10.2.1.2" }]`,
which looks as though applying it would drop the iBGP neighbour, the
router-id and the address-family that day-0 configured. It does not -- the
provider merges rather than replaces. That is worth knowing rather than
assuming, so `Day-0 Config Survived The Network As Code Apply` asserts it
explicitly.

**`-o StrictHostKeyChecking=no` and `ssh -J` do not mix**, which is why
`nac.sh` builds its tunnel with an explicit `-L` session rather than a
`ProxyJump`. Same reason `lab.sh ssh` uses a `ProxyCommand`; see the OOB
section.

## Syslog

Both routers ship syslog to nms over the OOB network:

```
logging trap informational
logging 10.99.0.10 vrf default severity info
logging source-interface MgmtEth0/RP0/CPU0/0
logging hostnameprefix xr1
```

Sourcing from the management port is what makes messages arrive with the
router's OOB address, which is how rsyslog files them per router:

```
lab@nms:~$ ls /var/log/routers/
10.99.0.11.log  10.99.0.12.log  all.log

lab@nms:~$ tail -1 /var/log/routers/10.99.0.11.log
... 10.99.0.11 354: xr1 RP/0/RP0/CPU0:...: %MGBL-SYS-5-CONFIG_I : Configured from console by admin on vty0 (10.99.0.10)
```

If `/var/log/routers/` is empty, check ownership first: rsyslog drops
privileges to the `syslog` user, and a directory left owned by `root:root`
makes every message fail with `open error: Permission denied` in
`/var/log/syslog` while `show logging` on the router still cheerfully reports
"Logging to 10.99.0.10, N message lines logged". The cloud-init seed chowns it
to `syslog:adm` for exactly this reason.

## SNMPv3

nms is both the poller and the trap receiver. Everything is v3 in **authPriv**
mode -- SHA authentication, AES privacy -- so nothing on the wire is readable
and an unauthenticated request gets no answer. There is no v1 or v2c
community anywhere in the lab.

On each router:

```
snmp-server view  LABVIEW 1.3.6.1 included
snmp-server group LABGROUP v3 priv read LABVIEW notify LABVIEW
snmp-server user  labmon LABGROUP v3 auth sha clear Snmp_Auth_12345 \
                                       priv aes 128 clear Snmp_Priv_12345 SystemOwner
snmp-server host  10.99.0.10 traps version 3 priv labmon
snmp-server trap-source MgmtEth0/RP0/CPU0/0
snmp-server traps config
snmp-server traps snmp linkup
snmp-server traps snmp linkdown
snmp-server traps bgp cbgp2
```

`trap-source` matters for the same reason `logging source-interface` does:
it makes traps arrive from the router's OOB address, which is what tells the
receiver -- and the tests -- which router sent them.

### Polling

cloud-init installs an `xrsnmp` wrapper on nms that carries the credentials,
so a poll is:

```
lab@nms:~$ xrsnmp xr1 1.3.6.1.2.1.1.5.0
.1.3.6.1.2.1.1.5.0 = STRING: "xr1"

lab@nms:~$ xrsnmp xr2 1.3.6.1.2.1.1.6.0
.1.3.6.1.2.1.1.6.0 = STRING: "IOS-XRv9000 lab"
```

With a wrong password the router simply does not answer the question:

```
lab@nms:~$ snmpwalk -v3 -l authPriv -u labmon -a SHA -A 'Wrong_Auth_12345' \
             -x AES -X 'Snmp_Priv_12345' 10.99.0.11 1.3.6.1.2.1.1.5.0
snmpwalk: Authentication failure (incorrect password, community or key)
```

which is what the `security`-tagged test asserts. A polling test that only
checks the happy path passes just as well against an agent with no security
at all.

### Traps

`snmptrapd` files one line per trap under `/var/log/snmp/traps.log`, with the
sending address on every line:

```
lab@nms:~$ tail -1 /var/log/snmp/traps.log
2026-09-10T21:26:19+00:00 host=<UNKNOWN> addr=UDP: [10.99.0.11]:161->[10.99.0.10]:162 \
  | .1.3.6.1.2.1.1.3.0=0:0:39:30.58 \
  | .1.3.6.1.6.3.1.1.4.1.0=.1.3.6.1.4.1.9.9.43.2.0.1 | ...
```

Committing a change produces `ciscoConfigManEvent` (`.1.3.6.1.4.1.9.9.43.2.0.1`),
which is what the trap test uses as a trigger; shutting an interface produces
`linkDown`/`linkUp` and, on xr1's gobgp link, `cbgpPeer2` state changes
carrying the cause as text (`"administrative shutdown"`).

Three things about this were not obvious, and each one fails silently:

**The engine ID is not what you configure.** A v3 trap is authenticated
against the *sender's* engine ID, so the receiver needs a `createUser` line
keyed to each router. XRv9k **accepts and ignores** `snmp-server engineID
local` -- it derives the engine ID from its management MAC instead, as
`000000090300` followed by the MAC. Hence:

```
createUser -e 0x000000090300525400e90101 labmon SHA "..." AES "..."   # xr1
createUser -e 0x000000090300525400e90201 labmon SHA "..." AES "..."   # xr2
```

Those two values track `MAC_PREFIX` in `topology.env`. Get one wrong and the
trap is dropped as unauthenticated with nothing logged -- indistinguishable
from a router that never sent it. `tcpdump -ni oob udp port 162` is how to
tell the difference: the packets are there, `U="labmon"`.

**The config file has to be readable by the daemon.** Ubuntu runs snmptrapd
as `User=Debian-snmp`, so a sensible-looking `0600 root:root` on
`/etc/snmp/snmptrapd.conf` -- it does hold the SNMPv3 passwords -- means the
daemon cannot read its own configuration and logs `No access configuration -
dropping trap` after decrypting every one. The seed makes it `0640
root:Debian-snmp`. (`authUser` is itself the access configuration; without an
access rule of some kind the same message appears.)

**Received traps are not in the daemon's log by default.** Ubuntu's unit runs
`snmptrapd -LOw`, which sends only warnings and above to syslog: errors show
up, traps do not. Rather than override `ExecStart`, the seed installs a
`traphandle` script -- the packaged unit and its socket activation of UDP 162
stay untouched, and the format is easy for a test to parse. `outputOption n`
keeps OIDs numeric so the tests do not depend on which MIBs are installed.

## Resources

Router defaults are 4 vCPU and **20480 MiB** each; nms and gobgp take 1 vCPU
and 1024 MiB each, so the lab wants about 42 GiB in total. The
memory figure is not a comfort setting — see below. `lab.sh` warns if the host
does not have that much available, which is worth heeding when the c8000v lab
is also running.

```bash
VM_VCPUS=6 ./lab.sh start        # more vCPUs is fine
VM_RAM_MB=16384 ./lab.sh start   # this will NOT boot; see below
NMS_RAM_MB=2048 ./lab.sh start   # the Linux VMs are not fussy
GOBGP_RAM_MB=2048 ./lab.sh start
```

Per-node `start`/`stop` is handy here: the Linux VMs boot in a couple of
minutes, so their cloud-init can be iterated on without touching the routers.

```bash
./lab.sh stop gobgp && rm -f run/gobgp.qcow2 run/gobgp-seed.iso
./lab.sh start gobgp
```

Note that a change to `configs/xr1.cfg` needs xr1's disk removed as well as a
restart -- day-0 config only applies to a fresh disk -- and that is a ~20
minute first boot.

## Tests

```bash
./run_tests.sh                    # whole suite
./run_tests.sh --include cdp      # any robot option is passed through
./run_tests.sh --include ospf
```

The system Python is PEP 668 "externally managed", so `run_tests.sh` creates
`.venv/` on first run and installs `robotframework` and `paramiko` into it.

Before running anything it validates the environment: it refuses to start if
no node is up, and warns by name about any node that is down, rather than
letting the suite fail with a wall of SSH timeouts.

Every run gets its own timestamped directory under `test_results/`, so runs
accumulate for comparison instead of overwriting each other:

```
test_results/
├── latest -> results_2026-09-10_10-22-10
├── results_2026-09-10_10-21-08/
│   ├── log.html          <- open this when something fails
│   ├── output.xml
│   └── report.html
└── results_2026-09-10_10-22-10/
    └── ...
```

`test_results/latest` is a symlink to the most recent run, so it is a stable
path to hand to a browser or a CI step.

The most recent run's `report.html` and `log.html` are **committed**, as the
record of what this lab was last verified to do. Two caveats: GitHub will not
render them in the browser -- they have to be downloaded, or opened through a
raw-HTML proxy -- and `output.xml` is excluded to keep each run to the two
files that actually get read (drop the `test_results/**/output.xml` line from
`.gitignore` if you want it; it is what `rebot` needs to merge or re-render
runs).

The lab must be booted *and* have its day-0 config applied -- wait for
`%MGBL-CVAC-4-CONFIG_DONE` -- or the tests will correctly report an
unconfigured box. CDP takes up to a minute after that to populate.

| Test | Tags | Checks |
| --- | --- | --- |
| XR Version Is The Expected Release | `version` | `show version` reports 26.1.1 on both nodes |
| Both Nodes Report The Expected Hostname | `version` `config` | day-0 config actually applied, so later failures are not just an unconfigured node |
| CDP Discovers The Peer On Every Link | `cdp` | each node sees *exactly* its peer over each link, on the matching remote port |
| CDP Reports The Peer As An XRv9000 Router | `cdp` | two neighbours per node, Router capability, `IOS-XRv 9` platform |
| OSPF Adjacency Is Full On Every Link | `ospf` | one neighbour per link, `FULL`, with the right router-id |
| OSPF Has Exactly Two Neighbors Per Node | `ospf` | both links carry an adjacency and no others exist |
| OSPF Authentication Is Active On Every Link | `ospf` `auth` | message-digest authentication in effect on the interface, key id 1 |
| BFD Is Protecting Both OSPF Links | `bfd` `ospf` | a single-hop session per link, `UP`, and OSPF reporting it uses BFD at 300 ms x 3 |
| BFD Is Protecting The IBGP Session | `bfd` `bgp` | the multihop session between the loopbacks is `UP`, and BGP reports it up |
| Loopback0 Has The Expected Host Address | `loopback` | the peering loopback is configured as a /32 |
| Peer Loopback Is Learned From OSPF Over Two ECMP Paths | `loopback` `ospf` `ecmp` | the peer's /32 comes from OSPF with exactly 2 paths, one per link, via the right next hop on each |
| IBGP Session To The Peer Is Established | `bgp` | exactly one neighbour, the peer's loopback, in AS 65000, Established |
| IBGP Peering Uses The Loopback Addresses | `bgp` `loopback` | the TCP session's local/foreign addresses are the loopbacks, so `update-source` really took effect |
| Management Server Is Ready | `nms` | nms finished cloud-init and rsyslog is running |
| Router Management Port Is On The OOB Network | `nms` `oob` | `MgmtEth0/RP0/CPU0/0` carries the router's OOB address, Up/Up |
| Routers Can Reach The Management Server Over OOB | `nms` `oob` | each router pings nms -- the direction syslog needs |
| Management Server Can Log In To Each Router Over SSH | `nms` `ssh` | `xrssh` from nms runs commands on each router, and the right router answers |
| Routers Send Syslog To The Management Server | `nms` `syslog` | a commit on each router produces new lines in its file on nms |
| SNMP Trap Receiver Is Ready On The Management Server | `nms` `snmp` | snmptrapd is running and holding UDP 162 |
| Management Server Can Poll Both Routers Over SNMPv3 | `nms` `snmp` | authPriv poll of sysName and sysLocation, and the right router answers |
| Routers Reject An SNMPv3 Poll With The Wrong Credentials | `nms` `snmp` `security` | the same poll with a wrong auth password fails and leaks nothing |
| Routers Send SNMPv3 Traps To The Management Server | `nms` `snmp` `traps` | a commit on each router produces its `ciscoConfigManEvent` trap on nms |
| External BGP Speaker Is Ready | `gobgp` | gobgp finished cloud-init; gobgpd and the injection service are up |
| External Speaker Originates The Expected Prefixes | `gobgp` | gobgp's own RIB holds all 10000, so a shortfall can be attributed to the right side |
| EBGP Session To The External Speaker Is Established | `gobgp` `bgp` | xr1↔gobgp is Established, AS 65100, external -- checked from both ends |
| Router Learns All Injected Prefixes Over EBGP | `gobgp` `bgp` `prefixes` | xr1 accepts all 10000, and both ends of the range are individually present (this is what fails if the eBGP route-policy is missing) |
| Injected Prefixes Are Installed In The Routing Table | `gobgp` `prefixes` | a prefix is in the RIB with gobgp as next hop, not merely in the BGP table |
| Injected Prefixes Reach The Other Router Over IBGP | `gobgp` `bgp` `prefixes` `ibgp` | xr2 holds all 10000, with xr1's loopback as next hop (proves next-hop-self) |
| Network As Code Manages The Labelled Loopback | `nac` | `Loopback98` matches `nac/iosxr.nac.yaml` -- config only Terraform creates |
| Network As Code Manages The Login Banner | `nac` `banner` | the login banner on each router matches the model -- again, config only Terraform creates |
| Login Banner Is Shown When Logging In | `nac` `banner` `ssh` | logging in from nms actually displays that router's banner, not just stores it |
| Network As Code Owns The EBGP Route Policies | `nac` `bgp` | the NAC policies exist *and* are the ones the eBGP neighbour uses |
| Day-0 Config Survived The Network As Code Apply | `nac` `bgp` | Terraform managing part of `router bgp` did not prune the day-0 iBGP neighbour, router-id or next-hop-self |
| Routing Policies Check The AS Path | `nac` `bgp` `aspath` | the AS-path set exists on both routers and is referenced by the policies actually applied |
| Route Policies Filter On A Named Prefix Set | `nac` `bgp` `prefixset` | the prefix-set exists on both routers, pins the length to /24, and is referenced by both inbound policies |
| Prefixes Outside The Prefix Set Are Denied | `nac` `bgp` `prefixset` | end to end: of three prefixes with identical AS paths, only the in-range /24 is accepted |
| Prefix With The Wrong AS Path Is Denied | `nac` `bgp` `aspath` | end to end: of two prefixes differing only in AS path, only the legitimate one reaches xr1's table |

Layout:

| Path | Purpose |
| --- | --- |
| `tests/xr_lab.robot` | The test cases |
| `tests/topology.resource` | Node names, ports, interfaces, expected values |
| `tests/XrCli.py` | Opens one persistent XR shell per node (through nms) and runs commands |
| `tests/XrParse.py` | Turns show output into structured rows |

Two things worth knowing if you extend this:

**Not SSHLibrary.** XR's sshd allows one `exec` channel per connection: the
first `Execute Command` works and the next fails with `Channel closed`. So
`XrCli` opens an interactive shell per node, sends `terminal length 0` once,
and reads until the `RP/0/RP0/CPU0:<host>#` prompt returns rather than for a
fixed delay.

**Everything goes through nms.** `XrCli` connects to nms on its host SSH
forward and tunnels each router session over a `direct-tcpip` channel, because
there is no route from the host to a router's management port. If the whole
suite fails at setup, check nms first: `./lab.sh ssh nms`.

**Parsed, not grepped.** `XrParse` turns the tables into dicts so assertions
are about counts and fields, and a failure prints the rows the device actually
returned. Asserting `Should Contain    ${output}    xr2` would have passed
happily against the looping-multicast bug described under "How the virtual
machines are wired" below; `exactly one neighbour per interface` did not.

The two BGP tests deliberately check different things. The summary test proves
the session is up; the neighbour test reads the `Local host:` and
`Foreign host:` of the live TCP session, so it passes only if
`update-source Loopback0` actually took effect rather than merely appearing in
the configuration.

### Checking the tests themselves

Shutting one link is a quick way to confirm the suite is not vacuous, and it
doubles as a demonstration of why the iBGP session peers on loopbacks:

```bash
# on xr1: configure terminal / interface Gi0/0/0/1 / shutdown / commit
./run_tests.sh --include ecmp --include bgp
```

The prefix-set and AS-path tests can be checked the same way, by removing one
half of the condition from `NAC-GOBGP-IN` by hand: the corresponding pair of
tests fails -- including the end-to-end one, which is the proof that the
rejected prefix really would have been accepted -- and `./nac.sh apply` puts
the policy back.

The ECMP test fails and names the interface
(`xr1: 2.2.2.2/32 has [...one path...] -- expected 2 ECMP paths`), while both
iBGP tests keep passing: the session simply reconverges onto the surviving
link. `no shutdown` and the suite returns to all green.

The prefix tests can be checked by withdrawing some on the speaker
(`gobgp global rib del 10.100.99.0/24`): xr1 and xr2 both drop to the new
count and the tests say so (`xr1 accepted 9999 prefixes from gobgp, expected
10000`). `sudo systemctl restart gobgp-prefixes` puts them back.

The two bulk counts are read from XR's `Processed N prefixes` trailer via
`| include Processed`, not by parsing the table: at 10000 prefixes the full
`show bgp ipv4 unicast` is roughly 700 KB, which would go through the session
and into `log.html` on every assertion. The ends of the range are checked as
individual prefixes instead, so a count that happened to be right would still
have to be right about *which* prefixes.

The syslog test can be checked the same way -- remove
`logging 10.99.0.10 vrf default severity info` from a router and it fails with
`nms has filed 30 syslog lines for xr1 (10.99.0.11), was 30 -- no new messages
arrived`.

The SNMP trap test is checked by removing `snmp-server host 10.99.0.10 traps
version 3 priv labmon` from a router, or by breaking one `createUser` line on
nms: either way it fails naming the router and the OID it did not see. It only
looks at trap lines filed *after* its own trigger, so it cannot pass on a trap
that was already in the log from an earlier run. The polling test is checked
by removing `snmp-server user labmon ...`.

The syslog test commits a `description` on `Loopback0` to force a router to
log something, and removes it again in its teardown, so the running config
still matches `configs/<node>.cfg` afterwards.

## How the virtual machines are wired

XRv9k fixes the meaning of each vNIC by position, so `lab.sh` adds them in this
order and no other. (The image's own platform config confirms the naming:
`PLATFORM_MGMT_ETH=mgmt-eth0`, `PLATFORM_CTRL_ETH=ctrl-eth0`,
`PLATFORM_HOST_ETH=host-eth0`.)

| vNIC | XR interface | Backing |
| --- | --- | --- |
| 1 | `MgmtEth0/RP0/CPU0/0` | user-mode NAT + SSH forward |
| 2 | CtrlEth | dead-end QEMU hub |
| 3 | DevEth | dead-end QEMU hub |
| 4 | `GigabitEthernet0/0/0/0` | link1 |
| 5 | `GigabitEthernet0/0/0/1` | link2 |

CtrlEth and DevEth are internal to a real chassis, but the image still expects
the vNICs to exist, so they get one-port hubs. QEMU prints
`warning: hub N is not connected to host network` for each; that is the
intended state, not a problem.

The two links are QEMU `socket` netdevs: a pair of unicast UDP endpoints on
loopback per link (11001/11002 for link1, 11003/11004 for link2), crossed so
each node sends to the other's port. Nothing needs root: no bridges, no tap
devices.

Multicast (`mcast=`) sockets would be the obvious choice here, and are easier
to extend to a third node on the same link, but QEMU loops multicast frames
back to the sender. With those, `show cdp neighbors` on xr1 listed *xr1* as
well as xr2 on both interfaces: every node saw itself on the wire. The CDP
test below is what caught it. Unicast UDP makes each link a real
point-to-point wire.

Day-0 configuration is delivered the way XRv9k expects it: `configs/<node>.cfg`
is written to a small ISO as `iosxr_config.txt` and attached as a CD-ROM. XR's
`cvac` process applies it on first boot and logs to `/disk0:/cvac.log`. Editing
a config and re-running `./lab.sh start` rebuilds that node's ISO, but day-0
config only applies to a fresh disk, so a node that has already booted needs
`./lab.sh clean` first.

## Two things this image needs that are easy to get wrong

Both of these cost a lot of time to find, because in each case the VM fails
*silently* — no error, no panic, just a guest that sits there.

**It is UEFI-only.** The qcow2 has a GPT with an EFI System Partition and a
protective MBR whose boot code is all zeros. Booted on SeaBIOS it prints
`Booting from Disk...`, jumps into the zeroed MBR, and spins forever at 100%
CPU with nothing on the serial console. `lab.sh` gives each node OVMF firmware
plus its own writable copy of the variable store.

**It needs more than 18 GiB of RAM, and 16 GiB hangs it.** This is the one that
matters most, because 16 GiB is the figure usually quoted as the XRv9k minimum
and it looks like it should work.

The image's own GRUB config boots the host OS with `hugepages=6`, i.e. six
1 GiB hugepages. Cisco's platform code checks that the hugepage boot arguments
match what it expects for the amount of RAM present, and its constants are:

```
PLATFORM_DEFAULT_HUGE_PAGE_MEM_KB_NEEDED=3145728        # 3 GiB, i.e. 3 pages
PLATFORM_SYS_MEM_GB_THRESHOLD_DOUBLE_HUGEPAGES=18       # double them above 18 GiB
```

So `hugepages=6` is the *doubled* allocation, which the platform expects only
when the guest has more than 18 GiB. Give a node 16 GiB and the expected
setting (3 pages) disagrees with the command line (6 pages), and
`check_hugepage_setting` — called from `platform_mount_huge_pages` in
`/usr/bin/spirit_sysinit.sh` — never returns.

What that looks like from outside: the host OS boots normally as far as
`systemd-vconsole-setup`, then stops. systemd stays alive and keeps answering
journald's watchdog, one vCPU spins, the disk stops growing, and nothing is
ever printed again. Underneath, `spirit_sysinit.service` never finishes, so
`local-fs.target` never completes, `sysinit.target` is held back, and XR is
never started. With `systemd.log_target=console debug` on the command line the
last useful line is:

```
local-fs.target: starting held back, waiting for: spirit_sysinit.service
```

At 20 GiB every boot has completed normally. Nothing else about the image needs
changing: boot arguments are stock and the base image is untouched.

A caution on chasing this yourself: the failure looks maddeningly like a
timing/race bug. Two of the early attempts here *did* boot at 16 GiB, which
made verbose-console boot arguments look like the fix. They were not — the two
successes were luck, and heavier console output only changed the timing. Only
the memory threshold explains every attempt.

## Debugging aids

`tools/conmux.py` keeps a console attached and logged even while nothing is
reading it, which matters because a QEMU telnet chardev accepts one client at a
time and discards output when nobody is connected:

```bash
./tools/conmux.py xr1 5101 &
tail -f run/xr1-console.log
printf 'show ospf neighbor\r' > run/xr1.in
```

`tools/qmon.py` talks to a node's QEMU monitor and refuses to forward `quit`
(which would kill the VM):

```bash
./tools/qmon.py 4101 'info block' 'info network'
```

Two quirks worth knowing if you go further: the monitor parses an unquoted path
as an expression, so file arguments need quoting
(`screendump "/abs/path.ppm"`), and `pmemsave`'s size argument is 32-bit, so
dumping guest RAM has to be done in chunks under 4 GiB. SysRq is compiled out
of this kernel, so `sendkey alt-sysrq-*` reports the operation as disabled.
