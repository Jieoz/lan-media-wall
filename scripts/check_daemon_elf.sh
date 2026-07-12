#!/usr/bin/env bash
# check_daemon_elf.sh — build-artifact gate for the QZX root daemon binary.
#
# WHY THIS EXISTS (real v1.14.0 field failure):
#   On the real QZX_C1 / Android 4.4.2 (API19) box the shipped daemon died with
#       CANNOT LINK EXECUTABLE: cannot locate symbol "signal"
#             referenced by "/system/xbin/lmw_root_daemon"
#   The v1.14.0 workflow compiled the daemon with `-fPIE -pie` (a DYNAMIC PIE),
#   so at exec time the loader had to resolve libc symbols against the DEVICE's
#   bionic. API19 bionic does NOT export `signal` as a dynamic symbol (it was a
#   header-inline shim on old bionic), so the box could not link the executable
#   and the daemon never started — remote restart/update were dead.
#
# WHAT THIS GATE ENFORCES (fail the CI build before it can ship a broken daemon):
#   1. STATIC: the binary must be fully statically linked — no PT_INTERP program
#      header and no DT_NEEDED dynamic dependency. A static binary carries its own
#      libc, so there is NOTHING to resolve against the device bionic at exec time.
#      This is the root fix: it makes the whole "which API level exports which
#      symbol" question moot for every syscall wrapper the daemon uses.
#   2. NO API19-UNSAFE UNDEFINED SYMBOLS: defense in depth. If a future change ever
#      reverts to a dynamic build, we still fail loudly on the specific symbols
#      that bit us (and their cousins) instead of shipping another broken box.
#
# Usage:
#   scripts/check_daemon_elf.sh <path-to-daemon-binary>
# Exit 0 = safe to ship; non-zero = would break API19.
#
# Portable: uses llvm-readelf (NDK) if present, else the distro readelf. Works on
# the CI host inspecting the cross-compiled armv7 binary (readelf is arch-neutral).

set -euo pipefail

BIN="${1:-}"
if [ -z "$BIN" ] || [ ! -f "$BIN" ]; then
  echo "check_daemon_elf: usage: $0 <daemon-binary>" >&2
  exit 2
fi

# Prefer the NDK's llvm-readelf when it is on PATH (CI has it), else distro readelf.
READELF=""
for cand in llvm-readelf readelf; do
  if command -v "$cand" >/dev/null 2>&1; then READELF="$cand"; break; fi
done
if [ -z "$READELF" ]; then
  echo "check_daemon_elf: no readelf/llvm-readelf found on PATH." >&2
  exit 2
fi

echo "== check_daemon_elf: inspecting $BIN with $READELF =="

fail=0

# ---- Check 1: fully static (no interpreter, no NEEDED libs) ----------------
prog_headers="$("$READELF" -l "$BIN" 2>/dev/null || true)"
dyn_section="$("$READELF" -d "$BIN" 2>/dev/null || true)"

if printf '%s' "$prog_headers" | grep -qi "INTERP"; then
  echo "FAIL[static]: binary has a PT_INTERP (dynamic executable). It will try to" >&2
  echo "              resolve libc symbols against the DEVICE bionic at exec time —" >&2
  echo "              exactly the API19 'cannot locate symbol' failure. Build -static." >&2
  fail=1
else
  echo "ok[static]: no PT_INTERP program header."
fi

if printf '%s' "$dyn_section" | grep -q "(NEEDED)"; then
  echo "FAIL[static]: binary has DT_NEEDED shared-library dependencies:" >&2
  printf '%s\n' "$dyn_section" | grep "(NEEDED)" >&2
  fail=1
else
  echo "ok[static]: no DT_NEEDED shared-library dependencies."
fi

# ---- Check 2: no API19-unsafe UNDEFINED dynamic symbols --------------------
# These libc symbols are absent or late-exported on API19 bionic and are the
# class of failure this gate exists to stop:
#   * signal   — on old bionic <signal.h> made signal() a static-inline shim over
#                bsd_signal/sysv_signal; API19 libc.so exports THOSE, not `signal`.
#                Unified NDK headers emit a real `signal` reference → the exact
#                field break. (sigaction, by contrast, IS exported since API1 —
#                it is the safe replacement, so it is deliberately NOT denied.)
#   * dprintf / vdprintf — only exported by bionic from API21; a dynamic build
#                referencing them dies the same way on API19.
DENY="signal dprintf vdprintf"
# Undefined dynamic symbols (UND) — meaningful only for a dynamic binary; a static
# binary's --dyn-syms is empty, so this loop simply finds nothing (still correct).
dyn_syms="$("$READELF" --dyn-syms "$BIN" 2>/dev/null || true)"
und_syms="$(printf '%s\n' "$dyn_syms" | awk '$7=="UND" && $8!="" {print $8}' | sort -u)"

if [ -n "$und_syms" ]; then
  echo "info: undefined dynamic symbols present (dynamic binary):"
  printf '%s\n' "$und_syms" | sed 's/^/    /'
fi

for sym in $DENY; do
  # match the bare symbol name (strip any @GLIBC/@version suffix first)
  if printf '%s\n' "$und_syms" | sed 's/@.*//' | grep -qx "$sym"; then
    echo "FAIL[symbol]: undefined dynamic symbol '$sym' — not safely resolvable on" >&2
    echo "              API19 bionic. This is the field-failure class. Build -static." >&2
    fail=1
  fi
done
if [ "$fail" -eq 0 ]; then
  echo "ok[symbol]: no API19-unsafe undefined dynamic symbols."
fi

echo "----"
if [ "$fail" -ne 0 ]; then
  echo "check_daemon_elf: FAILED — this binary would break on API19. Not shippable." >&2
  exit 1
fi
echo "check_daemon_elf: PASSED — statically linked, no API19-unsafe dynamic symbols."
