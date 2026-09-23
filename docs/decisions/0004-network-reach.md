# ADR 0004: internal addresses stay refused

Status: accepted, 2026-09-23.

## Context

A crawler inside Cloudron's Docker network can be asked to fetch internal addresses: other apps'
containers, the addon hosts, the platform's own services. The token limits who can ask, but a
leaked token would otherwise turn the crawler into a scanner of the server's private network.

Upstream 0.9.3 already guards this. `egress_broker.py` refuses private, loopback, link-local and
reserved destinations unless `CRAWL4AI_ALLOW_INTERNAL_URLS=true`, and routes Chromium through a
pinning proxy so the browser never resolves the target itself. That defeats DNS rebinding and
redirects to internal addresses. The same broker covers `/crawl`, `/md`, `/html`, `/screenshot`,
`/pdf` and `/execute_js`.

Note for operators: other apps on the same Cloudron are reached through their public domain names,
which resolve to the server's public address and are therefore not "internal". Refusing internal
addresses does not stop the crawler reading a public app on the same server, which is the intended
behaviour.

## Decision

- Keep upstream's default. The package sets `CRAWL4AI_ALLOW_INTERNAL_URLS=false` explicitly in
  `start.sh`, after sourcing the operator's `/app/data/env`, so an override there cannot switch it
  on by accident. An operator who truly needs it must edit the package's start behaviour, which is
  deliberate friction.
- Proving Ground gate (P4): a request for an internal address, such as the app's own container
  IP or an addon host, must be refused, and a public page must still work. Record both.

## Consequences

Gate 0 had to set `CRAWL4AI_ALLOW_INTERNAL_URLS=true` because its test site lived on a private
network; the harness says so, and the package never does.
