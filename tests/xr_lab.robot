*** Settings ***
Documentation     Validates the two-node IOS-XRv9000 lab: the software
...               release on each node, CDP neighbour discovery over both
...               links, IS-IS adjacency over both links, the loopbacks and
...               their ECMP reachability through IS-IS, and the iBGP session
...               peering loopback-to-loopback.
...
...               Requires the lab to be up and its day-0 config applied
...               (./lab.sh status, and %MGBL-CVAC-4-CONFIG_DONE on both
...               consoles). Run with ./run_tests.sh.
Resource          topology.resource
Suite Setup       Connect To All Nodes
Suite Teardown    Disconnect From All Nodes

*** Test Cases ***
XR Version Is The Expected Release
    [Documentation]    Both nodes run the release the base image ships.
    [Tags]    version
    FOR    ${node}    IN    @{NODES}
        ${output}=     Run Command      ${node}    show version
        ${version}=    Parse Version    ${output}
        Should Be Equal    ${version}    ${XR_VERSION}
        ...    ${node} runs ${version}, expected ${XR_VERSION}
    END

Both Nodes Report The Expected Hostname
    [Documentation]    Confirms the day-0 config was applied, so a failure in
    ...                the later tests is not just an unconfigured node.
    [Tags]    version    config
    FOR    ${node}    IN    @{NODES}
        ${output}=    Run Command    ${node}    show running-config hostname
        Should Contain    ${output}    hostname ${node}
        ...    ${node} did not report its own hostname; day-0 config may not have applied
    END

CDP Discovers The Peer On Every Link
    [Documentation]    Each node learns exactly its peer over each of the two
    ...                links, and nothing else. Seeing itself here would mean
    ...                frames are looping back rather than crossing a
    ...                point-to-point wire.
    [Tags]    cdp
    FOR    ${node}    IN    @{NODES}
        FOR    ${interface}    IN    @{LINK_INTERFACES_SHORT}
            ${rows}=    Neighbors On Interface    ${node}    ${interface}
            Length Should Be    ${rows}    1
            ...    ${node} ${interface}: expected exactly 1 CDP neighbour, got ${rows}
            ${row}=    Set Variable    ${rows}[0]
            Should Be Equal    ${row}[device_id]    ${PEER}[${node}]
            ...    ${node} ${interface}: CDP neighbour is ${row}[device_id], expected ${PEER}[${node}]
            Should Be Equal    ${row}[port_id]    ${interface}
            ...    ${node} ${interface}: peer reports port ${row}[port_id]; the links are cross-wired
        END
    END

CDP Reports The Peer As An XRv9000 Router
    [Documentation]    Sanity-checks the capability and platform columns, so
    ...                the neighbour is confirmed to be the router we think.
    [Tags]    cdp
    FOR    ${node}    IN    @{NODES}
        ${output}=    Run Command    ${node}    show cdp neighbors
        ${rows}=      Parse Cdp Neighbors    ${output}
        Length Should Be    ${rows}    2
        ...    ${node}: expected 2 CDP neighbours (one per link), got ${rows}
        FOR    ${row}    IN    @{rows}
            Should Contain    ${row}[capability]    R
            ...    ${node}: neighbour ${row}[device_id] lacks the Router capability
            Should Be Equal    ${row}[platform]    ${CDP_PLATFORM}
            ...    ${node}: neighbour platform is ${row}[platform], expected ${CDP_PLATFORM}
        END
    END

ISIS Adjacency Is Up On Every Link
    [Documentation]    One level-2 adjacency to the peer per link, both Up.
    [Tags]    isis
    FOR    ${node}    IN    @{NODES}
        FOR    ${interface}    IN    @{LINK_INTERFACES_SHORT}
            ${rows}=    Adjacencies On Interface    ${node}    ${interface}
            Length Should Be    ${rows}    1
            ...    ${node} ${interface}: expected exactly 1 IS-IS adjacency, got ${rows}
            ${row}=    Set Variable    ${rows}[0]
            Should Be Equal    ${row}[state]    Up
            ...    ${node} ${interface}: adjacency to ${row}[system_id] is ${row}[state], not Up
            Should Be Equal    ${row}[system_id]    ${PEER}[${node}]
            ...    ${node} ${interface}: adjacency is with ${row}[system_id], expected ${PEER}[${node}]
        END
    END

ISIS Has Exactly Two Adjacencies Per Node
    [Documentation]    Both links carry an adjacency and no extra ones exist,
    ...                which is what makes the pair an equal-cost pair.
    [Tags]    isis
    FOR    ${node}    IN    @{NODES}
        ${output}=    Run Command    ${node}    show isis adjacency
        ${rows}=      Parse Isis Adjacencies    ${output}
        Length Should Be    ${rows}    2
        ...    ${node}: expected 2 IS-IS adjacencies, got ${rows}
        ${interfaces}=    Get Values    ${rows}    interface
        Sort List         ${interfaces}
        Lists Should Be Equal    ${interfaces}    ${LINK_INTERFACES_SHORT}
        ...    ${node}: adjacencies are on ${interfaces}, expected one per link
        ${states}=    Get Values    ${rows}    state
        FOR    ${state}    IN    @{states}
            Should Be Equal    ${state}    Up    ${node}: adjacency states are ${states}
        END
    END

Loopback0 Has The Expected Host Address
    [Documentation]    The loopback each router uses as its identity, and as
    ...                its iBGP peering address, is configured as a /32.
    [Tags]    loopback
    FOR    ${node}    IN    @{NODES}
        ${output}=    Run Command    ${node}    show running-config interface Loopback0
        Should Contain    ${output}    ipv4 address ${LOOPBACK}[${node}] 255.255.255.255
        ...    ${node}: Loopback0 is not ${LOOPBACK}[${node}]/32:\n${output}
    END

Peer Loopback Is Learned From ISIS Over Two ECMP Paths
    [Documentation]    The whole point of advertising the loopbacks: each
    ...                router reaches the other's /32 through IS-IS, and does
    ...                so over both links rather than just one.
    [Tags]    loopback    isis    ecmp
    FOR    ${node}    IN    @{NODES}
        ${peer_lo}=    Set Variable    ${PEER_LOOPBACK}[${node}]
        ${output}=     Run Command    ${node}    show route ${peer_lo}
        ${route}=      Parse Route    ${output}

        Should Be Equal    ${route}[prefix]    ${peer_lo}/32
        Should Be Equal    ${route}[protocol]    ${ISIS_PROTOCOL}
        ...    ${node}: ${peer_lo}/32 came from "${route}[protocol]", expected "${ISIS_PROTOCOL}"

        Length Should Be    ${route}[paths]    2
        ...    ${node}: ${peer_lo}/32 has ${route}[paths] -- expected 2 ECMP paths

        # One path per link, via the peer's address on that link.
        ${next_hops}=     Get Values    ${route}[paths]    next_hop
        ${interfaces}=    Get Values    ${route}[paths]    interface
        Sort List    ${next_hops}
        Sort List    ${interfaces}
        ${expected_hops}=    Create List
        ...    ${PEER_IP_LINK1}[${node}]    ${PEER_IP_LINK2}[${node}]
        Sort List    ${expected_hops}
        Lists Should Be Equal    ${next_hops}    ${expected_hops}
        ...    ${node}: next hops are ${next_hops}, expected one per link
        Lists Should Be Equal    ${interfaces}    ${LINK_INTERFACES}
        ...    ${node}: paths use ${interfaces}, expected one per link
    END

IBGP Session To The Peer Is Established
    [Documentation]    The iBGP session to the other router is up, in the
    ...                same AS. xr1 also has an eBGP neighbour (gobgp), so
    ...                the iBGP row is picked out of the table by address
    ...                rather than by assuming there is only one.
    [Tags]    bgp
    FOR    ${node}    IN    @{NODES}
        ${output}=    Run Command    ${node}    show bgp summary
        ${rows}=      Parse Bgp Summary    ${output}
        Length Should Be    ${rows}    ${BGP_NEIGHBOR_COUNT}[${node}]
        ...    ${node}: expected ${BGP_NEIGHBOR_COUNT}[${node}] BGP neighbours, got ${rows}

        ${peer_lo}=    Set Variable    ${PEER_LOOPBACK}[${node}]
        ${matching}=   Create List
        FOR    ${row}    IN    @{rows}
            IF    '${row}[neighbor]' == '${peer_lo}'
                Append To List    ${matching}    ${row}
            END
        END
        Length Should Be    ${matching}    1
        ...    ${node}: no BGP neighbour at the peer loopback ${peer_lo}: ${rows}
        ${row}=    Set Variable    ${matching}[0]
        Should Be Equal    ${row}[remote_as]    ${BGP_AS}
        ...    ${node}: neighbour AS is ${row}[remote_as], expected ${BGP_AS}
        Should Be True    ${row}[established]
        ...    ${node}: session to ${row}[neighbor] is "${row}[state]", not Established
    END

IBGP Peering Uses The Loopback Addresses
    [Documentation]    Checks the addresses the TCP session actually uses, so
    ...                this passes only if update-source Loopback0 took
    ...                effect -- not merely because it is in the config.
    [Tags]    bgp    loopback
    FOR    ${node}    IN    @{NODES}
        ${peer_lo}=    Set Variable    ${PEER_LOOPBACK}[${node}]
        ${output}=     Run Command    ${node}    show bgp neighbor ${peer_lo}
        ${nbr}=        Parse Bgp Neighbor    ${output}

        Should Be Equal    ${nbr}[state]    Established
        ...    ${node}: BGP state to ${peer_lo} is ${nbr}[state]
        Should Be Equal    ${nbr}[local_host]    ${LOOPBACK}[${node}]
        ...    ${node}: session sources from ${nbr}[local_host], expected its loopback ${LOOPBACK}[${node}]
        Should Be Equal    ${nbr}[foreign_host]    ${peer_lo}
        ...    ${node}: session goes to ${nbr}[foreign_host], expected the peer loopback ${peer_lo}
        Should Be Equal    ${nbr}[link_type]    internal
        ...    ${node}: BGP reports an "${nbr}[link_type]" link; iBGP should be internal
        Should Be Equal    ${nbr}[local_as]    ${BGP_AS}
        Should Be Equal    ${nbr}[remote_as]    ${BGP_AS}
    END

Management Server Is Ready
    [Documentation]    nms finished cloud-init and is running rsyslog. Every
    ...                other nms-dependent test assumes this.
    [Tags]    nms
    Nms Should Be Ready

Router Management Port Is On The OOB Network
    [Documentation]    MgmtEth0/RP0/CPU0/0 carries the router's OOB address
    ...                and is up -- this is the interface nms reaches it on.
    [Tags]    nms    oob
    FOR    ${node}    IN    @{NODES}
        ${output}=    Run Command    ${node}    show ipv4 interface brief
        Should Match Regexp    ${output}
        ...    (?m)^MgmtEth0/RP0/CPU0/0\\s+${OOB_IP}[${node}]\\s+Up\\s+Up
        ...    ${node}: MgmtEth0/RP0/CPU0/0 is not ${OOB_IP}[${node}] Up/Up:\n${output}
    END

Routers Can Reach The Management Server Over OOB
    [Documentation]    Proves the OOB segment forwards in the router-to-nms
    ...                direction, which is the direction syslog needs.
    [Tags]    nms    oob
    FOR    ${node}    IN    @{NODES}
        ${output}=    Run Command    ${node}    ping ${NMS_OOB_IP} count 5
        Should Contain    ${output}    Success rate is 100 percent
        ...    ${node} cannot ping nms at ${NMS_OOB_IP}:\n${output}
    END

Management Server Can Log In To Each Router Over SSH
    [Documentation]    The management server's core job: reach each router on
    ...                its management port over the OOB network and run a
    ...                command. Uses the xrssh wrapper installed by
    ...                cloud-init, so it exercises the same path an operator
    ...                would use.
    [Tags]    nms    ssh
    FOR    ${node}    IN    @{NODES}
        ${rc}    ${out}    ${err}=    Run Command On Nms
        ...    xrssh ${node} show version
        Should Be Equal As Integers    ${rc}    0
        ...    nms could not run a command on ${node}: rc=${rc}\n${out}${err}
        Should Contain    ${out}    ${XR_VERSION}
        ...    nms reached ${node} but got no version banner:\n${out}

        # `show version` does not name the router -- the hostname only shows
        # up in the prompt, which a non-interactive session never prints. Ask
        # for something that does, to prove which router answered.
        ${rc}    ${out}    ${err}=    Run Command On Nms
        ...    xrssh ${node} show running-config hostname
        Should Be Equal As Integers    ${rc}    0
        ...    nms could not read the hostname from ${node}: rc=${rc}\n${out}${err}
        Should Contain    ${out}    hostname ${node}
        ...    nms logged in but ${node} reported a different hostname:\n${out}
    END

Routers Send Syslog To The Management Server
    [Documentation]    Each router's messages arrive at nms over the OOB
    ...                network and are filed under its own address. A commit
    ...                is used as the trigger so the test does not have to
    ...                wait for a router to log something spontaneously.
    [Tags]    nms    syslog
    [Teardown]    Remove Syslog Probe Description
    FOR    ${node}    IN    @{NODES}
        ${before}=    Syslog Line Count    ${node}
        Trigger Syslog Event On    ${node}
        Wait Until Keyword Succeeds    45s    5s
        ...    Syslog Count Should Have Grown    ${node}    ${before}
    END

External BGP Speaker Is Ready
    [Documentation]    gobgp finished cloud-init, gobgpd is running, and the
    ...                prefix-injection service has completed.
    [Tags]    gobgp
    Gobgp Should Be Ready

External Speaker Originates The Expected Prefixes
    [Documentation]    All ${GOBGP_PREFIX_COUNT} prefixes exist in gobgp's
    ...                own RIB. Checked on the speaker as well as on the
    ...                router, so a shortfall can be blamed on the right side.
    [Tags]    gobgp
    ${rc}    ${out}    ${err}=    Run Command On Gobgp    gobgp global rib summary
    Should Be Equal As Integers    ${rc}    0    gobgp rib query failed: ${err}
    Should Match Regexp    ${out}    Destination:\\s+${GOBGP_PREFIX_COUNT},
    ...    gobgp does not hold ${GOBGP_PREFIX_COUNT} prefixes:\n${out}

EBGP Session To The External Speaker Is Established
    [Documentation]    xr1 peers eBGP with gobgp over the point-to-point
    ...                link, and gobgp agrees the session is up.
    [Tags]    gobgp    bgp
    ${output}=    Run Command    ${GOBGP_PEER}    show bgp neighbor ${GOBGP_LINK_IP_GOBGP}
    ${nbr}=       Parse Bgp Neighbor    ${output}
    Should Be Equal    ${nbr}[state]    Established
    ...    ${GOBGP_PEER}: eBGP to gobgp is ${nbr}[state]
    Should Be Equal    ${nbr}[remote_as]    ${GOBGP_AS}
    ...    ${GOBGP_PEER}: peer AS is ${nbr}[remote_as], expected ${GOBGP_AS}
    Should Be Equal    ${nbr}[link_type]    external
    ...    ${GOBGP_PEER}: BGP reports an "${nbr}[link_type]" link; this should be external

    # And from gobgp's side, so a one-sided view cannot pass this.
    ${rc}    ${out}    ${err}=    Run Command On Gobgp    gobgp neighbor
    Should Contain    ${out}    ${GOBGP_LINK_IP_XR1}
    ...    gobgp does not list ${GOBGP_LINK_IP_XR1} as a peer:\n${out}
    Should Contain    ${out}    Establ
    ...    gobgp does not consider the session to ${GOBGP_LINK_IP_XR1} established:\n${out}

Router Learns All Injected Prefixes Over EBGP
    [Documentation]    xr1 accepts all ${GOBGP_PREFIX_COUNT} of them. This
    ...                is the test that would fail if the eBGP route-policy
    ...                were missing: IOS-XR applies no default policy to an
    ...                eBGP neighbour, so the session would be up with zero
    ...                prefixes accepted.
    [Tags]    gobgp    bgp    prefixes
    ${output}=    Run Command    ${GOBGP_PEER}
    ...    show bgp ipv4 unicast neighbors ${GOBGP_LINK_IP_GOBGP} routes | include Processed
    ${count}=     Parse Processed Count    ${output}
    Should Be Equal As Integers    ${count}    ${GOBGP_PREFIX_COUNT}
    ...    ${GOBGP_PEER} accepted ${count} prefixes from gobgp, expected ${GOBGP_PREFIX_COUNT}

    # Both ends of the range, so a count that is right by accident still fails.
    FOR    ${prefix}    IN    ${GOBGP_FIRST_PREFIX}    ${GOBGP_LAST_PREFIX}
        ${output}=    Run Command    ${GOBGP_PEER}    show bgp ipv4 unicast ${prefix}
        Should Contain    ${output}    ${GOBGP_AS}
        ...    ${GOBGP_PEER}: ${prefix} is not in the BGP table from AS ${GOBGP_AS}:\n${output}
    END

Injected Prefixes Are Installed In The Routing Table
    [Documentation]    Being in the BGP table is not the same as being
    ...                usable: this checks one of the prefixes made it into
    ...                the RIB with gobgp as the next hop.
    [Tags]    gobgp    prefixes
    ${output}=    Run Command    ${GOBGP_PEER}    show route ${GOBGP_FIRST_PREFIX}
    ${route}=     Parse Route    ${output}
    Should Be Equal    ${route}[protocol]    bgp 65000
    ...    ${GOBGP_PEER}: ${GOBGP_FIRST_PREFIX} came from "${route}[protocol]", expected BGP
    ${next_hops}=    Get Values    ${route}[paths]    next_hop
    Should Contain    ${next_hops}    ${GOBGP_LINK_IP_GOBGP}
    ...    ${GOBGP_PEER}: ${GOBGP_FIRST_PREFIX} next hops are ${next_hops}, expected gobgp

Injected Prefixes Reach The Other Router Over IBGP
    [Documentation]    xr1 passes the external prefixes to xr2 with
    ...                next-hop-self, so xr2 both receives them and can
    ...                resolve them -- without it they would arrive pointing
    ...                at 10.2.1.2, which xr2 has no route to, and sit
    ...                inactive.
    [Tags]    gobgp    bgp    prefixes    ibgp
    ${output}=    Run Command    xr2    show bgp ipv4 unicast | include Processed
    ${count}=     Parse Processed Count    ${output}
    Should Be Equal As Integers    ${count}    ${GOBGP_PREFIX_COUNT}
    ...    xr2 holds ${count} BGP prefixes, expected ${GOBGP_PREFIX_COUNT} from xr1

    ${output}=    Run Command    xr2    show route ${GOBGP_FIRST_PREFIX}
    ${route}=     Parse Route    ${output}
    ${next_hops}=    Get Values    ${route}[paths]    next_hop
    Should Contain    ${next_hops}    ${LOOPBACK}[xr1]
    ...    xr2: ${GOBGP_FIRST_PREFIX} next hops are ${next_hops}, expected xr1's loopback (next-hop-self)

Network As Code Manages The Labelled Loopback
    [Documentation]    Loopback98 exists on both routers with the address and
    ...                description from nac/iosxr.nac.yaml. This is config
    ...                that only Network as Code creates -- it is absent from
    ...                configs/<node>.cfg -- so it failing means Terraform
    ...                has not been applied, or has drifted.
    [Tags]    nac
    FOR    ${node}    IN    @{NODES}
        ${output}=    Run Command    ${node}
        ...    show running-config interface ${NAC_LOOPBACK_ID}
        Should Contain    ${output}    description ${NAC_LOOPBACK_DESC}
        ...    ${node}: ${NAC_LOOPBACK_ID} is missing the NaC description:\n${output}
        Should Contain    ${output}    ipv4 address ${NAC_LOOPBACK}[${node}] 255.255.255.255
        ...    ${node}: ${NAC_LOOPBACK_ID} is not ${NAC_LOOPBACK}[${node}]/32:\n${output}
    END

Network As Code Owns The EBGP Route Policies
    [Documentation]    The policies exist and are the ones actually applied to
    ...                the eBGP neighbour. Day-0 applies a permissive PASS in
    ...                both directions; Terraform replaces the inbound half
    ...                with a prefix-checked policy, so seeing PASS here means
    ...                the NaC apply has not happened.
    [Tags]    nac    bgp
    FOR    ${policy}    IN    ${NAC_POLICY_IN}    ${NAC_POLICY_OUT}
        ${output}=    Run Command    ${GOBGP_PEER}
        ...    show running-config route-policy ${policy}
        Should Contain    ${output}    route-policy ${policy}
        ...    ${GOBGP_PEER}: route-policy ${policy} does not exist:\n${output}
    END

    ${output}=    Run Command    ${GOBGP_PEER}    show running-config router bgp
    Should Contain    ${output}    route-policy ${NAC_POLICY_IN} in
    ...    ${GOBGP_PEER}: the eBGP neighbour is not using ${NAC_POLICY_IN} inbound:\n${output}
    Should Contain    ${output}    route-policy ${NAC_POLICY_OUT} out
    ...    ${GOBGP_PEER}: the eBGP neighbour is not using ${NAC_POLICY_OUT} outbound:\n${output}

Day-0 Config Survived The Network As Code Apply
    [Documentation]    Terraform managing part of `router bgp` must not prune
    ...                the rest of it. The iBGP neighbour, its next-hop-self
    ...                and the router-id all come from day-0 and are checked
    ...                here because a provider that replaced the BGP subtree
    ...                instead of merging into it would silently remove them
    ...                -- taking the lab's iBGP session with them.
    [Tags]    nac    bgp
    ${output}=    Run Command    ${GOBGP_PEER}    show running-config router bgp
    Should Contain    ${output}    bgp router-id ${LOOPBACK}[${GOBGP_PEER}]
    ...    ${GOBGP_PEER}: the day-0 router-id is gone:\n${output}
    Should Contain    ${output}    neighbor ${PEER_LOOPBACK}[${GOBGP_PEER}]
    ...    ${GOBGP_PEER}: the day-0 iBGP neighbour is gone:\n${output}
    Should Contain    ${output}    next-hop-self
    ...    ${GOBGP_PEER}: the day-0 next-hop-self is gone:\n${output}

Routing Policies Check The AS Path
    [Documentation]    The AS-path set and the policies that use it exist on
    ...                both routers, and are the ones actually applied: xr1
    ...                on the eBGP session, xr2 on the iBGP session as a
    ...                second line of defence.
    [Tags]    nac    bgp    aspath
    FOR    ${node}    IN    @{NODES}
        ${output}=    Run Command    ${node}
        ...    show running-config as-path-set ${NAC_ASPATH_SET}
        Should Contain    ${output}    as-path-set ${NAC_ASPATH_SET}
        ...    ${node}: as-path-set ${NAC_ASPATH_SET} does not exist:\n${output}
        Should Contain    ${output}    ${GOBGP_AS}
        ...    ${node}: ${NAC_ASPATH_SET} does not mention AS ${GOBGP_AS}:\n${output}
    END

    # xr1 checks it inbound from the external speaker...
    ${output}=    Run Command    ${GOBGP_PEER}    show running-config route-policy ${NAC_POLICY_IN}
    Should Contain    ${output}    as-path in ${NAC_ASPATH_SET}
    ...    ${GOBGP_PEER}: ${NAC_POLICY_IN} does not check the AS path:\n${output}

    # ...and xr2 checks it again on what xr1 relays.
    ${output}=    Run Command    xr2    show running-config router bgp
    Should Contain    ${output}    route-policy ${NAC_POLICY_IBGP_IN} in
    ...    xr2: the iBGP session is not using ${NAC_POLICY_IBGP_IN} inbound:\n${output}

Prefix With The Wrong AS Path Is Denied
    [Documentation]    The point of the AS-path policy, exercised end to end.
    ...                gobgp originates two prefixes in the same subnet range:
    ...                one with its normal AS path, one claiming to have
    ...                transited AS ${ASPATH_PROBE_BAD_AS}. Only the first
    ...                should reach xr1's BGP table -- both match the policy's
    ...                destination range, so the AS path is the only thing
    ...                that can separate them.
    [Tags]    nac    bgp    aspath
    [Teardown]    Withdraw Probe Prefixes On Gobgp
    ${before}=    Accepted Prefix Count On    ${GOBGP_PEER}
    Should Be Equal As Integers    ${before}    ${GOBGP_PREFIX_COUNT}
    ...    ${GOBGP_PEER} started from ${before} prefixes, not ${GOBGP_PREFIX_COUNT} -- probe would be ambiguous

    Inject Probe Prefixes On Gobgp

    # Exactly one of the two should be accepted, so the count rises by one.
    Wait Until Keyword Succeeds    60s    5s
    ...    Accepted Count Should Be    ${GOBGP_PEER}    ${{ int(${before}) + 1 }}

    Prefix Should Be In Bgp Table        ${GOBGP_PEER}    ${ASPATH_PROBE_GOOD}
    Prefix Should Not Be In Bgp Table    ${GOBGP_PEER}    ${ASPATH_PROBE_BAD}
