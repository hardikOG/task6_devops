#!/usr/bin/env bash
# Blue-green release control. Usage:
#   deploy.sh deploy <version> [none|unhealthy|late]
#   deploy.sh rollback
#   deploy.sh status
set -euo pipefail

cd "$(dirname "$0")/.."

HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-90}"
POST_SWITCH_SECONDS="${POST_SWITCH_SECONDS:-30}"
MAX_POST_SWITCH_FAILURES="${MAX_POST_SWITCH_FAILURES:-3}"
ACTIVE_FILE=active_color
HISTORY_FILE=deploy-history.log
UPSTREAM_FILE=nginx/upstream/active.conf

compose() { docker compose --env-file .env --env-file release.env "$@"; }

log() { echo "[deploy] $*"; }

record() {
  log "$*"
  echo "$(date -u +%FT%TZ) $*" >> "$HISTORY_FILE"
}

active_color() { cat "$ACTIVE_FILE" 2>/dev/null || true; }

other_color() { if [ "$1" = blue ]; then echo green; else echo blue; fi; }

version_of() {
  local key
  key="$(echo "$1" | tr '[:lower:]' '[:upper:]')_VERSION"
  grep "^${key}=" release.env | cut -d= -f2-
}

set_version() {
  local key
  key="$(echo "$1" | tr '[:lower:]' '[:upper:]')_VERSION"
  sed -i "s|^${key}=.*|${key}=$2|" release.env
}

start_color() { compose up --detach --no-deps --force-recreate "app-$1"; }

wait_until_healthy() {
  local color=$1 container state deadline
  container=$(compose ps --quiet "app-$color")
  deadline=$((SECONDS + HEALTH_TIMEOUT_SECONDS))
  while [ "$SECONDS" -lt "$deadline" ]; do
    state=$(docker inspect --format '{{.State.Health.Status}}' "$container")
    log "app-$color health: $state"
    [ "$state" = healthy ] && return 0
    [ "$state" = unhealthy ] && return 1
    sleep 3
  done
  log "app-$color did not become healthy within ${HEALTH_TIMEOUT_SECONDS}s"
  return 1
}

smoke_test() { compose exec -T "app-$1" python smoke_test.py "$2"; }

# nginx finishes in-flight requests on its old workers during a reload, so no request is dropped.
switch_traffic() {
  local color=$1 previous_config=""
  [ -f "$UPSTREAM_FILE" ] && previous_config=$(cat "$UPSTREAM_FILE")
  printf 'upstream shop {\n    server app-%s:8000;\n}\n' "$color" > "$UPSTREAM_FILE"

  if [ -z "$(compose ps --quiet --status running nginx)" ]; then
    compose up --detach --no-deps nginx
  elif ! compose exec -T nginx nginx -t; then
    log "nginx rejected the new configuration, keeping the current one"
    [ -n "$previous_config" ] && printf '%s\n' "$previous_config" > "$UPSTREAM_FILE"
    return 1
  else
    compose exec -T nginx nginx -s reload
  fi
  echo "$color" > "$ACTIVE_FILE"
}

# Real requests through nginx, because some faults only appear once a release is serving traffic.
watch_after_switch() {
  local version=$1 failures=0 elapsed
  for ((elapsed = 0; elapsed < POST_SWITCH_SECONDS; elapsed++)); do
    if ! curl --fail --silent --max-time 3 http://localhost/health | grep -q "\"version\":\"$version\"" \
      || ! curl --fail --silent --max-time 3 --output /dev/null http://localhost/api/products; then
      failures=$((failures + 1))
      log "post-switch check failed ($failures of $MAX_POST_SWITCH_FAILURES allowed)"
      [ "$failures" -ge "$MAX_POST_SWITCH_FAILURES" ] && return 1
    fi
    sleep 1
  done
}

# Puts the standby back on the release it was running, so manual rollback still has a good target.
restore_standby() {
  local color=$1 version=$2
  set_version "$color" "$version"
  if [ "$version" = none ]; then
    compose stop "app-$color"
    compose rm --force "app-$color"
  else
    start_color "$color"
  fi
}

remove_unused_images() {
  local keep_blue keep_green image
  keep_blue=$(version_of blue)
  keep_green=$(version_of green)
  for image in $(docker images shop --format '{{.Tag}}'); do
    if [ "$image" != "$keep_blue" ] && [ "$image" != "$keep_green" ]; then
      # Cleanup only: a failure here must not fail a release that is already live.
      docker rmi "shop:$image" > /dev/null || log "could not remove image shop:$image"
    fi
  done
}

deploy() {
  local version=$1 bad_release=${2:-none} active target previous_target_version
  case "$bad_release" in
    none | unhealthy | late) ;;
    *)
      log "unknown bad-release mode: $bad_release"
      return 2
      ;;
  esac

  # A faulty build of the live commit must not take over the image tag the live release restarts from.
  [ "$bad_release" = none ] || version="$version-fault-$bad_release"

  active=$(active_color)
  if [ -n "$active" ]; then target=$(other_color "$active"); else target=blue; fi
  previous_target_version=$(version_of "$target")
  record "START version=$version target=$target active=${active:-none} bad_release=$bad_release"

  docker build --tag "shop:$version" --build-arg "APP_VERSION=$version" --build-arg "BAD_RELEASE=$bad_release" ./app
  set_version "$target" "$version"
  start_color "$target"

  if ! wait_until_healthy "$target" || ! smoke_test "$target" "$version"; then
    restore_standby "$target" "$previous_target_version"
    record "REJECTED version=$version reason=failed-pre-switch-checks traffic-stayed-on=${active:-none}"
    return 1
  fi

  switch_traffic "$target"
  record "SWITCHED version=$version traffic-on=$target"

  if ! watch_after_switch "$version"; then
    if [ -z "$active" ]; then
      record "FAILED version=$version reason=failed-post-switch-checks no-previous-release"
      return 1
    fi
    switch_traffic "$active"
    restore_standby "$target" "$previous_target_version"
    record "ROLLED_BACK version=$version reason=failed-post-switch-checks traffic-on=$active"
    return 1
  fi

  remove_unused_images
  record "SUCCESS version=$version traffic-on=$target"
}

rollback() {
  local active target version
  active=$(active_color)
  if [ -z "$active" ]; then
    log "nothing is deployed yet"
    return 1
  fi
  target=$(other_color "$active")
  version=$(version_of "$target")
  if [ "$version" = none ]; then
    log "no previous release to roll back to"
    return 1
  fi
  record "MANUAL_ROLLBACK_START version=$version target=$target"
  if [ -z "$(compose ps --quiet --status running "app-$target")" ]; then
    start_color "$target"
  fi
  wait_until_healthy "$target"
  smoke_test "$target" "$version"
  switch_traffic "$target"
  record "MANUAL_ROLLBACK_DONE version=$version traffic-on=$target"
}

status() {
  local active
  active=$(active_color)
  echo "active: ${active:-none}"
  echo "blue:   $(version_of blue)"
  echo "green:  $(version_of green)"
  compose ps --format '{{.Service}}: {{.Status}}'
  echo "live:   $(curl --silent --max-time 3 http://localhost/health || echo 'no response')"
}

exec 9> .deploy.lock
if [ "${1:-}" != status ] && ! flock --nonblock 9; then
  log "another deployment is already running"
  exit 3
fi

case "${1:-}" in
  deploy)
    [ $# -ge 2 ] || { log "usage: deploy.sh deploy <version> [none|unhealthy|late]"; exit 2; }
    deploy "$2" "${3:-none}"
    ;;
  rollback) rollback ;;
  status) status ;;
  *)
    log "usage: deploy.sh deploy|rollback|status"
    exit 2
    ;;
esac
