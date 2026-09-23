# Changelog

[1.0.2]

- Bump three of upstream's own bundled Python packages to close known HIGH-severity CVEs:
  PyJWT (CVE-2026-32597, CVE-2026-48526), msgpack (GHSA-6v7p-g79w-8964), and setuptools
  (CVE-2025-47273). PyJWT is not reachable in this package regardless, since JWT auth is forced
  off; the others get the same fix out of caution.
- Remove pip from the runtime image. Nothing in the running app uses it, and its own vendored
  copies of msgpack and setuptools still carried the fixed CVEs, so scanners kept reporting them.
  The image now has no known fixable HIGH or CRITICAL issue in its own Python packages; what
  remains is inherited unchanged from the Cloudron base image.

[1.0.1]

- Update Crawl4AI to 0.9.4, a security release: it closes two SSRF paths that bypassed the
  server's egress controls, and a trust-boundary bypass that could expose server environment
  variables to an API client. Updating is recommended.
- The app icon is now Crawl4AI's own mark, taken from the project's wordmark, replacing a
  placeholder.
- The store listing now shows a real screenshot instead of a placeholder.
- Rebuilt on `cloudron/base:5.1.0` (was `5.0.0`); no functional change, a newer Ubuntu 24.04 point
  release with more OS security patches.

[1.0.0]

- Initial package, wrapping Crawl4AI 0.9.3.
- Web crawling and extraction API: fetch a page with a real headless browser and get back
  Markdown, HTML, a screenshot, a PDF, or structured extraction. Also exposes an MCP endpoint for
  AI agent tools.
- Every request requires an API token, generated automatically at first start.
- The browser's own page sandbox cannot run inside a Cloudron container and is disabled; the API
  token, a default refusal of addresses on your server's own network, and disabled scripting
  hooks are the compensating protections. See the package README for the full reasoning.
- Concurrent page crawls capped at 10 by default (upstream's own default is 40), sized to the
  package's 2 GiB memory limit; both can be raised together.
- No persistent state beyond the API token: nothing else needs backing up.
- Includes software developed by UncleCode as part of the Crawl4AI project, Apache-2.0 with an
  attribution requirement (see NOTICE).
