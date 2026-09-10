"""Robot Framework library that turns XR show output into structured data.

Keeping the parsing here (rather than doing `Should Contain` on raw text)
means a test failure reports what the device actually said, and a test cannot
pass by accidentally matching a substring somewhere else in the output.
"""
import re

from robot.api.deco import keyword


class XrParseError(AssertionError):
    """Raised when show output does not look like what we expect to parse."""


class XrParse:
    ROBOT_LIBRARY_SCOPE = "GLOBAL"

    @keyword("Parse Version")
    def parse_version(self, output):
        """Return the release string from `show version`.

        Matches the ` Version      : 26.1.1` line, which is the one XR
        reports for the running software.
        """
        m = re.search(r"^\s*Version\s*:\s*(\S+)\s*$", output, re.MULTILINE)
        if not m:
            raise XrParseError(
                "no 'Version :' line in show version output:\n%s" % output)
        return m.group(1)

    @keyword("Parse Cdp Neighbors")
    def parse_cdp_neighbors(self, output):
        """Return `show cdp neighbors` rows as a list of dicts.

        Each row has device_id, local_interface, capability, platform and
        port_id. The platform column contains a space ("IOS-XRv 9"), so the
        row is parsed with an anchored regex rather than by splitting.
        """
        if "Device ID" not in output:
            raise XrParseError(
                "no CDP neighbor table in output (is cdp configured?):\n%s" % output)
        rows = []
        row_re = re.compile(
            r"^(?P<device_id>\S+)\s+"
            r"(?P<local_interface>[A-Za-z]+[\d/.]+)\s+"
            r"(?P<holdtime>\d+)\s+"
            r"(?P<capability>[A-Za-z ]*?)\s+"
            r"(?P<platform>.+?)\s+"
            r"(?P<port_id>[A-Za-z]+[\d/.]+)\s*$")
        # Only consider lines after the header row.
        body = output.split("Device ID", 1)[1].split("\n", 1)[1]
        for line in body.split("\n"):
            if not line.strip():
                continue
            m = row_re.match(line.strip())
            if m:
                row = m.groupdict()
                row["capability"] = row["capability"].strip()
                row["platform"] = row["platform"].strip()
                rows.append(row)
        return rows

    @keyword("Parse Isis Adjacencies")
    def parse_isis_adjacencies(self, output):
        """Return `show isis adjacency` rows as a list of dicts.

        Each row has system_id, interface, snpa and state. The reported
        "Total adjacency count" is cross-checked against the rows parsed, so
        a parsing miss fails loudly instead of silently shrinking the list.
        """
        rows = []
        row_re = re.compile(
            r"^(?P<system_id>\S+)\s+"
            r"(?P<interface>[A-Za-z]+[\d/.]+)\s+"
            r"(?P<snpa>\S+)\s+"
            r"(?P<state>Up|Init|Down|Failed)\b")
        for line in output.split("\n"):
            m = row_re.match(line.strip())
            if m:
                rows.append(m.groupdict())

        total = re.search(r"Total adjacency count:\s*(\d+)", output)
        if total is None:
            raise XrParseError(
                "no 'Total adjacency count' line in output; "
                "is IS-IS configured?\n%s" % output)
        if int(total.group(1)) != len(rows):
            raise XrParseError(
                "parsed %d adjacency rows but the device reported %s:\n%s"
                % (len(rows), total.group(1), output))
        return rows

    @keyword("Get Values")
    def get_values(self, rows, key):
        """Pluck one field out of a list of parsed rows."""
        missing = [r for r in rows if key not in r]
        if missing:
            raise XrParseError("rows without key %r: %r" % (key, missing))
        return [r[key] for r in rows]

    @keyword("Parse Route")
    def parse_route(self, output):
        """Parse `show route <prefix>` into a dict.

        Returns prefix, protocol (e.g. "isis CORE"), metric and a `paths`
        list of {next_hop, interface} -- one entry per ECMP path, in the
        order the device listed them.
        """
        entry = re.search(r"Routing entry for (\S+)", output)
        if not entry:
            raise XrParseError(
                "not a 'show route' result -- is the prefix in the table?\n%s"
                % output)
        known = re.search(r'Known via "([^"]+)"(?:.*?metric (\d+))?', output)
        if not known:
            raise XrParseError("no 'Known via' line in:\n%s" % output)

        paths = []
        # Connected/IGP paths name an interface:
        #     10.1.1.2, from 2.2.2.2, via GigabitEthernet0/0/0/0
        # BGP paths do not -- the next hop is recursive, so the outgoing
        # interface is whatever resolving it yields:
        #     10.2.1.2, from 10.2.1.2, BGP external
        #     1.1.1.1, from 1.1.1.1
        # `interface` is None for those rather than the row being skipped.
        for m in re.finditer(
                r"^\s*(?P<next_hop>\d+\.\d+\.\d+\.\d+)"
                r", from (?P<source>\d+\.\d+\.\d+\.\d+)"
                r"(?:, via (?P<interface>\S+))?"
                r"(?:,[^\n]*)?\s*$",           # e.g. ", BGP external"
                output, re.MULTILINE):
            paths.append(m.groupdict())
        if not paths:
            raise XrParseError(
                "no 'Routing Descriptor Blocks' paths found in:\n%s" % output)
        return {
            "prefix": entry.group(1),
            "protocol": known.group(1),
            "metric": known.group(2),
            "paths": paths,
        }

    @keyword("Parse Bgp Summary")
    def parse_bgp_summary(self, output):
        """Parse the neighbour table of `show bgp summary` into a list.

        Each row has neighbour, remote_as, up_down, state and established.
        XR puts the prefix count in the St/PfxRcd column once a session is
        up and a state name (Idle, Active, OpenSent...) while it is not, so
        a purely numeric value there means Established.
        """
        if "Neighbor" not in output:
            raise XrParseError(
                "no neighbour table in show bgp summary (is BGP configured?):\n%s"
                % output)
        body = output.split("Neighbor", 1)[1].split("\n", 1)[1]
        row_re = re.compile(
            r"^(?P<neighbor>\d+\.\d+\.\d+\.\d+)\s+"
            r"(?P<spk>\d+)\s+"
            r"(?P<remote_as>\d+)\s+"
            r"(?P<msg_rcvd>\d+)\s+"
            r"(?P<msg_sent>\d+)\s+"
            r"(?P<tbl_ver>\d+)\s+"
            r"(?P<in_q>\d+)\s+"
            r"(?P<out_q>\d+)\s+"
            r"(?P<up_down>\S+)\s+"
            r"(?P<state>\S+)\s*$")
        rows = []
        for line in body.split("\n"):
            m = row_re.match(line.strip())
            if m:
                row = m.groupdict()
                row["established"] = row["state"].isdigit()
                row["prefixes_received"] = row["state"] if row["state"].isdigit() else None
                rows.append(row)
        return rows

    @keyword("Parse Bgp Neighbor")
    def parse_bgp_neighbor(self, output):
        """Parse `show bgp neighbor <ip>` into a dict.

        local_host and foreign_host are the addresses the TCP session
        actually uses, which is how you prove an update-source is in effect
        rather than trusting the configuration.
        """
        fields = {
            "neighbor": r"BGP neighbor is (\S+)",
            "remote_as": r"Remote AS (\d+)",
            "local_as": r"local AS (\d+)",
            "link_type": r"local AS \d+, (\w+) link",
            "state": r"BGP state = (\w+)",
            "local_host": r"Local host: (\d+\.\d+\.\d+\.\d+)",
            "foreign_host": r"Foreign host: (\d+\.\d+\.\d+\.\d+)",
        }
        result = {}
        for name, pattern in fields.items():
            m = re.search(pattern, output)
            result[name] = m.group(1) if m else None
        if result["neighbor"] is None:
            raise XrParseError(
                "not a 'show bgp neighbor' result:\n%s" % output)
        # local_host/foreign_host only appear once a TCP session exists, so
        # report the state rather than a confusing None comparison later.
        if result["state"] != "Established" and result["local_host"] is None:
            result["local_host"] = "(no session: state %s)" % result["state"]
            result["foreign_host"] = "(no session: state %s)" % result["state"]
        return result

    @keyword("Parse Bgp Prefix Count")
    def parse_bgp_prefix_count(self, output):
        """Count the prefixes in `show bgp ipv4 unicast` output.

        Uses the "Processed N prefixes" trailer XR prints, cross-checked
        against the network lines actually parsed so a parsing miss cannot
        quietly turn into a wrong count.
        """
        trailer = re.search(r"Processed (\d+) prefixes, (\d+) paths", output)
        if not trailer:
            raise XrParseError(
                "no 'Processed N prefixes' trailer in output:\n%s" % output[:2000])
        # Table rows look like "*>i10.100.7.0/24   1.1.1.1  0  100  0  65100 i"
        rows = re.findall(r"^[*sdhriS>\s]{0,4}(\d+\.\d+\.\d+\.\d+/\d+)\s",
                          output, re.MULTILINE)
        reported = int(trailer.group(1))
        if len(rows) != reported:
            raise XrParseError(
                "parsed %d prefix rows but the device reported %d:\n%s"
                % (len(rows), reported, output[:2000]))
        return reported

    @keyword("Parse Processed Count")
    def parse_processed_count(self, output):
        """Return N from XR's "Processed N prefixes, M paths" trailer.

        Unlike Parse Bgp Prefix Count this does not cross-check against the
        table rows, so it works with `show bgp ... | include Processed` --
        which is how the 10000-prefix counts are checked. Shipping the whole
        table would mean ~700 KB through the session and into log.html for
        every assertion.
        """
        m = re.search(r"Processed (\d+) prefixes, (\d+) paths", output)
        if not m:
            raise XrParseError(
                "no 'Processed N prefixes' trailer in:\n%s" % output[:1000])
        return int(m.group(1))

    @keyword("Parse Bgp Prefixes")
    def parse_bgp_prefixes(self, output):
        """Return the list of prefixes in `show bgp ipv4 unicast` output."""
        self.parse_bgp_prefix_count(output)   # validates the trailer matches
        return re.findall(r"^[*sdhriS>\s]{0,4}(\d+\.\d+\.\d+\.\d+/\d+)\s",
                          output, re.MULTILINE)
