#!/usr/bin/env bash
# Dev harness: a sandboxed, unprivileged nginx on 127.0.0.1:8088 that mirrors a Mainsail
# host's nginx setup (same binary, same site file, same conf.d) without touching /etc/nginx.
# Klipper/Moonraker come from the host (or virtual-klipper-printer on 127.0.0.1:7125).
#
#   harness.sh setup <mainsail.zip|mainsail-dir>   create .run/ with a Mainsail copy
#   harness.sh start | stop | reload
#   harness.sh swap-mainsail <mainsail.zip>        simulate a Mainsail update (replace files)
#   harness.sh env                                 print env vars that point install.sh here
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="$HERE/.run"
PORT="${PORT:-8088}"
SRC_SITE="${SRC_SITE:-$HERE/mainsail-site.conf}"
NGINX_ARGS="-p $RUN -c $RUN/etc/nginx.conf -e $RUN/logs/error.log"

put_mainsail() {
    rm -rf "$RUN/mainsail"
    mkdir -p "$RUN/mainsail"
    if [[ -d "$1" ]]; then cp -a "$1/." "$RUN/mainsail/"; else unzip -q "$1" -d "$RUN/mainsail"; fi
    echo "mainsail $(cat "$RUN/mainsail/.version" 2>/dev/null || echo '?') in $RUN/mainsail"
}

case "${1:-}" in
setup)
    [[ -n "${2:-}" ]] || { echo "usage: $0 setup <mainsail.zip|dir>"; exit 1; }
    "$0" stop 2>/dev/null || true
    rm -rf "$RUN"
    mkdir -p "$RUN"/{etc/conf.d,etc/sites-available,etc/sites-enabled,logs,tmp}
    put_mainsail "$2"
    cp "$HERE"/conf.d/*.conf "$RUN/etc/conf.d/"
    sed -e "s|^\( *\)listen .*|\1listen 127.0.0.1:$PORT;|" \
        -e "s|/var/log/nginx/|$RUN/logs/|" \
        -e "s|^\( *\)root .*|\1root $RUN/mainsail;|" \
        "$SRC_SITE" >"$RUN/etc/sites-available/mainsail"
    ln -s "$RUN/etc/sites-available/mainsail" "$RUN/etc/sites-enabled/mainsail"
    cat >"$RUN/etc/nginx.conf" <<EOF
worker_processes 1;
pid $RUN/nginx.pid;
events { worker_connections 256; }
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    sendfile on;
    access_log $RUN/logs/access.log;
    client_body_temp_path $RUN/tmp/body;
    proxy_temp_path $RUN/tmp/proxy;
    fastcgi_temp_path $RUN/tmp/fastcgi;
    uwsgi_temp_path $RUN/tmp/uwsgi;
    scgi_temp_path $RUN/tmp/scgi;
    gzip on;
    include $RUN/etc/conf.d/*.conf;
    include $RUN/etc/sites-enabled/*;
}
EOF
    echo "harness ready; run: $0 start"
    ;;
start) nginx $NGINX_ARGS && echo "serving http://127.0.0.1:$PORT/" ;;
stop) [[ -f "$RUN/nginx.pid" ]] && nginx $NGINX_ARGS -s stop || true ;;
reload) nginx $NGINX_ARGS -s reload ;;
swap-mainsail) put_mainsail "$2" ;;
env)
    cat <<EOF
export NGINX_DIR='$RUN/etc' NGINX_ARGS='$NGINX_ARGS' NGINX_RELOAD='nginx $NGINX_ARGS -s reload'
export SUDO='' CCAD_HOME='$RUN/communitycad' VERIFY_URL='http://127.0.0.1:$PORT'
EOF
    ;;
*) sed -n '2,11p' "$0"; exit 1 ;;
esac
