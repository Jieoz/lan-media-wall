"""Topology-mode decision logic (protocol_spec §14).

§14 keeps the §2–§12 message set identical across three deployment shapes;
only *who coordinates* differs. The player declares nothing here — it just
picks a transport *role* from what discovery turns up (§14.5):

  - found a broker (mode A `dedicated` or B `cohosted`)  → run as **WS client**
    and dial that broker_hint.
  - `--broker` requested (mode B `cohosted`)             → spawn an in-process
    broker, then dial 127.0.0.1:8770 as an ordinary client.
  - timeout, no broker (mode C `p2p`)                    → flip to **p2p server
    mode**: listen on 8770, let the controller connect, and act as the
    coordinator (clock = controller, see p2p_server).

This module is the *pure* decision: given a discovery result (or the cohost
flag), return a Decision. The networking that produces the discovery result
and that acts on the Decision lives elsewhere (discovery_probe / p2p_server /
cohost). Fully unit-tested by mocking the discovery result.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

import auth

# topology labels (§14) — declared by the coordinator, shown for diagnostics.
DEDICATED = "dedicated"
COHOSTED = "cohosted"
P2P = "p2p"

# transport roles this player can take.
ROLE_CLIENT = "client"          # dial a broker (modes A / B)
ROLE_P2P_SERVER = "p2p_server"  # listen for the controller (mode C)

P2P_LISTEN_PORT = 8770          # §14.3 p2p server listens on 8770
COHOST_BROKER_HOST = "127.0.0.1"
COHOST_BROKER_PORT = 8770       # §14.2 local player dials 127.0.0.1:8770


@dataclass(frozen=True)
class BrokerFound:
    """A broker discovered via UDP announce (§7 broker_hint)."""
    host: str
    port: int
    auth_mode: str = auth.DEFAULT_MODE
    topology: str = DEDICATED


@dataclass(frozen=True)
class Decision:
    """The chosen transport role + the parameters needed to act on it."""
    role: str                       # ROLE_CLIENT | ROLE_P2P_SERVER
    topology: str                   # DEDICATED | COHOSTED | P2P
    auth_mode: str                  # effective auth mode to start with
    host: Optional[str] = None      # client: where to dial
    port: Optional[int] = None
    listen_port: Optional[int] = None  # p2p server: where to listen
    cohost_broker: bool = False     # client: must we spawn a broker first?


def decide_topology(
    broker: Optional[BrokerFound],
    *,
    cohost: bool = False,
    fallback_auth_mode: str = auth.DEFAULT_MODE,
    p2p_listen_port: int = P2P_LISTEN_PORT,
) -> Decision:
    """Pick a transport role from a discovery outcome (§14.5).

    Args:
      broker: a BrokerFound if discovery saw one, else None.
      cohost: operator asked this player to *be* the broker (mode B). When set
        we always run as a client to a local broker we spawn — regardless of
        what discovery saw (the operator's intent wins).
      fallback_auth_mode: auth mode to assume when we have no coordinator to
        learn it from (p2p server / freshly-spawned cohost). Defaults to open
        (§15.3 zero-config).
      p2p_listen_port: port to listen on in p2p server mode.

    Precedence: cohost flag > discovered broker > p2p server fallback."""
    if cohost:
        # mode B: we host the broker locally and connect to it as a client.
        return Decision(
            role=ROLE_CLIENT,
            topology=COHOSTED,
            auth_mode=auth.normalize_mode(fallback_auth_mode),
            host=COHOST_BROKER_HOST,
            port=COHOST_BROKER_PORT,
            cohost_broker=True,
        )
    if broker is not None:
        # mode A or B (someone else cohosts) — dial the discovered broker.
        return Decision(
            role=ROLE_CLIENT,
            topology=broker.topology,
            auth_mode=auth.normalize_mode(broker.auth_mode),
            host=broker.host,
            port=broker.port,
        )
    # mode C: nobody coordinating — become the p2p server (§14.3).
    return Decision(
        role=ROLE_P2P_SERVER,
        topology=P2P,
        auth_mode=auth.normalize_mode(fallback_auth_mode),
        listen_port=p2p_listen_port,
    )
