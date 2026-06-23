# PyInstaller runtime hook — make the bundled mpv.exe discoverable.
#
# Why this exists:
#   windows_player drives mpv by SPAWNING a real mpv.exe as a subprocess over
#   JSON IPC (see windows_player/mpv_controller.py + watchdog.py). The default
#   config has mpv.path = "mpv", so at runtime the player calls
#   subprocess.Popen(["mpv", ...]); on Windows that resolves "mpv" -> "mpv.exe"
#   by searching the PATH environment variable.
#
#   In a PyInstaller --onefile build, files added via --add-binary are unpacked
#   into a temporary directory exposed as sys._MEIPASS. That directory is NOT on
#   PATH, so the bundled mpv.exe would not be found and the player could not
#   start mpv. This hook runs before the app's own code and prepends _MEIPASS to
#   PATH so the co-bundled mpv.exe is found transparently.
#
# This file lives under .github/ and is passed to PyInstaller via
# --runtime-hook; it is not part of the application source tree.
import os
import sys

_meipass = getattr(sys, "_MEIPASS", None)
if _meipass:
    os.environ["PATH"] = _meipass + os.pathsep + os.environ.get("PATH", "")
