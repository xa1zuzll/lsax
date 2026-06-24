#!/usr/bin/env python3
"""
Usage:
    python3 patch.py soga
    python3 patch.py soga --verify
    python3 patch.py soga --restore
"""

import argparse
import os
import shutil
import struct
import sys

VA_BASE = 0x400000

# v2.13.7: aY6OR2Qxcfj.IVdU9scV
AACXJBIX_VA = 0x11c9520
WRAPPER_VA = 0x1852d89
WRAPPER_CAVE_SIZE = 55  # available int3 padding bytes

CONTROLLED_URL = b"https://api.igotu.cc/query"

AUTH_CALL_SITES = [
    # Gq7CvvpN9 package (initial auth) — 10 selectors
    ("u00qvWv",        0x11d5e98),
    ("zmew2nm",        0x11da9c9),
    ("wNPIUlwaU2",     0x11e06f1),
    ("yZ1WR7M_DuTL",   0x11e73d8),
    ("eEOKJyAJ117",    0x11ec3a9),
    ("lXU9clXh1EV",    0x11f0178),
    ("xSAz9zgEm99",    0x11f46e9),
    ("_tOHaOaMuz7D",   0x11f9c7a),
    ("gzS47FK",        0x11fe520),
    ("aPE6EhPe",       0x12031b1),
    # Y41eDd package (10-min re-verification) — 5 selectors
    ("ewXr2SKPQ",      0x172b471),
    ("yZBpfUM0mZwE",   0x173199a),
    ("doN3hlfvUXH",    0x1735f89),
    ("lWfl59Zh",       0x173a409),
    ("rztByhjeCfHf",   0x173ea80),
]


def _rel32(from_va, to_va):
    return struct.pack("<i", to_va - from_va)


def _build_orig_call(call_va):
    """Original 5-byte call AACxJBix at a given call site."""
    return b"\xe8" + _rel32(call_va + 5, AACXJBIX_VA)


def _build_redirect_call(call_va):
    """Redirected 5-byte call to wrapper at a given call site."""
    return b"\xe8" + _rel32(call_va + 5, WRAPPER_VA)


def _build_wrapper(url_bytes):
    """Build the wrapper code placed at WRAPPER_VA."""
    code = bytearray()
    va = WRAPPER_VA

    # lea rax, [rip + offset_to_url_data]
    lea_end = va + 7
    code += b"\x48\x8d\x05"
    url_offset_pos = len(code)
    code += b"\x00\x00\x00\x00"
    va = lea_end

    # mov ebx, len(url)
    code += b"\xbb" + struct.pack("<I", len(url_bytes))
    va += 5

    # jmp AACxJBix (original function)
    jmp_next = va + 5
    code += b"\xe9" + _rel32(jmp_next, AACXJBIX_VA)
    va = jmp_next

    # Fix lea RIP-relative offset: url_data is right here
    url_data_va = va
    struct.pack_into("<i", code, url_offset_pos, url_data_va - lea_end)

    # URL bytes
    code += url_bytes

    assert len(code) <= WRAPPER_CAVE_SIZE, \
        f"wrapper overflow: {len(code)} > {WRAPPER_CAVE_SIZE}"
    return bytes(code)


def _read(f, va, n):
    f.seek(va - VA_BASE)
    return f.read(n)


def _write(f, va, data):
    f.seek(va - VA_BASE)
    f.write(data)


def apply_patch(binary_path, url=CONTROLLED_URL):
    wrapper = _build_wrapper(url)
    patched = 0

    with open(binary_path, "r+b") as f:
        # Verify cave is clean (all 0xcc)
        cave_cur = _read(f, WRAPPER_VA, WRAPPER_CAVE_SIZE)
        if cave_cur == wrapper:
            print(f"  Wrapper: already in place ({len(wrapper)}B)")
        elif all(b == 0xcc for b in cave_cur):
            _write(f, WRAPPER_VA, wrapper)
            print(f"  Wrapper: written at 0x{WRAPPER_VA:x} ({len(wrapper)}B)")
        else:
            print(f"  Wrapper: SKIP — cave not clean at 0x{WRAPPER_VA:x}")
            print(f"    found: {cave_cur[:16].hex()}...")
            return False

        for name, call_va in AUTH_CALL_SITES:
            orig = _build_orig_call(call_va)
            redir = _build_redirect_call(call_va)
            cur = _read(f, call_va, 5)

            if cur == redir:
                print(f"  {name:18s}: already redirected")
                patched += 1
            elif cur == orig:
                _write(f, call_va, redir)
                print(f"  {name:18s}: redirected (0x{call_va:x})")
                patched += 1
            else:
                print(f"  {name:18s}: SKIP unexpected @ 0x{call_va:x}: {cur.hex()}")

    print(f"\nRedirected {patched}/{len(AUTH_CALL_SITES)} auth call sites")
    print(f"Controlled URL: {url.decode()} ({len(url)}B)")
    return patched == len(AUTH_CALL_SITES)


def verify(binary_path, url=CONTROLLED_URL):
    wrapper = _build_wrapper(url)
    ok = True

    with open(binary_path, "rb") as f:
        cave_cur = _read(f, WRAPPER_VA, len(wrapper))
        if cave_cur == wrapper:
            print(f"[WRAPPER OK] 0x{WRAPPER_VA:x} ({len(wrapper)}B)")
        else:
            print(f"[WRAPPER BAD] 0x{WRAPPER_VA:x}")
            ok = False

        for name, call_va in AUTH_CALL_SITES:
            redir = _build_redirect_call(call_va)
            orig = _build_orig_call(call_va)
            cur = _read(f, call_va, 5)

            if cur == redir:
                print(f"  [PATCHED ] {name}")
            elif cur == orig:
                print(f"  [ORIGINAL] {name}")
                ok = False
            else:
                print(f"  [UNKNOWN ] {name}: {cur.hex()}")
                ok = False
    return ok


def restore(binary_path):
    backup = binary_path + ".https_orig"
    if not os.path.exists(backup):
        print(f"ERROR: backup {backup} not found")
        return False
    shutil.copy2(backup, binary_path)
    os.chmod(binary_path, 0o755)
    print(f"Restored from {backup}")
    return True


def main():
    p = argparse.ArgumentParser(
        description="Patch soga auth at HTTPS unified entry (AACxJBix wrapper)")
    p.add_argument("binary", nargs="?", default="soga")
    p.add_argument("--verify", action="store_true")
    p.add_argument("--restore", action="store_true")
    p.add_argument("--url", default=CONTROLLED_URL.decode(),
                   help="Controlled URL (default: %(default)s)")
    args = p.parse_args()

    url = args.url.encode()

    if args.restore:
        sys.exit(0 if restore(args.binary) else 1)
    if args.verify:
        sys.exit(0 if verify(args.binary, url) else 1)

    backup = args.binary + ".https_orig"
    if not os.path.exists(backup):
        shutil.copy2(args.binary, backup)
        print(f"Backup: {backup}")

    print("Applying patches:")
    if not apply_patch(args.binary, url):
        print("FAILED")
        sys.exit(1)


if __name__ == "__main__":
    main()
