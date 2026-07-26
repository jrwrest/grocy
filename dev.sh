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
    # Multi-household isolation harness. Fails until the feature is implemented —
    # that is the point: it is the definition of done.
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
