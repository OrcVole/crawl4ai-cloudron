## API token

Every request needs an API token, seeded automatically at first start. Read it from
`/app/data/.secrets/api-token`, using the Cloudron file manager or the app's web terminal:

```bash
cat /app/data/.secrets/api-token
```

## Try it

Fetch a page as Markdown:

```bash
curl -X POST https://your-app-address/md \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"url": "https://example.com"}'
```

## AI agent tools (MCP)

The app also exposes an MCP endpoint at `/mcp/sse` and `/mcp/ws`, using the same Bearer token.

## Security note

The browser's own sandbox cannot be enabled inside a container. The API token and a default
refusal of internal network addresses are the safeguards in its place. If you deliberately need
the crawler to reach an address on your own internal network, see the README rather than changing
this here.

## Concurrency and memory

The package caps concurrent page crawls at 10, lower than upstream's default of 40, because that
is what fits safely inside the default memory limit. Raising it needs raising the app's memory
limit too; see the README.
