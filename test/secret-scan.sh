#!/bin/bash
# secret-scan.sh — the pre-publish secret and anonymity release gate. CANONICAL COPY.
#
# SCAN_VERSION below is the consolidation handle. This script is copied into every package, so the
# only defence against the drift that produced twelve different gates is a version stamp that CI can
# compare against estate/templates/secret-scan.sh. Bump it when this file changes; never edit a
# package's copy in place.
SCAN_VERSION=2026-08-09.4
#
# WHY ONE COPY. Before 2026-08-09 this script existed in three generations across 18 packages: ten
# scanned the built image, eight scanned only the repo, and the denylists ranged from 5 patterns to
# 19. "secret-scan passed" therefore meant something different in every repository, which is the
# same class of defect as a gate that does not run at all — worse, because it reports green.
#
# Scans TWO surfaces and exits non-zero on ANY hit:
#   1. the publishable repo file set, meaning what a `git push` would expose
#      (tracked union untracked-but-not-ignored), and
#   2. the built container image filesystem, which is the artefact already public on GHCR.
# Run before every publish, and before flipping any image to public.
#
# Why two surfaces: .dockerignore SHOULD keep secrets out of the build context, but "should" is a
# claim. Scanning the actual image is the proof, and the image is what the world pulls.
#
# THE DENYLIST PATTERN. Box-specific, identity-specific and session-specific strings live in the
# GITIGNORED .anonymize-list, so this published script never itself leaks the very strings it hunts
# for. That is the mistake the naive "patterns inline in the tracked script" approach makes. Only
# generic credential SHAPES are inlined here. Add these to .gitignore:
#
#     .anonymize-list
#     *token*.txt
#     .env
#     .env.*
#     phase-notes/
#     .claude/
#
# .anonymize-list holds one extended-regular-expression per line, blank lines and # comments
# ignored. Populate it with: the box FQDN and any subdomain of it, the private mirror host, sibling
# app names, real email addresses, the operator's usernames, and any session-specific identifier.
# If the file is absent the scan still runs but proves far less, and says so loudly.
#
# Usage: test/secret-scan.sh [IMAGE]
#   IMAGE defaults to $SCAN_IMAGE, else the dockerImage in CloudronManifest.json, else repo-only.
#   SCAN_INFISICAL_NAMES="NAME1 NAME2" additionally fetches those exact token values from Infisical
#   into a mode-600 scratch file for fixed-string matching. Off by default: it puts real secret
#   values on disk for the duration of the scan, which is a deliberate trade, not a default.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
REPO="$PWD"
SELF="test/secret-scan.sh"

IMAGE="${1:-${SCAN_IMAGE:-}}"
if [[ -z "$IMAGE" ]]; then
  IMAGE="$(grep -oE '"dockerImage"[[:space:]]*:[[:space:]]*"[^"]+"' CloudronManifest.json 2>/dev/null \
           | grep -oE '"[^"]+"$' | tr -d '"')"
fi
CRI="$(command -v podman || command -v docker || true)"   # build host is rootless podman

umask 077
SCRATCH="$(mktemp -d)"; trap 'rm -rf "$SCRATCH"' EXIT
ANON="$SCRATCH/anon.ere"     # box, identity and session patterns, from .anonymize-list
SHAPE="$SCRATCH/shape.ere"   # generic credential shapes, inlined below
FIXED="$SCRATCH/fixed.txt"   # exact token strings, optional, never written into the repo tree

# --- generic credential shapes (safe to publish: they contain no box specifics) ---
cat > "$SHAPE" <<'ERE'
ghp_[A-Za-z0-9]{20,}
github_pat_[A-Za-z0-9_]{20,}
gho_[A-Za-z0-9]{20,}
ghs_[A-Za-z0-9]{20,}
ghr_[A-Za-z0-9]{20,}
glpat-[A-Za-z0-9_-]{20,}
xox[baprs]-[A-Za-z0-9-]{10,}
AKIA[0-9A-Z]{16}
ASIA[0-9A-Z]{16}
AIza[0-9A-Za-z_-]{35}
sk-ant-[A-Za-z0-9_-]{20,}
sk-proj-[A-Za-z0-9_-]{20,}
-----BEGIN [A-Z ]*PRIVATE KEY-----
ERE

# --- box, identity and session patterns, from the gitignored denylist ---
if [[ -f .anonymize-list ]]; then
  grep -vE '^[[:space:]]*(#|$)' .anonymize-list > "$ANON"
else
  : > "$ANON"
  echo "WARN: .anonymize-list absent. Box, identity and session strings are NOT scanned (shapes only)."
fi

# --- exact token values, opt-in, from Infisical; scratch only, never committed ---
: > "$FIXED"
if [[ -n "${SCAN_INFISICAL_NAMES:-}" ]] && command -v secret >/dev/null 2>&1; then
  for n in $SCAN_INFISICAL_NAMES; do
    secret "$n" 2>/dev/null >> "$FIXED" || echo "WARN: could not fetch $n from Infisical" >&2
  done
fi
sed -i '/^[[:space:]]*$/d' "$ANON" "$SHAPE" "$FIXED" 2>/dev/null   # a blank line matches everything

echo "patterns: $(wc -l < "$ANON") box/identity/session, $(wc -l < "$SHAPE") shapes, $(wc -l < "$FIXED") exact tokens"

fail=0; allowed=0
# A package that LEGITIMATELY contains a denylisted string declares it in .scan-allowlist, one fixed
# string per line. Exceptions are visible and counted, never silent — the alternative, a package
# quietly carrying a shorter denylist, is exactly what made this gate mean a different thing in every
# repo. An allowlist entry is a reviewable claim; a missing pattern is an invisible one.
ALLOW="$REPO/.scan-allowlist"
emit() {  # $1=tag  $2=grep output
  local out="${2:-}" before after
  [[ -z "$out" ]] && return 0
  if [[ -s "$ALLOW" ]]; then
    before="$(printf '%s\n' "$out" | grep -c . || true)"
    out="$(printf '%s\n' "$out" | grep -vFf <(grep -vE '^[[:space:]]*(#|$)' "$ALLOW") || true)"
    after="$(printf '%s\n' "$out" | grep -c . || true)"
    if (( before > after )); then
      echo "  (allowlisted $((before - after)) line(s) via .scan-allowlist)"
      allowed=$((allowed + before - after))
    fi
  fi
  [[ -z "$out" ]] && return 0
  printf '%s\n' "$out" | sed "s/^/  [$1] /"
  fail=1
}

echo "=== REPO scan: publishable file set ==="
mapfile -t FILES < <( { git ls-files; git status --short --untracked-files=all 2>/dev/null | sed -n 's/^?? //p'; } \
                      | sort -u | grep -vx "$SELF" )
if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "  (no publishable files found)"
else
  echo "  ${#FILES[@]} files"
  [[ -s "$ANON"  ]] && emit anon  "$(grep -IEnHf "$ANON"  "${FILES[@]}" 2>/dev/null)"
  [[ -s "$SHAPE" ]] && emit shape "$(grep -IEnHf "$SHAPE" "${FILES[@]}" 2>/dev/null)"
  [[ -s "$FIXED" ]] && emit token "$(grep -IFnHf "$FIXED" "${FILES[@]}" 2>/dev/null)"
fi

echo "=== IMAGE scan: ${IMAGE:-<none>} ==="
if   [[ -z "$IMAGE" ]]; then echo "  (no image given; pass one as \$1 or set SCAN_IMAGE)"
elif [[ -z "$CRI"   ]]; then echo "  (no podman or docker found; skipped)"
elif ! "$CRI" image exists "$IMAGE" 2>/dev/null && ! "$CRI" image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "  ($IMAGE not present locally; pull it to scan)"
else
  # --- runtime-managed files are NOT image content -------------------------------------------
  # Both engines bind-mount /etc/hosts, /etc/resolv.conf and /etc/hostname into every container, so
  # a `run`-based grep reads the HOST'S copies and reports the operator's own machine as a leak
  # inside the artefact. Found 2026-08-08 by this package's first CI run: it failed on /etc/hosts
  # entries naming the rig. Verified against the mounted image layers: the image ships /etc/hosts
  # and /etc/resolv.conf as EMPTY files and /etc/hostname as "localhost.localdomain" — the rig's
  # names exist only in the RUNNING container's copy. podman's default base_hosts_file="" means
  # "seed it from the host's file", which is how the runner machine's own hosts entries came to
  # look like the contents of a published image.
  #
  # Suppress what can be suppressed, then PROVE the rest rather than trusting it: copy each path out
  # of a CREATED, NEVER STARTED container — which reads the image layers with no injection — and
  # scan those copies with the same patterns. A file the image genuinely ships is still scanned; one
  # it does not ship is simply absent. Only then are the container-side hits for these exact paths
  # dropped, and only for these exact paths, in the same spirit as the pinned SSH keys below.
  RUNTIME_PATHS=(/etc/hosts /etc/resolv.conf /etc/hostname)
  RUNFLAGS=(--network=none)                       # no DNS/hosts wiring either engine can avoid
  [[ "$CRI" == *podman* ]] && RUNFLAGS+=(--no-hosts)   # podman only; docker always injects

  drop_runtime() {  # remove hits whose path is one of the runtime-managed files
    local s="$1" p
    for p in "${RUNTIME_PATHS[@]}"; do s="$(printf '%s\n' "$s" | grep -vF "$p:" || true)"; done
    printf '%s' "$s"
  }

  # VENDORED TREES are third-party code we did not write, and an estate identity string cannot leak
  # INTO a PyPI wheel, a Next.js build chunk or the Go standard library. They are also enormous.
  # Measured 2026-08-09, the first time eight packages ever had their image scanned: 746 of 746 hits
  # came from exactly these directories and NOT ONE was authored content — 711 from site-packages
  # alone (Google API schemas, botocore fixtures), the rest from .next bundles, a HuggingFace
  # vocabulary and Go stdlib test data. A gate that reports 746 non-findings is a gate nobody reads.
  #
  # Excluded from the ANON and SHAPE sweeps ONLY. The FIXED-token sweep still covers them, because a
  # real credential copied into a venv IS possible — and that sweep can say so without drowning the
  # result, since it matches exact known secrets rather than shapes and common words.
  VENDOR_EXCLUDES=(--exclude-dir=node_modules --exclude-dir=.git --exclude-dir=site-packages
                   --exclude-dir=dist-packages --exclude-dir=.venv --exclude-dir=vendor
                   --exclude-dir=third_party --exclude-dir=.next
                   --exclude-dir=go    # /usr/local/go/src: the Go toolchain, shipped by some images
                   # Downloaded ML model artefacts are upstream DATA, not authored content, and a
                   # tokenizer vocabulary contains essentially every common word — so any denylist
                   # entry that is also an ordinary word matches it by construction. Excluded by
                   # FILENAME rather than by directory: a dir called "models" may well be ours.
                   --exclude=tokenizer.json --exclude=tokenizer_config.json
                   --exclude=vocab.json --exclude=merges.txt
                   --exclude=special_tokens_map.json)
  img() {  # $1=E|F  $2=pattern file  $3..=dirs
    local mode="$1" pf="$2"; shift 2
    [[ -s "$pf" ]] || return 0
    local ex=""
    [[ "$mode" == "E" ]] && ex="${VENDOR_EXCLUDES[*]}"   # anon/shape only; F keeps full reach
    [[ "$mode" == "F" ]] && ex="--exclude-dir=.git"
    "$CRI" run --rm -i --user 0 "${RUNFLAGS[@]}" --entrypoint /bin/bash "$IMAGE" \
      -c "grep -rIn${mode}H $ex -f - $* 2>/dev/null" < "$pf"
  }
  CRIT_DIRS="/app /etc /root /home /usr/local /opt"
  emit anon  "$(drop_runtime "$(img E "$ANON"  $CRIT_DIRS)")"
  emit token "$(drop_runtime "$(img F "$FIXED" $CRIT_DIRS)")"
  shp="$(drop_runtime "$(img E "$SHAPE" $CRIT_DIRS)")"

  # Now scan the image's OWN copies of those paths, if it ships any.
  LAYERD="$SCRATCH/layer"; mkdir -p "$LAYERD"
  cid="$("$CRI" create "$IMAGE" 2>/dev/null || true)"
  if [[ -n "$cid" ]]; then
    for p in "${RUNTIME_PATHS[@]}"; do
      "$CRI" cp "$cid:$p" "$LAYERD/${p//\//_}" 2>/dev/null || true
    done
    "$CRI" rm -f "$cid" >/dev/null 2>&1 || true
  fi
  shopt -s nullglob; layerfiles=("$LAYERD"/*); shopt -u nullglob
  if (( ${#layerfiles[@]} )); then
    echo "  (image ships ${#layerfiles[@]} of ${#RUNTIME_PATHS[@]} runtime-managed paths; scanned from the layers)"
    [[ -s "$ANON"  ]] && emit anon  "$(grep -IEnHf "$ANON"  "${layerfiles[@]}" 2>/dev/null)"
    [[ -s "$SHAPE" ]] && emit shape "$(grep -IEnHf "$SHAPE" "${layerfiles[@]}" 2>/dev/null)"
    [[ -s "$FIXED" ]] && emit token "$(grep -IFnHf "$FIXED" "${layerfiles[@]}" 2>/dev/null)"
  else
    echo "  (image ships none of: ${RUNTIME_PATHS[*]} — the container's copies are injected, not artefact)"
  fi

  # --- the inert /etc/ssh host keys: whitelist BY EXACT PATH, with a VISIBLE COUNT ---
  # cloudron/base ships three inert SSH host keys. No sshd runs in the app and the Dockerfile never
  # touches ssh, so they are noise, not a leak. Allow ONLY these exact paths, pinned by sha256, and
  # print how many key files were found versus how many are pinned. A glob such as ssh_host_*_key
  # would silently pass a real future leak; a count that does not match fails loudly. Re-verify the
  # hashes whenever the base image digest changes.
  declare -A PINNED_SSH=(
    [/etc/ssh/ssh_host_ecdsa_key]=677458f83d985da3fd7cdd208e90e4eac09da5be205425a5f96a6242dc985c33
    [/etc/ssh/ssh_host_ed25519_key]=0c575ce8d9ba487b05cc473fad4b0650fb950181028e6ac19796f86f56f22a7a
    [/etc/ssh/ssh_host_rsa_key]=ae0ea8087e90baf138d277ca52b6cf47b5010adc0e5bd84236713eee1b85de85
  )
  ssh_listing="$("$CRI" run --rm --user 0 "${RUNFLAGS[@]}" --entrypoint /bin/bash "$IMAGE" \
                  -c 'for f in /etc/ssh/ssh_host_*_key; do [ -e "$f" ] && sha256sum "$f"; done' 2>/dev/null)"
  found=0; pinned_ok=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    found=$((found + 1))
    h="${line%% *}"; f="${line##* }"
    if [[ "${PINNED_SSH[$f]:-}" == "$h" ]]; then
      pinned_ok=$((pinned_ok + 1))
      echo "  (pinned-ok: $f matches the base image's inert host key)"
      shp="$(printf '%s\n' "$shp" | grep -vF "$f:" || true)"   # drop ONLY this verified exact path
    else
      emit ssh-key "$f sha256=$h is NOT a pinned base host key (new, changed or extra: treat as a leak)"
    fi
  done <<< "$ssh_listing"
  echo "  host keys: $found found, $pinned_ok pinned-ok, ${#PINNED_SSH[@]} expected"
  [[ "$found" -eq "${#PINNED_SSH[@]}" && "$pinned_ok" -eq "${#PINNED_SSH[@]}" ]] \
    || emit ssh-key "host key count mismatch: $found found, $pinned_ok pinned-ok, ${#PINNED_SSH[@]} expected"

  # DISTRO-GENERATED PLACEHOLDER KEYS. Some Debian packages mint a self-signed key in their
  # postinst: ssl-cert makes the snakeoil pair, prosody makes a localhost pair. They are inert (the
  # real certificate arrives from the platform at runtime), the package never references them, and
  # they are regenerated on every build — so unlike the SSH host keys above they CANNOT be pinned by
  # hash. Each is dropped by EXACT PATH and announced, so the exemption is visible, never silent.
  # Nothing else is exempt: a key at any other path is still a finding, including a second key in
  # the same directory. Add a path here only after confirming the package does not reference it.
  PLACEHOLDER_KEYS=(/etc/ssl/private/ssl-cert-snakeoil.key /etc/prosody/certs/localhost.key)
  for k in "${PLACEHOLDER_KEYS[@]}"; do
    if printf '%s' "$shp" | grep -qF "$k:"; then
      echo "  (distro-placeholder-ok: $k, generated by a package postinst and unused by this app)"
      shp="$(printf '%s\n' "$shp" | grep -vF "$k:" || true)"
    fi
  done

  emit shape "$shp"
fi

echo "==================================================="
[[ "$allowed" -gt 0 ]] && echo "note: $allowed line(s) allowlisted via .scan-allowlist"
if [[ $fail -ne 0 ]]; then
  if [[ "${SCAN_REPORT_ONLY:-0}" == "1" ]]; then
    echo "secret-scan REPORT-ONLY: the hits above were NOT enforced (SCAN_REPORT_ONLY=1)."
    echo "  This exists for ONE evidence-gathering pass, after the denylists were unified and eight"
    echo "  packages had their image surface scanned for the first time. Leaving it set turns a gate"
    echo "  into a log nobody reads. Unset it as soon as the findings are triaged."
    exit 0
  fi
  echo "secret-scan FAILED. Anonymise and rebuild before publishing (see the hits above)."
  exit 1
fi
echo "secret-scan OK: no box specifics, identities, session secrets or credential shapes found."
