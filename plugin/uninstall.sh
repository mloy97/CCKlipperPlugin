#!/usr/bin/env bash
# Remove the CommunityCAD injection. Idempotent. Backs up every nginx file it changes or
# removes to $CCAD_HOME/backups, then checks the served page is byte-identical to Mainsail's.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SITE=""
SITE_ORIGINAL=""
[[ -f "$CCAD_STATE" ]] && source "$CCAD_STATE"
if [[ -z "$SITE" ]]; then
    SITE="$(grep -lF "$MARK_BEGIN" "$NGINX_DIR"/sites-available/* 2>/dev/null | head -n1 || true)"
fi

changed=0
BACKED_UP=()

if [[ -n "$SITE" ]] && $SUDO grep -qF "$MARK_BEGIN" "$SITE"; then
    bk="$(backup_file "$SITE")"
    BACKED_UP+=("$bk")
    $SUDO awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
        index($0, b) { skip = 1; next }
        skip && index($0, e) { skip = 0; next }
        !skip { print }
    ' "$bk" | $SUDO tee "$SITE" >/dev/null
    changed=1
    if [[ -n "$SITE_ORIGINAL" && -f "$SITE_ORIGINAL" ]]; then
        if $SUDO cmp -s "$SITE" "$SITE_ORIGINAL"; then
            log "$SITE is byte-identical to its pre-install backup"
        else
            log "NOTE: $SITE differs from its pre-install backup ($SITE_ORIGINAL), presumably edited since install:"
            $SUDO diff "$SITE_ORIGINAL" "$SITE" || true
        fi
    fi
else
    log "no include found in nginx site config"
fi

for f in "$HTTP_CONF" "$SERVER_CONF"; do
    if [[ -e "$f" ]]; then
        BACKED_UP+=("$(backup_file "$f")")
        $SUDO rm -f "$f"
        changed=1
    fi
done
$SUDO rmdir "$SERVER_CONF_DIR" 2>/dev/null || true

for b in "${BACKED_UP[@]}"; do log "backed up -> $b"; done

if [[ $changed -eq 1 ]]; then
    if ! out="$(nginx_test)"; then
        printf '%s\n' "$out" >&2
        die "nginx -t failed after removal; backups are in $CCAD_BACKUPS/$TS. nginx was NOT reloaded."
    fi
    nginx_reload
    log "nginx reloaded"
fi

rm -rf "$CCAD_WEB_DIR"
rm -f "$CCAD_STATE"
log "removed $CCAD_WEB_DIR (backups kept in $CCAD_BACKUPS)"

# --- verify the served page is stock ---------------------------------------------------
if [[ -n "$SITE" ]]; then
    URL="$(site_url "$SITE")"
    ROOT="$(site_root "$SITE")"
    sleep 0.5
    for f in index.html sw.js; do
        if curl -fsS "$URL/$f" | cmp -s - "$ROOT/$f"; then
            log "verified: served /$f is byte-identical to $ROOT/$f"
        else
            log "WARNING: served /$f differs from $ROOT/$f"
        fi
    done
fi
