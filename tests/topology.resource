*** Settings ***
Documentation     Facts about the lab under test, plus the keywords that talk
...               to it. Everything here mirrors topology.env and configs/.
Library           ../tests/XrCli.py
Library           ../tests/XrParse.py
Library           Collections

*** Variables ***
# Expected software release. Taken from the base image filename,
# xrv9k-fullk9-x-26.1.1.qcow2.
${XR_VERSION}         26.1.1

# The routers, and their management addresses on the OOB network. There is
# no host route to these: sessions are tunnelled through nms, which is
# reached on its own SSH forward (see XrCli).
@{NODES}              xr1    xr2
&{PEER}               xr1=xr2    xr2=xr1
&{OOB_IP}             xr1=10.99.0.11    xr2=10.99.0.12
${NMS_OOB_IP}         10.99.0.10

# Where rsyslog on nms files each router's messages.
${SYSLOG_DIR}         /var/log/routers

# Configuration owned by Cisco Network as Code (nac/iosxr.nac.yaml) rather
# than by the day-0 config. Kept in step with that file by hand -- the point
# of the tests is to catch the two drifting apart.
&{NAC_LOOPBACK}           xr1=10.98.1.1    xr2=10.98.2.1
${NAC_LOOPBACK_ID}        Loopback98
${NAC_LOOPBACK_DESC}      Managed by Network as Code
${NAC_POLICY_IN}          NAC-GOBGP-IN
${NAC_POLICY_OUT}         NAC-GOBGP-OUT
${NAC_POLICY_IBGP_IN}     NAC-IBGP-IN
${NAC_ASPATH_SET}         NAC-GOBGP-ASPATH

# Probe prefixes for the AS-path policy test. Both sit inside the policy's
# destination match (10.128.0.0/12) but outside the 10000 gobgp originates
# (which stop at 10.139.15.0/24), so injecting them cannot collide with a
# real one -- picking 10.101.x by mistake silently *replaces* an injected
# prefix instead of adding a new one.
${ASPATH_PROBE_GOOD}      10.140.0.0/24
${ASPATH_PROBE_BAD}       10.140.1.0/24
${ASPATH_PROBE_BAD_AS}    65200

# The external BGP speaker: which router it peers with, over what addresses,
# and how many prefixes it originates.
${GOBGP_PEER}             xr1
${GOBGP_AS}               65100
${GOBGP_LINK_IP_GOBGP}    10.2.1.2
${GOBGP_LINK_IP_XR1}      10.2.1.1
${GOBGP_PREFIX_COUNT}     10000
# gobgp originates prefix n as 10.<100 + n/256>.<n % 256>.0/24, so 10000 of
# them run from 10.100.0.0/24 to 10.139.15.0/24. The ends are spot-checked
# individually; the bulk is only ever counted.
${GOBGP_FIRST_PREFIX}     10.100.0.0/24
${GOBGP_LAST_PREFIX}      10.139.15.0/24

# The two links, by the interface each node uses. Both links are
# point-to-point between the same pair of routers.
@{LINK_INTERFACES}    GigabitEthernet0/0/0/0    GigabitEthernet0/0/0/1
# CDP and IS-IS both abbreviate interface names in their tables.
@{LINK_INTERFACES_SHORT}      Gi0/0/0/0    Gi0/0/0/1

# `show cdp neighbors` reports the XRv9000 platform truncated to this.
${CDP_PLATFORM}       IOS-XRv 9

# Loopback0 per node: advertised into IS-IS and used as the iBGP peering
# address, so it appears in the routing, IS-IS and BGP assertions alike.
&{LOOPBACK}           xr1=1.1.1.1     xr2=2.2.2.2
&{PEER_LOOPBACK}      xr1=2.2.2.2     xr2=1.1.1.1

# The peer's address on each link -- the two next hops a node should use to
# reach the peer's loopback, one per link.
&{PEER_IP_LINK1}      xr1=10.1.1.2    xr2=10.1.1.1
&{PEER_IP_LINK2}      xr1=10.1.2.2    xr2=10.1.2.1

# OSPF reports the process it learned a route from as "<protocol> <tag>".
${OSPF_PROTOCOL}      ospf CORE
${OSPF_PROCESS}       CORE
# Sub-second failure detection: 300 ms x 3 on every session.
${BFD_INTERVAL}       300
${BFD_MULTIPLIER}     3
# One single-hop session per link (OSPF) plus one multihop (iBGP loopbacks).
${BFD_SINGLE_HOP_SESSIONS}    2
${BFD_MULTIHOP_SESSIONS}      1

# Both routers are in one AS, so the peering is iBGP ("internal link").
${BGP_AS}             65000
# How many BGP neighbours each router has: xr1 also peers eBGP with gobgp.
&{BGP_NEIGHBOR_COUNT}     xr1=2    xr2=1

*** Keywords ***
Connect To All Nodes
    [Documentation]    Suite setup: open one persistent XR shell per node,
    ...                tunnelled through nms.
    FOR    ${node}    IN    @{NODES}
        Connect To Node    ${node}    ${OOB_IP}[${node}]
    END

Disconnect From All Nodes
    [Documentation]    Suite teardown.
    Close All Nodes

Neighbors On Interface
    [Documentation]    CDP rows on ${node} learned via ${interface}.
    [Arguments]    ${node}    ${interface}
    ${output}=    Run Command    ${node}    show cdp neighbors
    ${rows}=      Parse Cdp Neighbors    ${output}
    ${matching}=  Create List
    FOR    ${row}    IN    @{rows}
        IF    '${row}[local_interface]' == '${interface}'
            Append To List    ${matching}    ${row}
        END
    END
    RETURN    ${matching}

Ospf Neighbors On Interface
    [Documentation]    OSPF neighbour rows on ${node} over ${interface}.
    [Arguments]    ${node}    ${interface}
    ${output}=    Run Command    ${node}    show ospf neighbor
    ${rows}=      Parse Ospf Neighbors    ${output}
    ${matching}=  Create List
    FOR    ${row}    IN    @{rows}
        IF    '${row}[interface]' == '${interface}'
            Append To List    ${matching}    ${row}
        END
    END
    RETURN    ${matching}

Bfd Sessions On
    [Documentation]    All BFD sessions ${node} currently has.
    [Arguments]    ${node}
    ${output}=    Run Command    ${node}    show bfd session
    ${rows}=      Parse Bfd Sessions    ${output}
    RETURN    ${rows}

Nms Should Be Ready
    [Documentation]    cloud-init has finished and the syslog server is up.
    ...                Checked first so a syslog or SSH failure elsewhere is
    ...                not just nms still installing packages.
    ${rc}    ${out}    ${err}=    Run Command On Nms    cat /var/lib/cloud/nms-ready
    Should Be Equal As Integers    ${rc}    0
    ...    nms has not finished cloud-init (no /var/lib/cloud/nms-ready): ${err}
    ${rc}    ${out}    ${err}=    Run Command On Nms    systemctl is-active rsyslog
    Should Be Equal    ${out.strip()}    active
    ...    rsyslog on nms is "${out.strip()}", not active

Syslog Line Count
    [Documentation]    Lines rsyslog on nms has filed for ${node} so far.
    ...                A missing file counts as 0: rsyslog only creates it
    ...                when the first message from that router arrives.
    [Arguments]    ${node}
    ${ip}=    Set Variable    ${OOB_IP}[${node}]
    ${rc}    ${out}    ${err}=    Run Command On Nms
    ...    wc -l < ${SYSLOG_DIR}/${ip}.log 2>/dev/null || echo 0
    RETURN    ${out.strip()}

Trigger Syslog Event On
    [Documentation]    Make ${node} emit a syslog message on demand, by
    ...                committing a harmless change. XR logs every commit
    ...                (%MGBL-CONFIG-6-DB_COMMIT), so this is a reliable
    ...                trigger; waiting for the routers to say something on
    ...                their own would make the test slow and flaky.
    [Arguments]    ${node}
    Run Command    ${node}    configure terminal
    Run Command    ${node}    interface Loopback0
    Run Command    ${node}    description syslog-probe
    Run Command    ${node}    commit
    Run Command    ${node}    end

Remove Syslog Probe Description
    [Documentation]    Undo Trigger Syslog Event On, on every router, so the
    ...                running config matches configs/<node>.cfg again.
    FOR    ${node}    IN    @{NODES}
        Run Command    ${node}    configure terminal
        Run Command    ${node}    interface Loopback0
        Run Command    ${node}    no description
        Run Command    ${node}    commit
        Run Command    ${node}    end
    END

Syslog Count Should Have Grown
    [Documentation]    Retried by the syslog test until messages arrive.
    [Arguments]    ${node}    ${before}
    ${now}=    Syslog Line Count    ${node}
    Should Be True    ${now} > ${before}
    ...    nms has filed ${now} syslog lines for ${node} (${OOB_IP}[${node}]), was ${before} -- no new messages arrived

Gobgp Should Be Ready
    [Documentation]    cloud-init finished on gobgp and both its services are
    ...                up, so a peering failure is not just a half-built VM.
    ${rc}    ${out}    ${err}=    Run Command On Gobgp    cat /var/lib/cloud/gobgp-ready
    Should Be Equal As Integers    ${rc}    0
    ...    gobgp has not finished cloud-init (no /var/lib/cloud/gobgp-ready): ${err}
    ${rc}    ${out}    ${err}=    Run Command On Gobgp
    ...    systemctl is-active gobgpd gobgp-prefixes
    Should Be Equal    ${out.split()}    ${{ ['active', 'active'] }}
    ...    gobgpd / gobgp-prefixes on gobgp are ${out.split()}, expected both active

Accepted Prefix Count On
    [Documentation]    How many prefixes ${node} currently accepts from gobgp.
    [Arguments]    ${node}
    ${output}=    Run Command    ${node}
    ...    show bgp ipv4 unicast neighbors ${GOBGP_LINK_IP_GOBGP} routes | include Processed
    ${count}=     Parse Processed Count    ${output}
    RETURN    ${count}

Inject Probe Prefixes On Gobgp
    [Documentation]    Originate two prefixes from gobgp: one with the normal
    ...                AS path, one that claims to have transited another AS.
    ...                gobgp prepends its own 65100 on the way out, so the
    ...                second arrives as "65100 ${ASPATH_PROBE_BAD_AS}".
    ${rc}    ${out}    ${err}=    Run Command On Gobgp
    ...    gobgp global rib add ${ASPATH_PROBE_GOOD} -a ipv4
    Should Be Equal As Integers    ${rc}    0    could not originate ${ASPATH_PROBE_GOOD}: ${err}
    ${rc}    ${out}    ${err}=    Run Command On Gobgp
    ...    gobgp global rib add ${ASPATH_PROBE_BAD} -a ipv4 aspath ${ASPATH_PROBE_BAD_AS}
    Should Be Equal As Integers    ${rc}    0    could not originate ${ASPATH_PROBE_BAD}: ${err}

Withdraw Probe Prefixes On Gobgp
    [Documentation]    Teardown for the AS-path test: leave gobgp originating
    ...                exactly the ${GOBGP_PREFIX_COUNT} it started with.
    Run Command On Gobgp    gobgp global rib del ${ASPATH_PROBE_GOOD} -a ipv4
    Run Command On Gobgp    gobgp global rib del ${ASPATH_PROBE_BAD} -a ipv4

Prefix Should Be In Bgp Table
    [Arguments]    ${node}    ${prefix}
    ${output}=    Run Command    ${node}    show bgp ipv4 unicast ${prefix}
    Should Contain    ${output}    BGP routing table entry for ${prefix}
    ...    ${node}: ${prefix} is not in the BGP table:\n${output}

Prefix Should Not Be In Bgp Table
    [Arguments]    ${node}    ${prefix}
    ${output}=    Run Command    ${node}    show bgp ipv4 unicast ${prefix}
    Should Contain    ${output}    Network not in table
    ...    ${node}: ${prefix} reached the BGP table but should have been denied:\n${output}

Accepted Count Should Be
    [Documentation]    Retried while BGP reconverges after a prefix change.
    [Arguments]    ${node}    ${expected}
    ${count}=    Accepted Prefix Count On    ${node}
    Should Be Equal As Integers    ${count}    ${expected}
    ...    ${node} accepts ${count} prefixes from gobgp, expected ${expected}
