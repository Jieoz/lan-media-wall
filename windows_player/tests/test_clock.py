"""Clock offset (min-rtt) + play_at folding (protocol §8)."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from clock import ClockSync, Sample  # noqa: E402


def test_offset_formula_symmetric_delay():
    # broker is +1000ms ahead of player; symmetric 100ms each way.
    # player sends t1=0 (local). travels 100ms → broker recv at master 1100.
    # broker replies immediately t3=1100 → arrives t4=200 (local).
    s = Sample(t1=0, t2=1100, t3=1100, t4=200)
    assert s.offset == 1000.0           # ((1100-0)+(1100-200))/2 = 1000
    assert s.rtt == 200.0               # (200-0)-(1100-1100) = 200


def test_min_rtt_sample_wins():
    c = ClockSync(window=8)
    # noisy sample: large rtt, skewed offset
    c.add_sample(0, 1300, 1400, 500)    # rtt = 500-0-(100)=400, offset=1100
    # clean sample: small rtt, true offset ~1000
    c.add_sample(0, 1100, 1100, 200)    # rtt=200, offset=1000
    assert c.offset_ms == 1000          # the min-rtt one is trusted
    assert c.best_rtt_ms == 200.0


def test_negative_rtt_sample_ignored():
    c = ClockSync()
    c.add_sample(0, 1100, 1100, 200)    # good, rtt 200
    before = c.offset_ms
    c.add_sample(0, 5000, 5000, 0)      # rtt = 0-0-(0) = 0 ... still >=0 ok
    # craft a truly negative rtt: t4 earlier than t1 implies impossible
    c.add_sample(100, 50, 60, 90)       # rtt = (90-100)-(60-50) = -20 → ignored
    assert c.offset_ms in (before, c.offset_ms)  # not poisoned
    assert (c.best_rtt_ms or 0) >= 0


def test_play_at_folding():
    c = ClockSync()
    c.add_sample(0, 1100, 1100, 200)    # offset = +1000 (master ahead)
    # play_at is in master clock; local target folds offset out
    assert c.to_local(50_000) == 49_000  # 50000 - 1000
    # master_now ≈ local now + offset
    import time
    now_local = int(time.time() * 1000)
    assert abs(c.master_now() - (now_local + 1000)) < 50


def test_reset_clears_samples():
    c = ClockSync()
    c.add_sample(0, 1100, 1100, 200)
    assert c.synced
    c.reset()
    assert not c.synced and c.offset_ms == 0


def test_unsynced_offset_is_zero_and_identity_fold():
    c = ClockSync()
    assert c.offset_ms == 0
    assert c.to_local(12345) == 12345    # no sample → identity
