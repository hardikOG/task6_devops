FROM python:3.12-slim

WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py smoke_test.py ./
COPY templates ./templates

RUN useradd --system --no-create-home appuser
USER appuser

ARG APP_VERSION=dev
ENV APP_VERSION=$APP_VERSION
# Fault injection for rollback demonstrations: none, unhealthy or late.
ARG BAD_RELEASE=none
ENV BAD_RELEASE=$BAD_RELEASE

EXPOSE 8000
HEALTHCHECK --interval=5s --timeout=3s --start-period=5s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health', timeout=2)"

# One worker with threads: prometheus_client keeps counters per process, so more workers would split them.
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "1", "--threads", "8", "--graceful-timeout", "30", "--access-logfile", "-", "app:app"]
