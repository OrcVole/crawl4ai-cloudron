# syntax=docker/dockerfile:1
#
# Build shape per docs/decisions/0001-build-shape.md: copy upstream's self-contained Python
# runtime, application source and Playwright browsers onto the Cloudron base image, unmodified,
# then let Playwright install Chromium's system libraries for this base's Ubuntu release. Proven
# in gate 0's build-shape probe (evidence/GATE0-VERDICT.md, finding 7): the copied tree launched
# Chromium and crawled a real page as uid 1000, read-only root, 64 MiB /dev/shm.

# ARG documents which upstream release this digest was resolved from. The build is pinned by
# DIGEST, not by this ARG or a tag: Docker Hub tags can be reassigned, so the digest below was
# resolved from the v0.9.4 GitHub release (a security release) with skopeo on 2026-09-23.
ARG C4AI_VERSION=0.9.4

# Stage 1: upstream's own image. Source of /usr/local (Python 3.12.14 + the crawl4ai package),
# /app (the API server), and the Playwright browser cache.
FROM docker.io/unclecode/crawl4ai@sha256:9021b3cb5c6f12570bbcd5395638495e0a06969b3148e377b953d174af2ebc9b AS upstream

# Stage 2: the Cloudron base image. This is the ONLY stage that ships.
# 5.1.0, not 5.0.0: same Ubuntu 24.04/glibc 2.39 ABI (build-shape gate's findings still hold), but
# a newer Ubuntu point release (24.04.4, more OS security patches). crawl4ai does not use this
# base's bundled Node (it is not on PATH by that route; see the COPY below), so the base's Node
# 22 -> 24 bump is irrelevant here. Resolved with skopeo on 2026-09-23.
FROM cloudron/base:5.1.0@sha256:1c0666c9abe9e2090d33686826d4e97769b799124573118d41e0d7485135748e

ARG C4AI_VERSION
LABEL org.opencontainers.image.version="${C4AI_VERSION}" \
      org.opencontainers.image.source="https://github.com/OrcVole/crawl4ai-cloudron"

# No name clashes: the base's /usr/local/bin holds only gosu, and its Node lives under
# /usr/local/node-22.14.0, not on PATH by that route. Upstream's python3 therefore becomes the
# python3 this image runs, which is intended (docs/decisions/0001-build-shape.md).
COPY --from=upstream /usr/local/bin/       /usr/local/bin/
COPY --from=upstream /usr/local/lib/       /usr/local/lib/
COPY --from=upstream /usr/local/include/   /usr/local/include/
COPY --from=upstream /app/                 /app/code/c4ai/
COPY --from=upstream /home/appuser/.cache/ms-playwright/ /app/code/ms-playwright/

ENV PLAYWRIGHT_BROWSERS_PATH=/app/code/ms-playwright \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Chromium's system libraries (playwright install-deps resolves them for this base's Ubuntu
# release) and redis-server. No crawl4ai/Python packages are (re)installed; upstream's site-
# packages under /usr/local/lib came across in the COPY above unchanged.
RUN set -eux; \
    ldconfig; \
    apt-get update; \
    /usr/local/bin/python3 -m playwright install-deps chromium; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends redis-server; \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*; \
    redis-server --version

# --- Build gate: fail the BUILD, not the first boot, if the copied tree does not import or the
# server module does not construct. Mirrors wger's build-shape gate (docs/decisions/0001).
RUN /usr/local/bin/python3 -c "import crawl4ai, playwright; print('crawl4ai', crawl4ai.__version__, 'import OK')"

# Package config (docs/decisions/0005): upstream's own config.yml loader reads
# /app/code/c4ai/config.yml relative to server.py, so that path becomes a symlink into the
# writable effective-config location start.sh writes to on every boot. Upstream's original file
# ships alongside, untouched, as the base start.sh's defaults are derived from.
RUN mv /app/code/c4ai/config.yml /app/code/config.upstream.yml && \
    ln -s /run/crawl4ai/config.yml /app/code/c4ai/config.yml

COPY config.defaults.yml   /app/code/config.defaults.yml
COPY start.sh              /app/code/start.sh
COPY supervisor/supervisord.conf          /app/code/supervisor/supervisord.conf
COPY supervisor/fatal-exit-listener.py    /app/code/supervisor/fatal-exit-listener.py
COPY supervisor/conf.d/                   /app/code/supervisor/conf.d/
COPY NOTICE                               /app/code/NOTICE

RUN chmod 0755 /app/code/start.sh

WORKDIR /app/code

# No ENTRYPOINT: it breaks Cloudron debug mode. start.sh runs as root to create/chown writable
# paths and seed the API token, then hands off to supervisord, which runs every program as
# `cloudron`.
CMD ["/app/code/start.sh"]
