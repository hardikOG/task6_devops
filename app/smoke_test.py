"""Exercises a new release's main shopping flow before it receives any traffic."""
import json
import sys
import urllib.error
import urllib.request

BASE_URL = "http://localhost:8000"


def request_json(path: str, payload: dict | None = None) -> tuple[int, dict]:
    """Send a GET, or a POST when a payload is given, and return the status and JSON body."""
    body = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(BASE_URL + path, data=body, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, {}


def main(expected_version: str) -> int:
    """Return 0 if the release serves the expected version, its catalog and an order."""
    status, health = request_json("/health")
    if status != 200 or health.get("version") != expected_version:
        print(f"FAILED health: status={status} version={health.get('version')} expected={expected_version}")
        return 1

    status, catalog = request_json("/api/products")
    if status != 200 or not catalog.get("products"):
        print(f"FAILED catalog: status={status}")
        return 1

    first_product = catalog["products"][0]
    status, order = request_json("/api/orders", {"items": [{"id": first_product["id"], "quantity": 2}]})
    if status != 201 or order.get("total") != first_product["price"] * 2:
        print(f"FAILED order: status={status} total={order.get('total')}")
        return 1

    print(f"Smoke test passed for {expected_version}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
