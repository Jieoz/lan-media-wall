"""mpv launch-arg construction — §9/§11 kiosk flags + §9 hardware decoding."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from mpv_controller import mpv_launch_args  # noqa: E402


def test_kiosk_flags_present():
    args = mpv_launch_args("/tmp/x.sock")
    # black-screen-proof kiosk invariants (§11) must always be present
    for flag in ("--idle=yes", "--force-window=yes", "--fullscreen=yes",
                 "--ontop=yes", "--border=no", "--background=#000000"):
        assert flag in args


def test_hwdec_default_auto_safe():
    args = mpv_launch_args("/tmp/x.sock")
    assert "--hwdec=auto-safe" in args


def test_hwdec_explicit_off():
    for off in ("no", "off", "none", "false", "0", ""):
        args = mpv_launch_args("/tmp/x.sock", hwdec=off)
        assert "--hwdec=no" in args, off
        # never emit a bare/duplicate hwdec
        assert sum(a.startswith("--hwdec=") for a in args) == 1


def test_hwdec_none_disables():
    args = mpv_launch_args("/tmp/x.sock", hwdec=None)
    assert "--hwdec=no" in args


def test_hwdec_pinned_decoder_passthrough():
    args = mpv_launch_args("/tmp/x.sock", hwdec="d3d11va")
    assert "--hwdec=d3d11va" in args


def test_hwdec_survives_extra_args():
    args = mpv_launch_args("/tmp/x.sock", hwdec="auto-safe",
                           extra=["--vd-lag-frames=2"])
    assert "--hwdec=auto-safe" in args
    assert "--vd-lag-frames=2" in args
    # exactly one hwdec flag regardless of extras
    assert sum(a.startswith("--hwdec=") for a in args) == 1
