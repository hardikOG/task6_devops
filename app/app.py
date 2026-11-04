"""Demo storefront API. Stateless, so blue and green instances are interchangeable."""
import os
import threading
import time
import uuid

from flask import Flask, Response, g, jsonify, render_template, request
from prometheus_client import CONTENT_TYPE_LATEST, CollectorRegistry, Counter, Gauge, Histogram, generate_latest

UNINSTRUMENTED_PATHS = {"/metrics", "/health"}
# A deliberately broken release stays healthy for this many catalog requests, so it passes pre-switch checks.
LATE_FAILURE_AFTER_REQUESTS = 10

PRODUCTS = [
    {"id": 1, "name": "Mechanical Keyboard", "price": 4999},
    {"id": 2, "name": "Wireless Mouse", "price": 1499},
    {"id": 3, "name": "USB-C Hub", "price": 2299},
    {"id": 4, "name": "Laptop Stand", "price": 1899},
    {"id": 5, "name": "Noise-Cancelling Headphones", "price": 8999},
    {"id": 6, "name": "Webcam 1080p", "price": 3299},
]
PRICES = {product["id"]: product["price"] for product in PRODUCTS}


def create_app() -> Flask:
    """Build the app with its own metrics registry, so each instance counts independently."""
    app = Flask(__name__)
    version = os.environ.get("APP_VERSION", "dev")
    color = os.environ.get("APP_COLOR", "none")
    bad_release = os.environ.get("BAD_RELEASE", "none")

    catalog_lock = threading.Lock()
    catalog_requests = {"count": 0}

    registry = CollectorRegistry()
    requests_total = Counter(
        "shop_http_requests", "HTTP requests handled", ["method", "endpoint", "status"], registry=registry
    )
    request_duration = Histogram(
        "shop_http_request_duration_seconds", "HTTP request duration in seconds", ["endpoint"], registry=registry
    )
    orders_total = Counter("shop_orders", "Orders accepted", registry=registry)
    build_info = Gauge("shop_build_info", "Running release", ["version", "color"], registry=registry)
    build_info.labels(version, color).set(1)

    @app.before_request
    def start_timer() -> None:
        g.started_at = time.perf_counter()

    @app.after_request
    def finish_request(response: Response) -> Response:
        response.headers["X-App-Version"] = version
        response.headers["X-App-Color"] = color
        if request.path not in UNINSTRUMENTED_PATHS:
            # Flask's endpoint name, not the raw path, so scanners can't create unbounded label values.
            endpoint = request.endpoint or "unmatched"
            requests_total.labels(request.method, endpoint, str(response.status_code)).inc()
            request_duration.labels(endpoint).observe(time.perf_counter() - g.started_at)
        return response

    @app.get("/")
    def home() -> str:
        return render_template("index.html", version=version, color=color)

    @app.get("/health")
    def health() -> tuple[Response, int]:
        status = 503 if bad_release == "unhealthy" else 200
        state = "unhealthy" if status == 503 else "ok"
        return jsonify(status=state, version=version, color=color), status

    @app.get("/metrics")
    def metrics() -> Response:
        return Response(generate_latest(registry), content_type=CONTENT_TYPE_LATEST)

    @app.get("/api/products")
    def products() -> tuple[Response, int]:
        with catalog_lock:
            catalog_requests["count"] += 1
            served = catalog_requests["count"]
        if bad_release == "late" and served > LATE_FAILURE_AFTER_REQUESTS:
            return jsonify(error="catalog unavailable"), 500
        return jsonify(products=PRODUCTS), 200

    @app.post("/api/orders")
    def create_order() -> tuple[Response, int]:
        payload = request.get_json(silent=True)
        items = payload.get("items") if isinstance(payload, dict) else None
        if not isinstance(items, list) or not items:
            return jsonify(error="items must be a non-empty list"), 400

        total = 0
        for item in items:
            if not isinstance(item, dict):
                return jsonify(error="each item needs a product id and quantity"), 400
            product_id = item.get("id")
            quantity = item.get("quantity")
            if type(product_id) is not int or product_id not in PRICES:
                return jsonify(error=f"unknown product: {product_id}"), 400
            if type(quantity) is not int or quantity < 1:
                return jsonify(error="quantity must be a positive whole number"), 400
            total += PRICES[product_id] * quantity

        orders_total.inc()
        return jsonify(order_id=str(uuid.uuid4()), total=total, status="confirmed"), 201

    return app


app = create_app()
