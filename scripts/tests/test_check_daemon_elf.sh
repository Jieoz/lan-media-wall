#!/usr/bin/env bash
# test_check_daemon_elf.sh — host regression test for scripts/check_daemon_elf.sh.
#
# This is the TDD gate for the real v1.14.0 field failure ("cannot locate symbol
# signal" on API19). It proves — architecture-independently, with the distro gcc —
# that the ELF gate:
#   (A) REJECTS a DYNAMIC binary that references `signal` (the exact break), and
#   (B) ACCEPTS a fully STATIC binary.
# So even before the armv7 cross build runs in cloud CI, this locks the gate's
# behavior. The workflow then runs the SAME gate on the real cross-compiled
# armv7 daemon, which is the actual ship-blocker.
#
# Run: scripts/tests/test_check_daemon_elf.sh   (exit 0 = pass)

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/../check_daemon_elf.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CC="${CC:-gcc}"
if ! command -v "$CC" >/dev/null 2>&1; then
  echo "SKIP: no C compiler ($CC) on host; gate exercised in cloud CI on armv7." >&2
  exit 0
fi

fails=0

# (A) dynamic binary that references signal() — must be REJECTED.
cat > "$TMP/dyn.c" <<'EOF'
#include <signal.h>
int main(void){ signal(SIGPIPE, SIG_IGN); return 0; }
EOF
if "$CC" -o "$TMP/dyn" "$TMP/dyn.c" 2>/dev/null; then
  if bash "$GATE" "$TMP/dyn" >/dev/null 2>&1; then
    echo "FAIL: gate ACCEPTED a dynamic binary referencing signal (should reject)."
    fails=$((fails+1))
  else
    echo "ok: gate rejected dynamic signal() binary."
  fi
else
  echo "SKIP: host could not build a dynamic test binary." >&2
fi

# (B) fully static binary — must be ACCEPTED (if the host can build static).
# NOTE: a glibc host injects its OWN PT_TLS aligned to 8 into every static binary
# (a host-libc artifact, harmless under glibc). The real armv7 bionic daemon has
# NO PT_TLS, so it passes cleanly in cloud CI. To keep this host case honest under
# the new ARM-Bionic TLS gate, we only assert plain-static ACCEPTANCE when the
# host's static binary has no under-aligned TLS; when glibc adds align-8 TLS we
# note that the static-accept property is instead proven by case (D2) below (a
# static binary whose PT_TLS is aligned >= 32 is accepted).
cat > "$TMP/stat.c" <<'EOF'
int main(void){ return 0; }
EOF
if "$CC" -static -o "$TMP/stat" "$TMP/stat.c" 2>/dev/null; then
  stat_tls=""
  [ -n "${READELF:-}" ] || for cand in llvm-readelf readelf; do
    command -v "$cand" >/dev/null 2>&1 && { READELF="$cand"; break; }
  done
  [ -n "${READELF:-}" ] && stat_tls="$("$READELF" -l "$TMP/stat" 2>/dev/null | awk 'f{print $NF; exit} $1=="TLS"{f=1}')"
  if bash "$GATE" "$TMP/stat" >/dev/null 2>&1; then
    echo "ok: gate accepted a fully static binary."
  elif [ "$stat_tls" = "0x8" ] || [ "$stat_tls" = "8" ] || [ "$stat_tls" = "0x10" ] || [ "$stat_tls" = "16" ]; then
    echo "SKIP: host glibc injected an under-aligned ($stat_tls) PT_TLS into the plain" >&2
    echo "      static binary (host-libc artifact); static-accept is proven by case (D2)." >&2
  else
    echo "FAIL: gate REJECTED a fully static binary (should accept)."
    fails=$((fails+1))
  fi
else
  echo "SKIP: host lacks static libc; static-accept case exercised in cloud CI." >&2
fi

# (C) usage / missing-arg must fail closed.
if bash "$GATE" >/dev/null 2>&1; then
  echo "FAIL: gate returned success with no argument (should fail closed)."
  fails=$((fails+1))
else
  echo "ok: gate fails closed on missing argument."
fi

# (D) PT_TLS alignment gate — the real v1.18.1 field failure. On the QZX_C1
# (API19 ARM Bionic) a daemon whose PT_TLS program header is aligned to only 8
# died at exec with:
#   "TLS segment is underaligned: alignment is 8, needs to be at least 32 for ARM Bionic"
# ARM Bionic's loader requires TLS segment alignment >= 32. So the gate MUST:
#   (D1) REJECT a STATIC binary carrying a PT_TLS aligned < 32, and
#   (D2) ACCEPT a STATIC binary whose PT_TLS is aligned >= 32.
# Both fixtures are static (no PT_INTERP) so the ONLY reason for the D1 rejection
# is the TLS alignment — never the pre-existing static/symbol checks.
tls_align() { # $1 binary -> prints the PT_TLS Align token (empty if no TLS)
  "$READELF" -l "$1" 2>/dev/null | awk 'f{print $NF; exit} $1=="TLS"{f=1}'
}
# We need a readelf for the fixture-shape assertions the same way the gate does.
READELF=""
for cand in llvm-readelf readelf; do
  if command -v "$cand" >/dev/null 2>&1; then READELF="$cand"; break; fi
done

# (D1) static binary with an UNDER-aligned (8) TLS segment — must be REJECTED.
cat > "$TMP/tls8.c" <<'EOF'
#include <stdint.h>
_Thread_local uint64_t lmw_tls = 1;
int main(void){ return (int)lmw_tls; }
EOF
if [ -n "$READELF" ] && "$CC" -static -fno-PIE -no-pie -o "$TMP/tls8" "$TMP/tls8.c" 2>/dev/null; then
  a="$(tls_align "$TMP/tls8")"
  if [ -z "$a" ]; then
    echo "SKIP: toolchain produced no PT_TLS for the under-aligned fixture." >&2
  elif [ "$a" != "0x8" ] && [ "$a" != "8" ]; then
    echo "SKIP: under-aligned TLS fixture came out aligned '$a' (>=32?); alignment case exercised in cloud CI." >&2
  elif bash "$GATE" "$TMP/tls8" >/dev/null 2>&1; then
    echo "FAIL: gate ACCEPTED a static binary with PT_TLS aligned 8 (< 32, ARM-Bionic-fatal)."
    fails=$((fails+1))
  else
    echo "ok: gate rejected the under-aligned (align=8) PT_TLS binary."
  fi
else
  echo "SKIP: no readelf or host could not build the static under-aligned TLS fixture." >&2
fi

# (D2) static binary with a >=32-aligned TLS segment — must be ACCEPTED.
cat > "$TMP/tls32.c" <<'EOF'
#include <stdint.h>
_Alignas(32) _Thread_local uint64_t lmw_tls = 1;
int main(void){ return (int)lmw_tls; }
EOF
if [ -n "$READELF" ] && "$CC" -static -fno-PIE -no-pie -o "$TMP/tls32" "$TMP/tls32.c" 2>/dev/null; then
  a="$(tls_align "$TMP/tls32")"
  if [ "$a" = "0x20" ] || [ "$a" = "32" ]; then
    if bash "$GATE" "$TMP/tls32" >/dev/null 2>&1; then
      echo "ok: gate accepted the well-aligned (align=32) PT_TLS binary."
    else
      echo "FAIL: gate REJECTED a static binary with PT_TLS aligned 32 (>= 32, safe)."
      fails=$((fails+1))
    fi
  else
    echo "SKIP: could not force a 32-aligned TLS fixture (got '$a'); accept-case in cloud CI." >&2
  fi
else
  echo "SKIP: no readelf or host could not build the static 32-aligned TLS fixture." >&2
fi

echo "----"
if [ "$fails" -ne 0 ]; then
  echo "test_check_daemon_elf: $fails failure(s)."
  exit 1
fi
echo "test_check_daemon_elf: all checks passed."
