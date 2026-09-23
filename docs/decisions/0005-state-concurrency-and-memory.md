# ADR 0005: state, writable paths, concurrency and memory

Status: accepted, 2026-09-23.

## State

Crawl4AI keeps nothing that must survive. Upstream runs read-only with six tmpfs mounts, which
states plainly that its state is disposable:

| Upstream path | Holds | Package location |
|---|---|---|
| `/tmp` | Chromium temp files (with `--disable-dev-shm-usage`, Chromium uses this instead of `/dev/shm`) | `/tmp` |
| `/var/lib/redis` | the job queue's Redis data | `/run/redis`, owned by the app user |
| `/var/lib/crawl4ai/outputs` | transient crawl outputs | `/run/crawl4ai/outputs` |
| `/home/appuser/.crawl4ai` | a SQLite page cache (`crawl4ai.db`), cleaned-HTML and extraction caches, a log | `/run/crawl4ai/home` (see below) |
| `/home/appuser/.cache/url_seeder` | URL-seeder cache | `/tmp/url_seeder` |
| `/home/appuser/.gunicorn` | gunicorn worker temp | `/run/gunicorn` |

- **No `backupCommand`, no `persistentDirs`.** The only thing in `/app/data` is the API token and
  the operator's `env` file, which the ordinary backup covers.
- The page cache lives in `/run`, so it is empty after every restart. Upstream's API bypasses the
  cache by default (responses report `"cache": "0"`), so nothing is lost.
- **Redis must move.** Upstream's `/var/lib/redis` is `root:root 0750` in the image and Redis runs
  as the app user, so with a read-only root it fails at start with `FATAL CONFIG FILE ERROR ...
  Permission denied` and the job queue silently has no Redis (gate 0, finding 6). The package runs
  Redis with `--dir /run/redis`, created and owned by the app user in `start.sh`, bound to
  loopback, with a per-boot password as upstream's entrypoint does.
- The process runs as `cloudron` (uid 1000), not upstream's `appuser` (999). `HOME` points at
  `/run/crawl4ai/home` so upstream's `~/.crawl4ai` lands in writable space.

## Concurrency and memory

Gate 0 (`evidence/GATE0-VERDICT.md`) measured, on 80 heavy generated pages:

- 64 MiB of `/dev/shm` is not a constraint: zero renderer crashes at 40 pages whenever memory
  sufficed.
- Throughput is flat at about 2.8 pages per second from 10 to 40 concurrent pages. More pages in
  flight buy latency and memory, not speed.
- Memory: about 570 MB idle plus roughly 45 to 80 MB per page in flight.
- Upstream's `memory_threshold_percent` does not protect the HTTP endpoints: at a 2 GiB cap and
  40 pages, renderers were killed and about half the requests failed with 502, at 95% and at 70%
  alike.
- `pool.max_pages` does protect them: at 10, forty simultaneous clients all succeeded under a
  2 GiB cap, with 1.36 GB peak and the same wall time as upstream's default under 4 GiB.

**Decision:** the package's `config.yml` sets `crawler.pool.max_pages: 10`, and the manifest's
`memoryLimit` is **2 GiB, provisionally**, until P4's memory gate on real-world pages confirms or
raises it. Operators who raise `max_pages` must raise the memory limit with it (about 3 GiB for
20, 4 GiB or more for 40); `POSTINSTALL.md` and the description say so.

## Configuration mechanism

Upstream loads `config.yml` from the directory holding `server.py`
(`Path(__file__).parent / "config.yml"`), not from the working directory, and the only
environment overrides it applies are `LLM_PROVIDER`, `LLM_API_KEY` and `REDIS_TASK_TTL`. There is
no environment variable for `max_pages`.

So:

- At build time, `/app/code/c4ai/config.yml` becomes a symlink to `/run/crawl4ai/config.yml`.
  That is the only change to upstream's tree, and it is a configuration file, not code.
- The package ships its defaults as `/app/code/config.defaults.yml`: upstream's file with
  `crawler.pool.max_pages: 10`.
- On every boot `start.sh` writes the effective `/run/crawl4ai/config.yml`: the package defaults,
  deep-merged with `/app/data/config.override.yml` if the operator created one, and then the
  security settings re-asserted last so an override cannot switch them off (the hooks setting and
  the insecure-TLS setting).
- `LLM_PROVIDER` and `LLM_API_KEY` are ordinary operator settings in `/app/data/env`.
  `CRAWL4AI_ALLOW_INTERNAL_URLS` and `CRAWL4AI_CHROMIUM_SANDBOX` are forced after that file is
  sourced (ADRs 0003 and 0004).

Verified 2026-09-23 against the pinned image: `/md` and `/screenshot` both refuse an internal
hostname, a private IP, loopback and `169.254.169.254` ("URL blocked (SSRF protection)"), and
both succeed on a public page.
