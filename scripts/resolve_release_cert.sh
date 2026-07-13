#!/usr/bin/env bash
# Resolve the expected release signing certificate SHA-256 fingerprint (§根因B).
#
# Single source of truth for every signing/verify/promote lane so they all gate
# against ONE coherent expected fingerprint. Resolution order:
#   1. ANDROID_RELEASE_CERT_SHA256 env/repository variable, when non-empty
#      (operator override — e.g. a key rotation before the file is updated).
#   2. android_apps/player/release-cert-sha256.txt (checked-in canonical value).
#
# Emits the normalised fingerprint (uppercase hex, no colons, exactly 64 chars)
# to stdout. Exits non-zero with a ::error:: line if neither source yields a
# valid 64-hex-char fingerprint, so the release lanes stay fail-closed: a
# missing/garbled expected value never lets an unverified APK ship.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
canonical_file="$repo_root/android_apps/player/release-cert-sha256.txt"

raw=""
source_desc=""
if [ -n "${ANDROID_RELEASE_CERT_SHA256:-}" ]; then
  raw="$ANDROID_RELEASE_CERT_SHA256"
  source_desc="ANDROID_RELEASE_CERT_SHA256 variable"
elif [ -f "$canonical_file" ]; then
  # First non-comment, non-blank line.
  raw="$(grep -vE '^[[:space:]]*(#|$)' "$canonical_file" | head -1 || true)"
  source_desc="$canonical_file"
else
  echo "::error::No expected release certificate: set ANDROID_RELEASE_CERT_SHA256 or provide $canonical_file" >&2
  exit 1
fi

# Strict parse (fail-closed). Accept ONLY a SHA-256 fingerprint written as hex,
# optionally in keytool's colon-delimited byte form (XX:XX:...:XX) and/or wrapped
# in surrounding whitespace. Reject every other character: arbitrary junk mixed
# with 64 hex chars, or non-colon separators like '-'/'.', must NOT be silently
# reduced to a valid-looking fingerprint (the old `tr -cd '[:xdigit:]'` did just
# that). Whitespace anywhere is stripped first, then the remainder must be either
# contiguous hex or strictly colon-separated hex byte pairs.
trimmed="$(printf '%s' "$raw" | tr -d '[:space:]')"
if ! printf '%s' "$trimmed" | grep -qE '^([0-9A-Fa-f]+|[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2})*)$'; then
  echo "::error::Expected release certificate from $source_desc is malformed: only hex (optionally colon-delimited byte pairs) is allowed" >&2
  exit 1
fi
norm="$(printf '%s' "$trimmed" | tr -d ':' | tr '[:lower:]' '[:upper:]')"
if [ "${#norm}" -ne 64 ]; then
  echo "::error::Expected release certificate from $source_desc is not a 64-hex-char SHA-256 (got ${#norm} hex chars)" >&2
  exit 1
fi

printf '%s\n' "$norm"
