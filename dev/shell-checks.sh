#!/usr/bin/env bash
# Non-browser checks against the dev harness: B (gzip_static), E (byte-for-byte uninstall +
# idempotency), F (no sub module / nginx -t failure rollback). Writes dev/evidence/*.txt.
# Expects: harness running, plugin NOT installed.
set -uo pipefail
cd "$(dirname "$0")/.."
eval "$(dev/harness.sh env)"
R=dev/.run
U=http://127.0.0.1:8088
SITE=$R/etc/sites-available/mainsail
TMP="$(mktemp -d)"
EV=dev/evidence
mkdir -p "$EV"
short() { sha256sum | cut -c1-16; }
clean() { sed "s|$PWD/||g"; }

# ---------------------------------------------------------------------------------------- B
{
    echo "### B: gzip_static (harness, Mainsail $(cat $R/mainsail/.version))"
    echo "--- stock KIAUH/MainsailOS config, plugin installed:"
    plugin/install.sh >/dev/null
    echo "gzip-negotiating client: $(curl -s --compressed $U/ | grep -c inject.js) script tag(s); identity client: $(curl -s $U/ | grep -c inject.js)"
    echo "precompressed files in Mainsail dir: $(find $R/mainsail -name '*.gz' | wc -l)"
    echo "--- add 'gzip_static on;' at http level + index.html.gz/sw.js.gz (a web UI that ships precompressed files):"
    sed -i 's/^    gzip on;/    gzip on;\n    gzip_static on;/' $R/etc/nginx.conf
    gzip -k9 $R/mainsail/index.html $R/mainsail/sw.js
    $NGINX_RELOAD; sleep 0.5
    echo "gzip-negotiating client: $(curl -s --compressed $U/ | grep -c inject.js) script tag(s)   <-- silently skipped"
    echo "identity client (curl default): $(curl -s $U/ | grep -c inject.js) script tag(s)   <-- why it's easy to miss"
    echo "sw.js rewritten for gzip client: $(curl -s --compressed $U/sw.js | grep -c 'ccad1-')"
    curl -s -D- -o /dev/null -H 'Accept-Encoding: gzip' $U/ | grep -iE '^content-encoding'
    echo "--- installer on this setup:"
    plugin/uninstall.sh >/dev/null
    plugin/install.sh 2>&1 | tail -1 | clean
    echo "install.sh exit=${PIPESTATUS[0]}; include present: $(grep -c '>>> communitycad' $SITE)"
    echo "--- fix: 'gzip_static off;' in Mainsail's server scope (demonstrated by adding it to our include):"
    mv $R/mainsail/index.html.gz $R/mainsail/sw.js.gz "$TMP/"
    plugin/install.sh >/dev/null
    mv "$TMP"/index.html.gz "$TMP"/sw.js.gz $R/mainsail/
    sed -i '1a gzip_static off;' $R/etc/communitycad/mainsail-server.conf
    $NGINX_RELOAD; sleep 0.5
    echo "gzip-negotiating client: $(curl -s --compressed $U/ | grep -c inject.js) script tag(s); sw.js rewritten: $(curl -s --compressed $U/sw.js | grep -c 'ccad1-')"
    plugin/uninstall.sh >/dev/null
    rm -f $R/mainsail/index.html.gz $R/mainsail/sw.js.gz
    sed -i '/gzip_static on;/d' $R/etc/nginx.conf
    $NGINX_RELOAD; sleep 0.5
} 2>&1 | tee $EV/B-gzip-static.txt

# ---------------------------------------------------------------------------------------- E
{
    echo "### E + idempotency (harness, Mainsail $(cat $R/mainsail/.version))"
    cp $SITE "$TMP/site.pristine"
    echo "stock served: /=$(curl -s $U/ | short) sw.js=$(curl -s $U/sw.js | short)   on disk: index.html=$(short <$R/mainsail/index.html) sw.js=$(short <$R/mainsail/sw.js)"
    echo "--- install #1"; plugin/install.sh | clean
    echo "--- install #2 (idempotency)"; plugin/install.sh | clean
    echo "include blocks in site file: $(grep -c '>>> communitycad' $SITE)"
    echo "served while installed: /=$(curl -s $U/ | short) (injected)"
    echo "--- uninstall #1"; plugin/uninstall.sh | clean
    echo "--- uninstall #2 (idempotency)"; plugin/uninstall.sh | clean
    echo "site file vs pre-install copy: $(cmp $SITE "$TMP/site.pristine" && echo IDENTICAL)"
    echo "served after uninstall: /=$(curl -s $U/ | short) /(gzip)=$(curl -s --compressed $U/ | short) /console=$(curl -s $U/console | short) sw.js=$(curl -s $U/sw.js | short)"
    echo "leftover files: conf.d=[$(ls $R/etc/conf.d | tr '\n' ' ')] communitycad-dir=$(ls -d $R/etc/communitycad 2>/dev/null || echo absent) web-dir=$(ls -d $R/communitycad/web 2>/dev/null || echo absent)"
} 2>&1 | tee $EV/E-uninstall-idempotency.txt

# ---------------------------------------------------------------------------------------- F
{
    echo "### F: ngx_http_sub_module"
    echo "--- this Pi: $(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2), $(cat /etc/mainsailos-release 2>/dev/null), $(nginx -v 2>&1)"
    nginx -V 2>&1 | grep -o -- '--with-http_sub_module\|--with-http_gzip_static_module'
    echo "--- simulated nginx without the module (wrapper hides it from nginx -V):"
    printf '#!/bin/sh\ncase " $* " in *" -V "*) /usr/sbin/nginx "$@" 2>&1 | sed "s/ --with-http_sub_module//"; exit 0;; esac\nexec /usr/sbin/nginx "$@"\n' >"$TMP/nginx-nosub"
    chmod +x "$TMP/nginx-nosub"
    cp $SITE "$TMP/site.before"
    NGINX_BIN="$TMP/nginx-nosub" plugin/install.sh 2>&1 | clean
    echo "install.sh exit=${PIPESTATUS[0]}; site file unchanged: $(cmp -s $SITE "$TMP/site.before" && echo yes); conf.d=[$(ls $R/etc/conf.d | tr '\n' ' ')]"
    echo "--- simulated 'nginx -t' failure after config is written (module missing but not detected):"
    printf '#!/bin/sh\ncase " $* " in *" -t "*) echo "nginx: [emerg] unknown directive \\"sub_filter\\" (simulated)" >&2; exit 1;; esac\nexec /usr/sbin/nginx "$@"\n' >"$TMP/nginx-failtest"
    chmod +x "$TMP/nginx-failtest"
    NGINX_BIN="$TMP/nginx-failtest" plugin/install.sh 2>&1 | clean
    echo "install.sh exit=${PIPESTATUS[0]}; site file restored: $(cmp -s $SITE "$TMP/site.before" && echo byte-identical); conf.d=[$(ls $R/etc/conf.d | tr '\n' ' ')]; state file: $(ls $R/communitycad/install-state 2>/dev/null || echo absent)"
    echo "running nginx untouched, served page: $(curl -s $U/ | grep -c inject.js) script tags"
} 2>&1 | tee $EV/F-sub-module.txt

rm -rf "$TMP"
