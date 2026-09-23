#!/bin/bash
#
# start.sh: the crawl4ai Cloudron package entrypoint. Runs as root (CMD, never ENTRYPOINT -- see
# docs/decisions/0001) to create and chown writable paths and seed the API token, then hands off
# to supervisord via tini. There is no bootstrap.sh: crawl4ai has no database to migrate and no
# slow first-run step, so gunicorn answering /health is the whole readiness story
# (docs/decisions/0005 -- no persistent state).
set -euo pipefail
umask 022

log() { printf '==> %s\n' "$*"; }

SECRETS_DIR=/app/data/.secrets
TOKEN_FILE="${SECRETS_DIR}/api-token"
SECRET_KEY_FILE="${SECRETS_DIR}/secret-key"

# --- 1. Persisted state: only /app/data, re-assert ownership and mode on EVERY boot -------------
mkdir -p /app/data "${SECRETS_DIR}"
chown -R cloudron:cloudron /app/data
chmod 0700 "${SECRETS_DIR}"

# --- 2. Seed the API token once (docs/decisions/0002). Never regenerated once seeded: rotation is
#    an operator action (delete the file, restart), which is documented in POSTINSTALL.md and
#    signs every existing caller out on purpose. -------------------------------------------------
if [[ ! -s "${TOKEN_FILE}" ]]; then
    log "seeding CRAWL4AI_API_TOKEN (first boot)"
    ( umask 077; openssl rand -hex 32 > "${TOKEN_FILE}" )
fi
chmod 0600 "${TOKEN_FILE}"
chown cloudron:cloudron "${TOKEN_FILE}"
export CRAWL4AI_API_TOKEN
CRAWL4AI_API_TOKEN="$(cat "${TOKEN_FILE}")"

# SECRET_KEY signs JWTs, which this package never issues (jwt_enabled is forced false and the
# /token endpoint's own api_token is left empty in the merged config, both below -- see
# auth.py's fail-closed get_token()). Seeded anyway so upstream stops warning on every boot; not
# treated as data-loss-critical, since nothing of ours depends on it.
if [[ ! -s "${SECRET_KEY_FILE}" ]]; then
    openssl rand -hex 32 > "${SECRET_KEY_FILE}"
fi
chmod 0600 "${SECRET_KEY_FILE}"
chown cloudron:cloudron "${SECRET_KEY_FILE}"
export SECRET_KEY
SECRET_KEY="$(cat "${SECRET_KEY_FILE}")"

log "API token present (value never logged)"

# --- 3. /run does not persist across restarts: (re)create every writable path this boot, before
#    supervisord starts. These are the six paths upstream's own compose grants as tmpfs
#    (docs/decisions/0005), redirected off the read-only paths in upstream's image. ---------------
mkdir -p /run/supervisor /run/redis /run/crawl4ai/home /run/crawl4ai/outputs \
         /run/crawl4ai/url_seeder /run/gunicorn
chown -R cloudron:cloudron /run/redis /run/crawl4ai /run/gunicorn
chown root:cloudron /run/supervisor
chmod 0750 /run/supervisor
chmod 0700 /run/redis

# --- 4. Redis: ephemeral queue state only (docs/decisions/0005), so a fresh password every boot
#    is correct, not a shortcut -- there is nothing to reconnect to across a restart. -------------
REDIS_PASSWORD="$(openssl rand -hex 32)"
cat > /run/redis/redis.conf <<EOF
bind 127.0.0.1 -::1
port 6379
dir /run/redis
requirepass ${REDIS_PASSWORD}
loglevel notice
EOF
chown cloudron:cloudron /run/redis/redis.conf
chmod 0600 /run/redis/redis.conf

# --- 5. Effective configuration (docs/decisions/0005): package defaults deep-merged with an
#    optional operator override, written to the path upstream's own config.yml symlink resolves
#    to. Security-relevant keys are re-asserted AFTER the merge so an override file cannot weaken
#    them; the sandbox, network-reach and hooks postures are enforced via environment below, not
#    through this file, because upstream reads those via os.environ, not config.yml. -------------
OVERRIDE=/app/data/config.override.yml
gosu cloudron:cloudron python3 - "$OVERRIDE" <<'PYEOF'
import sys, yaml

def deep_merge(base, over):
    if isinstance(base, dict) and isinstance(over, dict):
        out = dict(base)
        for k, v in over.items():
            out[k] = deep_merge(base.get(k), v) if k in base else v
        return out
    return over if over is not None else base

with open("/app/code/config.defaults.yml") as f:
    cfg = yaml.safe_load(f) or {}

override_path = sys.argv[1]
try:
    with open(override_path) as f:
        override = yaml.safe_load(f) or {}
    cfg = deep_merge(cfg, override)
    print(f"==> operator override merged from {override_path}")
except FileNotFoundError:
    pass

# security.jwt_enabled is a config.yml key, not an environment variable (unlike hooks_enabled and
# allow_insecure_tls, which upstream DOES read from os.environ -- see start.sh's exports below).
# Re-assert it after the merge, last, so an override file cannot turn JWT issuance on: the static
# API token is the package's only credential (docs/decisions/0002). api_token also stays out of
# this file on purpose -- the token reaches gunicorn as CRAWL4AI_API_TOKEN, an environment
# variable, never written to a file an operator override could accidentally expose.
cfg.setdefault("security", {})
cfg["security"]["jwt_enabled"] = False
cfg["security"]["api_token"] = ""

with open("/run/crawl4ai/config.yml", "w") as f:
    yaml.safe_dump(cfg, f, sort_keys=False)
PYEOF
chmod 0644 /run/crawl4ai/config.yml
chown cloudron:cloudron /run/crawl4ai/config.yml

# --- 6. Operator-tunable defaults, `:=` so /app/data/env (sourced next) can replace them. --------
: "${LLM_PROVIDER:=}"
: "${LLM_API_KEY:=}"
export LLM_PROVIDER LLM_API_KEY

if [[ -f /app/data/env ]]; then
    log "sourcing operator overrides from /app/data/env"
    # shellcheck disable=SC1091
    source /app/data/env
fi

log "forcing package security posture (always wins over operator overrides)"

# Bind: upstream's own entrypoint.sh refuses to expose on anything but loopback unless a token
# or JWT mode is configured. A token is always seeded above, so this is always the public bind;
# kept explicit rather than relying on upstream's entrypoint (this script replaces it, see below).
export GUNICORN_BIND="[::]:11235"
export REDIS_PASSWORD

# docs/decisions/0003: the Chromium sandbox cannot run in a Cloudron container -- proven, not
# assumed (probed 2026-09-23; see the ADR). Setting this true would only stop Chromium starting.
export CRAWL4AI_CHROMIUM_SANDBOX=false

# docs/decisions/0004: internal addresses stay refused. Forced after sourcing the operator file so
# an override there cannot switch it on by accident; a genuine need means editing this script.
export CRAWL4AI_ALLOW_INTERNAL_URLS=false

# No caller-supplied Python hooks, no disabling TLS verification (docs/decisions/0003). JWT mode
# (security.jwt_enabled) is a config.yml key, forced in the merge step above, not an env var.
export CRAWL4AI_HOOKS_ENABLED=false
export CRAWL4AI_ALLOW_INSECURE_TLS=false

export HOME=/run/crawl4ai/home
export PYTHONUSERBASE=/run/crawl4ai/home

# The crawl4ai library resolves its own state under $HOME/.crawl4ai and ~/.cache/url_seeder
# (crawl4ai/config.py, async_url_seeder.py), both already redirected above via HOME. The one
# writable path with no HOME-relative default is screenshot/PDF/execute_js artifact storage,
# which is hardcoded to /var/lib/crawl4ai/outputs unless overridden (deploy/docker/artifacts.py).
export CRAWL4AI_ARTIFACT_DIR=/run/crawl4ai/outputs

log "gunicorn bind ${GUNICORN_BIND}  max_pages from config.yml  internal-urls blocked  sandbox off"

# --- 7. Hand off. tini as pid 1 for correct signal disposition; supervisord runs every program as
#    cloudron (see supervisor/conf.d/*.conf). -----------------------------------------------------
log "handing off to supervisord"
exec /usr/bin/tini -- /usr/bin/supervisord --nodaemon --configuration /app/code/supervisor/supervisord.conf
