# ADR 0001: build shape

Status: accepted, 2026-09-23.

## Context

Upstream publishes a versioned image, `unclecode/crawl4ai`, built on Debian bookworm: a
self-contained Python 3.12.14 in `/usr/local` (865 MB with its packages), the API server in
`/app` (1.7 MB), Playwright's Chromium and headless shell in `/home/appuser/.cache/ms-playwright`
(651 MB), Redis 8.10.1, and supervisor running Redis and one gunicorn worker. Every other package
in this fleet ships `cloudron/base` as its final stage, so the platform's tooling (web terminal,
file manager, `gosu`, supervisor, the logging conventions) behaves the same everywhere.

## Decision

Copy upstream's runtime onto `cloudron/base:5.0.0`, pinned by digest, from the upstream image
pinned by digest:

- `/usr/local/bin`, `/usr/local/lib`, `/usr/local/include` from upstream. There are no name
  clashes: the base's `/usr/local/bin` holds only `gosu`, and its Node lives in its own directory.
  Upstream's Python therefore shadows the base's `python3` on `PATH`, which is intended.
- `/app` from upstream to `/app/code/c4ai`, unmodified.
- The Playwright browsers to `/app/code/ms-playwright`, with `PLAYWRIGHT_BROWSERS_PATH` set.
- Chromium's system libraries from `playwright install-deps chromium`, which supports Ubuntu
  24.04, and `redis-server` from the Redis apt source the base already configures.

Upstream's code is never patched. Configuration is a package-owned `config.yml` passed to the
server (ADR 0005), not an edit to upstream's copy.

## Evidence

Gate 0's build-shape probe (`evidence/GATE0-VERDICT.md`, finding 7): the copied tree on
`cloudron/base` launched Chromium and crawled a real page as uid 1000, with a read-only root and a
64 MiB `/dev/shm`. With the browsers hidden, the same probe failed with Playwright's own error,
so the pass was not vacuous.

## Consequences

- Upstream bumps are a digest change in two `FROM` lines, and a re-run of the probe.
- The image is about 1.5 GB plus the base, like upstream's.
- Fallback, if a future upstream needs a library Ubuntu cannot supply: build `FROM` upstream's
  image and record the exception here.
