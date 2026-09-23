# CommunityCAD for Klipper: Execution Plan

Technical plan for Claude Code. Read with:
- `klipper-plugin/feature-overview.md`: what the plugin does and why (non-technical)
- `klipper-plugin/api-audit.md`: current state of the CommunityCAD API, with file and line references
- `klipper-plugin/phase0-spike-report.md`: results of the injection spike, including every gotcha the installer must handle

Where this plan and the audit disagree, this plan wins. Where this plan is silent, follow existing codebase conventions and keep it simple.

---

## 0. The point of this plugin: seamless sharing

The plugin exists to get CommunityCAD in front of more makers. Every print that comes from CommunityCAD should be one tap away from being shared back to the site and out to social media, with a link that brings people back. Sharing features get the same care as browsing, and never feel like an afterthought.

**Sharing, version one:**
1. **One-tap print profile share.** Settings, printer, material and print result are attached to the model automatically, read from the G-code, Moonraker and Spoolman. The user doesn't type anything.
2. **Posts with drafts.** Photo plus caption from the plugin. "Publish" posts it right away; "Save as draft" lets the user review it on the site first.
3. **Share out.** After publishing, the phone's native share sheet (X, Bluesky, Threads, Instagram, Discord, whatever is installed), plus share buttons for X, Bluesky, Reddit and Mastodon.
4. **Rich link previews.** Every print and model page renders as a card showing the photo of the actual print, the model name, printer and material, and "Printed from CommunityCAD". Without this, shares are bare links that nobody clicks.
5. **Creator loop.** When someone shares a print of a model, its creator is notified with one-tap reshare. Creators promoting their own work to their own followers reaches more people than users posting once.

**Deliberately left out of version one:**
- **Bluesky auto-posting through linked accounts:** free, but fiddly to build (OAuth with DPoP, PKCE and PAR, through an SDK). Add it only if users ask for it.
- **The X API:** pay-per-use since February 2026, at $0.20 per post containing a link. CommunityCAD would pay for every user's post, and every useful post has a link. Share links cover X at no cost.

---

## 1. Decisions

| # | Decision | Resolved |
|---|----------|----------|
| D1 | Accounts | Browsing works without an account. **Downloading, sending and sharing require a linked account.** There's no anonymous download allowance: the first "send" is the moment to prompt sign-in. *(Confirmed.)* |
| D2 | Download limits | The same tier limits as the website apply to plugin users. The paid tiers stay the incentive to upgrade. |
| D3 | Send to printer | Follow what Orca and PrusaSlicer do: upload G-code into Moonraker's `gcodes` folder through Moonraker's upload API. Sliced `.gcode.3mf` files have their G-code extracted and saved the same way. Unsliced files (STL, 3MF, STEP) get "Download to this device" until slicing ships. |
| D4 | Plugin repo | New standalone public repo: `github.com/communitycad/communitycad-klipper`. It's separate because it's open source and the platform isn't, it has its own releases, and Moonraker's update manager needs its own git repo. |
| D5 | Plugin license | **Apache-2.0**, with a `NOTICE` file crediting CommunityCAD. Forks must keep the NOTICE, and the license grants no right to the CommunityCAD name or brand. Commercial use of the *API* is covered by CommunityCAD's API terms ("commercial use requires an agreement"), not by the plugin license. *(Confirmed. Not legal advice.)* |
| D6 | Moderation | Print profiles are published immediately and reportable. For posts, a new account's first post waits for admin approval; after 2 approved posts, the user's posts publish immediately. Daily caps apply to both. The creator of a model can hide prints and posts on their own model. |

---

## 2. Decided so far

- **Embedding:** the plugin's own UI is injected into Mainsail and Fluidd by nginx `sub_filter` adding one script tag. No fork of Mainsail or Fluidd, and no iframe webcam slot.
- **Interfaces:** Mainsail first (Miguel's test setup). Fluidd must work before public release.
- **Data flow:** the browser UI talks only to the Pi. A Moonraker component makes every CommunityCAD API call. No CORS changes on CommunityCAD, and the token never lives in the browser.
- **Sign-in:** device code flow (RFC 8628). Users sign in on communitycad.dev with the existing GitHub or Google sign-in and approve a short code.
- **Slicing (later stages):** runs on the user's own hardware only. No cloud slicing.
- **Settings live in one place each:** settings about *this printer* are in the plugin and stored on the Pi. Settings about *the person* are in their CommunityCAD account and apply across every printer and the website. The plugin links to the account page for anything account-level and never duplicates it.
- **Open vs closed:** the plugin is open source. The CommunityCAD platform is not. No backend code goes in the plugin repo, and nothing in copy or docs should imply the platform is open source.

---

## 2a. Environments and deploys

- **There's no staging.** Backend changes go to production with the usual manual `gcloud` deploy. Miguel does the final testing from his own printers against production.
- **Claude Code's automated tests run locally:** the existing Docker Compose backend plus the virtual Klipper printer from Phase 0. The plugin's `[communitycad] api_base` setting points at the local backend during development and defaults to `https://communitycad.dev/api/v1`.
- **Guardrails for testing in production:**
  - Take an on-demand Cloud SQL backup before every migration.
  - Migrations are additive only: new tables and nullable columns. Nothing is dropped or renamed in this project.
  - The backfill script has a `--dry-run` mode, and is run with it first.
  - New web UI (the `/link` page, the Prints section, the settings additions) stays behind an env flag, `PLUGIN_FEATURES_ENABLED`, until launch, so site visitors never see half-built features. The `/v1` API can be live without the flag, since it's unlinked and undocumented until launch.
- **Paid tiers are live.** The limit message links to `/subscribe`.
- **Terms of Service:** one simple update, published before public launch. It needs two clauses:
  - a license for user-shared photos, videos, posts and print profiles, so CommunityCAD can display them;
  - commercial use of the API requires an agreement with CommunityCAD (D5).

---

## 2b. Launch

- **Public launch happens when the full plugin is done:** Phases 0 to 5 plus on-printer profile import and slicing (Phases 6 and 7, still to be planned). Until then, the plugin repo can be public but isn't announced, and the web features stay behind `PLUGIN_FEATURES_ENABLED`.
- Miguel tests every phase on his own printers against production as it lands.
- Before launch:
  - the Terms of Service update is published,
  - Fluidd works,
  - install and uninstall are tested on a clean MainsailOS image,
  - the README with the install command is written.

## 2c. Failure behavior

| Situation | What the plugin does |
|---|---|
| CommunityCAD unreachable (site down or no internet) | "Can't reach CommunityCAD. Your printer works as normal." with Retry. Files already sent stay in G-code files. |
| Token revoked on the site | On the first 401, delete the local token and show "This printer was disconnected from your account." with Reconnect. |
| Download fails partway | Download to a temporary `.part` file outside the G-code folder. Move it in only once it's complete and its size and hash are verified. Retrying is free (same destination). |
| Printer is printing | Sending still works (it only saves the file). "Start print" becomes "Add to queue", using Moonraker's job queue. |
| Search down, rest of API up | "Search is temporarily unavailable." Model pages and sending keep working. |
| Plugin older than the API supports | The API returns `X-Min-Plugin-Version` on `/v1` responses. The plugin shows "Update available", pointing to the interface's update manager, and blocks only the actions that would fail. |
| Share or post upload fails | Keep it on the Pi in `<data_path>/communitycad/outbox/` and retry with backoff. The Share tab shows "Waiting to upload". |
| Any plugin error | Never affects the printer. `inject.js` catches everything, and a failure leaves Mainsail or Fluidd untouched. Component errors are caught and logged, and never stop Moonraker or a print. The plugin fails quietly inside its own view. |

---

## 3. Architecture

```
Phone / tablet / PC browser
  └─ Mainsail or Fluidd page
       └─ <script src="/communitycad/inject.js">   (added by nginx sub_filter)
            └─ <communitycad-browser> custom element, Shadow DOM
                 │  same-origin calls only
                 ▼
Pi: Moonraker
  └─ communitycad component  (/server/communitycad/*)
       │  holds token, reads printer info, downloads files
       ▼
communitycad.dev/api/v1/*   (new, versioned, plugin-facing router)
```

Thumbnails and gallery images load directly from the public GCS bucket via `<img>`. This already works, with no proxy.

---

## 4. Phases

Phase 0 and Phase 1 have no dependency on each other and can run in parallel. Everything else runs in order.

### Phase 0: Injection spike — DONE (2026-09-22): feasible with caveats

Full results: `klipper-plugin/phase0-spike-report.md`. Tested against Mainsail v2.17.0 and v2.19.0 on MainsailOS 3.0.0, 20/20 browser tests on each. All criteria passed. What the production version must carry over:

- **Rewrite `sw.js` too.** Mainsail's service worker precaches `index.html` and serves it for every navigation, so injecting only `index.html` leaves PWA users on stock Mainsail forever (and, after uninstall, on the injected page forever). The fix rewrites the Workbox revision string in `sw.js` so browsers install a new worker.
- **`etag off; if_modified_since off;` scoped to `= /sw.js`.** Without it nginx answers update checks with 304 from the unchanged file and the `sw.js` rewrite silently does nothing.
- **Scope `sub_filter` with a `map $uri`** so only `/index.html` and `/sw.js` are rewritten, never the API proxy or webcam streams.
- **`gzip_static` check.** It silently disables injection and `curl` hides the failure. Not enabled in any stock setup. The installer refuses to install when `gzip_static` is on with `.gz` files present.
- **Selectors live in one `SELECTORS` object.** Prefer the stable ids `#app`, `main#content`, `#page-container`. The sidebar hook depends on Vuetify 2 classes and would break on a Vuetify 3 migration (not on Mainsail's roadmap as of 2026-09-22). A floating fallback button appears if the sidebar can't be found.
- **Shadow DOM isolates selectors, not the host box.** Layout goes on an inner wrapper, since Vuetify's global reset hits the host element.
- **Mobile:** clone the last real nav link (the first is a logo), and close the drawer via the app bar menu button. Only ever match an exact selector with exactly one hit, never by position: Emergency Stop is in the same header.
- **Survive config regeneration.** KIAUH reinstall or repair can regenerate Mainsail's nginx site file and drop the include. Production needs a check that re-applies it and a visible "CommunityCAD disabled" state.
- **Installer:** find Mainsail's server block via `nginx -T` rather than guessing from `sites-enabled`, handle HTTPS and multiple server blocks, handle Mainsail and Fluidd side by side (KIAUH ports 80 and 81), and rotate backups.
- **Health check after Mainsail updates:** if Workbox changes its manifest format, the `sw.js` rewrite stops matching silently.
- **Our view has no URL.** Add an optional deep link such as `/?communitycad` in Phase 3, without confusing vue-router.
- **Upstream ask:** request a stable sidebar hook (an id or `data-` attribute, or an official custom navigation entry) from Mainsail's maintainers. That's the single change that most reduces long-term risk.
- **Fluidd is uninvestigated.** The nginx half should carry over; the DOM and service worker will differ.

### Phase 0 original brief (kept for reference)

Goal: prove the embedding works on a real Mainsail install before building on it.

- Dev environment: `mainsail-crew/virtual-klipper-printer` in Docker, with Mainsail and Fluidd served by nginx. The same setup is reused for e2e tests.
- nginx snippet: `sub_filter '</head>' '<script src="/communitycad/inject.js" defer></script></head>'; sub_filter_once on;` in the location that serves `index.html`.
- Handle pre-compressed files: disable `gzip_static` for `index.html` only, or `sub_filter` is silently skipped.
- `inject.js` adds a CommunityCAD entry to the sidebar and mounts a full-page view in the main content area when it's selected.

Acceptance criteria (all must pass):
1. The script loads on first visit, on hard reload, and after the service worker is installed.
2. Everything still works after a Mainsail update (release files replaced, nginx config kept).
3. Mainsail's own navigation and routing keep working. Leaving the view and coming back works.
4. Uninstalling returns the served page byte-for-byte to stock.
5. Confirm `ngx_http_sub_module` is present in MainsailOS's and KIAUH's nginx (`nginx -V`).

If criterion 1 or 2 can't be met, stop and report to Miguel with findings. Don't work around it silently.

### Phase 1: Backend foundations (CommunityCAD repo)

**1a. Security fixes (do first, independent of the plugin)**
- `GET /models/{id}` and all three download endpoints: return 404 for `private` models unless the caller is the owner or an admin. Add tests for anonymous, other-user, owner and admin callers.
- `/models/{id}/files/{file_id}/download`: apply the same `check_download_limit` and visibility check as the other download endpoints.

**1b. Versioned plugin router**
- New router mounted at `/v1`, only for plugin-facing endpoints. Existing web routes stay as they are (the web frontend deploys in lockstep with the backend).
- Declare `HTTPBearer` as the security scheme on `/v1` so the OpenAPI output shows auth.
- `limit` bounded `Query(ge=1, le=50)` on every `/v1` list endpoint.

**1c. Device tokens and device code flow**

Token design: opaque tokens, not JWTs. Keep it simple and revocable.
- Format `ccad_<random 32 bytes, base64url>`. Store only the SHA-256 hash.
- Table `api_tokens`: `id`, `user_id`, `name` (for example "Voron 2.4"), `scopes` (text[]), `token_hash` (unique), `created_at`, `last_used_at`, `revoked_at`, `client_name`, `client_version`.
- Long-lived with no refresh: valid until revoked. `last_used_at` is updated at most once per hour.
- Auth: extend `_extract_token` so a Bearer value starting with `ccad_` is looked up by hash. JWT behavior stays unchanged.
- Scopes: `catalog:read`, `download`, `prints:write`, `posts:write`.
- Scope enforcement: add a `require_scope(...)` dependency. Cookie sessions have every scope. Device tokens only get routes that explicitly declare a scope they hold, so any route without a declared scope rejects device tokens. That keeps payments, account, admin and upload routes safe by default.

Device code flow:
- Table `device_authorizations`: `id`, `device_code_hash`, `user_code`, `client_name`, `client_version`, `scopes`, `status` (`pending|approved|denied|expired|consumed`), `user_id`, `expires_at`, `interval_s`, `last_polled_at`, `created_at`.
- `user_code`: 8 characters, shown as `XXXX-XXXX`, from the alphabet `ABCDEFGHJKLMNPQRSTUVWXYZ23456789` (no 0/O/1/I). Expires after 10 minutes. Poll interval 5 seconds.

| Endpoint | Auth | Purpose |
|---|---|---|
| `POST /v1/auth/device/code` | none, rate-limited per IP | `{client_name, client_version}` → `{device_code, user_code, verification_uri, verification_uri_complete, expires_in, interval}` |
| `POST /v1/auth/device/token` | none | `{device_code}` → RFC 8628 errors `authorization_pending`, `slow_down`, `expired_token`, `access_denied`, or `{access_token, token_type, scope, token_id}`. One-time: status becomes `consumed`. |
| `GET /v1/auth/device/{user_code}` | web session | Shows the approval page: client name, printer name, scopes |
| `POST /v1/auth/device/{user_code}/approve` and `/deny` | web session + CSRF protection | Approve or deny |
| `GET /v1/auth/tokens` | web session | List connected devices |
| `PATCH /v1/auth/tokens/{id}` / `DELETE /v1/auth/tokens/{id}` | web session | Rename or revoke |

Frontend (Next.js):
- `/link` page: code entry (prefilled from `verification_uri_complete`), sign-in if needed, approve/deny screen. Plain and short.
- `/settings/devices` page: connected printers, last used, rename, revoke.

**1d. Request rate limiting**
- Add `slowapi` (or equivalent) on `/v1`: 120 requests/min per token, 30/min per IP when unauthenticated, 10/min per IP for `device/code`.

Tests: pytest for every new endpoint, including expiry, reuse of a consumed code, `slow_down`, revoked tokens, and scope rejection on an unscoped route.

### Phase 2: Catalog data pass (CommunityCAD repo)

One pass over the corpus fills everything the plugin's browse view needs.

**Schema (migration 0026)**
- `model_versions`: `bbox_x_mm`, `bbox_y_mm`, `bbox_z_mm` (float, nullable), `bbox_source` (`declared` | `assumed_mm` | null), `has_printable` (bool), `printable_types` (text[]), `total_size_bytes` (bigint).
- Denormalize the latest version's values onto `cad_models`.

**Capture in the render pipeline**
- `render_upload` / `_render_mesh_to_png`: keep `mesh.extents` instead of discarding it.
- ZIPs: use the largest extents among `_collect_render_targets`.
- Units: 3MF and STEP give declared units (convert to mm, `bbox_source=declared`). STL is assumed mm (`bbox_source=assumed_mm`).
- STEP sources: export the already-loaded mesh as STL to the private bucket and register it as a `model_files` row with `role="export"`. It then shows up in `files[]` and downloads through the existing endpoint.
- `has_printable` / `printable_types`: derived from `model_files` (STL, 3MF, OBJ, G-code), including the new mesh exports.

**Search index**
- Add the bbox fields, `has_printable`, `printable_types` and `total_size_bytes` to the Meilisearch document, and to the filterable and sortable attributes in `search_service.init_search_index`.

**Backfill**
- `scripts/backfill_catalog_geometry.py`, modeled on `scripts/regenerate_thumbnails.py`. It's resumable and idempotent, logs failures without stopping, then reindexes Meilisearch.
- Models that fail geometry extraction keep null bbox values and show as "size unknown".

**Plugin-facing catalog endpoints**

| Endpoint | Scope | Notes |
|---|---|---|
| `GET /v1/catalog/search` | none (D1) | Params: `q`, `sort`, `limit`, `offset`, `printable_only`, `fit_x`, `fit_y`, `fit_z`, `fit=only|exclude|any`. |
| `GET /v1/catalog/models/{id}` | none | Detail, including files with role, type, size and printable flag. |
| `POST /v1/catalog/models/{id}/files/{file_id}/download-url` | `download` (D1) | Presigned URL. Applies tier limits (D2) and returns the `X-Download-*` headers. |

**Download counting rules (strict: creator stats, user limits and CommunityCAD's costs all depend on this)**

**The principle: only downloads from CommunityCAD count toward user limits and the creator's download count.** A download counts only when CommunityCAD's servers deliver a file. What happens to a file after it leaves CommunityCAD (copies, reprints, moving it between printers) never counts toward limits or `download_count`.

Other metrics about local activity are allowed only if the user opts in, and they're always kept separate from download counting (see "Opt-in print activity stats" in Later).

A **download** is one delivery from CommunityCAD of one model to one destination on one day.
- A **destination** is a printer (identified by its device token) or a web user.
- A model counts once per destination per day, however many of its files are sent. Sending the STL and the 3MF of one model to one printer counts as 1.
- Two printers each downloading from CommunityCAD are 2 destinations, so that counts as 2.
- A web download and a printer download are separate destinations.
- A failed or interrupted download retried to the same destination on the same day is free, because it's the same destination.
- Print counts and shared print profiles (Phase 5) are a separate statistic. They never add to, or take from, download counts or limits.

**Durable ledger.** Redis stays the fast limit check, but it isn't the record.
- New table `download_events`: `id`, `user_id`, `token_id` (nullable), `model_id`, `version_number`, `file_id`, `destination_key`, `counted` (bool), `reason` (`counted|same_destination_today|over_limit`), `bytes`, `created_at`.
- One row for every URL issued.
- The creator-facing `download_count` is incremented only from `counted=true` events, so it can be rebuilt from the ledger at any time.
- An admin report (by model, by user, by day) reads from the ledger.

**No surprises for users**
- New endpoint `GET /v1/catalog/models/{id}/download-check` (scope `download`). It returns `{would_count: bool, reason, daily_remaining, weekly_remaining, reset_at}` without issuing anything.
- Before sending, the plugin shows one of:
  - "Uses 1 of your 3 remaining downloads today"
  - "Free: already sent to this printer today"
  - "Daily limit reached, resets at {time}", with the upgrade link.
- Account page: a "Download history" list from the ledger (model, destination, counted or free, date). Users can see exactly what used their limit.

**Protecting costs**
- Free same-destination re-downloads still cost egress. Cap URL issuance at 5 per model per destination per day. Beyond that, return 429 with a plain message.
- Before requesting a URL, the plugin checks `library.json` and the file's hash. If the same version is already on the Pi, it skips the download and just offers to print it.

Tests: two tokens on one account, same model (2 counted); same token twice in a day (1 counted, 1 free); multi-file model on one token (1 counted); over limit (429 and `over_limit` row); the 6th issuance on one destination (429); and `download_count` rebuilt from the ledger matches the live value.

- Fit rule: allow an XY swap, no Z rotation. Meilisearch filter: `((bbox_x_mm <= X AND bbox_y_mm <= Y) OR (bbox_x_mm <= Y AND bbox_y_mm <= X)) AND bbox_z_mm <= Z`. Models with null bbox values are excluded from `fit=only` and included in `fit=exclude`.
- Each search result carries everything a grid card needs, so the plugin never fetches detail per card: `id`, `slug`, `title`, `thumbnail_url`, `creator {username, display_name}`, `license_name`, `bbox {x, y, z, source}`, `has_printable`, `printable_types`, `total_size_bytes`, `like_count`, `download_count`, `print_count`.

### Phase 3: Plugin Stage 1, connect and browse (plugin repo)

**Repo layout**
```
communitycad-klipper/
  component/communitycad.py     Moonraker component
  web/                          Preact + TypeScript + Vite
    src/app/                    browser UI, shared by both interfaces
    src/adapters/mainsail.ts    nav entry + mount point
    src/adapters/fluidd.ts
    src/inject.ts               detects the interface, loads the adapter
  nginx/communitycad.conf
  scripts/install.sh  scripts/uninstall.sh
  dev/                          virtual printer docker-compose
  LICENSE                       Apache-2.0
  NOTICE                        credits CommunityCAD (D5)
```

**Moonraker component** (`[communitycad]` in moonraker.conf)
- Registers endpoints under `/server/communitycad/`. They inherit Moonraker's own auth.
- Token stored at `<data_path>/communitycad/credentials.json` with mode 0600. This is outside every Moonraker file root, so it's never visible in the file manager.
- Build volume: read from Klipper's `toolhead.axis_minimum` / `axis_maximum`. The user can override it in plugin settings because axis limits can include overtravel. Delta printers (circular beds): no fit filtering at first, just show everything.
- Link flow: calls `device/code`, polls `device/token` in the background, and notifies the UI via a Moonraker notification (`notify_communitycad_linked`).

| Component endpoint | Purpose |
|---|---|
| `GET /server/communitycad/status` | Linked account, build volume, plugin version |
| `POST /server/communitycad/link/start` | Returns `user_code` and URL for the UI to show |
| `POST /server/communitycad/unlink` | Revokes the token on the server and deletes it locally |
| `GET /server/communitycad/search` | Proxies `/v1/catalog/search`, filling in fit params from the build volume |
| `GET /server/communitycad/models/{id}` | Proxies detail |
| `GET` / `POST /server/communitycad/settings` | Build volume override, default view |

**UI**
- `<communitycad-browser>` custom element with Shadow DOM, so no styles leak in either direction.
- Match the host's look: dark theme, and read the host's primary color where possible.
- Screens: Browse (tabs "Fits your printer" and "All"), Search, Model detail, Connect (shows the code large, with the link and a QR code), Settings.

**Plugin settings screen** (per printer, stored in `<data_path>/communitycad/settings.json`, read and written through `/server/communitycad/settings`)

Each group ships in the phase that uses it; show only groups whose features exist.

| Group | Setting | Default | Phase |
|---|---|---|---|
| Account | Linked account, printer name shown on CommunityCAD (renames the token), Unlink | printer hostname | 3 |
| Account | "Manage account on CommunityCAD" link to `/settings` | | 3 |
| Printer | Build volume X/Y/Z | auto-detected, editable, with "Reset to detected" | 3 |
| Printer | Default browse tab | Fits your printer | 3 |
| Sending | Folder inside `gcodes` | `communitycad` | 4 |
| Sharing | Prompt to share when a print finishes | on | 5a |
| Sharing | Use webcam for post photos | **off** | 5b |
| Sharing | Which webcam (shown only when the above is on and there's more than one) | first webcam | 5b |
| Sharing | Offer timelapse in posts (shown only if moonraker-timelapse is installed) | **off** | 5b |
| Sharing | Attach print profile to posts | on | 5b |
| About | Plugin version, "updates through Mainsail or Fluidd", link to repo | | 3 |

Not settings: confirm before printing and the printer-mismatch warning are always on and can't be turned off.
- Cards show the thumbnail, title, creator, size (with "≈" when `bbox_source=assumed_mm`), a fit badge and the print count.
- Signed out: browsing works fully. Any action that needs an account (send, download, share) opens the Connect screen, then carries on with that action once linked (D1).
- Mobile first. Everything works at 360px width.

**Multiple printers**

Model: one plugin install per Moonraker instance, and one device token per printer. Every printer is linked separately and shows up by name in "Connected printers". Build volume, settings, `library.json` and share prompts are all per printer.

- **Linking a second printer:** if the browser already has a linked printer, the Connect screen notes "Signed in on another printer as {username}". Linking is still a normal device code approval, which takes a few seconds on the site if already signed in there.
- **Download limits** are per account, shared across all printers, same as the website (D2).
- **Each printer counts as its own download.** See "Download counting rules" in Phase 2, which are the single source of truth for counting.
- **Several Klipper instances on one Pi** (KIAUH multi-instance, `printer_1_data`, `printer_2_data`, ...): `install.sh` detects every Moonraker instance and asks which ones to install for (default: all). Each instance gets its own `[communitycad]` section, `data_path`, token and settings.
- **Mainsail or Fluidd multi-printer mode** (one interface switching between several Moonraker hosts):
  - The adapter reads which printer is currently selected and sends component calls to that printer's Moonraker URL, not the host serving the page.
  - Farm setups already need the interface's host in each Moonraker's `cors_domains`, and that CORS config covers component endpoints too.
  - Switching printers in the interface reloads the plugin's state for the new printer (account, build volume, "Fits" tab).
  - If the selected printer doesn't have the plugin, show "CommunityCAD isn't installed on this printer" with the install command.
- **Sending to a different printer** than the one being browsed isn't in version one. In multi-printer mode, users switch printers in the interface. A "send to any of my printers" picker needs a cloud queue that Pis poll, so it's in Later.

**Install and update**
- `install.sh`: symlinks the component into Moonraker, adds the `[communitycad]` and `[update_manager communitycad]` sections, installs the nginx snippet, restarts Moonraker and reloads nginx. Idempotent, and backs up every file before changing it.
- If the nginx layout isn't recognized, stop with clear manual instructions. Don't guess.
- `uninstall.sh` reverses everything from those backups.
- Updates: CI builds `web/dist` and commits it to a `release` branch. `update_manager` tracks that branch as `type: git_repo` with `managed_services: moonraker`. No Node.js needed on the Pi.

**Acceptance**
- Linking works end to end against the local backend in automated tests, then against production from Miguel's printer.
- The first grid loads in under 1.5 s on a Pi 4 over LAN.
- The web bundle is under 200 KB gzipped.
- Playwright e2e passes on the virtual printer for Mainsail.
- Two virtual printers with different build volumes, linked to one account: each shows its own "Fits" results, and switching between them in Mainsail's multi-printer mode loads the right one.

### Phase 4: Plugin Stage 2, send to printer

Follow what Orca and PrusaSlicer already do (D3).

- `POST /server/communitycad/send {model_id, file_id, start_print: bool}`:
  - `.gcode`: download on the Pi, then save into the `gcodes` folder under `gcodes/communitycad/` through Moonraker's file manager (the same path a slicer upload takes).
  - `.gcode.3mf` (sliced 3MF): extract the plate G-code and save it the same way.
  - Unsliced files (STL, 3MF, STEP): not sent to the printer. The UI offers "Download to this device" instead.
- **Printer match check before printing.** Pre-sliced G-code only works on the printer it was sliced for, and a mismatched file can crash the toolhead or use the wrong temperatures.
  - Read the slicer header (printer model, bed size, nozzle diameter, firmware flavor) and compare it with the user's printer and build volume.
  - If they don't match, show a clear warning and default to "Save only".
  - `start_print` always requires an explicit confirm. Never start a print automatically.
- Record `gcode filename → model_id, version, file_id` in `<data_path>/communitycad/library.json`, so Phase 5 knows which model a print came from.
- Call `download-check` before every send and show its result on the send button (Phase 2 counting rules).
- Show remaining downloads from the `X-Download-*` headers. A 429 shows a plain message with the reset time and a link to the paid tiers.
- Fluidd adapter plus Playwright e2e on Fluidd. Required before public release.

### Phase 5: Sharing (both repos)

This is the growth phase (section 0). Build it in this order: 5a, then 5b, then 5c.

#### 5a. One-tap print profile share

**Plugin**
- On print completion (Moonraker history and job events), for files in `library.json`, show "Share your print profile" with a single button.
- A "Share" tab lists recent prints of CommunityCAD files, each with a one-tap "Share profile" button.
- Everything is collected automatically:
  - **Slicer settings:** parsed from the config block in the G-code file (PrusaSlicer `; prusaslicer_config = begin`…`end`, Orca `; CONFIG_BLOCK_START`…`CONFIG_BLOCK_END`), plus Moonraker's file metadata (slicer, slicer version, layer height, filament type, estimated time).
  - **Printer:** name and kinematics from Moonraker and Klipper.
  - **Material:** from Spoolman if it's installed (vendor, material, color). Otherwise from the G-code filament type.
  - **Result:** from Moonraker history (status, print duration, filament used).
- **Allowlist only.** Share only the keys in one allowlist file (`component/profile_allowlist.py`): layer heights, nozzle diameter, line widths, walls, top and bottom layers, infill density and pattern, supports, brim, temperatures, speeds, fan, retraction, filament type. Never send host addresses, API keys, file paths or custom G-code blocks. Unit test the allowlist against sample Orca and PrusaSlicer G-code files that contain `print_host` and API key fields.
- Before sending, show the user exactly what will be shared, in a collapsed "details" view. The share button stays one tap.

**Backend**
- Table `print_profiles`: `id`, `model_id`, `version_number`, `author_id`, `printer_name`, `printer_kinematics`, `slicer`, `slicer_version`, `material` (jsonb: vendor, type, color), `settings` (jsonb, allowlisted keys only), `result` (`completed|cancelled|error`), `print_duration_s`, `filament_used_mm`, `created_at`, `hidden_at`, `hidden_by`.
- `POST /v1/prints/profiles` (scope `prints:write`). The server revalidates the settings keys against its own copy of the allowlist and drops anything else. Limit 20 per user per day.
- `GET /models/{id}/profiles` (public). The web model page gets a "Printed N times" line and a list of profiles (printer, material, key settings, result), with a download of each profile as JSON.
- `print_count` on `cad_models`, counting completed prints, is indexed in Meilisearch and sortable.
- Published immediately (D6). Reportable. The model's creator can hide one on their own model.

#### 5b. Posts with drafts

**Plugin**
- From the Share tab or the completion prompt: "Create post."
  - Photo from the phone's camera or gallery through a file input. That's the default.
  - Webcam snapshot (Moonraker webcam list) only if "Use webcam for post photos" is turned on. When it's off, the plugin never reads the webcam, not even for a preview. Even when it's on, the user sees the snapshot and can replace or remove it before posting.
  - Timelapse: if "Offer timelapse in posts" is on and moonraker-timelapse rendered a video for this print, show an "Include timelapse" checkbox. It's unchecked by default, and the video can be previewed before posting.
    - Match the video to the print through moonraker-timelapse's render event (`notify_timelapse_event`, action `render`, status `success`) and its filename, which includes the G-code name. Record the match in `library.json`.
    - The Pi uploads the video straight to CommunityCAD. The large file never goes through the phone.
    - If the setting is off, or moonraker-timelapse isn't installed, the plugin never reads the timelapse folder.
  - Caption up to 500 characters.
  - "Attach print profile" is on by default when one exists.
- Two buttons: **Publish** and **Save as draft**.
  - Publish sends the post; if accepted, the plugin opens the post's share page on communitycad.dev (5c) in a new tab.
  - Save as draft sends it as a draft and opens it on communitycad.dev for review.

**Backend**
- Table `posts`: `id`, `author_id`, `model_id`, `print_profile_id` (nullable), `caption`, `status` (`draft|pending_review|published|removed`), `created_at`, `published_at`, `hidden_at`, `hidden_by`. Plus `post_media` (`kind` = `image|video`), stored in a public prefix and separate from `ModelImage`, so the model thumbnail is never touched.
  - Images: JPEG/PNG/WebP, max 5 MB each, max 4 per post.
  - Video: at most 1 per post, MP4 (H.264), max 50 MB and 90 seconds. Validate with `ffprobe` on upload and reject anything else.
  - For video, generate a poster frame (JPEG) at upload time. It's used for the post card and the link preview.
  - Serve media through Cloudflare's cache to limit GCS egress, since video is the largest file type on the site.
- `POST /v1/posts` (scope `posts:write`, multipart, `publish: bool`). Limit 10 per user per day.
- Moderation (D6):
  - If `publish=true` and the author has fewer than 2 approved posts, the status becomes `pending_review` and the user sees "Your first post will be live after a quick review."
  - Otherwise the status becomes `published`.
- Admin review queue for `pending_review` posts, in the existing admin dashboard.
- Web frontend:
  - Post page `/p/{id}`.
  - Draft review and edit page, with Publish from there.
  - A "Prints" section on model pages showing published posts.
  - Model creators can hide posts on their own model.
- Add `post` and `print_profile` to the report `target_type` values, with admin views.
- Reuse `Comment` for discussion on posts. An optional printability score goes through the existing `AccuracyScore` upsert.

#### 5c. Share out and the creator loop

**Share page** (web, `communitycad.dev/p/{id}`, HTTPS)
- Posts with a timelapse get an autoplaying, muted, looping video on the page, and a second button, "Share video". It calls `navigator.share({files: [mp4], text, url})` where `navigator.canShare` supports files, so the actual video goes to Instagram, TikTok, X and others as native video, not a link.
- A large Share button that calls `navigator.share({title, text, url})`. That opens the phone's native share sheet. The Web Share API needs HTTPS and a user tap, which is why sharing happens on the site and not in the plugin: Mainsail usually runs on plain http.
- Share buttons shown always, which is the only option on desktop:
  - X: `https://x.com/intent/post?text=…&url=…`
  - Bluesky: `https://bsky.app/intent/compose?text=…`
  - Reddit: `https://www.reddit.com/submit?url=…&title=…`
  - Mastodon: ask for the user's server once and remember it (the account setting when signed in, otherwise `localStorage`), then open `https://{server}/share?text=…`
- A "Copy link" button.
- Default share text, which the user can edit: `{model title} printed on my {printer} in {material}. Files on CommunityCAD: {url}`. Plain, with no hashtags and no exclamation marks.

**Rich link previews** (web)
- Open Graph and Twitter card tags on `/p/{id}` and model pages: `og:title`, `og:description`, `og:image`, `og:url`, `twitter:card=summary_large_image`.
- Timelapse posts also get `og:video` tags, and the preview image uses the video's poster frame with a small play marker.
- Generated preview images through Next.js `opengraph-image.tsx`. The post card shows the print photo, the model title, printer and material, and "Printed from CommunityCAD". Model pages use the model thumbnail with the title and creator.
- Validate with the X, Bluesky and Facebook card preview tools before release.

**Creator loop**
- When someone publishes a post or shares a profile on a model, notify the creator by email: "Someone printed your {model} on a {printer}". If there's more than one in a day, send a daily digest instead. Creators can opt out in settings.
- The email links to a creator share page with the same share buttons and prefilled text: `Someone printed my {model} on a {printer}. Files on CommunityCAD: {url}`.
- The creator dashboard shows print count and recent posts per model.

**Account settings** (web, existing `/settings` area; new user columns in one migration)

| Section | Setting | Default | Phase |
|---|---|---|---|
| Connected printers | List, last used, rename, revoke (`/settings/devices`, built in 1c) | | 1 |
| Notifications | When someone prints my models: each time / daily digest / off (`notify_creator_prints`) | daily digest | 5c |
| Notifications | When my post is approved (`notify_post_review`) | on | 5b |
| Privacy | Show my printer name on shared profiles and posts (`show_printer_name`) | on | 5a |
| Privacy | Show print time and result on shared profiles (`show_print_result`) | on | 5a |
| Sharing | Mastodon server (`share_mastodon_server`), used by the share page instead of `localStorage` when signed in | empty | 5c |

- Privacy settings are applied server-side when rendering profiles and posts, so they also cover anything already shared.
- The plugin doesn't need to read account settings.

**Acceptance**
- From the plugin on a phone: print finished → share profile takes 1 tap, and a post with photo takes 3 taps or fewer to reach the native share sheet.
- Links posted to X, Bluesky and Reddit show the rich preview with the print photo.
- The allowlist tests pass. No host, API key, path or custom G-code value ever leaves the Pi.

### Later

- **Bluesky auto-posting** through linked accounts (OAuth with an SDK): only if users ask for it.
- **Opt-in print activity stats:** a plugin setting, "Share print activity with CommunityCAD", **off by default**. When on, prints of CommunityCAD files (including reprints) are reported for the user's own print history and for "printed N times" on model pages. Kept in its own table, and never used for download limits or `download_count`. Turning it off stops reporting, and the user can delete what was collected from their account page.
- **"Send to any of my printers"** from any device or from the website: a per-printer queue on CommunityCAD that each linked Pi polls, so no inbound connection to the Pi is needed. Pairs well with a "My printers" section on the account page.
### Phases 6 and 7: Profile import and on-printer slicing (to be planned, required for launch)

- Phase 6: import the user's own slicer profile.
- Phase 7: slice on the printer, with a quick orient and preview.
- Shared print profiles (5a) become a source for "slice with a profile that worked for someone else". Phase 2's mesh export already covers "CAD file to printable mesh".
- Detailed planning happens next. It isn't blocked by Phases 0 to 5.

---

## 5. Rules for Claude Code

- Work phase by phase. Don't start a phase until the one before it meets its acceptance criteria (except that Phases 0 and 1 run in parallel).
- Don't modify Mainsail or Fluidd source. Everything happens through the injected script and the nginx snippet.
- Never store the CommunityCAD token in the browser.
- Never start a print without an explicit user confirm.
- The plugin can never break the printer, Moonraker, Mainsail or Fluidd. Every plugin error is contained (section 2c).
- Never send slicer settings outside the allowlist.
- Never read a webcam unless the user turned on "Use webcam for post photos".
- Never read timelapse files unless the user turned on "Offer timelapse in posts".
- Only downloads served by CommunityCAD count toward user limits and `download_count`. Local activity (copies, reprints) never counts toward either, and is only collected at all if the user has opted in.
- Never change how downloads are counted outside the Phase 2 counting rules. Any change to them needs Miguel's sign-off.
- Don't integrate the X API or store anyone's social media credentials.
- Don't add features beyond the current phase. No slicing work until Phases 6 and 7 are planned in this file.
- Follow existing backend conventions: SQLAlchemy/Alembic, migrations numbered from 0026, pytest, and the existing service layer pattern.
- Keep plugin and share copy short and plain. No hype, no exclamation marks. Never imply the CommunityCAD platform is open source.
- Only stop and ask Miguel when:
  - a Phase 0 acceptance criterion fails,
  - a decision in section 1 turns out to be unworkable,
  - a change would touch payments, auth for the web frontend, or production data outside the backfill script,
  - the nginx layout on a target install isn't recognized.
- At the end of each phase, update this file: mark the phase done, and record anything that changed from the plan and why.

---

## 6. Status

| Phase | Status |
|---|---|
| 0. Injection spike | **Done 2026-09-22: feasible with caveats** |
| 1. Backend foundations | Not started |
| 2. Catalog data pass | Not started |
| 3. Plugin: connect and browse | Not started |
| 4. Plugin: send to printer | Not started |
| 5a. Print profile share | Not started |
| 5b. Posts with drafts | Not started |
| 5c. Share out and creator loop | Not started |
| 6. Profile import | To be planned |
| 7. On-printer slicing | To be planned |
| Public launch | After Phase 7 (section 2b) |
