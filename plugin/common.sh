# Shared settings/helpers for install.sh and uninstall.sh. Sourced, not executed.
# Every path/command is overridable via environment so the same scripts can target
# the dev harness nginx (see dev/) as well as the system nginx on a real Pi.

set -euo pipefail

PLUGIN_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CCAD_HOME="${CCAD_HOME:-$HOME/communitycad}"
CCAD_WEB_DIR="$CCAD_HOME/web"
CCAD_BACKUPS="$CCAD_HOME/backups"
CCAD_STATE="$CCAD_HOME/install-state"

NGINX_DIR="${NGINX_DIR:-/etc/nginx}"
NGINX_BIN="${NGINX_BIN:-nginx}"
NGINX_ARGS="${NGINX_ARGS:-}"
NGINX_RELOAD="${NGINX_RELOAD:-systemctl reload nginx}"
MAINSAIL_SITE="${MAINSAIL_SITE:-}"

HTTP_CONF="$NGINX_DIR/conf.d/communitycad.conf"
SERVER_CONF_DIR="$NGINX_DIR/communitycad"
SERVER_CONF="$SERVER_CONF_DIR/mainsail-server.conf"

MARK_BEGIN="# >>> communitycad (managed by communitycad install.sh; remove with uninstall.sh)"
MARK_END="# <<< communitycad"

if [[ -z "${SUDO+x}" ]]; then
    if [[ $EUID -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi
fi

TS="$(date +%Y%m%d-%H%M%S)"

log() { printf '[communitycad] %s\n' "$*"; }
die() { printf '[communitycad] ERROR: %s\n' "$*" >&2; exit 1; }

nginx_cmd() { $SUDO $NGINX_BIN $NGINX_ARGS "$@"; }
nginx_test() { nginx_cmd -t 2>&1; }
nginx_reload() { $SUDO $NGINX_RELOAD; }

# Copy a file into this run's backup dir, mirroring its absolute path.
backup_file() {
    local src="$1" dest
    [[ -e "$src" ]] || return 0
    dest="$CCAD_BACKUPS/$TS$(realpath "$src")"
    mkdir -p "$(dirname "$dest")"
    $SUDO cat "$src" >"$dest"
    printf '%s\n' "$dest"
}

site_root() {
    # First `root` directive in the file (Mainsail's static dir).
    $SUDO sed -nE 's/^[[:space:]]*root[[:space:]]+([^;]+);.*/\1/p' "$1" | head -n1
}

is_mainsail_dir() {
    local d="$1"
    [[ -f "$d/index.html" ]] || return 1
    grep -qs '"project_name"[[:space:]]*:[[:space:]]*"mainsail"' "$d/release_info.json" && return 0
    grep -qs '<title>Mainsail</title>' "$d/index.html"
}

find_mainsail_site() {
    if [[ -n "$MAINSAIL_SITE" ]]; then
        realpath "$MAINSAIL_SITE"
        return
    fi
    local f r found=()
    for f in "$NGINX_DIR"/sites-enabled/*; do
        [[ -e "$f" ]] || continue
        r="$(site_root "$f")"
        [[ -n "$r" ]] && is_mainsail_dir "$r" && found+=("$(realpath "$f")")
    done
    [[ ${#found[@]} -eq 1 ]] || die "expected exactly one enabled nginx site serving Mainsail, found ${#found[@]} (${found[*]:-none}). Set MAINSAIL_SITE=/path/to/site."
    printf '%s\n' "${found[0]}"
}

# Base URL of the site for post-install verification (first `listen` port on this host).
site_url() {
    if [[ -n "${VERIFY_URL:-}" ]]; then printf '%s\n' "$VERIFY_URL"; return; fi
    local listen port
    listen="$($SUDO sed -nE 's/^[[:space:]]*listen[[:space:]]+([^; ]+).*/\1/p' "$1" | head -n1)"
    port="${listen##*:}"
    printf 'http://127.0.0.1:%s\n' "${port:-80}"
}
