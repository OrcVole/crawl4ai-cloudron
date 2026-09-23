# Changelog

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
