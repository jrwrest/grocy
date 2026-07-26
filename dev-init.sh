#!/usr/bin/with-contenv bash
# shellcheck shell=bash
#
# Replacement for the image's init-grocy-config step, mounted over it in
# docker-compose.dev.yml.
#
# The stock script does:
#     i=/app/www/data
#     if [[ -e "$i" && ! -L "$i" && -e /config/data ]]; then rm -Rf "$i"; ln -s /config/data "$i"; fi
#     if [[ -e "$i" && ! -L "$i" ]]; then mv "$i" /config/data; ln -s /config/data "$i"; fi
#
# With the git worktree bind-mounted at /app/www that DELETES tracked files
# (data/.gitignore, data/.htaccess, data/plugins/.gitignore) out of the repo.
#
# For development we want the opposite: keep data/ inside the worktree, where
# grocy's own data/.gitignore already excludes the database, viewcache and
# uploads from git. So: no symlink, no rm -Rf.

mkdir -p /app/www/data/viewcache /app/www/data/plugins /app/www/data/storage || :

if [[ ! -f /app/www/data/config.php ]]; then
    cp /app/www/config-dist.php /app/www/data/config.php
fi

if [[ ! -f /app/www/data/plugins/DemoBarcodeLookupPlugin.php ]]; then
    cp -R /defaults/plugins/. /app/www/data/plugins/ 2>/dev/null || :
fi

lsiown -R abc:abc /app/www/data || :
