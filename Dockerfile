# syntax=docker/dockerfile:1
#
# Build shape per docs/decisions/0001-build-shape.md: copy upstream's self-contained Python
# runtime, application source and Playwright browsers onto the Cloudron base image, unmodified,
# then let Playwright install Chromium's system libraries for this base's Ubuntu release. Proven
# in gate 0's build-shape probe (evidence/GATE0-VERDICT.md, finding 7): the copied tree launched
# Chromium and crawled a real page as uid 1000, read-only root, 64 MiB /dev/shm.

# ARG documents which upstream release this digest was resolved from. The build is pinned by
# DIGEST, not by this ARG or a tag: Docker Hub tags can be reassigned, so the digest below was
# resolved from the v0.9.5 GitHub release (a security release) with skopeo on 2026-10-16.
ARG C4AI_VERSION=0.9.5

# Stage 1: upstream's own image. Source of /usr/local (Python 3.12.15 + the crawl4ai package),
# /app (the API server), and the Playwright browser cache.
FROM docker.io/unclecode/crawl4ai@sha256:0b05666882bfb67f45d559a5b827839c54127b74aedd723f8ab338a3571b5fc9 AS upstream

# Official Node.js 24.22.1 (security release 2026-10-20), glibc build; source of the replacement driver node.
FROM docker.io/library/node:24.22.1-bookworm-slim@sha256:2dd9a4f758e173b65fee15388f7706af6fb01ef50cf7a2c0538711d67a6981ae AS officialnode

# Stage 2: the Cloudron base image. This is the ONLY stage that ships.
# 6.0.1 (Ubuntu 26.04, glibc 2.43; the security patch of 2026-10-21 over 6.0.0, which was resolved with
# skopeo on 2026-10-16). Moved from 5.1.0 by
# estate/doctrine/base-6-migration.md. crawl4ai uses none of the base's own runtimes: Python comes
# from the upstream image (copied under /usr/local, ahead of the base's python3.14 on PATH), and the
# package never used the base's Node (base 6 has none, so nothing changes there).
FROM docker.io/cloudron/base:6.0.1@sha256:7b1e729960c3ca312d26e886917ba89483241bba0219ff292858e10d9d5768ee

ARG C4AI_VERSION
LABEL org.opencontainers.image.version="${C4AI_VERSION}" \
      org.opencontainers.image.source="https://github.com/OrcVole/crawl4ai-cloudron"

# No name clashes: the base's /usr/local/bin holds only gosu (base 6 has no Node at all).
# Upstream's python3 therefore becomes the
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

# --- Deliberate exception to "unmodified" above (docs/decisions/0001-build-shape.md): a trivy
# scan comparing this image against bare cloudron/base:5.1.0 (2026-09-23) found every CRITICAL
# inherited unmodified from the base (unreachable: node-tar and Go stdlib TLS binaries we never
# invoke), but three of upstream's own frozen Python packages carried real, fixed HIGH CVEs --
# PyJWT (CVE-2026-32597, CVE-2026-48526), msgpack (GHSA-6v7p-g79w-8964), setuptools
# (CVE-2025-47273). PyJWT is unreachable here too (start.sh forces security.jwt_enabled=False,
# so nothing calls it), but the fix is one line and safe: bump in place, don't wait for upstream's
# next image. Pure-Python packages only, no native rebuild risk; the build gate below still fails
# the build if this broke anything.
#
# pip itself is then removed. Nothing at runtime calls it (crawl4ai's own "pip install ..." strings
# are error-message hints only), and its vendored copies (pip/_vendor/vendor.txt lists msgpack
# 1.1.2 and setuptools 70.3.0) kept the fixed CVEs visible to scanners after the real packages were
# bumped. A package manager in a read-only runtime image is dead weight anyway.
RUN /usr/local/bin/python3 -m pip install --no-cache-dir --upgrade \
    "PyJWT>=2.13.0" "msgpack>=1.2.1" "setuptools>=78.1.1" \
 && /usr/local/bin/python3 -m pip uninstall -y pip \
 && ! /usr/local/bin/python3 -c "import pip" 2>/dev/null \
 && ! ls /usr/local/bin/pip* 2>/dev/null

# --- Node.js security release (CVE-2026-111497 Brotli RCE, TLS hostname bypasses, CA store): Playwright
# and Patchright each bundle their own node (24.21.0) in driver/. Replace both with the official 24.22.1
# binary (stage "officialnode") and fail the build if either does not report it.
COPY --from=officialnode /usr/local/bin/node /tmp/node-official
RUN set -eu; \
    for d in playwright patchright; do \
      t=/usr/local/lib/python3.12/site-packages/$d/driver/node; \
      [ -f "$t" ] || { echo "FATAL: $t missing"; exit 1; }; \
      install -m 0755 /tmp/node-official "$t"; \
      [ "$("$t" --version)" = "v24.22.1" ] || { echo "FATAL: $t is not v24.22.1"; exit 1; }; \
      echo "gate: $d driver node $("$t" --version)"; \
    done; \
    rm -f /tmp/node-official

# --- Build gate: fail the BUILD, not the first boot, if the copied tree does not import or the
# server module does not construct. Mirrors wger's build-shape gate (docs/decisions/0001).
RUN /usr/local/bin/python3 -c "import crawl4ai, playwright; from crawl4ai.__version__ import __version__ as v; print('crawl4ai', v, 'import OK')"

# --- Library gate (base-6-migration.md step 6b): every ELF file Chromium, its headless shell and
# Playwright's bundled driver ship must resolve every shared library in THIS image. Measured
# 2026-10-16: the only unresolved names anywhere in /usr/local and the browser cache were Python's
# optional _tkinter (libtcl8.6, libtk8.6) and nis (libnsl.so.2) extensions, which neither base 5.1.0
# nor base 6.0.0 resolved, so they are not regressions and are not used.
RUN set -eu; \
    bad=0; \
    for f in $(find /app/code/ms-playwright /usr/local/lib/python3.12/site-packages/playwright/driver -type f \( -name '*.so' -o -name '*.so.*' -o -perm -u+x \)); do \
      head -c4 "$f" | grep -q ELF || continue; \
      if ldd "$f" 2>/dev/null | grep -q 'not found'; then echo "UNRESOLVED in $f:"; ldd "$f" | grep 'not found'; bad=1; fi; \
    done; \
    [ "$bad" = 0 ] && echo "ldd gate ok: browser binaries and Playwright driver fully resolved"

# --- Runtime gate: launch headless Chromium through the server's own library path and load a local
# file (no network). The bind mount keeps the gate script out of the shipped image.
RUN --mount=type=bind,source=test/chromium-gate.py,target=/tmp/chromium-gate.py \
    HOME=/tmp/gate-home CRAWL4AI_NO_CLOUD_NOTICE=1 /usr/local/bin/python3 /tmp/chromium-gate.py; \
    rm -rf /tmp/gate-home

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
