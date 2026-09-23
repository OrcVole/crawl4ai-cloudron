<upstream>0.9.4</upstream>

# Notes for Crawl4AI's own developers

Packaging Crawl4AI for Cloudron (a managed container platform) surfaced a few places where a
constrained container environment differs from the reference deployment. Offered in case any are
useful; none of this is a complaint, the application itself packaged cleanly.

- **No Chromium sandbox is available inside a Cloudron container** (no `CAP_SYS_ADMIN`, restricted
  user namespaces, 64 MiB `/dev/shm`), so we run with `--no-sandbox` and compensate at the API layer
  instead (mandatory token, default refusal of internal-network URLs, disabled scripting hooks).
  This is the same situation every headless-browser app faces in this kind of environment, not
  specific to Crawl4AI.
- **`memory_threshold_percent` does not protect the HTTP endpoints**, only the internal dispatcher.
  A single large `/crawl` batch can push memory past the configured threshold with nothing refusing
  the request. We plan to file this as a separate issue with a reproduction.
- **Redis needs a writable directory that is not `/var/lib/redis`** in a read-only-root container;
  we relocate it via `dir` in the generated `redis.conf`.
- Everything else (the config.yml loader, the artifact directory, the job queue) was
  straightforward to point at container-writable paths with existing config, no patches needed.

Package repository: https://github.com/OrcVole/crawl4ai-cloudron
