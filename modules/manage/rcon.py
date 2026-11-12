"""Minimal Source RCON client for Project Zomboid.

Project Zomboid's dedicated server implements the Source RCON protocol:

    int32 size | int32 id | int32 type | body | \\0 | \\0

Two quirks are handled explicitly, both confirmed against the Build 42 server:

* The server answers ``SERVERDATA_AUTH`` with an empty
  ``SERVERDATA_RESPONSE_VALUE`` packet carrying the auth id, *then* the real
  ``SERVERDATA_AUTH_RESPONSE``. The empty packet must be skipped, not treated
  as an authentication failure.
* A reply longer than one packet is split into packets that all share the
  command's id and there is no terminator packet. A packet whose body is
  exactly 4086 bytes may be followed by more, so the reader keeps the command
  open for a short quiet window.

No third-party dependencies: this is stdlib only, so it runs under the
module's ``pkgs.python3`` without a wheel or a venv.
"""

from __future__ import annotations

import select
import socket
import struct

TYPE_AUTH = 3
TYPE_AUTH_RESPONSE = 2
TYPE_EXECCOMMAND = 2
TYPE_RESPONSE_VALUE = 0

# id(4) + type(4) + two NUL terminators.
MIN_PACKET_SIZE = 10
# A nominal Source RCON packet carries at most 4096 bytes after the length
# field, i.e. 4086 body bytes. PZ does not enforce that cap on responses
# (`showoptions` on a heavily modded server is tens of KB), so the reader
# accepts much larger packets and uses the nominal body size only to decide
# whether a reply may continue.
MAX_FULL_PACKET_BODY_BYTES = 4086
MAX_PACKET_SIZE = 8 * 1024 * 1024
CONTINUATION_QUIET_SECONDS = 0.15


class RconError(RuntimeError):
    """Any RCON failure: connection, authentication, timeout, framing."""


def _encode_packet(req_id: int, packet_type: int, body: str) -> bytes:
    body_bytes = body.encode("utf-8", "replace")
    size = 4 + 4 + len(body_bytes) + 2
    return (
        struct.pack("<i", size)
        + struct.pack("<ii", req_id, packet_type)
        + body_bytes
        + b"\x00\x00"
    )


class RconClient:
    """A short-lived RCON connection.

    The dashboard and backup helper open one connection per operation rather
    than holding a persistent socket: PZ restarts are frequent, a stale
    socket would be indistinguishable from a dead server, and the traffic is
    a handful of commands.
    """

    def __init__(self, host: str, port: int, password: str, timeout: float = 5.0):
        self.host = host
        self.port = int(port)
        self.password = password
        self.timeout = float(timeout)
        self._sock: socket.socket | None = None
        self._next_id = 1

    def __enter__(self) -> "RconClient":
        self.connect()
        return self

    def __exit__(self, *_exc) -> None:
        self.close()

    # ── socket / framing ────────────────────────────────────────────────────

    def connect(self) -> None:
        if not self.password:
            raise RconError("RCON password is empty")
        try:
            self._sock = socket.create_connection(
                (self.host, self.port), timeout=self.timeout
            )
        except OSError as exc:
            raise RconError(f"cannot connect to RCON at {self.host}:{self.port}: {exc}") from exc
        self._sock.settimeout(self.timeout)
        try:
            self._sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass

        auth_id = self._allocate_id()
        self._send(auth_id, TYPE_AUTH, self.password)
        try:
            while True:
                req_id, packet_type, body = self._recv_packet()
                if packet_type == TYPE_AUTH_RESPONSE:
                    if req_id == -1:
                        raise RconError("RCON authentication failed (wrong password)")
                    # PZ also sends an empty RESPONSE_VALUE before this packet;
                    # the loop above has already skipped it.
                    return
                if packet_type == TYPE_RESPONSE_VALUE and req_id == auth_id:
                    # The empty pre-auth reply. Keep reading for AUTH_RESPONSE.
                    continue
                # Anything else before authentication is a protocol error.
                raise RconError(
                    f"unexpected RCON packet before auth: id={req_id} type={packet_type}"
                )
        except Exception:
            self.close()
            raise

    def close(self) -> None:
        sock, self._sock = self._sock, None
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass

    def _allocate_id(self) -> int:
        # Wrap well below Java's signed-int limit.
        self._next_id = (self._next_id % 0x7FFFFFFF) + 1
        return self._next_id

    def _send(self, req_id: int, packet_type: int, body: str) -> None:
        if self._sock is None:
            raise RconError("RCON is not connected")
        try:
            self._sock.sendall(_encode_packet(req_id, packet_type, body))
        except OSError as exc:
            raise RconError(f"RCON write failed: {exc}") from exc

    def _read_exact(self, size: int) -> bytes:
        if self._sock is None:
            raise RconError("RCON is not connected")
        chunks: list[bytes] = []
        remaining = size
        while remaining > 0:
            try:
                chunk = self._sock.recv(remaining)
            except socket.timeout as exc:
                raise RconError("RCON read timed out") from exc
            except OSError as exc:
                raise RconError(f"RCON read failed: {exc}") from exc
            if not chunk:
                raise RconError("RCON connection closed by the server")
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)

    def _recv_packet(self) -> tuple[int, int, str]:
        header = self._read_exact(4)
        (size,) = struct.unpack("<i", header)
        if size < MIN_PACKET_SIZE or size > MAX_PACKET_SIZE:
            raise RconError(f"corrupt RCON packet length: {size}")
        payload = self._read_exact(size)
        req_id, packet_type = struct.unpack("<ii", payload[:8])
        # The two trailing NULs are terminators, not part of the body.
        body = payload[8:-2] if payload.endswith(b"\x00\x00") else payload[8:]
        return req_id, packet_type, body.decode("utf-8", "replace")

    def _has_pending(self, timeout: float) -> bool:
        if self._sock is None:
            return False
        try:
            ready, _, _ = select.select([self._sock], [], [], timeout)
        except (OSError, ValueError):
            return False
        return bool(ready)

    # ── commands ────────────────────────────────────────────────────────────

    def command(self, command: str) -> str:
        """Run one RCON command and return the server's reply."""
        if not command or "\x00" in command:
            raise RconError("invalid RCON command")
        req_id = self._allocate_id()
        self._send(req_id, TYPE_EXECCOMMAND, command)
        chunks: list[str] = []
        while True:
            packet_id, packet_type, body = self._recv_packet()
            if packet_id == -1:
                raise RconError("RCON authentication failed")
            if packet_type != TYPE_RESPONSE_VALUE:
                continue
            if packet_id != req_id:
                # A late reply for an earlier command; ignore it.
                continue
            chunks.append(body)
            # A full-size packet may be followed by more with the same id.
            if len(body.encode("utf-8")) >= MAX_FULL_PACKET_BODY_BYTES and self._has_pending(
                CONTINUATION_QUIET_SECONDS
            ):
                continue
            break
        return "".join(chunks)


def parse_players(reply: str) -> dict:
    """Parse the ``players`` reply.

    Build 42 returns exactly ``Players connected (N):\\n-name\\n-name\\n`` with
    no extra whitespace; the ``-`` sits directly against the raw username.
    Usernames may themselves contain leading/trailing spaces, so only a
    trailing ``\\r`` is stripped, never the name.

    Returns ``{players, count, ambiguous}``. ``ambiguous`` is true when the
    header's count disagrees with the number of ``-`` lines, which means a
    username contains a newline (PZ writes names raw) and the entries cannot
    be told apart. The dashboard shows the list but disables per-player
    actions when the reply is ambiguous.
    """
    players: list[str] = []
    if not reply:
        return {"players": players, "count": 0, "ambiguous": False}
    for raw_line in reply.split("\n"):
        line = raw_line[:-1] if raw_line.endswith("\r") else raw_line
        if line.startswith("-"):
            players.append(line[1:])
    header_count = None
    first = reply.split("\n", 1)[0].strip()
    if first.lower().startswith("players connected"):
        # "Players connected (3):"
        start = first.find("(")
        end = first.find(")", start + 1)
        if start != -1 and end != -1:
            try:
                header_count = int(first[start + 1 : end])
            except ValueError:
                header_count = None
    count = header_count if header_count is not None else len(players)
    return {
        "players": players,
        "count": count,
        "ambiguous": header_count is None or header_count != len(players),
    }
