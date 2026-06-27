"""p2p server-mode pure helpers (§14.3): welcome + time_sync_ack payloads."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import p2p_server as PS  # noqa: E402
import envelope as E  # noqa: E402


def test_welcome_payload_declares_p2p_topology():
    p = PS.build_welcome_payload(1_700_000_000_000, group_id="lobby",
                                 auth_mode="open")
    assert p["topology"] == "p2p"
    assert p["auth_mode"] == "open"
    assert p["group_id"] == "lobby"
    assert p["assigned"] is True
    assert p["server_time"] == 1_700_000_000_000
    assert p["v"] == E.PROTOCOL_VERSION


def test_welcome_payload_normalizes_bad_mode():
    p = PS.build_welcome_payload(0, group_id="g", auth_mode="weird")
    assert p["auth_mode"] == "open"


def test_welcome_payload_declares_key_mode():
    # §17.3: the p2p coordinator declares its key_mode so the controller adapts.
    p = PS.build_welcome_payload(0, group_id="g", auth_mode="required",
                                 key_mode="derived")
    assert p["key_mode"] == "derived"
    # default + bad value normalize to global (v1.2 backward compat)
    assert PS.build_welcome_payload(0, group_id="g",
                                    auth_mode="open")["key_mode"] == "global"
    assert PS.build_welcome_payload(0, group_id="g", auth_mode="open",
                                    key_mode="weird")["key_mode"] == "global"


def test_time_sync_ack_payload_echoes_and_stamps():
    p = PS.build_time_sync_ack_payload(100, 250, 260, req_msg_id="mid-7")
    assert p["t1"] == 100
    assert p["t2"] == 250
    assert p["t3"] == 260
    assert p["req_msg_id"] == "mid-7"


def test_time_sync_ack_payload_without_req_msg_id():
    p = PS.build_time_sync_ack_payload(1, 2, 3)
    assert "req_msg_id" not in p
    assert p == {"t1": 1, "t2": 2, "t3": 3}
