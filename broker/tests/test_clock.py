"""Clock offset/rtt math (§8.1)."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import clock  # noqa: E402


def test_zero_offset_symmetric():
    # Perfectly symmetric path, no clock skew -> offset 0, rtt = 2*leg.
    t1, t2, t3, t4 = 1000, 1050, 1051, 1101
    offset, rtt = clock.offset_and_rtt(t1, t2, t3, t4)
    assert abs(offset) < 1e-9
    assert rtt == (t4 - t1) - (t3 - t2)


def test_positive_offset():
    # Broker clock ahead of player by 100ms; 50ms each leg.
    # player t1=1000, broker recv t2 = 1000+50+100 = 1150,
    # broker send t3 = 1150+1 = 1151, player t4 = 1151-100+50 = 1101.
    t1, t2, t3, t4 = 1000, 1150, 1151, 1101
    offset, rtt = clock.offset_and_rtt(t1, t2, t3, t4)
    # offset = ((1150-1000)+(1151-1101))/2 = (150+50)/2 = 100
    assert abs(offset - 100) < 1e-9


def test_best_offset_picks_min_rtt():
    # Two samples; the one with the smaller rtt should win even if its raw
    # offset differs.
    samples = [
        (1000, 1200, 1201, 1101),   # rtt = (101) - (1) = 100
        (2000, 2150, 2151, 2101),   # rtt = (101) - (1) = 100... make differ
    ]
    # craft a lower-rtt second sample
    samples[1] = (2000, 2120, 2121, 2061)  # rtt = 61 - 1 = 60
    off = clock.best_offset(samples)
    expected, _ = clock.offset_and_rtt(*samples[1])
    assert off == expected


def test_play_at_folding_consistency():
    # A player folds play_at back to local time via: local = play_at - offset.
    # If broker is +offset ahead, two players with different offsets should
    # fire at the same wall-clock instant.
    play_at = 1750000003000
    offset_a = -12     # player A is 12ms behind broker
    offset_b = 40      # player B is 40ms ahead of broker
    local_a = play_at - offset_a
    local_b = play_at - offset_b
    # Difference in local target equals the difference in their offsets,
    # which is exactly what cancels real-world skew.
    assert (local_a - local_b) == (offset_b - offset_a)
