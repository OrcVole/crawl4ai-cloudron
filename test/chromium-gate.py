# test/chromium-gate.py: launches the image's headless Chromium through the same library code the
# server uses (AsyncWebCrawler, BrowserConfig) and loads a LOCAL file, so no network is needed.
# Asserts the page rendered, its JavaScript ran and a screenshot came back. Run by the Dockerfile in
# the runtime stage (the only stage), so a missing Chromium system library fails the BUILD, not the
# first crawl. --no-sandbox matches docs/decisions/0003; the build has no user namespaces either.
import asyncio, os, tempfile, sys
import crawl4ai
from crawl4ai import AsyncWebCrawler, BrowserConfig, CrawlerRunConfig, CacheMode
async def main():
    d = tempfile.mkdtemp()
    p = os.path.join(d, "gate.html")
    open(p, "w").write("<!doctype html><title>gate</title><h1>chromium-gate-marker</h1><p>"+("Offline gate page used to prove that headless Chromium launches, renders and runs page JavaScript. "*8)+"</p><p id=x></p><script>document.getElementById('x').textContent='js-ran-'+(6*7)</script>")
    bc = BrowserConfig(headless=True, extra_args=["--no-sandbox", "--disable-dev-shm-usage"])
    async with AsyncWebCrawler(config=bc) as c:
        r = await c.arun("file://" + p, config=CrawlerRunConfig(cache_mode=CacheMode.BYPASS, screenshot=True))
    assert r.success, r.error_message
    assert "chromium-gate-marker" in r.markdown.raw_markdown, r.markdown.raw_markdown
    assert "js-ran-42" in r.html, "page JavaScript did not run"
    assert r.screenshot and len(r.screenshot) > 200, "no screenshot"
    print("chromium gate ok:", crawl4ai.__version__ if isinstance(crawl4ai.__version__, str) else crawl4ai.__version__.__version__, "screenshot bytes(b64):", len(r.screenshot))
asyncio.run(main())
