"""Robot Framework library for running show commands on the lab's XR nodes.

Reaching the routers
--------------------
The routers' management ports live only on the OOB network, so there is no
route to them from the host. nms is on that network and has a host SSH
forward, so it is used as a jump host: connect to nms, open a direct-tcpip
channel to the router's OOB address, and run the router session over it.
That is also how an operator would reach them.

Why this is not SSHLibrary
--------------------------
XR's sshd allows a single `exec` channel per connection: the first
`Execute Command` succeeds and the next one fails with "Channel closed". So
this library opens one interactive shell per node, runs `terminal length 0`
once, and keeps the shell for the whole suite -- which is also how you would
drive a real router.

Commands are read until the XR prompt (`RP/0/RP0/CPU0:<host>#`) comes back
rather than until a fixed delay, so a slow box does not truncate output.
"""
import re
import time

import paramiko

from robot.api import logger
from robot.api.deco import keyword

# Matches an XR prompt at the end of a read. Covers exec mode
# ("RP/0/RP0/CPU0:xr1#") and configuration sub-modes, which append a
# parenthesised tag ("...:xr1(config)#", "...:xr1(config-if)#") -- without
# those, any config command appears to hang until the read times out.
PROMPT = re.compile(r"\r?\n?RP/0/[^\s:]+:[\w.-]+(?:\([\w.-]*\))?[#>]\s*$")

# Lines XR prepends/appends to command output that carry no information.
TIMESTAMP = re.compile(
    r"^(Mon|Tue|Wed|Thu|Fri|Sat|Sun) \w+ +\d+ \d\d:\d\d:\d\d(\.\d+)? \w+$")


class XrCliError(AssertionError):
    """Raised when a node cannot be reached or a command is rejected."""


class XrCli:
    ROBOT_LIBRARY_SCOPE = "SUITE"

    # The Linux helper VMs, each with its own host SSH forward.
    LINUX_NODES = {
        "nms":   {"port": 2261, "username": "lab", "password": "Lab_123!"},
        "gobgp": {"port": 2262, "username": "lab", "password": "Lab_123!"},
    }

    def __init__(self, host="127.0.0.1", username="admin", password="Admin@12345"):
        self._host = host
        self._username = username
        self._password = password
        self._linux = {}             # name -> SSHClient (nms doubles as jump)
        self._sessions = {}          # node -> (SSHClient, Channel)

    # --- connection management ---------------------------------------------

    def _linux_client(self, name, timeout=30):
        """Connect to a Linux helper VM once and reuse the session."""
        if name in self._linux:
            return self._linux[name]
        if name not in self.LINUX_NODES:
            raise XrCliError("unknown Linux node %r" % name)
        cfg = self.LINUX_NODES[name]
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        try:
            client.connect(self._host, port=cfg["port"],
                           username=cfg["username"], password=cfg["password"],
                           look_for_keys=False, allow_agent=False,
                           timeout=timeout)
        except Exception as exc:
            extra = (" nms is also the jump host for the routers."
                     if name == "nms" else "")
            raise XrCliError(
                "cannot SSH to %s on %s:%s (%s: %s).%s Check ./lab.sh status, "
                "and that cloud-init has finished."
                % (name, self._host, cfg["port"], type(exc).__name__, exc, extra))
        self._linux[name] = client
        logger.info("connected to %s on port %s" % (name, cfg["port"]))
        return client

    def _jump_client(self, timeout=30):
        """nms is the only node with a route to the routers' mgmt ports."""
        return self._linux_client("nms", timeout)

    def _run_on_linux(self, name, command, timeout):
        client = self._linux_client(name)
        _, out, err = client.exec_command(command, timeout=int(timeout))
        stdout = out.read().decode(errors="replace")
        stderr = err.read().decode(errors="replace")
        rc = out.channel.recv_exit_status()
        logger.info("%s$ %s\n(rc=%s)\n%s%s" % (name, command, rc, stdout, stderr))
        return rc, stdout, stderr

    @keyword("Connect To Node")
    def connect_to_node(self, node, address, timeout=30):
        """Open an interactive XR shell for ``node`` at its OOB ``address``.

        The session is tunnelled through nms; ``address`` is the router's
        management address on the OOB network, not a host port.
        """
        if node in self._sessions:
            return
        jump = self._jump_client(int(timeout))
        try:
            channel = jump.get_transport().open_channel(
                "direct-tcpip", (address, 22), ("127.0.0.1", 0))
        except Exception as exc:
            raise XrCliError(
                "nms could not open a connection to %s (%s): %s: %s. Is the "
                "OOB network up? Try: ./lab.sh ssh nms, then ping %s"
                % (node, address, type(exc).__name__, exc, address))

        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        try:
            client.connect(address, username=self._username,
                           password=self._password, look_for_keys=False,
                           allow_agent=False, timeout=int(timeout),
                           sock=channel)
        except Exception as exc:
            raise XrCliError(
                "cannot SSH to %s (%s) through nms (%s: %s)"
                % (node, address, type(exc).__name__, exc))
        shell = client.invoke_shell(width=250, height=10000)
        self._sessions[node] = (client, shell)
        self._drain(shell, settle=2.0)
        # Without this XR paginates at 24 lines and waits for a keypress.
        self.run_command(node, "terminal length 0")
        # And without this XR wraps its command echo at 80 columns, so a long
        # command comes back split across lines and _clean cannot recognise
        # and drop it -- fragments of the echo then leak into the output a
        # parser sees.
        self.run_command(node, "terminal width 512")
        logger.info("connected to %s at %s via nms" % (node, address))

    @keyword("Run Command On Nms")
    def run_command_on_nms(self, command, timeout=60):
        """Run a shell command on nms and return (rc, stdout, stderr)."""
        return self._run_on_linux("nms", command, timeout)

    @keyword("Run Command On Gobgp")
    def run_command_on_gobgp(self, command, timeout=60):
        """Run a shell command on gobgp and return (rc, stdout, stderr)."""
        return self._run_on_linux("gobgp", command, timeout)

    @keyword("Close All Nodes")
    def close_all_nodes(self):
        for node, (client, _) in list(self._sessions.items()):
            try:
                client.close()
            except Exception:                     # nothing useful to do
                logger.debug("error closing %s, ignoring" % node)
        self._sessions.clear()
        for name, client in list(self._linux.items()):
            try:
                client.close()
            except Exception:
                logger.debug("error closing the %s session, ignoring" % name)
        self._linux.clear()

    # --- running commands ---------------------------------------------------

    @keyword("Run Command")
    def run_command(self, node, command, timeout=60):
        """Run one command on ``node`` and return its output.

        The echoed command line, XR's timestamp line and the trailing prompt
        are stripped, so the result is just what the command printed.
        """
        if node not in self._sessions:
            raise XrCliError("no session for %r; call Connect To Node first" % node)
        _, shell = self._sessions[node]
        self._drain(shell, settle=0.2)

        shell.send(command + "\n")
        raw = self._read_until_prompt(shell, node, command, float(timeout))
        output = self._clean(raw, command)

        if "% Invalid input detected" in output or "% Incomplete command" in output:
            raise XrCliError("%s rejected %r:\n%s" % (node, command, output))
        logger.info("%s# %s\n%s" % (node, command, output))
        return output

    # --- internals ----------------------------------------------------------

    @staticmethod
    def _drain(shell, settle=0.2):
        """Discard anything already buffered (banners, syslog lines)."""
        time.sleep(settle)
        while shell.recv_ready():
            shell.recv(65536)
            time.sleep(0.1)

    @staticmethod
    def _read_until_prompt(shell, node, command, timeout):
        buf = b""
        deadline = time.time() + timeout
        while time.time() < deadline:
            if shell.recv_ready():
                buf += shell.recv(65536)
                if PROMPT.search(buf.decode(errors="replace")):
                    return buf.decode(errors="replace")
            else:
                time.sleep(0.2)
        raise XrCliError(
            "%s did not return a prompt within %ss for %r. Got:\n%s"
            % (node, timeout, command, buf.decode(errors="replace")[-2000:]))

    @staticmethod
    def _clean(raw, command):
        lines = raw.replace("\r\n", "\n").replace("\r", "").split("\n")
        # Drop the echoed command line wherever the device put it.
        lines = [ln for ln in lines if ln.strip() != command.strip()]
        lines = [ln for ln in lines if not TIMESTAMP.match(ln.strip())]
        lines = [ln for ln in lines if not PROMPT.search(ln + "\n")]
        # XR interleaves syslog notices into the session; they are not output.
        lines = [ln for ln in lines
                 if not re.match(r"^(RP|LC|\d+)/[\w/]+:\w{3} +\d+ ", ln.strip())]
        return "\n".join(lines).strip()
