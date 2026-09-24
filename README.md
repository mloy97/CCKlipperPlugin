# CommunityCAD × Mainsail: injection spike

Throwaway prototype for a feasibility question: can we add our own UI to Mainsail
without forking it, by having nginx inject one `<script>` tag? The verdict and
evidence are in **[REPORT.md](REPORT.md)**.

**Planning docs** (execution plan, phase status, API audit, reports) are kept in the
CommunityCADPlatform repo under `docs/planning/`; see [docs/planning/README.md](docs/planning/README.md).
That copy is the source of truth; this repo holds no duplicate.

```
plugin/                       what would ship (prototype quality)
  web/inject.js               sidebar entry + Shadow DOM panel; guards every entry point
  nginx/communitycad-http.conf    -> /etc/nginx/conf.d/communitycad.conf   (http-level maps)
  nginx/communitycad-server.conf  -> /etc/nginx/communitycad/mainsail-server.conf (sub_filter rules)
  install.sh / uninstall.sh   idempotent, back up every file they touch, nginx -t + rollback
  common.sh                   shared settings; every path/command can be overridden via env
dev/
  harness.sh                  unprivileged sandbox nginx on 127.0.0.1:8088 (same binary + site config)
  acceptance.py               Playwright browser tests (criteria A, C, D, G + failure modes)
  shell-checks.sh             curl/nginx checks (criteria B, E, F)
  mainsail-site.conf, conf.d/ MainsailOS's nginx site config (identical to KIAUH's template)
  mainsail-releases/          Mainsail v2.17.0 and v2.19.0 release zips
  docker/docker-compose.yml   upstream virtual-klipper-printer (Klipper + Moonraker on :7125)
  evidence/                   logs, JSON results and screenshots from the runs in the report
```

## Try it on your own Pi (MainsailOS or KIAUH install)

Needs `sudo`, because it edits `/etc/nginx`. Nothing in `~/mainsail` is touched.

```bash
# copy the plugin/ folder to the Pi, e.g.
scp -r plugin pi@<your-pi>:~/communitycad-plugin
ssh pi@<your-pi>

cd ~/communitycad-plugin
./install.sh
```

What `install.sh` does:

1. Checks that `nginx -V` includes `--with-http_sub_module`. If it doesn't, it stops without changing anything.
2. Finds the one enabled nginx site whose `root` is a Mainsail release. Set `MAINSAIL_SITE=/etc/nginx/sites-available/<name>` to override.
3. Refuses to continue if `gzip_static` is on and Mainsail has `.gz` files (see REPORT.md, criterion B).
4. Copies `inject.js` to `~/communitycad/web/`.
5. Writes the two nginx snippets and adds one marked `include` line to Mainsail's `server { }` block.
6. Backs up everything it changes to `~/communitycad/backups/<timestamp>/…`.
7. Runs `nginx -t`. If that fails it restores the backups; if it passes it reloads nginx.
8. Uses `curl` to check that the page, `sw.js` and `inject.js` are served as expected.

Then open `http://<your-pi>/`. A **CommunityCAD** entry appears at the bottom of the sidebar.

To remove it:

```bash
./uninstall.sh   # removes the include + snippets, reloads nginx, and checks that the served
                 # index.html and sw.js are byte-identical to the files in ~/mainsail
```

If you've opened Mainsail over HTTPS or on `localhost`, it runs a service worker. The first
page load after install or uninstall can still show the previous version; the next load is
correct (REPORT.md, criterion A). Over plain `http://<ip>` there is no service worker, so
this doesn't apply.

## Reproduce the test runs (no printer needed)

Works on any Linux machine with an `nginx` binary. Root is not required: the harness runs its
own nginx on port 8088 and never touches `/etc/nginx`.

```bash
# 1. Klipper + Moonraker on 127.0.0.1:7125. Either a real one, or the virtual printer
#    (follow virtual-klipper-printer's README to populate printer_data/ first):
(cd dev/docker && docker compose up -d)

# 2. Sandbox nginx serving a Mainsail release
dev/harness.sh setup dev/mainsail-releases/mainsail-v2.17.0.zip
dev/harness.sh start

# 3. Browser tests (the plugin must NOT be installed in the harness when this starts)
python3 -m venv .venv && .venv/bin/pip install playwright && .venv/bin/playwright install chromium
TAG=v2.17.0 .venv/bin/python dev/acceptance.py               # A, C, SW-staleness, failure modes, G
NEW_ZIP=$PWD/dev/mainsail-releases/mainsail-v2.19.0.zip TAG=update .venv/bin/python dev/acceptance.py D

# 4. nginx-level checks
dev/shell-checks.sh                                           # B, E, F

dev/harness.sh stop
```

To point `install.sh`/`uninstall.sh` at the harness by hand, run `eval "$(dev/harness.sh env)"` first.
