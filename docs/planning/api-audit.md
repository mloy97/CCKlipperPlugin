# CommunityCAD API — audit against a planned Klipper / Mainsail plugin

**Date:** 2026-09-21
**Scope:** read-only audit. No code changed.
**Sources of truth:** `backend/app/routers/*.py` and the OpenAPI schema generated from
`app.main:app` (121 paths, `info.version = 0.1.0`).
**Prod base URL:** `https://communitycad.dev/api` — the load balancer strips `/api` before
the request reaches FastAPI (`phase5_deploy_plan.md:741`), so a route documented here as
`/models/search` is `https://communitycad.dev/api/models/search` from the printer.

---

## Summary table

Ordered: Stage 1 blockers first, then the rest by stage.

| # | Need | Status | Endpoint(s) today | Gap |
|---|------|--------|-------------------|-----|
| 1 | Sign-in from a keyboard-less device (device code / PAT) | **Missing** | `GET /auth/oauth/{provider}/start`, `GET /auth/oauth/{provider}/callback` | Only a browser redirect flow that ends in an httpOnly cookie + 302 to the frontend. No endpoint hands a token to a non-browser client. Needs a device-code grant or a PAT mint/list/revoke surface. |
| 2 | Token refresh | **Missing** | — | `create_access_token()` mints one HS256 JWT, payload `{sub, exp}`, 7-day life (`jwt_expire_minutes=10080`). No refresh token, no rotation. Plugin silently dies every 7 days. |
| 3 | Token revocation | **Missing** | `POST /auth/logout` | Logout only deletes the cookie. The JWT is stateless — no `jti`, no denylist, no per-device record — so a leaked token is valid until `exp`. Only account-wide suspension kills it. |
| 4 | Scopes | **Missing** | — | Token payload carries no scope/audience claim. Authorization is per-route owner-or-admin checks. A plugin token is a full account token. |
| 5 | CORS from the printer's local address | **Missing** | `app.add_middleware(CORSMiddleware, …)` in `main.py:57` | `allow_origins = settings.allowed_origins_list` (explicit; prod `https://communitycad.dev`) with `allow_credentials=True`, which forbids `*`. `http://mainsail.local` / `http://192.168.x.x` fails preflight. Either proxy through the Pi, or add an origin allowlist/regex for RFC1918 + `.local` served with `allow_credentials=False` + Bearer-only. |
| 6 | Bounding box X/Y/Z per model, filterable/sortable | **Missing** | — | Nothing stored, indexed or exposed. Not in `cad_models`, `model_versions`, the Meilisearch document, or any schema. The render pipeline computes `mesh.extents` (`tasks.py:114-117`) purely to frame the camera and discards it. This is the "fits your printer" feature — it is the largest single gap. |
| 7 | Filter by file type (STL/3MF vs CAD-only) | **Partial** | `GET /models/search?file_type=` | Meili filterable attribute exists, but single-value only (no `stl,3mf` OR-list) and it is the **model-level** type. The standard archive upload is `file_type="zip"`, so "contains a printable STL/3MF" is unanswerable. Per-member types live in `model_files` (unindexed). `GET /models/semantic-search` has no `file_type` param at all. |
| 8 | Catalog listing, pagination, sorting | **Partial** | `GET /models/search?q=&limit=&offset=&sort=` | There is **no** `GET /models`. The homepage uses empty-`q` search as the catalog. `limit`/`offset` have no `Query(ge=, le=)` bounds. `total` is Meili's `estimatedTotalHits`, capped around 1000, so deep paging is unreliable. Sort keys limited to `created_at`, `avg_accuracy_score`, `view_count`, `download_count`, `like_count`. Hard dependency on Meilisearch — `main.py` tolerates a failed *index init*, but a live Meili outage 500s the whole browse path. |
| 9 | Text search | **Supported** | `GET /models/search` | Searchable attributes `title`, `description`, `tags`; always filtered to `visibility = public`. |
| 10 | Semantic search | **Partial** | `GET /models/semantic-search?q=&limit=` | pgvector cosine (`<=>`) over 384-dim embeddings. No `offset`, no tag/file-type filter, no similarity score or threshold in the response, `total = len(items)`. Can't be combined with a "fits my printer" filter later. |
| 11 | Model detail (previews, files, creator, license, versions) | **Supported** | `GET /models/{id}`, `/versions`, `/images`, `/datasheets` | `CADModelDetail` returns `thumbnail_path`, `images[]`, `files[]`, owner badge, `license_name` + `license_text`, `versions[]`, tags, `readme_markdown`, source attribution, counts. Two caveats below (view-count inflation, private-model exposure). |
| 12 | Direct download URLs for STL/3MF | **Supported** | `GET /models/{id}/download`, `GET /models/{id}/versions/{n}/download`, `GET /models/{id}/files/{file_id}/download` | First two return `{"url": "<presigned>"}` as JSON; the third 307s. GCS V4-signed via IAM `signBlob`. Expiry is a hard-coded 3600 s (`storage_service.get_presigned_url`) — not configurable per call. All three accept anonymous callers. |
| 13 | File size info | **Partial** | `GET /models/{id}/versions` (`file_size`), `GET /models/{id}` → `files[].size_bytes` | Size is **not** in `CADModelOut.versions` (`ModelVersionOut` omits it) and **not** in the Meilisearch document — so a list view can't show or filter on size without one extra request per model. |
| 14 | Rate limits | **Partial** | `tier_service.check_download_limit` + `X-Download-*` headers | Download counting only. Free 5/day + 20/week, Supporter 10/50, Believer 50/200, Professional unlimited. Anonymous callers bucket by **IP** (`dl:ip:<ip>`), so a print farm behind one NAT shares 5/day. Same-model re-download is deduped free for the day. No general request-rate limiting anywhere (no `slowapi`/limiter in the codebase). `/files/{file_id}/download` skips the check entirely. |
| 15 | Large-file handling | **Partial** | `MAX_SIZE_BYTES = 50 MB` | Upload cap 50 MB, read fully into memory. Downloads bypass the backend (client pulls from GCS) — good. But a ZIP member's first download extracts synchronously inside the request (`ensure_member_extracted`) and 500s on failure. |
| 16 | Create a "shared print" (photo, printer, material, settings) | **Missing** | — | No model, table, router or schema. Closest reusable pieces listed under Stage 3. |
| 17 | Existing comments / reviews to reuse | **Supported** | `GET`/`POST /models/{id}/comments`, `DELETE /models/comments/{id}`, `GET`/`POST /models/{id}/scores`, `GET /models/{id}/scores/summary` | Threaded comments (one reply level, soft delete, comment-ban gate) and a 5-dimension accuracy score including `printability`. |
| 18 | Moderation hooks for user content | **Partial** | `POST /reports`, `GET /reports`, `PUT /reports/{id}`, `/reports/admin/*` | Report `target_type` is limited to `model`/`comment`/`user`; a `shared_print` type needs backend work. Admin tooling (suspend, comment-ban, upload-limit, DMCA takedown, audit log) already exists. No automated image/text scanning and no pre-publication queue. |
| 19 | Mesh (STL) generated from CAD source (STEP etc.) | **Partial** | internal only — `tasks._generate_step_thumbnail`, `worker-render` `POST /render` | The conversion already works: STEP → `cascadio`/trimesh → mesh → PNG. The mesh is thrown away; nothing is persisted or served. `worker-render` is `ingress=internal` + OIDC, unreachable from the plugin. No on-demand conversion endpoint, no job/status API. |
| 20 | API versioning | **Missing** | — | No `/v1` prefix, no version header, no deprecation policy. `info.version` is still `0.1.0`. Any breaking change lands on deployed plugins immediately. |
| 21 | Auth mechanism usable by non-browser clients | **Partial** | `deps.py::_extract_token` | Cookie first, then `Authorization: Bearer` — Bearer works on **every** authenticated route. The mechanism is fine; the missing piece is item 1, a way to obtain the token headlessly. Authentik/OIDC was retired 2026-08-16; it is now direct Google + GitHub OAuth with PKCE. |
| 22 | Public API documentation | **Partial** | `/api/docs` (Swagger), `/api/openapi.json` | Auto-generated only, linked from the site's `/docs` page. The spec has **no `components.securitySchemes` and no `security` on any operation** — auth is plain `Depends`, not an `APIKeyCookie`/`HTTPBearer` security dependency — so generated clients come out unauthenticated. No hand-written guide, examples or changelog. |

---

## Stage 1 — Connect and browse

Three hard blockers, in the order they'll stop you.

### 1. There is no headless sign-in path

The whole auth flow assumes a browser that will keep a cookie on the API domain:

```
GET  /auth/oauth/{provider}/start     → 302 to Google/GitHub, sets state/PKCE/nonce cookies
GET  /auth/oauth/{provider}/callback  → Set-Cookie: access_token=<JWT>; HttpOnly, 302 to frontend
```

The token never appears in a response body. A plugin can open that URL on the user's phone,
but the resulting cookie is httpOnly on `communitycad.dev` and unreadable by the plugin.

The good news is that the verification side already works for API clients —
`deps.py::_extract_token` checks the cookie, then falls back to `Authorization: Bearer`. So
once a plugin holds a JWT, every authenticated route accepts it. The work is entirely on
the minting side. Two options:

- **RFC 8628 device code flow** — `POST /auth/device/code` → `{device_code, user_code,
  verification_uri}`, plugin polls `POST /auth/device/token`. Best UX: the user types a
  6-character code on their phone.
- **Personal access tokens** — `POST /auth/tokens` from the web UI, shown once, plugin
  stores it. Much less backend work; the user has to copy a long string to the Pi, which is
  exactly the keyboard problem the plugin exists to avoid, though it can be pasted into
  Mainsail's settings from a laptop.

Either one drags in items 2–4: refresh, revocation, and scopes. Today's JWT is
`{sub, exp}` with a 7-day life and no `jti`, so a plugin token can't be listed, scoped
down to read-only, or revoked without changing `JWT_SECRET` (which logs out every user on
the platform). If you only do one thing here, give the token a `jti` and a
`token_type`/`scope` claim now — retrofitting a claim onto tokens already in the wild is
much worse than shipping it from the start.

### 2. CORS will block a browser page served from the printer

```python
# main.py:57
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.allowed_origins_list,   # prod: https://communitycad.dev
    allow_credentials=True,
    ...
)
```

`allow_credentials=True` rules out a wildcard, and printer origins
(`http://mainsail.local`, `http://fluidd.local`, `http://192.168.x.x`, arbitrary ports) can't
be enumerated in an env var. As it stands, a page served from the Pi cannot call the API
directly.

Two ways out:

- **Proxy through the Pi** (recommended). The plugin's Python side (a Moonraker component)
  makes the API calls; the browser UI talks only to its own origin. No CORS at all, and the
  token lives in a `0600` file on the Pi instead of in browser storage. This also solves the
  download path — the Pi fetches the presigned GCS URL server-side, so GCS bucket CORS never
  comes into play.
- **Widen CORS deliberately**: add an `allow_origin_regex` for RFC1918 + `.local` origins on
  a Bearer-only, `allow_credentials=False` route group. Keep it separate from the
  cookie-credentialed config — mixing the two is how CSRF bugs get in.

Note what already works without CORS: `<img>` tags against the public bucket. Thumbnails,
gallery images, avatars and logos are served from
`NEXT_PUBLIC_STORAGE_PUBLIC_BASE` (a public GCS bucket, prefixes in
`storage_service._PUBLIC_PREFIXES`), so previews render in the plugin UI today with no
backend involvement.

### 3. No bounding box anywhere

This is the plugin's headline feature and there is nothing to build on. Not a column, not an
index field, not a schema field. The one place the data exists is transient:

```python
# tasks.py:114-117 — inside _render_mesh_to_png
mesh.apply_translation(-mesh.bounding_box.centroid)
extents = mesh.extents
max_extent = float(max(extents)) if max(extents) > 0 else 1.0
```

It's computed to frame the camera, then discarded. The shape of the work:

1. Migration `0026` — add `bbox_x_mm`, `bbox_y_mm`, `bbox_z_mm` to `model_versions` (per
   version, not per model — a v2 can change dimensions), plus a `bbox_source` marker for
   whether units were declared or assumed.
2. Capture `mesh.extents` in `render_upload` where it's already in hand. For a ZIP,
   `_collect_render_targets` already picks the renderable members — take the union or the
   largest.
3. Denormalise onto `cad_models` for the latest version, add to the Meilisearch document,
   and add all three to `update_filterable_attributes` **and** `update_sortable_attributes`
   in `search_service.init_search_index`.
4. New query params on `/models/search` — `max_x`/`max_y`/`max_z` (Meili supports numeric
   range filters), and `sort=bbox_z_mm:asc` etc. for free once sortable.
5. Backfill — a script over existing versions, same shape as
   `scripts/regenerate_thumbnails.py`.
6. Expose on `CADModelOut` so the list view can show "180 × 180 × 200 mm".

**Units caveat worth deciding early:** STL has no unit declaration — the convention is mm,
but a model exported from an inch-unit CAD package will read 25.4× small and rank as "fits"
on every printer. 3MF and STEP both carry units. Store what the file declared and flag
STL-derived values as assumed, so the UI can say "≈" rather than quietly lying about fit.

### 4. Browsing works, but on a search endpoint

There is no `GET /models`. The catalog is empty-query Meilisearch, exactly as the homepage
does it:

```
GET /models/search?limit=6&sort=view_count:desc
GET /models/search?limit=6&sort=created_at:desc
```

That's serviceable for Stage 1. Three things to know before relying on it:

- `limit: int = 20, offset: int = 0` are declared without `Query(ge=…, le=…)` — unvalidated.
  `limit=100000` reaches Meilisearch.
- `total` is `estimatedTotalHits`, which Meili caps (default 1000). An infinite-scroll UI
  will hit a wall and the count will drift.
- If Meilisearch is down, browse is down. `main.py` deliberately survives a failed index
  *init* at boot, but that only covers startup — a live outage 500s every search request,
  and there's no DB-backed fallback listing.

The `file_type` filter is real but coarse. It's Meili-filterable, single-valued (no
`file_type=stl,3mf`), and reflects the **model-level** type assigned at upload from the
file's extension. The platform's standard archive layout uploads a ZIP, which normalises to
`file_type="zip"` — so the models most likely to contain a print-ready STL are precisely the
ones you can't find by filtering on `stl`. Per-member types are in `model_files`
(`role` ∈ `cad|export|asset|doc|readme|license|other`, plus `path` and `mime`), which is not
indexed. A `has_printable` boolean or a `member_types` array on the Meili document, derived
from the manifest at index time, would fix this cheaply.

Model detail is genuinely complete — `CADModelDetail` gives previews, the file manifest,
creator badge, license name *and* full text, versions, tags, README and source attribution
in one call. Two behaviours to plan around:

- **`GET /models/{id}` increments `view_count` and commits on every call.** If the plugin
  polls or prefetches detail for a grid, it inflates creator stats and writes to the DB on
  every read.
- **`private` models are readable by ID.** `get_model` only gates `visibility == "removed"`
  (410 for non-admins); `private` falls through and is returned to any caller. The download
  endpoints (`/download`, `/versions/{n}/download`, `/files/{id}/download`) have no
  visibility check at all. The *listing* paths do filter correctly (Meili filters
  `visibility = public`, `/users/{username}/models` filters in SQL), so this is only
  reachable by guessing an ID — but it's a pre-existing access-control gap, not a
  plugin-specific one, and it's worth closing before a third-party client makes ID
  enumeration cheap.

---

## Stage 2 — Send to printer

Downloads are the most plugin-ready part of the API. Three endpoints, all working, all
accepting anonymous callers:

| Endpoint | Returns | Rate-limited |
|---|---|---|
| `GET /models/{id}/download` | `{"url": …}` JSON (latest version) | yes |
| `GET /models/{id}/versions/{n}/download` | `{"url": …}` JSON | yes |
| `GET /models/{id}/files/{file_id}/download` | 307 → presigned URL | **no** |

The JSON-instead-of-redirect shape on the first two is deliberate (so the frontend can read
the limit headers without a double-increment) and it suits the plugin fine.

Presigned URLs are GCS V4, signed through IAM `signBlob`, with a **hard-coded 3600-second
expiry** — `get_presigned_url(key, expiry_seconds=3600)` has the parameter but no caller
passes it. That's plenty for a download, but if the plugin caches a URL for a queued print,
it needs to re-request rather than store.

**The rate limit is the real Stage-2 constraint.** From `tier_service`:

| Tier | Daily | Weekly |
|---|---|---|
| Free | 5 | 20 |
| Supporter | 10 | 50 |
| Believer | 50 | 200 |
| Professional | unlimited | unlimited |

Anonymous callers bucket by IP (`dl:ip:<ip>:daily`), so an unauthenticated plugin gets 5
downloads a day per printer — and a workshop or print farm behind one NAT shares a single
bucket across every printer in the building. The same-model dedupe (`dedupe_key=f"model:{id}"`,
Redis `SET NX` with a midnight TTL) means re-downloading the same model within a day is free,
which helps a reprint but not browsing. On a 429 you get:

```json
{"error": "download_limit_reached", "limit_type": "daily",
 "daily_remaining": 0, "reset_at": "…", "upgrade_url": "/subscribe"}
```

plus `X-Download-Daily-Limit` / `-Remaining` / `X-Download-Reset-Daily` headers on every
allowed download too. The plugin should surface remaining-downloads in its UI from those
headers — it's the one piece of quota feedback the API already gives you.

Note that `/models/{id}/files/{file_id}/download` has **no** limit check and no auth. Today
that's an unintentional hole, not a feature — don't design the plugin's "grab the STL out of
the archive" path around it, because closing it is a one-line change someone will eventually
make.

There is no general request-rate limiting. No `slowapi`, no limiter middleware, nothing in
`requirements.txt`. A misbehaving plugin can hammer search and detail endpoints freely, which
argues for adding one *before* third-party clients exist rather than after.

On large files: uploads cap at 50 MB and are read fully into memory
(`file_bytes = await file.read()`), datasheets 20 MB, images 5 MB. Downloads never touch the
backend — the client pulls bytes straight from GCS, so file size doesn't cost API capacity.
The one rough edge is ZIP members: the first request for a member extracts it synchronously
inside the request (`file_structure_service.ensure_member_extracted`, caching to
`extracted/{version_id}/…`) and raises a 500 on failure. A cold, large member means a slow
first "send to printer" and an opaque error if extraction fails.

Practical gap for the UI: file size isn't in the list payload. `ModelVersionOut` (what
`CADModelOut.versions` uses) omits `file_size`, and the Meili document doesn't carry it, so
showing "12 MB" in a grid needs `GET /models/{id}/versions` per model. Adding `file_size` to
`ModelVersionOut` and the index document is a small change with a real payoff here.

---

## Stage 3 — Share back

**There is no makes/prints feature.** No `shared_print` model, table, router or schema —
I checked the ORM, the migrations (0001–0025), and the route list.

What exists that's worth reusing rather than reinventing:

- **`ModelImage`** (`POST /models/{id}/images`) — photo upload with a caption and sort order,
  max 20 per model, 5 MB, JPEG/PNG/GIF/WebP, stored in the public `model-images/` prefix.
  This is the photo-upload half of a "make" already built. **But** it's gated to
  `model.owner_id == current_user.id or admin`, and the first image syncs into the model's
  `thumbnail_path` — so it cannot be reused as-is for third-party print photos without
  separating the tables.
- **`Comment`** — threaded one level deep, soft-deleted via `deleted_at`, with a comment-ban
  gate (`_check_comment_ban`). Good base for the discussion part of a make.
- **`AccuracyScore`** (`POST /models/{id}/scores`) — five integer dimensions, one row per
  (user, model), upserted, feeding `cad_models.avg_accuracy_score`. One dimension is already
  `printability`. If a shared print carried a score, this is where it should land so it
  flows into the existing ranking.

None of these carry printer name, material, nozzle/layer height, or any print settings. A
`shared_prints` table (model_id, author_id, printer, material, settings JSON, notes, photos,
created_at) with its own image rows is the honest shape, reusing `Comment` for discussion and
`AccuracyScore` for the printability signal.

Moderation is half there. `POST /reports` takes `target_type` ∈ `model | comment | user` —
a `shared_print` value needs a backend change and a matching admin view. Downstream tooling
is solid: `GET /reports?report_status=`, `PUT /reports/{id}` (resolve/dismiss with notes),
suspension with expiry, comment bans, upload rate limits, DMCA takedown, and an admin audit
log. What's missing for user-submitted *photos* specifically: no automated image scanning, no
pre-publication queue, and no per-user upload throttle on images (the 20-per-model cap is the
only bound). If the plugin lets any user attach a photo to any model, that's a new abuse
surface with only reactive tooling behind it.

---

## Stages 4–5 — Slicing (later)

The STEP → mesh conversion **already exists and works**. `_generate_step_thumbnail`
(`tasks.py:197`) writes the STEP to a temp file, loads it through trimesh (with `cascadio`
providing the OCCT bridge), concatenates the scene into a single `Trimesh`, renders a PNG —
and drops the mesh. `_collect_render_targets` does the same walk across ZIP members, capped
at `MAX_AUTO_RENDERS_PER_ZIP = 10`, preferring `cad/` over `exports/`.

So the hard part — headless OCCT in a container that actually runs — is solved. What's
missing is persistence and an API:

1. In `render_upload`, where the mesh is already in memory, also export STL or GLB to the
   private bucket.
2. Register it as a `model_files` row with `role="export"` and a `storage_key`. The existing
   `GET /models/{id}/files/{file_id}/download` then serves it with no new endpoint — and it
   shows up in `CADModelDetail.files[]` automatically.
3. Backfill existing STEP versions with a script.

That gets you "every STEP model also has a downloadable mesh" without any new surface area.
It also produces the bounding box (item 6) as a by-product, since you need the mesh loaded
either way — worth doing these two together in one pass over the corpus.

What is *not* there and would be a genuine build: on-demand conversion (an
upload-STEP-get-STL endpoint), a job submission + status API for it, any slicer integration,
and any G-code handling. Note that `worker-render` runs with `ingress=internal` and Cloud
Tasks OIDC auth (`worker_render_main.py`), so the plugin can't call it directly — any
on-demand path has to go through the public backend, which means a job queue and a polling
endpoint, not a synchronous call. `.gcode`, `.nc` and `.tap` are already in `ALLOWED_TYPES`
for upload, but nothing generates or interprets them.

---

## Cross-cutting

**Versioning — none.** No `/v1` prefix, no `Accept-Version` header, no deprecation policy.
`info.version` is `0.1.0` and hasn't moved across six phases. The frontend is deployed in
lockstep with the backend so it has never mattered; a plugin installed on hundreds of
Raspberry Pis that update on their own schedule changes that completely. Adding a version
prefix is dramatically cheaper before the first plugin ships than after.

**Auth for non-browser clients — mechanism fine, minting missing.** Covered in Stage 1. One
detail worth recording: Authentik/OIDC was retired 2026-08-16. It is now direct Google +
GitHub OAuth with PKCE, matching on `google_sub` / `github_id`, with deliberate guards
against identity overwrite (`_set_github_id`) and against logging in as the archive bot
(`_guard_not_archive_bot`).

**Rate limiting — downloads only.** Detailed under Stage 2. Nothing guards search, detail,
comments or uploads at the request level.

**Public API documentation — auto-generated only.** Swagger at `/api/docs`, OpenAPI JSON at
`/api/openapi.json`, linked from the site's `/docs` page under "API Reference" (that page
carries a "Work in Progress" banner). The schema's weakest point for a third-party
integrator: **no `components.securitySchemes` and no `security` block on any operation.**
Auth is a plain `Depends(get_current_user)`, which FastAPI doesn't translate into a security
requirement, so `openapi-generator` produces a client with no way to attach credentials, and
nothing in the published docs tells an integrator that `Authorization: Bearer` is accepted.
Declaring an `HTTPBearer` security dependency would fix the generated docs, the generated
clients, and the "how do I authenticate" question in one change.

---

## Suggested order of work

1. **Device code flow or PAT, with `jti` + scope claims from day one** — nothing else in
   Stage 1 can ship without it.
2. **Decide the CORS posture** — proxy-through-the-Pi is less backend work and more secure;
   decide now because it determines the plugin's entire architecture.
3. **Bounding box: extract, store, index, filter, backfill** — the headline feature, and the
   longest lead time because of the backfill.
4. **Mesh export persisted as a `model_files` export row** — same pass over the corpus as
   #3, and it retires most of Stage 4.
5. **Index `has_printable` / member types from the ZIP manifest** — makes the STL-vs-CAD
   filter actually correct.
6. **`file_size` into `ModelVersionOut` and the Meili document** — small, removes an N+1
   from every list view.
7. **Version the API and declare `HTTPBearer` in the schema** — cheap now, expensive later.
8. **Close the `private`-model read/download gap and decide on `/files/{id}/download`
   limits** — before a public client makes ID enumeration cheap.
9. **`shared_prints` table + `shared_print` report target** — Stage 3, independent of
   everything above.
