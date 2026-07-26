#!/usr/bin/env bash
# Dev-instance helper for the multi-household work.
#   ./dev.sh up | down | reset | test | flush | logs | shell | db
set -euo pipefail

cd "$(dirname "$0")"
COMPOSE=(docker compose -f docker-compose.dev.yml)
DATA=./data

seed() {
  # the container's dev-init.sh seeds config.php/plugins/viewcache itself
  mkdir -p "$DATA"
}

# Self-registration ships OFF (see config-dist.php). Turn it ON for the dev
# instance so ./dev.sh test exercises the whole of phase 5 rather than just the
# "refused when disabled" path.
enable_self_registration() {
  # config.php starts as a copy of config-dist.php, where the flag is false, so
  # this must FLIP the existing setting - appending a second Setting() call would
  # be ignored, since Setting() only defines a constant that is not already set.
  if docker exec grocy-dev grep -q "FEATURE_FLAG_SELF_REGISTRATION', false" /app/www/data/config.php 2>/dev/null; then
    docker exec grocy-dev sed -i "s/FEATURE_FLAG_SELF_REGISTRATION', false/FEATURE_FLAG_SELF_REGISTRATION', true/" /app/www/data/config.php
    docker exec grocy-dev sh -c 'rm -rf /app/www/data/viewcache/*' 2>/dev/null || true
    echo "self-registration enabled for dev (shipped default stays off)"
  fi
}

case "${1:-up}" in
  up)
    seed
    "${COMPOSE[@]}" up -d
    docker exec grocy-dev sh -c 'rm -rf /app/www/data/viewcache/*' 2>/dev/null || true
    printf 'waiting for http://localhost:9284 '
    for _ in $(seq 1 30); do
      code=$(curl -s -o /dev/null -m 5 -w "%{http_code}" -L http://localhost:9284/ || true)
      if [[ "$code" == "200" ]]; then
        echo " ready (http 200)"
        # config.php is created by the container's init, so this has to happen
        # after it is up, not before
        enable_self_registration
        echo "login: admin / admin"
        exit 0
      fi
      printf '.'
      sleep 2
    done
    echo " TIMED OUT — check ./dev.sh logs"
    exit 1
    ;;
  down)
    "${COMPOSE[@]}" down
    ;;
  reset)
    "${COMPOSE[@]}" down || true
    rm -f "$DATA"/grocy.db "$DATA"/config.php
    rm -rf "$DATA"/viewcache "$DATA"/storage
    echo "dev database wiped (tracked files in data/ left alone)"
    exec "$0" up
    ;;
  test)
    # Warm the app first. Grocy caches its routes in data/viewcache, so the first
    # request after a flush rebuilds them and can return nothing — which showed up
    # as a positive control failing on the first run after ./dev.sh reset. Warming
    # here means the harness never measures a cold app.
    for _ in 1 2 3; do
      curl -s -o /dev/null -m 10 http://localhost:9284/login || true
    done
    docker exec grocy-dev php /app/www/tests/multihousehold/isolation_test.php
    ;;
  flush)
    # Not normally needed — Blade recompiles changed views automatically and PHP
    # source is picked up immediately. Here only as a fallback if the compiled
    # view cache is ever suspected of being stale.
    docker exec grocy-dev sh -c 'rm -rf /app/www/data/viewcache/*' || true
    echo "view cache flushed"
    ;;
  logs)
    "${COMPOSE[@]}" logs -f --tail=50
    ;;
  shell)
    docker exec -it grocy-dev bash
    ;;
  db)
    # quick sqlite query:  ./dev.sh db "select count(*) from products"
    docker exec grocy-dev php -r '
      $d = new PDO("sqlite:/app/www/data/grocy.db");
      foreach ($d->query($argv[1]) as $row) {
        echo implode(" | ", array_filter($row, "is_scalar", ARRAY_FILTER_USE_KEY ^ 0)), "\n";
      }' -- "${2:?usage: ./dev.sh db \"SQL\"}"
    ;;
  *)
    echo "usage: $0 {up|down|reset|test|flush|logs|shell|db}" >&2
    exit 1
    ;;
esac
