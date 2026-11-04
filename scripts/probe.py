"""Sends steady traffic during a release and reports every failure and which release answered."""
import argparse
import collections
import json
import time
import urllib.error
import urllib.request


def probe_once(url: str, timeout: float) -> tuple[str, str]:
    """Return the outcome ('200', '502', 'connection-error') and the release that served it."""
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            response.read()
            release = f"{response.headers.get('X-App-Color')}/{(response.headers.get('X-App-Version') or '')[:12]}"
            return str(response.status), release
    except urllib.error.HTTPError as error:
        return str(error.code), f"{error.headers.get('X-App-Color')}/{(error.headers.get('X-App-Version') or '')[:12]}"
    except (urllib.error.URLError, TimeoutError, ConnectionError) as error:
        return "connection-error", type(error).__name__


def main() -> None:
    """Probe until the duration ends, then print one JSON summary."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://localhost/api/products")
    parser.add_argument("--seconds", type=float, required=True)
    parser.add_argument("--rate", type=float, default=20, help="requests per second")
    parser.add_argument("--timeout", type=float, default=5)
    args = parser.parse_args()

    outcomes: collections.Counter[str] = collections.Counter()
    releases: dict[str, dict[str, float]] = {}
    slowest = 0.0
    started = time.monotonic()
    while (now := time.monotonic()) - started < args.seconds:
        outcome, release = probe_once(args.url, args.timeout)
        finished = time.monotonic()
        slowest = max(slowest, finished - now)
        outcomes[outcome] += 1
        seen = releases.setdefault(release, {"first_s": round(now - started, 1), "requests": 0})
        seen["requests"] += 1
        seen["last_s"] = round(now - started, 1)
        time.sleep(max(0.0, 1 / args.rate - (finished - now)))

    total = sum(outcomes.values())
    print(
        json.dumps(
            {
                "url": args.url,
                "duration_s": round(time.monotonic() - started, 1),
                "requests": total,
                "failed": total - outcomes["200"],
                "outcomes": dict(outcomes),
                "slowest_response_s": round(slowest, 3),
                "served_by": releases,
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
