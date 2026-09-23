#!/usr/bin/env bash
# Inject the CommunityCAD script into Mainsail via nginx sub_filter.
# Idempotent: re-running changes nothing if already installed (the web files are refreshed).
# Never touches Mainsail's own files. Backs up every nginx file it changes to $CCAD_HOME/backups.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# --- preflight -------------------------------------------------------------------------
command -v "$NGINX_BIN" >/dev/null || die "nginx binary '$NGINX_BIN' not found"
if ! nginx_cmd -V 2>&1 | grep -q -- '--with-http_sub_module'; then
    die "this nginx was built without ngx_http_sub_module (sub_filter), so the injection cannot work. Nothing was changed. On Debian 11 this means nginx-light; install nginx-core or nginx-full."
fi

SITE="$(find_mainsail_site)"
ROOT="$(site_root "$SITE")"
log "Mainsail site: $SITE (root $ROOT, version $(cat "$ROOT/.version" 2>/dev/null || echo unknown))"

# gzip_static serves index.html.gz as-is; sub_filter skips encoded responses, so injection
# would silently not happen. Mainsail releases ship no .gz files today; refuse if they appear.
if $SUDO grep -rqsE '^[[:space:]]*gzip_static[[:space:]]+(on|always)' "$NGINX_DIR"; then
    if [[ -e "$ROOT/index.html.gz" || -e "$ROOT/sw.js.gz" ]]; then
        die "gzip_static is enabled and $ROOT contains index.html.gz/sw.js.gz; sub_filter would be bypassed. Set 'gzip_static off;' for Mainsail's server (see REPORT.md, criterion B). Nothing was changed."
    fi
    log "WARNING: gzip_static is enabled somewhere under $NGINX_DIR. Fine today (no .gz files), but injection will stop if pre-compressed files ever appear."
fi

# --- web files (ours, outside Mainsail's dir) ------------------------------------------
mkdir -p "$CCAD_WEB_DIR" "$CCAD_BACKUPS"
chmod 755 "$CCAD_HOME" "$CCAD_WEB_DIR"
install -m 644 "$PLUGIN_SRC/web/inject.js" "$CCAD_WEB_DIR/inject.js"

# --- nginx config ----------------------------------------------------------------------
BACKED_UP=()
changed=0

# Write $2 (content) to $1 as root, backing up an existing different version first.
put_conf() {
    local dest="$1" content="$2"
    if [[ -e "$dest" ]] && [[ "$($SUDO cat "$dest")" == "$content" ]]; then return 0; fi
    [[ -e "$dest" ]] && BACKED_UP+=("$(backup_file "$dest")")
    $SUDO mkdir -p "$(dirname "$dest")"
    printf '%s\n' "$content" | $SUDO tee "$dest" >/dev/null
    changed=1
}

put_conf "$HTTP_CONF" "$(cat "$PLUGIN_SRC/nginx/communitycad-http.conf")"
put_conf "$SERVER_CONF" "$(sed "s|@CCAD_WEB_DIR@|$CCAD_WEB_DIR|g" "$PLUGIN_SRC/nginx/communitycad-server.conf")"

SITE_BACKUP=""
if $SUDO grep -qF "$MARK_BEGIN" "$SITE"; then
    log "include already present in $SITE"
else
    SITE_BACKUP="$(backup_file "$SITE")"
    BACKED_UP+=("$SITE_BACKUP")
    # Add the include as the first statement of every server block in the site file.
    $SUDO awk -v b="$MARK_BEGIN" -v e="$MARK_END" -v inc="include $SERVER_CONF;" '
        { print }
        /^[[:space:]]*server[[:space:]]*\{[[:space:]]*$/ { print "    " b; print "    " inc; print "    " e }
    ' "$SITE_BACKUP" | $SUDO tee "$SITE" >/dev/null
    $SUDO grep -qF "$MARK_BEGIN" "$SITE" || { $SUDO cp "$SITE_BACKUP" "$SITE"; die "no 'server {' line found in $SITE"; }
    changed=1
fi

for b in "${BACKED_UP[@]}"; do log "backed up -> $b"; done

if [[ $changed -eq 1 ]]; then
    if ! out="$(nginx_test)"; then
        printf '%s\n' "$out" >&2
        log "nginx -t failed, rolling back"
        [[ -n "$SITE_BACKUP" ]] && $SUDO cp "$SITE_BACKUP" "$SITE"
        $SUDO rm -f "$HTTP_CONF" "$SERVER_CONF"
        $SUDO rmdir "$SERVER_CONF_DIR" 2>/dev/null || true
        die "install aborted; nginx config restored"
    fi
    nginx_reload
    log "nginx reloaded"
    # Only after success: uninstall uses this to compare against the pre-install site file.
    [[ -n "$SITE_BACKUP" ]] && printf 'SITE=%s\nSITE_ORIGINAL=%s\n' "$SITE" "$SITE_BACKUP" >"$CCAD_STATE"
else
    log "nginx config already up to date"
fi

# --- verify ----------------------------------------------------------------------------
URL="$(site_url "$SITE")"
sleep 0.5
if curl -fsS "$URL/" | grep -q '/communitycad/inject.js'; then log "verified: $URL/ contains the script tag"; else log "WARNING: script tag not found at $URL/"; fi
if curl -fsS "$URL/sw.js" | grep -q 'revision:"ccad1-'; then log "verified: $URL/sw.js is rewritten"; else log "WARNING: sw.js not rewritten; PWA users may keep a stale page"; fi
curl -fsS -o /dev/null "$URL/communitycad/inject.js" && log "verified: $URL/communitycad/inject.js is served" || log "WARNING: inject.js not reachable (check that nginx can read $CCAD_WEB_DIR)"
