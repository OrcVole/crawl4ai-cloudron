# AGENTS.md: crawl4ai Cloudron package working contract

The settled-decisions record for packaging **Crawl4AI** (`unclecode/crawl4ai`, Apache-2.0 with an
attribution rider) as a Cloudron community app. Read this before changing anything. **The box is
the authority, not the docs.**

## What this package is

Crawl4AI is an open-source web crawling and extraction API: it fetches a page with a real headless
Chromium and returns Markdown, HTML, a screenshot, a PDF, or structured extraction, over a REST API
and an MCP endpoint. This package wraps the upstream 0.9.3 release, copying its runtime onto
`cloudron/base` (docs/decisions/0001), and adapts only the runtime environment, never the
application itself.

Topology, one row per process, all logging to stdout:

| Process | Role | Port |
|---|---|---|
| gunicorn | The crawl4ai API server (uvicorn worker) | bound directly on `httpPort` 11235 |
| redis | Job queue backing store | 127.0.0.1:6379, per-boot password |
| fatal-exit | Eventlistener: shuts the container down if a program crash-loops | none |

State: **nothing persists except the API token.** The page cache, artifact store, url-seeder cache
and job queue all live under `/run`, disposable by design (upstream's own compose grants them as
tmpfs). No `persistentDirs`, no `backupCommand`.

## Golden rules

1. **Conformance to the Cloudron contract first.** Adapt the runtime environment only. Never
   patch the application itself.
2. **Pin everything by digest**: the base image and the upstream image. One build argument for
   the upstream version, mirrored in the manifest as `upstreamVersion`.
3. **Persisted state only in `/app/data`** (the API token and SECRET_KEY secrets, and an optional
   operator `config.override.yml`). Re-assert ownership and mode on every boot.
4. **Fail loud.** Never silently regenerate the API token; rotating it is an explicit operator
   action (delete the file, restart) and signs every caller out on purpose.
5. **Code and docs ship together.** ADRs in `docs/decisions/`.
6. **`CMD`, never `ENTRYPOINT`**, because `ENTRYPOINT` breaks Cloudron debug mode.
7. **Never patch upstream's application code.** The only change to upstream's own tree is turning
   `config.yml` into a symlink so the package can write the effective config at boot
   (docs/decisions/0005) — a configuration change, not a code change.
8. **The Chromium sandbox stays off, deliberately** (docs/decisions/0003), proven by a platform
   probe, not assumed. `CRAWL4AI_CHROMIUM_SANDBOX` is never set true by this package.
9. **`CRAWL4AI_ALLOW_INTERNAL_URLS` stays `false`, forced after any operator override is sourced**
   (docs/decisions/0004). This is the one setting `start.sh` will not let an operator file change.
10. **Anonymise before every push.** No box or mirror hostnames, no real emails, no tokens in any
    tracked file. `test/secret-scan.sh` is the release gate.
11. **Git hygiene.** No AI co-authorship and no tool-attribution trailers. Commit as the
    maintainer identity, set repo-local.
12. **No `proxyAuth`, no `oidc` addon.** This is a programmatic API for other applications to call
    (docs/decisions/0002); an SSO wall would break every caller.

## Settled decisions

- **Manifest id:** `io.github.orcvole.crawl4ai`. `author` and `packagerName` are `OrcVole`.
- **Registry:** `ghcr.io/orcvole/crawl4ai-cloudron`, pushed public so the box pulls without
  credentials.
- **Repos:** GitHub `OrcVole/crawl4ai-cloudron` is canonical; a Forgejo mirror under
  `WanderingMonster` exists alongside it.
- **memoryLimit:** provisional 2 GiB (`2147483648`), from gate 0's measured concurrency ceiling
  (docs/decisions/0005). The Proving Ground's idle-versus-production memory gate confirms or
  raises it against real-world pages, not the gate-0 synthetic ones.
- **Health:** `healthCheckPath = /health`, upstream's own unauthenticated endpoint, answered
  directly by gunicorn (no separate nginx and no bootstrap delay: there is no database to
  migrate, so readiness is immediate).
- **Build shape:** copy upstream's `/usr/local` (self-contained Python 3.12.14), `/app`, and the
  Playwright browser cache onto `cloudron/base:5.0.0`, then `playwright install-deps chromium`
  and install `redis-server` from apt. Proven by a build-shape probe before this package was
  written (docs/decisions/0001).

## Secrets

First-run only, idempotent, under `/app/data/.secrets`, mode 0600, re-asserted on every boot.

| Secret | Shape | Criticality | Notes |
|---|---|---|---|
| `api-token` | 64 hex chars | seed-once, not data-loss-critical | The only credential this package issues. Rotation locks callers out until reissued; orphans no stored data (there is none). Never regenerated once seeded. |
| `secret-key` | 64 hex chars | seed-once, cosmetic | Signs JWTs, which this package never issues (`security.jwt_enabled` forced false). Seeded only to silence upstream's own startup warning. |

## Environment mapping

| Application variable | Source or value | Notes |
|---|---|---|
| `CRAWL4AI_API_TOKEN` | seeded secret | exported before every boot's config write |
| `SECRET_KEY` | seeded secret | see Secrets table |
| `GUNICORN_BIND` | forced `[::]:11235` | a token is always present, so upstream's own entrypoint logic (loopback-only without one) never applies here; this package's `start.sh` sets the bind directly and does not run upstream's `entrypoint.sh` |
| `CRAWL4AI_CHROMIUM_SANDBOX` | forced `false` | docs/decisions/0003 |
| `CRAWL4AI_ALLOW_INTERNAL_URLS` | forced `false`, after operator env is sourced | docs/decisions/0004 |
| `CRAWL4AI_HOOKS_ENABLED`, `CRAWL4AI_ALLOW_INSECURE_TLS` | forced `false` | docs/decisions/0003 |
| `CRAWL4AI_ARTIFACT_DIR` | `/run/crawl4ai/outputs` | upstream's default (`/var/lib/crawl4ai/outputs`) is not writable on a read-only root |
| `HOME`, `PYTHONUSERBASE` | `/run/crawl4ai/home` | redirects upstream's `~/.crawl4ai` (SQLite cache) and `~/.cache/url_seeder`, both `Path.home()`/`expanduser` relative in the crawl4ai library |
| `LLM_PROVIDER`, `LLM_API_KEY` | operator, via `/app/data/env` | the only upstream-recognised environment overrides for LLM extraction; everything else in `config.yml` is set by the deep-merge in `start.sh` |

## Backup and restore

Nothing beyond the standard filesystem backup of `/app/data` (the two secrets, and an optional
operator config override). No `persistentDirs`, `backupCommand` or `restoreCommand`: every other
writable path is under `/run` and is disposable by design.

## Future compatibility

The single bump point for a version upgrade is the upstream image digest (and the
`upstreamVersion` manifest field, kept in step). Re-run the build-shape probe at every bump: a
future upstream Python version or a Chromium bump could need libraries the base image's Ubuntu
release cannot supply, which is the documented fallback in docs/decisions/0001.
