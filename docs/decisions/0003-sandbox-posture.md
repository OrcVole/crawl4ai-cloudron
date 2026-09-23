# ADR 0003: the Chromium sandbox is off, and why

Status: accepted, 2026-09-23. The store-description sentence below needs the operator's
agreement before publish.

## Context

Chromium isolates each page's renderer in a sandbox. On Linux that needs unprivileged user
namespaces or the setuid `chrome-sandbox` helper. Upstream ships `--no-sandbox` in its default
browser arguments, and offers `CRAWL4AI_CHROMIUM_SANDBOX=true` to drop it on hosts that allow a
sandbox.

Probed inside a real Cloudron app container on 2026-09-23: Docker's seccomp filter is active
(`Seccomp: 2`) and the host sets `kernel.apparmor_restrict_unprivileged_userns=1`, so
`unshare --user` fails with "Operation not permitted". `NoNewPrivs` is 0, so setuid binaries
run, but the setuid helper needs `CAP_SYS_ADMIN` to create PID and network namespaces, and the
container's capabilities are Docker's default set without it. Neither route exists. Cloudron's
own browserless package also runs `--no-sandbox` (forum topic 15999).

## Decision

- Run Chromium with `--no-sandbox`. Keep `CRAWL4AI_CHROMIUM_SANDBOX` false: setting it would only
  stop Chromium from starting.
- Compensating controls, all on by default and not operator-togglable through the package's
  documented settings:
  - the mandatory API token (ADR 0002), so only callers the operator trusts can make the browser
    open a page;
  - internal addresses refused (ADR 0004);
  - `CRAWL4AI_HOOKS_ENABLED=false`, so callers cannot run their own Python hooks;
  - `CRAWL4AI_ALLOW_INSECURE_TLS=false`;
  - the container's own isolation: non-root, read-only root, Docker's default capabilities and
    seccomp.
- **Proposed store-description sentence** (operator to agree):
  "Chromium's page sandbox cannot run inside a Cloudron app container, so pages are rendered
  with it switched off. Only callers holding the API token can make the browser open a page, and
  it refuses addresses inside your server's network; treat it as a service for pages you choose,
  not for arbitrary links from untrusted people."

## Consequences

- A renderer exploit in a page the crawler opens would reach the container, not the host. The
  container holds the API token and the page cache, nothing else of value.
- If Cloudron ever grants a sandbox (user namespaces or `CAP_SYS_ADMIN` per app), revisit: set
  `CRAWL4AI_CHROMIUM_SANDBOX=true` and re-run gate 0.
