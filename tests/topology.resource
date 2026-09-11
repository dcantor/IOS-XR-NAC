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

# The login banner, also owned by Network as Code. Its first line names the
# router, so one login shows which device answered -- and gives the banner
# test something device-specific to match on rather than text that would be
# identical everywhere.
${BANNER_TYPE}            login
&{BANNER_IDENTITY}        xr1=xr1 -- Cisco IOS-XRv9000 lab    xr2=xr2 -- Cisco IOS-XRv9000 lab
${BANNER_NOTICE}          Authorized access only. Activity may be logged and monitored.
# Logging in needs the router credentials; XrCli holds the same pair.
${XR_USER}                admin
${XR_PASSWORD}            Admin@12345

# Probe prefixes. All of them sit inside NAC-GOBGP-PREFIXES (second octet
# 100-139) but above the 10000 gobgp actually originates (which stop at
# 10.139.15.0/24), so injecting one cannot collide with a real prefix --
# picking 10.101.x by mistake silently *replaces* an injected prefix instead
# of adding a new one, and the accepted count then falls instead of rising.
#
# The AS-path probes differ only in AS path, so only that check can separate
# them; the prefix probes carry a valid AS path, so only the prefix-set can.
${ASPATH_PROBE_GOOD}      10.139.30.0/24
${ASPATH_PROBE_BAD}       10.139.31.0/24
${ASPATH_PROBE_BAD_AS}    65200

${PREFIX_PROBE_GOOD}          10.139.40.0/24
${PREFIX_PROBE_OUT_OF_RANGE}  10.200.0.0/24
${PREFIX_PROBE_WRONG_LENGTH}  10.139.41.0/25
${NAC_PREFIX_SET}             NAC-GOBGP-PREFIXES

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

# SNMPv3, in authPriv mode: the credentials both routers accept
# (configs/<node>.cfg) and nms uses (its xrsnmp wrapper), and where
# snmptrapd files what it receives.
${SNMP_USER}              labmon
${SNMP_AUTH_PASS}         Snmp_Auth_12345
${SNMP_PRIV_PASS}         Snmp_Priv_12345
# Used to prove the routers actually authenticate a poll rather than
# answering anyone who asks.
${SNMP_WRONG_AUTH_PASS}   Wrong_Auth_12345
${SNMP_TRAP_LOG}          /var/log/snmp/traps.log
# sysName.0: each router answers with its own hostname, so one poll shows
# both that SNMP works and which router replied. sysLocation.0 is set by
# day-0 config, so it also confirms the poll reached the configured agent
# and not something else listening on udp/161.
${SNMP_SYSNAME_OID}       1.3.6.1.2.1.1.5.0
${SNMP_LOCATION_OID}      1.3.6.1.2.1.1.6.0
${SNMP_LOCATION}          IOS-XRv9000 lab
# CISCO-CONFIG-MAN-MIB::ciscoConfigManEvent -- the trap a commit produces,
# which is what the trap tests use as their trigger. Numeric because
# snmptrapd on nms is configured with `outputOption n`.
${SNMP_CONFIG_TRAP_OID}   .1.3.6.1.4.1.9.9.43.2.0.1

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

Trigger Config Commit On
    [Documentation]    Make ${node} report an event on demand, by committing
    ...                a harmless change. XR both logs every commit
    ...                (%MGBL-CONFIG-6-DB_COMMIT) and sends a
    ...                ciscoConfigManEvent trap for it, so one trigger serves
    ...                the syslog and the SNMP trap tests alike; waiting for
    ...                the routers to say something on their own would make
    ...                both slow and flaky.
    [Arguments]    ${node}
    Run Command    ${node}    configure terminal
    Run Command    ${node}    interface Loopback0
    Run Command    ${node}    description commit-probe
    Run Command    ${node}    commit
    Run Command    ${node}    end

Remove Probe Description
    [Documentation]    Undo Trigger Config Commit On, on every router, so the
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

Inject Prefix Probes On Gobgp
    [Documentation]    Originate three prefixes from gobgp, all with the
    ...                normal AS path: one the prefix-set should accept, one
    ...                outside the permitted range, and one inside the range
    ...                but more specific than /24.
    FOR    ${prefix}    IN    ${PREFIX_PROBE_GOOD}    ${PREFIX_PROBE_OUT_OF_RANGE}
    ...                       ${PREFIX_PROBE_WRONG_LENGTH}
        ${rc}    ${out}    ${err}=    Run Command On Gobgp
        ...    gobgp global rib add ${prefix} -a ipv4
        Should Be Equal As Integers    ${rc}    0
        ...    could not originate ${prefix}: ${err}
    END

Withdraw Prefix Probes On Gobgp
    [Documentation]    Teardown for the prefix-set test.
    FOR    ${prefix}    IN    ${PREFIX_PROBE_GOOD}    ${PREFIX_PROBE_OUT_OF_RANGE}
    ...                       ${PREFIX_PROBE_WRONG_LENGTH}
        Run Command On Gobgp    gobgp global rib del ${prefix} -a ipv4
    END

Snmp Trap Receiver Should Be Ready
    [Documentation]    snmptrapd is running on nms and holding udp/162, so a
    ...                missing trap is not just a receiver that never
    ...                started.
    ${rc}    ${out}    ${err}=    Run Command On Nms    systemctl is-active snmptrapd
    Should Be Equal    ${out.strip()}    active
    ...    snmptrapd on nms is "${out.strip()}", not active
    ${rc}    ${out}    ${err}=    Run Command On Nms
    ...    ss -lun | grep -F -c ':162'
    Should Be True    ${out.strip()} > 0
    ...    nothing on nms is listening on udp/162

Poll Router Over Snmpv3
    [Documentation]    Poll one OID on ${node} from nms with the lab's
    ...                SNMPv3 credentials, through the same xrsnmp wrapper an
    ...                operator would use. Returns rc, stdout, stderr.
    [Arguments]    ${node}    ${oid}
    ${rc}    ${out}    ${err}=    Run Command On Nms    xrsnmp ${node} ${oid}
    RETURN    ${rc}    ${out}    ${err}

Poll Router With The Wrong Password
    [Documentation]    The same authPriv poll as Poll Router Over Snmpv3, but
    ...                with a wrong authentication password, and going
    ...                straight to snmpwalk rather than through the xrsnmp
    ...                wrapper (which hardcodes the correct credentials).
    ...                Short timeout and one retry: this is expected to fail,
    ...                and the router answers a bad poll with silence.
    [Arguments]    ${node}
    ${cmd}=    Catenate
    ...    snmpwalk -v3 -l authPriv -u ${SNMP_USER}
    ...    -a SHA -A '${SNMP_WRONG_AUTH_PASS}'
    ...    -x AES -X '${SNMP_PRIV_PASS}'
    ...    -t 2 -r 1 ${OOB_IP}[${node}] ${SNMP_SYSNAME_OID}
    ${rc}    ${out}    ${err}=    Run Command On Nms    ${cmd}
    RETURN    ${rc}    ${out}    ${err}

Trap Line Count
    [Documentation]    Traps snmptrapd has filed from ${node} so far. The
    ...                traphandle records the sending address on every line,
    ...                which is what separates the two routers.
    ...
    ...                `grep | wc -l` rather than `grep -c`: grep exits 1 on
    ...                no match, and a missing log file is another 0 rather
    ...                than an error -- the file only appears once the first
    ...                trap arrives.
    [Arguments]    ${node}
    ${ip}=    Set Variable    ${OOB_IP}[${node}]
    ${rc}    ${out}    ${err}=    Run Command On Nms
    ...    grep -F 'addr=UDP: [${ip}]' ${SNMP_TRAP_LOG} 2>/dev/null | wc -l
    RETURN    ${out.strip()}

Trap Log Lines From
    [Documentation]    Trap lines nms has filed from ${node}, starting at
    ...                ${from_line}. The log accumulates across runs, so a
    ...                test that means "a trap arrived just now" has to skip
    ...                what was already there.
    [Arguments]    ${node}    ${from_line}=1
    ${ip}=    Set Variable    ${OOB_IP}[${node}]
    ${rc}    ${out}    ${err}=    Run Command On Nms
    ...    grep -F 'addr=UDP: [${ip}]' ${SNMP_TRAP_LOG} 2>/dev/null | tail -n +${from_line}
    RETURN    ${out}

Configuration Trap Should Have Arrived From
    [Documentation]    Retried while the trap is in flight. Asserting on the
    ...                trap's own OID rather than just a line count means
    ...                this cannot pass on some unrelated trap the router
    ...                happened to send at the same moment, and proves
    ...                snmptrapd authenticated and decrypted the v3 payload
    ...                -- an undecryptable trap has no readable varbinds.
    [Arguments]    ${node}    ${from_line}
    ${lines}=    Trap Log Lines From    ${node}    ${from_line}
    Should Contain    ${lines}    ${SNMP_CONFIG_TRAP_OID}
    ...    no ciscoConfigManEvent (${SNMP_CONFIG_TRAP_OID}) trap from ${node} since line ${from_line} of ${SNMP_TRAP_LOG}:\n${lines}

Login Banner From
    [Documentation]    Log in to ${node} from nms with a real SSH client and
    ...                return whatever it printed before the session began.
    ...
    ...                Not through the xrssh wrapper, and not through the
    ...                suite's own paramiko sessions, for two different
    ...                reasons. xrssh runs with `LogLevel=ERROR` to keep the
    ...                known-hosts warning out of command output, and that
    ...                also suppresses the banner. paramiko never sees one at
    ...                all: IOS-XR sends the banner in reply to the `none`
    ...                authentication probe OpenSSH opens with, and paramiko
    ...                given a password goes straight to password auth.
    ...
    ...                The banner arrives as SSH_MSG_USERAUTH_BANNER and the
    ...                client prints it to stderr, so stdout is discarded and
    ...                stderr kept.
    [Arguments]    ${node}
    ${cmd}=    Catenate
    ...    sshpass -p '${XR_PASSWORD}' ssh
    ...    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
    ...    -o LogLevel=INFO -o PreferredAuthentications=password
    ...    -o PubkeyAuthentication=no
    ...    ${XR_USER}@${OOB_IP}[${node}] 'show clock' 2>&1 1>/dev/null
    ${rc}    ${out}    ${err}=    Run Command On Nms    ${cmd}
    Should Be Equal As Integers    ${rc}    0
    ...    could not log in to ${node} from nms to read its banner: ${out}
    RETURN    ${out}
