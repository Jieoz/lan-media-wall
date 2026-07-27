#!/usr/bin/env python3
"""Print the signing certificate SHA-256 of an APK without apksigner/keytool.

An APK's v1 (JAR) signature stores the signer certificate as a DER blob inside
META-INF/*.RSA|DSA|EC (a PKCS#7 SignedData). The Android "certificate SHA-256
digest" that gates 覆盖升级 / remote update_app is the SHA-256 of that DER
certificate, so it can be recovered by locating the certificate inside the
PKCS#7 container and hashing its exact bytes.

We avoid a full ASN.1 parser dependency: the PKCS#7 embeds the X.509 cert as a
top-level SEQUENCE inside the `certificates [0] IMPLICIT` field. We walk the DER
structure with a minimal reader and hash the first certificate found.

Usage: python3 scripts/read_apk_cert_sha256.py <apk> [<apk> ...]
"""
import hashlib
import re
import sys
import zipfile


def read_len(data: bytes, i: int):
    """Return (length, next_index) for a DER length at offset i."""
    first = data[i]
    i += 1
    if first < 0x80:
        return first, i
    count = first & 0x7F
    if count == 0 or count > 4:
        raise ValueError("unsupported DER length form")
    length = int.from_bytes(data[i:i + count], "big")
    return length, i + count


def iter_sequences(data: bytes, start: int, end: int):
    """Yield (tag, body_start, body_end) for TLVs in [start, end)."""
    i = start
    while i < end:
        tag = data[i]
        try:
            length, j = read_len(data, i + 1)
        except (ValueError, IndexError):
            return
        body_end = j + length
        if body_end > end:
            return
        yield tag, j, body_end
        i = body_end


def find_certificate(data: bytes) -> bytes:
    """Locate the first X.509 certificate DER inside a PKCS#7 blob.

    An X.509 Certificate is SEQUENCE { tbsCertificate SEQUENCE, ... } where the
    tbsCertificate is itself a SEQUENCE. We scan for a SEQUENCE whose first child
    is a SEQUENCE containing a version/serial pattern, which is stable enough for
    the single-signer APKs this project produces.
    """
    best = None
    for i in range(len(data) - 4):
        if data[i] != 0x30:  # SEQUENCE
            continue
        try:
            length, j = read_len(data, i + 1)
        except (ValueError, IndexError):
            continue
        end = j + length
        if end > len(data) or length < 200:
            continue
        # First child must be the tbsCertificate SEQUENCE.
        if data[j] != 0x30:
            continue
        body = data[i:end]
        # X.509 certs carry an AlgorithmIdentifier + Validity; require the
        # signatureAlgorithm OID prefix for RSA/EC families to reduce false hits.
        if b"\x2a\x86\x48\x86\xf7\x0d\x01\x01" not in body and b"\x2a\x86\x48\xce\x3d" not in body:
            continue
        if best is None or len(body) > len(best):
            best = body
    if best is None:
        raise ValueError("no X.509 certificate found in signature block")
    return best


def apk_cert_sha256(apk_path: str) -> str:
    with zipfile.ZipFile(apk_path) as zf:
        blocks = [n for n in zf.namelist()
                  if re.match(r"META-INF/.*\.(RSA|DSA|EC)$", n, re.IGNORECASE)]
        if not blocks:
            raise ValueError("no v1 signature block (META-INF/*.RSA) present")
        raw = zf.read(sorted(blocks)[0])
    cert = find_certificate(raw)
    return hashlib.sha256(cert).hexdigest().upper()


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: read_apk_cert_sha256.py <apk> [...]")
        return 2
    status = 0
    for apk in sys.argv[1:]:
        try:
            print("%s -> %s" % (apk, apk_cert_sha256(apk)))
        except Exception as exc:  # noqa: BLE001 - report and continue
            print("%s -> ERROR %s: %s" % (apk, type(exc).__name__, exc))
            status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())
