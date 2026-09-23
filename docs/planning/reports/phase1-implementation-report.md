# Phase 1 implementation report: backend foundations

**Date:** 2026-09-23
**Spec:** `docs/planning/execution-plan.md`, Phase 1 (1a–1d)
**Where the code is:** `mloy97/CommunityCADPlatform`, branch `phase-1-backend-foundations`,
[PR #31](https://github.com/mloy97/CommunityCADPlatform/pull/31)
**Status:** implemented and tested locally, waiting for review. **Nothing has been deployed.**
Migration 0026 has only been run against local databases.

---

## 1. Summary

All four parts of Phase 1 are built, with tests:

| Part | What it does | Commit |
|---|---|---|
| 1a | Private models return 404 to everyone except the owner and admins, on the model page and all three download endpoints. `/files/{id}/download` now applies the download limit. | `c7bacfe` |
| 1b | Adds a `/v1` router for plugin endpoints only, the `X-Min-Plugin-Version` header, the Bearer auth declaration in OpenAPI, and list limits capped at 1–50. | `e838c99`, `c3285dc` |
| 1c | Device tokens and the RFC 8628 device code flow, migration 0026, and the `/link` and `/settings/devices` pages behind `PLUGIN_FEATURES_ENABLED` | `3b750f9` |
| 1d | Rate limiting on `/v1`: 120/min per token, 30/min per IP when signed out, 10/min per IP on `device/code` | `f534506` |
| docs | Test plan, new env vars, and the test command | `7ea2233` |

- 102 pytest tests pass.
- A Playwright run against a local backend and the built frontend covered the whole linking flow in a real browser.
- The rate limit was checked against real Redis.
- Nothing in the plugin code (`plugin/`) was changed.

---

## 2. How the session went

1. Read the three planning docs. Section 1, section 2, section 2a, section 2c, Phase 1 and section 5 of the execution plan were binding.
2. Found that the backend isn't in this repo. Attached `mloy97/CommunityCADPlatform`, cloned it, and read its `CLAUDE.md`, `deps.py`, `main.py`, `config.py`, the models router, `tier_service`, the auth router, the latest migrations and the frontend's auth helpers.
3. Set up a local test environment:
   - Postgres 16 with pgvector
   - Redis
   - a Python 3.12 virtualenv with the backend's dependencies
4. Confirmed that migrations 0001–0025 apply cleanly to an empty database.
5. Created `phase-1-backend-foundations` from `main` (`ba18a22`).
6. Did 1a, then 1b, 1c and 1d, running the test suite before each commit.
7. **Frontend.** `npm ci` failed because the repo's lockfile was already out of sync with `package.json` before this work. I installed without touching the lockfile, then ran `tsc`, ran `next build`, and started two built frontend servers, one with the flag on and one with it off.
8. **End-to-end run.** Seeded a user and used a locally minted session cookie. A Playwright script then played both sides: the plugin through HTTP calls, and the user in a browser.
   - It exposed a cramped phone layout on `/settings/devices`, which I fixed.
   - It also showed that the "Printer name" label wasn't attached to its input, which I fixed.
9. Re-read the whole diff before pushing. The only change: I replaced the header middleware with a plain ASGI one that only touches `/v1`, so website routes pass through exactly as before.
10. Pushed the branch and opened PR #31, whose description has the deploy and printer-test steps.

Mistakes I made along the way (none reached the branch):
- Early test runs failed because of test-script mistakes: I picked an admin route that turned out to be public, and a selector that also matched the nav search box.
- Two of my own process-kill commands matched their own shell and killed it.
- A stale frontend server kept serving old files after a rebuild.

---

## 3. What was built

### 1a. Security fixes (`backend/app/routers/models.py`)
- New helpers:
  - `_hidden_from(model, user)`: true for a private model when the caller is neither its owner nor an admin.
  - `_get_visible_model(...)`: loads the model and returns 404 when it's missing or hidden.
- `GET /models/{id}`: a private model returns 404 unless the caller is the owner or an admin. The check runs before `view_count` is incremented. Removed models still return 410 as before.
- `/download` and `/versions/{n}/download`: the same visibility check runs before any limit counting or `download_count` increment.
- `/files/{file_id}/download` now takes the optional user and Redis, checks visibility, and runs `check_download_limit`. It uses the same `model:{id}` dedupe key as the other two endpoints and returns the `X-Download-*` headers on the redirect. It still doesn't increment `download_count`, which is unchanged.

### Test harness (new: `backend/tests/`, `backend/pytest.ini`)
- Runs against real Postgres, because pgvector and `text[]` columns rule out SQLite. The schema is built with `alembic upgrade head`, so every test run also proves the migrations apply.
- Tables are truncated between tests.
- **Only runs against a database whose name ends in `_test`**, and creates `<db>_test` itself. The command is `docker compose exec backend pytest`.
- Redis is replaced with `fakeredis` (added to `requirements.txt`), and presigned URLs are stubbed.

### 1b. `/v1` router
- `app/routers/v1/__init__.py` defines the router and `MAX_PAGE_SIZE = 50`. It's mounted at `/v1`, which is `/api/v1` in production.
- `X-Min-Plugin-Version` is added to every `/v1` response, errors included, by a plain ASGI middleware in `main.py`. It's set by `MIN_PLUGIN_VERSION`, default `0.1.0`.
- `HTTPBearer` is declared as the `BearerAuth` scheme on every authenticated `/v1` route.

### 1c. Device tokens and the device code flow
**Migration `0026_device_tokens.py`** (additive only):
- `api_tokens`:
  - columns: `id`, `user_id`, `name`, `scopes text[]`, `token_hash` (unique), `created_at`, `last_used_at`, `revoked_at`, `client_name`, `client_version`
- `device_authorizations`:
  - columns: `id`, `device_code_hash` (unique), `user_code` (unique), `client_name`, `client_version`, `device_name`, `scopes`, `status`, `user_id`, `expires_at`, `interval_s`, `last_polled_at`, `created_at`
- Tested on a local database: upgrade, downgrade to 0025, upgrade again. The ORM models match the new tables.

**Tokens** (`app/services/device_auth_service.py`):
- Format: `ccad_` followed by 32 random bytes in base64url. Only the SHA-256 digest is stored.
- Valid until revoked. `last_used_at` is written at most once an hour.
- Scopes: `catalog:read`, `download`, `prints:write`, `posts:write`.

**Auth** (`app/deps.py`):
- `get_current_user` and `get_optional_user` refuse any `ccad_` token with 403. Every existing route (payments, account, admin, upload and the rest) rejects device tokens without being changed. JWT behavior is otherwise unchanged.
- `require_scope(*scopes)` is the only way a device token authenticates. A signed-in website session (cookie or JWT) holds every scope.
- `get_web_user` covers website sessions. `get_current_device_token` covers a plugin acting on its own token.
- `require_same_origin` guards against CSRF. Cookie-authenticated approve, deny, rename and revoke requests need an `Origin` (or `Referer`) from the site's own origins.

**Device flow:**
- User codes are `XXXX-XXXX` from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`. They expire after 10 minutes, with a 5-second poll interval.
- A poll arriving more than 1 second early gets `slow_down`, and the interval grows by 5 seconds.
- The token is minted once, under a row lock. Any later poll with the same code gets `invalid_grant`.

**Endpoints** (`app/routers/v1/device_auth.py`):

| Endpoint | Auth |
|---|---|
| `POST /v1/auth/device/code` | none (rate-limited per IP) |
| `POST /v1/auth/device/token` | none |
| `GET /v1/auth/device/{user_code}` | website session |
| `POST /v1/auth/device/{user_code}/approve` and `/deny` | website session + same origin |
| `GET /v1/auth/tokens` (limit 1–50) | website session |
| `PATCH` / `DELETE /v1/auth/tokens/{id}` | website session + same origin |
| `PATCH` / `DELETE /v1/auth/tokens/current` | the device token itself |

**Web pages** (Next.js):
- `/link` shows code entry (prefilled from `?code=`), a sign-in prompt, and an approve/deny screen with an editable printer name and plain-language scopes.
- `/settings/devices` lists connected printers with last-used and linked dates, and lets the user rename or disconnect each one.
- Both return 404 unless `PLUGIN_FEATURES_ENABLED=true` is set on the frontend service. The flag is read per request, so no rebuild is needed. Neither page is linked from the nav.

### 1d. Rate limiting (`app/rate_limit.py`)
- Built on the `limits` library, which is what slowapi uses underneath, with a moving window stored in Redis.
- The limit bucket is chosen after the credential is checked:
  - a valid device token or signed-in user gets 120/min;
  - anything else, including made-up tokens, shares the caller's IP limit of 30/min.
- `device/code` has an extra limit of 10/min per IP.
- If Redis is unreachable, the limiter logs a warning and lets requests through.
- A 429 response includes `Retry-After`.
- New settings: `RATE_LIMIT_ENABLED`, `RATE_LIMIT_STORAGE_URI`, `RATE_LIMIT_CLIENT_IP_FROM_RIGHT`.

### Docs updated in the platform repo
- `housekeeping/klipper_phase1_testplan.md`: the platform repo's CLAUDE.md asks for a test plan per phase.
- `housekeeping/backend_deploy.md`: optional `/v1` env vars.
- `housekeeping/frontend_build_args.md`: the runtime `PLUGIN_FEATURES_ENABLED` flag.
- `CLAUDE.md`: the backend test command.

---

## 4. Tests

102 tests, all passing:

| File | Covers |
|---|---|
| `test_model_visibility.py` | model page and all 3 download endpoints, for anonymous, other user, owner and admin callers, on both private and public models; a hidden model doesn't bump view or download counts; removed models still return 410 |
| `test_file_download_limits.py` | limit headers; 429 at the free daily limit, for both a user and an anonymous IP; the limit is shared with whole-model downloads; a model downloaded once today is free to download again |
| `test_v1_router.py` | the version header on `/v1` responses and not on website routes; website routes still work |
| `test_device_auth.py` | the whole device flow, expiry, **reusing a consumed code**, **`slow_down`**, deny, CSRF checks, scope checks, **device token rejected on unscoped routes** (account, payments, admin, upload, notifications), **revoked token → 401**, suspended user, `last_used_at` written hourly, the connected-devices endpoints, OpenAPI |
| `test_rate_limit.py` | all three limits; made-up tokens share the IP limit; website routes aren't limited; the limiter fails open; client IP selection |

To check the tests actually catch the 1a bugs, I ran them against the code as it was before 1a: 15 failed, all of them the private-model and file-download-limit cases.

---

## 5. Differences from the plan

1. **`device_name`:** an optional field on `device/code` and a nullable column. The approval screen needs a printer name, and the plan's request body had no field for one.
2. **`PATCH` / `DELETE /v1/auth/tokens/current`:** Phase 3 needs "Unlink" and "rename this printer" from the plugin itself, and the `{id}` routes only accept a website session.
3. **`username` in the token response:** lets the plugin show "Linked as …".
4. **`limits` instead of slowapi:** lets the limit bucket be chosen after the token is checked.
5. **403, not 401, for a valid device token on a route it can't use:** section 2c says the plugin deletes its token on the first 401, so 401 must only mean the token is revoked or unknown.
6. **Migration numbering:** Phase 1 uses **0026**, so the migration the plan calls 0026 in Phase 2 becomes **0027**.

The execution plan hasn't been updated yet. Phase 1 should be marked done after Miguel tests it in production.

---

## 6. Open questions for Miguel

- **Returning to `/link` after sign-in.** The sign-in callback always goes to `/`. Sending the user back to `/link` would change the website's own sign-in flow, which was off limits without asking. For now, sign-in opens in a new tab, and `/link` picks up the session when the user switches back.
- **Removed models can still be downloaded.** This predates the PR and is outside 1a.
- **Website file downloads now count toward the download limit** (a result of 1a). A user at the limit sees the raw 429 JSON instead of the usual limit message.
- **The client IP can be faked** through `X-Forwarded-For`, for both the existing download limits and the new rate limits. Set `RATE_LIMIT_CLIENT_IP_FROM_RIGHT=2` after checking a production request log.
- **`frontend/package-lock.json` is out of sync on `main`**, so `npm ci` fails. This predates the PR.

## 7. Not verified (needs production)

- Migration 0026 on Cloud SQL
- rate limiting through the production Redis
- real Google and GitHub sign-in from `/link`
- how the load balancer fills in `X-Forwarded-For`
- the two new pages in light mode

## 8. Next steps

1. **Take a Cloud SQL backup first.** Deploying the backend runs `alembic upgrade head`, which applies 0026.
2. Deploy the backend, then the frontend.
3. Set `PLUGIN_FEATURES_ENABLED=true` on the frontend service while testing.
4. Run the printer test script from the PR description over SSH on the Pi.
5. Review PR #31 and merge.
6. Update `execution-plan.md`: mark Phase 1 done, record the differences above, and change Phase 2's migration number to 0027.
