#!/usr/bin/env bash
#
# Rehearses the multi-household migrations against a COPY of a real database,
# on a separate port and a separate data directory, so nothing touches either
# production or the working dev instance.
#
#   ./rehearse.sh /path/to/snapshot.db
#
# Take the snapshot from production WITHOUT downtime or write access:
#   ssh root@HOST 'docker exec grocy php -r "
#     \$d = new PDO(\"sqlite:/config/data/grocy.db\");
#     \$d->exec(\"VACUUM INTO '\''/config/data/snapshot.db'\''\");"'
#   scp root@HOST:/opt/grocy/config/data/snapshot.db ./snapshot.db
#
# VACUUM INTO produces a consistent copy of a live SQLite database; a plain cp
# can catch it mid-write.
set -euo pipefail

cd "$(dirname "$0")"

SNAPSHOT="${1:-}"
if [[ -z "$SNAPSHOT" || ! -f "$SNAPSHOT" ]]; then
  echo "usage: $0 /path/to/snapshot.db" >&2
  exit 1
fi

DATA=./rehearsal-data
PORT=9285
NAME=grocy-rehearsal

cleanup_container() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}

echo "=== preparing a throwaway copy ==="
cleanup_container
rm -rf "$DATA"
mkdir -p "$DATA/viewcache" "$DATA/plugins" "$DATA/storage"
cp "$SNAPSHOT" "$DATA/grocy.db"
cp config-dist.php "$DATA/config.php"
BEFORE_VERSION=$(python3 - "$DATA/grocy.db" <<'PY'
import sqlite3, sys
print(sqlite3.connect(sys.argv[1]).execute('SELECT MAX(migration) FROM migrations').fetchone()[0])
PY
)
echo "  snapshot db_version: $BEFORE_VERSION"

# Row counts BEFORE, for every table in the snapshot
python3 - "$DATA/grocy.db" > /tmp/rehearsal-before.json <<'PY'
import sqlite3, sys, json
c = sqlite3.connect(sys.argv[1])
tables = [r[0] for r in c.execute(
    'SELECT name FROM sqlite_master WHERE type="table" AND name NOT LIKE "sqlite_%"')]
print(json.dumps({t: c.execute(f'SELECT COUNT(*) FROM "{t}"').fetchone()[0] for t in tables}))
PY

echo
echo "=== starting rehearsal instance on :$PORT (migrations run on first request) ==="
docker run -d --name "$NAME" \
  -e PUID=501 -e PGID=20 -e TZ=Europe/Madrid \
  -v "$PWD":/app/www \
  -v "$PWD/dev-init.sh":/etc/s6-overlay/s6-rc.d/init-grocy-config/run:ro \
  -v "$PWD/$DATA":/app/www/data \
  -p "127.0.0.1:$PORT:80" \
  lscr.io/linuxserver/grocy:latest >/dev/null

printf '  waiting '
for _ in $(seq 1 40); do
  code=$(curl -s -o /dev/null -m 5 -w "%{http_code}" -L "http://localhost:$PORT/" || true)
  if [[ "$code" == "200" ]]; then echo " up (http 200)"; break; fi
  printf '.'
  sleep 2
done

echo
echo "=== RESULT ==="
docker exec "$NAME" php -r '
$d = new PDO("sqlite:/app/www/data/grocy.db");
printf("  db_version now: %s\n", $d->query("SELECT MAX(migration) FROM migrations")->fetchColumn());
printf("  households:     %s\n", $d->query("SELECT COUNT(*) FROM households")->fetchColumn());
printf("  views:          %s\n", $d->query("SELECT COUNT(*) FROM sqlite_master WHERE type=\"view\"")->fetchColumn());
printf("  triggers:       %s\n", $d->query("SELECT COUNT(*) FROM sqlite_master WHERE type=\"trigger\"")->fetchColumn());
'

echo
echo "=== data preserved? (before vs after, per table) ==="
python3 - "$DATA/grocy.db" /tmp/rehearsal-before.json <<'PY'
import sqlite3, sys, json
after_db, before_file = sys.argv[1], sys.argv[2]
before = json.load(open(before_file))
c = sqlite3.connect(after_db)
bad = []
for t, n_before in sorted(before.items()):
    if t == 'migrations':
        # expected to grow: it is the schema-version ledger, one row per migration
        n_after = c.execute('SELECT COUNT(*) FROM migrations').fetchone()[0]
        print(f'  ok   {t:34} {n_before} -> {n_after} (new migrations recorded)')
        continue
    try:
        n_after = c.execute(f'SELECT COUNT(*) FROM "{t}"').fetchone()[0]
    except sqlite3.Error as e:
        bad.append((t, n_before, f'MISSING ({e})'))
        continue
    if n_after != n_before:
        bad.append((t, n_before, n_after))
    elif n_before:
        print(f'  ok   {t:34} {n_before}')
if bad:
    print('\n  ROW COUNT CHANGES:')
    for t, b, a in bad:
        print(f'  FAIL {t:34} before={b} after={a}')
    sys.exit(1)
print('\n  every table preserved its row count')
PY

echo
echo "=== every pre-existing row assigned to household 1? ==="
docker exec "$NAME" php -r '
$d = new PDO("sqlite:/app/www/data/grocy.db");
$bad = 0;
foreach ($d->query("SELECT name FROM sqlite_master WHERE type=\"table\" AND name NOT LIKE \"sqlite_%\"") as $r) {
  $t = $r["name"];
  $cols = [];
  foreach ($d->query("PRAGMA table_info($t)") as $c) $cols[] = $c["name"];
  if (!in_array("household_id", $cols)) continue;
  $n = $d->query("SELECT COUNT(*) FROM $t WHERE household_id != 1 OR household_id IS NULL")->fetchColumn();
  if ($n > 0) { printf("  FAIL %-30s %s rows not in household 1\n", $t, $n); $bad++; }
}
echo $bad === 0 ? "  all scoped rows are in household 1\n" : "";
exit($bad === 0 ? 0 : 1);
'
