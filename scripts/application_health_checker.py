#!/usr/bin/env python3
"""Check an HTTP endpoint and report whether it is responding successfully."""

from __future__ import annotations

import argparse
import math
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone


def check_url(url: str, timeout: float) -> tuple[bool, int | None, float, str | None]:
    """Return (is_up, status_code, elapsed_seconds, error_message)."""
    try:
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme not in {"http", "https"} or not parsed.hostname:
            raise ValueError("URL must be an absolute http:// or https:// URL.")
        if parsed.username is not None or parsed.password is not None:
            raise ValueError("URLs containing embedded credentials are not supported.")
        parsed.port
    except ValueError as exc:
        return False, None, 0.0, f"Invalid URL: {exc}"

    started = time.perf_counter()
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            status_code = response.status
        elapsed = time.perf_counter() - started
        if 200 <= status_code <= 299:
            return True, status_code, elapsed, None
        return False, status_code, elapsed, f"HTTP status {status_code}"
    except urllib.error.HTTPError as exc:
        exc.close()
        return False, exc.code, time.perf_counter() - started, f"HTTP status {exc.code}"
    except (urllib.error.URLError, TimeoutError, OSError, ValueError) as exc:
        reason = getattr(exc, "reason", exc)
        return False, None, time.perf_counter() - started, str(reason)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("url", help="absolute HTTP or HTTPS URL to check")
    parser.add_argument("--timeout", type=float, default=5.0, help="request timeout in seconds (default: 5)")
    parser.add_argument("--count", type=int, default=1, help="number of checks (default: 1)")
    parser.add_argument("--interval", type=float, default=5.0, help="seconds between checks (default: 5)")
    args = parser.parse_args()

    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be a finite number greater than zero")
    if args.count < 1:
        parser.error("--count must be at least one")
    if not math.isfinite(args.interval) or args.interval < 0:
        parser.error("--interval must be a finite non-negative number")

    overall_up = True
    for attempt in range(args.count):
        is_up, status_code, elapsed, error = check_url(args.url, args.timeout)
        overall_up = overall_up and is_up
        status_text = "UP" if is_up else "DOWN"
        http_text = str(status_code) if status_code is not None else "unavailable"
        timestamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
        message = (
            f"[{timestamp}] URL: {args.url} | {status_text} | "
            f"HTTP: {http_text} | response_time: {elapsed * 1000:.1f} ms"
        )
        if error:
            message += f" | error: {error}"
        print(message)
        if attempt + 1 < args.count:
            time.sleep(args.interval)

    return 0 if overall_up else 1


if __name__ == "__main__":
    raise SystemExit(main())
