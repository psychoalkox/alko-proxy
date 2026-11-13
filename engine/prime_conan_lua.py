"""Fetch SHA256-verified Lua 5.4.6 sources into Conan 2's source-backup cache.

Usage: python engine/prime_conan_lua.py

Purpose: Work around intermittent TLS resets from www.lua.org on GitHub Windows
runners. The Conan recipe stays unchanged. A checksum mismatch is an error,
not a reason to disable certificate verification.
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import subprocess
import sys
from urllib.request import Request, urlopen


LUA_VERSION = "5.4.6"
LUA_SHA256 = "7d5ea1b9cb6aa0b59ca3dde1c6adcb57ef83a1ba8e5432c0ecd06bf439b3ad88"
# Alternate distributions of the *official original tarball* (not GitHub ZIPs,
# which have different hashes and should NOT be substituted).
SOURCES = (
    "https://distfiles.icmpv6.org/distfiles/lua-5.4.6.tar.gz",
    "https://mirror.nju.edu.cn/buildroot/lua/lua-5.4.6.tar.gz",
    "https://mirror.nju.edu.cn/macports/distfiles/lua/lua-5.4.6.tar.gz",
    "https://www.lua.org/ftp/lua-5.4.6.tar.gz",
)
MAX_ARCHIVE_BYTES = 3_000_000


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fetch_verified(
    sources: tuple[str, ...] = SOURCES,
    expected_sha256: str = LUA_SHA256,
    opener=urlopen,
) -> bytes:
    failures: list[str] = []
    for url in sources:
        try:
            print(f"Trying Lua source: {url}", flush=True)
            request = Request(url, headers={"User-Agent": "ALKOProxy-source-build/0.3"})
            with opener(request, timeout=25) as response:
                blob = response.read(MAX_ARCHIVE_BYTES + 1)
            if len(blob) > MAX_ARCHIVE_BYTES:
                raise ValueError("Download unexpectedly large")
            digest = sha256(blob)
            if digest != expected_sha256:
                raise ValueError(f"SHA256 mismatch: got {digest}, expected {expected_sha256}")
            print(f"Verified Lua source SHA256: {digest}", flush=True)
            return blob
        except Exception as exc:
            msg = f"{url}: {type(exc).__name__}: {exc}"
            print(f"WARN {msg}", file=sys.stderr, flush=True)
            failures.append(msg)
    raise RuntimeError("Could not obtain checksum-verified Lua sources:\n" + "\n".join(failures))


def conan_home_path() -> Path:
    result = subprocess.run(["conan", "config", "home"], text=True,
                            check=True, capture_output=True)
    lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    if not lines:
        raise RuntimeError("Conan did not report a config home")
    return Path(lines[-1]).expanduser().resolve()


def ensure_config(conan_home: Path, source_cache: Path) -> None:
    config_file = conan_home / "global.conf"
    conan_home.mkdir(parents=True, exist_ok=True)
    text = config_file.read_text(encoding="utf-8") if config_file.exists() else ""
    lines = [line for line in text.splitlines()
             if not line.lstrip().startswith("core.sources:download_cache")]
    # Slash separators are accepted by Conan on Windows and are safe in its
    # key=value config format (no need for quoted/escaped backslashes).
    lines.append(f"core.sources:download_cache={source_cache.resolve().as_posix()}")
    config_file.write_text("\n".join(lines) + "\n", encoding="utf-8")


def prime_cache(source_cache: Path, conan_home: Path, *,
                expected_sha256: str = LUA_SHA256,
                sources: tuple[str, ...] = SOURCES,
                opener=urlopen) -> Path:
    source_cache.mkdir(parents=True, exist_ok=True)
    blob_file = source_cache / expected_sha256
    if blob_file.is_file() and sha256(blob_file.read_bytes()) == expected_sha256:
        print("Verified Lua archive already in local Conan source cache")
    else:
        archive = fetch_verified(sources, expected_sha256, opener)
        partial = source_cache / (expected_sha256 + ".partial")
        try:
            partial.write_bytes(archive)
            os.replace(partial, blob_file)
        finally:
            partial.unlink(missing_ok=True)
    # Conan source-backup cache blobs are keyed by the source SHA256. Conan may
    # generate its adjacent .json metadata file as needed when it consumes it.
    ensure_config(conan_home, source_cache)
    print(f"Conan source cache: {source_cache}")
    print(f"Checksum-verified Lua cache blob: {blob_file}")
    print("Conan global.conf: core.sources:download_cache configured")
    return blob_file


def main() -> int:
    try:
        conan_home = conan_home_path()
        base = Path(os.getenv("RUNNER_TEMP") or os.getenv("TEMP") or ".").resolve()
        cache = base / "alko-conan-source-cache"
        prime_cache(cache, conan_home)
    except Exception as exc:
        print(f"ALKO dependency preparation failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
