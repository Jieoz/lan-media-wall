"""§8.5 boundary_only loop resync — parity with the Android fleet.

These are not "does Python run" tests. Every case below encodes a rule the
Android implementation already obeys; if the Windows port diverges, a mixed wall
drifts apart while both sides report healthy sync. The parity block at the end
pins the exact constants both fleets promise via `loop_boundary_sync_v1`.
"""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import loop_boundary_sync as L  # noqa: E402


# --- constants are a cross-fleet contract, not tunables ----------------

def test_constants_match_the_android_fleet():
    # Mirrors PlayerService.LOOP_BOUNDARY_TOLERANCE_MS / _SAMPLE_SETTLE_MS and
    # ContentClock.LATE_START_THRESHOLD_MS. Changing one side alone silently
    # breaks mixed-wall alignment, so pin all three.
    assert L.LOOP_BOUNDARY_TOLERANCE_MS == 80
    assert L.LOOP_BOUNDARY_SAMPLE_SETTLE_MS == 40
    assert L.LATE_START_THRESHOLD_MS == 40


# --- boundary scheduling ------------------------------------------------

def test_first_lap_is_shortened_by_the_initial_seek():
    # A non-zero start seek means this box reaches the loop point EARLIER than
    # play_at + duration. Getting this wrong puts every later boundary off by
    # the seek amount.
    assert L.next_boundary_master_ms(1000, 0, 5000, 1000) == 6000
    assert L.next_boundary_master_ms(1000, 2000, 5000, 1000) == 4000


def test_later_boundaries_are_full_laps():
    # Joining mid-playback must land on the next real lap edge, not "now + one
    # duration", or this screen corrects against a phantom boundary forever.
    assert L.next_boundary_master_ms(1000, 0, 5000, 13500) == 16000


def test_boundary_exactly_on_the_edge_advances_to_the_next_lap():
    # Strictly-after semantics: sampling AT the edge would race the decoder's
    # own wrap and read the pre-wrap position.
    assert L.next_boundary_master_ms(1000, 0, 5000, 6000) == 11000


def test_unknown_duration_yields_no_boundary():
    # mpv reports no duration until the file loads; callers must wait rather
    # than compute a bogus edge.
    assert L.next_boundary_master_ms(1000, 0, 0, 5000) is None


# --- drift measurement --------------------------------------------------

def test_drift_is_measured_on_the_shortest_path_around_the_loop():
    # THE case that makes naive resync useless: a box sitting just before EOS
    # while the wall has already wrapped is 20ms apart, not 4980ms apart.
    assert L.shortest_circular_drift_ms(4990, 10, 5000) == 20
    assert L.shortest_circular_drift_ms(10, 4990, 5000) == -20


def test_drift_sign_is_ahead_positive():
    assert L.shortest_circular_drift_ms(1000, 1200, 5000) == 200   # ahead
    assert L.shortest_circular_drift_ms(1200, 1000, 5000) == -200  # trailing


# --- correction policy --------------------------------------------------

def test_micro_jitter_does_not_trigger_a_seek():
    # A correcting seek costs a visible frame, so drift inside tolerance must be
    # left alone -- otherwise the wall flickers once per lap forever.
    d = L.decide(play_at_master_ms=1000, base_seek_ms=0,
                 master_now_ms=1000 + 5000 + 30, duration_ms=5000,
                 actual_position_ms=30)
    assert d.seek_to_ms is None
    assert abs(d.drift_ms) <= L.LOOP_BOUNDARY_TOLERANCE_MS


def test_sustained_drift_seeks_to_the_expected_position():
    d = L.decide(play_at_master_ms=1000, base_seek_ms=0,
                 master_now_ms=1000 + 5000 + 300, duration_ms=5000,
                 actual_position_ms=0)
    assert d.seek_to_ms == d.expected_position_ms == 300
    assert d.drift_ms == -300


def test_drift_exactly_at_tolerance_is_left_alone():
    # Boundary condition: strictly-greater, matching Kotlin `abs(drift) > tol`.
    d = L.decide(play_at_master_ms=0, base_seek_ms=0,
                 master_now_ms=5000 + 80, duration_ms=5000,
                 actual_position_ms=0)
    assert abs(d.drift_ms) == 80
    assert d.seek_to_ms is None


def test_unknown_duration_never_seeks():
    d = L.decide(play_at_master_ms=0, base_seek_ms=0, master_now_ms=9999,
                 duration_ms=0, actual_position_ms=1234)
    assert d == L.BoundaryDecision(0, 0, None)


# --- expected-position math --------------------------------------------

def test_before_play_at_expects_the_primed_seek_frame():
    # Nothing has started; the primed frame IS the seek point. Projecting
    # backwards here would seek a not-yet-started box away from the group.
    assert L.expected_offset_ms(1000, 250, 500, 5000, True) == 250


def test_expected_offset_wraps_for_loops():
    assert L.expected_offset_ms(0, 0, 12000, 5000, True) == 2000


def test_expected_offset_clamps_for_non_loops():
    assert L.expected_offset_ms(0, 0, 12000, 5000, False) == 5000


@pytest.mark.parametrize("late_ms,expected", [
    (0, None), (40, None), (41, 41), (500, 500),
])
def test_late_start_compensation_ignores_sub_threshold_slips(late_ms, expected):
    # prepare/loadfile can finish after play_at; compensate only when the slip
    # is worth a seek, else the correction costs more than the error.
    assert L.late_start_seek_ms(1000, 0, 1000 + late_ms, 5000, True) == expected


def test_android_kotlin_vectors_reproduce_exactly():
    """The SAME numbers asserted in LoopBoundarySyncTest.kt.

    Copied verbatim from the Kotlin test so the two fleets are pinned to one set
    of vectors instead of each to its own. If this fails, a mixed Android+Windows
    wall drifts apart -- fix the port, do not relax the numbers.
    """
    # `next boundary accounts for a nonzero initial seek`
    assert L.next_boundary_master_ms(10_000, 2_000, 60_000, 20_000) == 68_000
    assert L.next_boundary_master_ms(10_000, 2_000, 60_000, 68_000) == 128_000

    # `small circular phase error at loop boundary does not seek`
    d = L.decide(10_000, 0, 70_030, 60_000, 60_000 - 20, 80)
    assert (d.expected_position_ms, d.drift_ms, d.seek_to_ms) == (30, -50, None)

    # `lagging phase beyond tolerance seeks to master projection`
    d = L.decide(10_000, 0, 70_050, 60_000, 59_800, 80)
    assert (d.expected_position_ms, d.drift_ms, d.seek_to_ms) == (50, -250, 50)

    # `leading phase beyond tolerance seeks to master projection`
    d = L.decide(10_000, 0, 70_050, 60_000, 260, 80)
    assert (d.drift_ms, d.seek_to_ms) == (210, 50)

    # `unknown duration disables boundary scheduling and correction`
    assert L.next_boundary_master_ms(10, 0, 0, 20) is None
    assert L.decide(10, 0, 20, 0, 5, 80).seek_to_ms is None


def test_negative_modulo_matches_kotlin_floormod():
    # Python % and Kotlin Math.floorMod agree for positive moduli, but this is
    # load-bearing for pre-play_at / wrapped math -- pin it explicitly.
    assert L._floormod(-30, 1000) == 970
    # A negative seek normalizes to 970 into the clip, so only 30ms of the first
    # lap remain -- NOT 970ms. Kotlin Math.floorMod gives the same.
    assert L.next_boundary_master_ms(0, -30, 1000, 0) == 30
