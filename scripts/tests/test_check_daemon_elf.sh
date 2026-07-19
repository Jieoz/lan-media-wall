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

# (B) A host static binary is not a shippable daemon: target identity must
# reject it rather than confusing an x86 artifact with the ARM32 box binary.
cat > "$TMP/stat.c" <<'EOF'
int main(void){ return 0; }
EOF
if "$CC" -static -o "$TMP/stat" "$TMP/stat.c" 2>/dev/null; then
  if bash "$GATE" "$TMP/stat" >/dev/null 2>&1; then
    echo "FAIL: gate ACCEPTED a host x86 static binary (should reject wrong target)."
    fails=$((fails+1))
  else
    echo "ok: gate rejected a host static binary as non-ARM target."
  fi
else
  echo "SKIP: host lacks static libc; target identity is exercised by fixtures." >&2
fi

# (C) The API19 ARM TLS failure must be rejected without requiring a cross
# compiler. A fake readelf returns a static ARM32 ET_EXEC with PT_TLS Align=0x8.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/llvm-readelf" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  -h) cat <<'OUT'
ELF Header:
  Class:                             ELF32
  Type:                              EXEC (Executable file)
  Machine:                           ARM
OUT
      ;;
  -l)
      case "${FIXTURE_TLS:-0x8}" in
        none) cat <<'OUT'
Program Headers:
  Type           Offset   VirtAddr   PhysAddr   FileSiz MemSiz  Flg Align
  LOAD           0x000000 0x00000000 0x00000000 0x00000 0x00000 R E 0x1000
OUT
              ;;
        *) cat <<OUT
Program Headers:
  Type           Offset   VirtAddr   PhysAddr   FileSiz MemSiz  Flg Align
  TLS            0x001000 0x00000000 0x00000000 0x00000 0x00004 R   ${FIXTURE_TLS}
OUT
              ;;
      esac
      ;;
  -d|--dyn-syms) : ;;
esac
EOF
chmod +x "$TMP/bin/llvm-readelf"
: > "$TMP/arm-static-fixture"
if PATH="$TMP/bin:$PATH" bash "$GATE" "$TMP/arm-static-fixture" >/dev/null 2>&1; then
  echo "FAIL: gate ACCEPTED an ARM PT_TLS Align=0x8 fixture (should reject)."
  fails=$((fails+1))
else
  echo "ok: gate rejected an underaligned ARM PT_TLS fixture."
fi
if ! FIXTURE_TLS=0x20 PATH="$TMP/bin:$PATH" bash "$GATE" "$TMP/arm-static-fixture" >/dev/null 2>&1; then
  echo "FAIL: gate REJECTED an ARM PT_TLS Align=0x20 fixture (should accept)."
  fails=$((fails+1))
else
  echo "ok: gate accepted an aligned ARM PT_TLS fixture."
fi
if ! FIXTURE_TLS=none PATH="$TMP/bin:$PATH" bash "$GATE" "$TMP/arm-static-fixture" >/dev/null 2>&1; then
  echo "FAIL: gate REJECTED an ARM fixture without PT_TLS (should accept)."
  fails=$((fails+1))
else
  echo "ok: gate accepted an ARM fixture without PT_TLS."
fi

# (D) usage / missing-arg must fail closed.
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
