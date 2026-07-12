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
cat > "$TMP/stat.c" <<'EOF'
int main(void){ return 0; }
EOF
if "$CC" -static -o "$TMP/stat" "$TMP/stat.c" 2>/dev/null; then
  if bash "$GATE" "$TMP/stat" >/dev/null 2>&1; then
    echo "ok: gate accepted a fully static binary."
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

echo "----"
if [ "$fails" -ne 0 ]; then
  echo "test_check_daemon_elf: $fails failure(s)."
  exit 1
fi
echo "test_check_daemon_elf: all checks passed."
