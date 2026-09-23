# crawl4ai-cloudron

A Cloudron package for [Crawl4AI](https://github.com/unclecode/crawl4ai), an open-source web
crawling and extraction API. Documentation for the upstream project is at
[docs.crawl4ai.com](https://docs.crawl4ai.com).

This repository is not affiliated with the Crawl4AI project. It packages the upstream application
for the Cloudron platform; application behaviour, features and bugs belong upstream.

## Licence

Crawl4AI is licensed Apache-2.0, with an Attribution Requirement appended to the LICENSE file.
This package mirrors that licence in `LICENSE` (fetched verbatim from the upstream repository at
the pinned tag) and satisfies the attribution requirement in `NOTICE` and in the store
description. The packaging code in this repository (Dockerfile, start script, configuration) is
offered under the same terms unless stated otherwise.

## Installation

Once this package is published, it will be available through the versions-url channel used by
this repository. Installation details (channel URL, `cloudron install` invocation) will be added
here once the package has a published version.

## Architecture

The package runs three processes under supervisor, all logging to stdout:

| Process | Role |
|---|---|
| gunicorn | The crawl4ai API server (FastAPI/uvicorn worker), bound directly on `httpPort` |
| redis | The server's own job queue backing store |
| fatal-exit | Eventlistener: shuts the container down if gunicorn or redis crash-loops, so a dead app never sits "healthy" |

State:

- **No persistent state beyond the API token.** The page cache, artifact store and job queue are
  all under `/run`, so they are empty after every restart; upstream's API bypasses the cache by
  default anyway. See [ADR 0005](docs/decisions/0005-state-concurrency-and-memory.md).
- **No `backupCommand`.** The API token in `/app/data/.secrets` is the only thing the ordinary
  filesystem backup needs to cover.

## Authentication

Token only: `CRAWL4AI_API_TOKEN` is generated once at first start and required on every request
(`Authorization: Bearer <token>`). There is no Cloudron SSO integration; this is a programmatic
API consumed by other applications, the same shape as this fleet's TEI, vLLM and Speaches
packages. See [ADR 0002](docs/decisions/0002-auth.md) for why `proxyAuth` does not fit here.

## The Chromium sandbox is off

Chromium's own page-isolation sandbox cannot run inside a Cloudron app container: it needs either
unprivileged user namespaces or a setuid helper with `CAP_SYS_ADMIN`, and neither is available.
This is not unique to Crawl4AI; Cloudron's own `browserless-cloudron-app` runs the same way. The
package compensates: the mandatory API token, a default refusal of internal-network addresses,
and scripting hooks disabled. See [ADR 0003](docs/decisions/0003-sandbox-posture.md) for the
platform probe that established this and the full reasoning.

## Internal addresses are refused by default

Upstream already guards against the crawler being used to reach addresses inside your server's
own network (other apps, addon hosts, cloud metadata services): `CRAWL4AI_ALLOW_INTERNAL_URLS` is
forced `false` by `start.sh`, after any operator override file is sourced, so it cannot be
switched on by accident. See [ADR 0004](docs/decisions/0004-network-reach.md).

## Concurrency and memory

The package caps concurrent page crawls at 10 (`crawler.pool.max_pages` in `config.defaults.yml`),
lower than upstream's own default of 40, because that is what fits safely inside the default
2 GiB `memoryLimit`. Measured in gate 0 (`docs/decisions/0005-state-concurrency-and-memory.md`):
upstream's own memory-pressure safeguard does not protect the HTTP endpoints under load, but
capping concurrent pages does. Raising `max_pages` (via `/app/data/config.override.yml`, deep-
merged over the defaults on every boot) needs raising the app's memory limit with it; roughly
3 GiB for 20 pages, 4 GiB or more for 40.

## Further documentation

- [docs/decisions/](docs/decisions/): architecture decision records for the build shape,
  authentication, the sandbox posture, network reach, and state/concurrency/memory.
- [NOTICE](NOTICE): the upstream attribution this package carries.
