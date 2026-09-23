#!/bin/bash
#
# test/smoke.sh: the runtime smoke test for io.github.orcvole.crawl4ai. Builds NOTHING -- it
# assumes the image tag below already exists locally. Runs it exactly as Cloudron would (read-only
# root, --shm-size=64m, /app/data bind mount) and asserts the behaviour in docs/decisions/. Every
# assertion is echoed PASS/FAIL; the script exits non-zero if any assertion failed. Cleans up on
# exit, including on failure, via a trap.
#
# Deliberately does NOT use `set -e`: a smoke test that stops at the first failing assertion hides
# every assertion after it.
set -uo pipefail

IMAGE="${SMOKE_IMAGE:-ghcr.io/orcvole/crawl4ai-cloudron:smoke}"
CRI="$(command -v podman || command -v docker || true)"
if [[ -z "${CRI}" ]]; then
    echo "FAIL: neither podman nor docker found on PATH"
    exit 2
fi

RUN_ID="c4ai-smoke-$$-${RANDOM}"
NET="${RUN_ID}-net"
SITE="${RUN_ID}-site"
APP="${RUN_ID}-app"
DATA_DIR=""
PAGES_DIR=""

FAIL_COUNT=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

CLEANED_UP=0
cleanup() {
    local ec=$?
    [[ "${CLEANED_UP}" == "1" ]] && return
    CLEANED_UP=1
    echo "--- cleanup ---"
    "${CRI}" rm -f "${APP}" "${SITE}" >/dev/null 2>&1 || true
    "${CRI}" network rm "${NET}" >/dev/null 2>&1 || true
    if [[ -n "${DATA_DIR}" ]]; then
        rm -rf "${DATA_DIR}" 2>/dev/null || "${CRI}" unshare rm -rf "${DATA_DIR}" 2>/dev/null || true
    fi
    [[ -n "${PAGES_DIR}" ]] && rm -rf "${PAGES_DIR}"
    exit "${ec}"
}
trap cleanup EXIT INT TERM

http_status() { curl -s -o /dev/null -m 30 -w '%{http_code}' "$@" 2>/dev/null || echo "000"; }

echo "=== crawl4ai Cloudron package smoke test ==="
echo "image under test: ${IMAGE}"

if ! "${CRI}" image exists "${IMAGE}" 2>/dev/null && ! "${CRI}" image inspect "${IMAGE}" >/dev/null 2>&1; then
    echo "FAIL: image ${IMAGE} is not present locally; this script does not build it (set SMOKE_IMAGE to override the tag)"
    exit 2
fi

DATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${RUN_ID}.data.XXXXXX")"
PAGES_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${RUN_ID}.pages.XXXXXX")"
chmod 0755 "${PAGES_DIR}"
cat > "${PAGES_DIR}/test.html" <<'EOF'
<!doctype html><html><body><h1>crawl4ai smoke test page</h1><p>smoke-test-marker-8f2c1a</p></body></html>
EOF
chmod 0644 "${PAGES_DIR}/test.html"

echo "--- network + local test site (no real site is loaded) ---"
"${CRI}" network create "${NET}" >/dev/null
"${CRI}" run -d --name "${SITE}" --network "${NET}" -v "${PAGES_DIR}:/usr/share/nginx/html:ro,Z" docker.io/library/nginx:alpine >/dev/null

echo "--- starting app container: read-only root, 64 MiB /dev/shm, as Cloudron runs it ---"
"${CRI}" run -d --name "${APP}" --network "${NET}" \
    -p "127.0.0.1::11235" \
    --read-only --shm-size=64m \
    -v "${DATA_DIR}:/app/data:Z" \
    "${IMAGE}" >/dev/null

HOST_PORT="$("${CRI}" port "${APP}" 11235/tcp 2>/dev/null | head -1 | sed -E 's/.*:([0-9]+)$/\1/')"
if [[ -z "${HOST_PORT}" ]]; then
    fail "could not determine the published host port for ${APP}/11235"
    echo "--- app container state and logs ---"
    "${CRI}" ps -a --filter "name=${APP}" --format '{{.Status}}' || true
    "${CRI}" logs "${APP}" 2>&1 | tail -40 || true
    exit 1
fi
BASE_URL="http://127.0.0.1:${HOST_PORT}"

# --- assertion 1: /health answers 200 within a reasonable window ---------------------------
health_ok=0
for _ in $(seq 1 30); do
    [[ "$(http_status "${BASE_URL}/health")" == "200" ]] && { health_ok=1; break; }
    sleep 1
done
[[ "${health_ok}" == "1" ]] && pass "/health returned 200" || fail "/health never returned 200"

# --- assertion 2: the API token was seeded, mode 0600 ---------------------------------------
TOKEN_MODE="$("${CRI}" exec "${APP}" stat -c '%a' /app/data/.secrets/api-token 2>/dev/null)"
[[ "${TOKEN_MODE}" == "600" ]] && pass "API token secret exists, mode 0600" || fail "API token missing or wrong mode (got '${TOKEN_MODE}')"
TOKEN="$("${CRI}" exec "${APP}" cat /app/data/.secrets/api-token 2>/dev/null)"

# --- assertion 3: a request with no token is refused -----------------------------------------
NO_TOKEN_STATUS="$(http_status -X POST -H 'Content-Type: application/json' -d '{"url":"https://example.com"}' "${BASE_URL}/md")"
[[ "${NO_TOKEN_STATUS}" == "401" ]] && pass "/md with no token returned 401" || fail "/md with no token returned ${NO_TOKEN_STATUS}, expected 401"

# --- assertion 4: a real crawl with the token succeeds and returns real page content ----------
# start.sh forces CRAWL4AI_ALLOW_INTERNAL_URLS=false unconditionally (docs/decisions/0004), even
# past an operator override, so the local test site on this harness's own network is exactly the
# kind of address the package must refuse -- it cannot be used for the "a crawl succeeds"
# assertion. example.com is stable, IANA-run and made for exactly this kind of test.
CRAWL_RESULT="$(curl -s -m 60 -X POST -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' -d '{"url":"https://example.com"}' "${BASE_URL}/md" 2>/dev/null)"
if echo "${CRAWL_RESULT}" | grep -q "Example Domain"; then
    pass "authenticated crawl of a real external page returned its own content"
else
    fail "authenticated crawl did not return real page content: ${CRAWL_RESULT:0:200}"
fi

# --- assertion 5: internal addresses are refused by default (docs/decisions/0004) -------------
SITE_IP="$("${CRI}" inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${SITE}" 2>/dev/null)"
INTERNAL_RESULT="$(curl -s -m 30 -X POST -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' -d "{\"url\":\"http://${SITE_IP}/test.html\"}" "${BASE_URL}/md" 2>/dev/null)"
if echo "${INTERNAL_RESULT}" | grep -qi "SSRF"; then
    pass "a raw internal IP address is refused (SSRF protection)"
else
    fail "a raw internal IP address was NOT refused: ${INTERNAL_RESULT:0:200}"
fi

# --- assertion 6: every application process runs as a non-root uid ----------------------------
PROC_REPORT="$("${CRI}" exec "${APP}" sh -c "ps -eo user,cmd | grep -v -E '^USER|^root '" 2>/dev/null)"
NON_ROOT_COUNT="$(echo "${PROC_REPORT}" | grep -c . || true)"
if [[ "${NON_ROOT_COUNT}" -ge 3 ]] && ! echo "${PROC_REPORT}" | grep -q '^root'; then
    pass "all non-supervisord processes run as a non-root uid (${NON_ROOT_COUNT} such processes)"
else
    fail "process/user report unexpected (${NON_ROOT_COUNT} processes): ${PROC_REPORT}"
fi

# --- assertion 7: the API token and SECRET_KEY never appear in container logs -----------------
LOGS="$("${CRI}" logs "${APP}" 2>&1)"
SECRET_KEY_VAL="$("${CRI}" exec "${APP}" cat /app/data/.secrets/secret-key 2>/dev/null)"
if echo "${LOGS}" | grep -qF "${TOKEN}"; then
    fail "the API token value appears in the container logs"
elif [[ -n "${SECRET_KEY_VAL}" ]] && echo "${LOGS}" | grep -qF "${SECRET_KEY_VAL}"; then
    fail "the SECRET_KEY value appears in the container logs"
else
    pass "API token and SECRET_KEY values do not appear in container logs"
fi

# --- assertion 8: idempotent secret seeding across a restart -----------------------------------
hash_secrets() { "${CRI}" exec "${APP}" sh -c 'sha256sum /app/data/.secrets/api-token /app/data/.secrets/secret-key 2>/dev/null'; }
BEFORE_HASH="$(hash_secrets)"
echo "--- restarting app container to test idempotent secret seeding ---"
"${CRI}" restart "${APP}" >/dev/null
restart_ok=0
for _ in $(seq 1 30); do
    [[ "$(http_status "${BASE_URL}/health")" == "200" ]] && { restart_ok=1; break; }
    sleep 1
done
if [[ "${restart_ok}" == "1" ]]; then
    pass "app answered /health again after restart"
else
    fail "app did not answer /health after restart"
fi
AFTER_HASH="$(hash_secrets)"
if [[ -n "${BEFORE_HASH}" && "${BEFORE_HASH}" == "${AFTER_HASH}" ]]; then
    pass "secret file hashes unchanged across a restart (idempotent seeding)"
else
    fail "secret file hashes CHANGED across a restart (seeding is not idempotent)"
fi

echo
if [[ "${FAIL_COUNT}" -eq 0 ]]; then
    echo "smoke test OK: all assertions passed"
    exit 0
else
    echo "smoke test FAILED: ${FAIL_COUNT} assertion(s) did not pass"
    exit 1
fi
