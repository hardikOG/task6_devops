import pytest
from flask.testing import FlaskClient

from app import LATE_FAILURE_AFTER_REQUESTS, PRODUCTS, create_app


def make_client(monkeypatch: pytest.MonkeyPatch, bad_release: str = "none") -> FlaskClient:
    monkeypatch.setenv("APP_VERSION", "test-version")
    monkeypatch.setenv("APP_COLOR", "green")
    monkeypatch.setenv("BAD_RELEASE", bad_release)
    return create_app().test_client()


@pytest.fixture
def client(monkeypatch: pytest.MonkeyPatch) -> FlaskClient:
    return make_client(monkeypatch)


def test_home_shows_store_and_release(client: FlaskClient) -> None:
    response = client.get("/")
    assert response.status_code == 200
    assert b"Hardik" in response.data
    assert b"green" in response.data
    assert b"test-version" in response.data


def test_responses_identify_the_release(client: FlaskClient) -> None:
    response = client.get("/health")
    assert response.headers["X-App-Version"] == "test-version"
    assert response.headers["X-App-Color"] == "green"
    assert response.get_json() == {"status": "ok", "version": "test-version", "color": "green"}


def test_products_are_listed(client: FlaskClient) -> None:
    response = client.get("/api/products")
    assert response.status_code == 200
    assert response.get_json()["products"] == PRODUCTS


def test_order_total_is_calculated_on_the_server(client: FlaskClient) -> None:
    response = client.post("/api/orders", json={"items": [{"id": 1, "quantity": 2}, {"id": 2, "quantity": 1}]})
    assert response.status_code == 201
    assert response.get_json()["total"] == PRODUCTS[0]["price"] * 2 + PRODUCTS[1]["price"]


@pytest.mark.parametrize(
    "payload",
    [
        {},
        {"items": []},
        {"items": "keyboard"},
        {"items": ["keyboard"]},
        {"items": [{"id": 999, "quantity": 1}]},
        {"items": [{"id": 1, "quantity": 0}]},
        {"items": [{"id": 1, "quantity": -1}]},
        {"items": [{"id": 1, "quantity": 1.5}]},
        {"items": [{"id": 1, "quantity": True}]},
        {"items": [{"id": [1], "quantity": 1}]},
    ],
)
def test_invalid_orders_are_rejected(client: FlaskClient, payload: dict) -> None:
    assert client.post("/api/orders", json=payload).status_code == 400


def test_non_json_order_is_rejected(client: FlaskClient) -> None:
    response = client.post("/api/orders", data="not json", content_type="text/plain")
    assert response.status_code == 400


def test_metrics_report_release_and_orders(client: FlaskClient) -> None:
    client.post("/api/orders", json={"items": [{"id": 1, "quantity": 1}]})
    body = client.get("/metrics").data.decode()
    assert 'shop_build_info{color="green",version="test-version"} 1.0' in body
    assert "shop_orders_total 1.0" in body


def test_unknown_paths_share_one_metric_label(client: FlaskClient) -> None:
    client.get("/wp-login.php")
    body = client.get("/metrics").data.decode()
    assert 'endpoint="unmatched"' in body
    assert "wp-login" not in body


def test_unhealthy_release_fails_its_health_check(monkeypatch: pytest.MonkeyPatch) -> None:
    client = make_client(monkeypatch, "unhealthy")
    assert client.get("/health").status_code == 503


def test_late_failing_release_passes_early_then_fails(monkeypatch: pytest.MonkeyPatch) -> None:
    client = make_client(monkeypatch, "late")
    assert client.get("/health").status_code == 200
    for _ in range(LATE_FAILURE_AFTER_REQUESTS):
        assert client.get("/api/products").status_code == 200
    assert client.get("/api/products").status_code == 500
