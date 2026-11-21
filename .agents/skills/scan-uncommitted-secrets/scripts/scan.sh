#!/usr/bin/env bash
# Scan staged, unstaged, and untracked (non-ignored) files for sensitive content.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

if [ -n "${SECRET_SCAN_FILES:-}" ]; then
  # Test hook: scan explicit paths (space-separated), skip git discovery.
  read -ra FILES <<< "$SECRET_SCAN_FILES"
else
  mapfile -t FILES < <(
    {
      git diff --name-only --diff-filter=ACMRTUXB HEAD 2>/dev/null || true
      git diff --cached --name-only --diff-filter=ACMRTUXB 2>/dev/null || true
      git ls-files --others --exclude-standard 2>/dev/null || true
    } | sort -u
  )
fi

if [ "${#FILES[@]}" -eq 0 ] || [ -z "${FILES[0]:-}" ]; then
  echo "No changed or untracked files to scan."
  exit 0
fi

FINDINGS=0
SUPPRESSED=0
ALLOW_FILE=""
PATH_PATS=()
LINE_PATS=()

is_binary() {
  local f="$1"
  local mime enc
  mime="$(file -b --mime-type "$f" 2>/dev/null || true)"
  [[ "$mime" == text/* ]] && return 1
  # `file` classifies JSON configs (appsettings.json, package.json, ...) as
  # application/json, not text/* — the old text-only check silently skipped
  # them, which is a prime secret-leak vector. Scan anything whose content is
  # text-encoded; skip only genuinely binary payloads.
  enc="$(file -b --mime-encoding "$f" 2>/dev/null || true)"
  case "$enc" in
    us-ascii|utf-8|utf8|utf-16*|iso-8859-*)
      [[ "$mime" == application/octet-stream ]] && return 0
      return 1 ;;
  esac
  return 0
}

is_lockfile() {
  local f="$1"
  local base="${f##*/}"
  [[ "$base" == *.lock ]] && return 0
  return 1
}

is_blocked_filename() {
  local f="$1"
  local base="${f##*/}"
  [[ "$base" == .env* ]] && return 0
  [[ "$base" == .envrc ]] && return 0
  [[ "$base" == auth.json ]] && return 0
  [[ "$base" == secrets.toml ]] && return 0
  [[ "$base" == .pypirc ]] && return 0
  [[ "$base" == credentials.json ]] && return 0
  [[ "$base" == id_rsa ]] && return 0
  [[ "$base" == id_dsa ]] && return 0
  [[ "$base" == id_ecdsa ]] && return 0
  [[ "$base" == id_ed25519 ]] && return 0
  [[ "$base" == *.pem ]] && return 0
  [[ "$base" == *.p12 ]] && return 0
  return 1
}

should_skip_file() {
  local f="$1"
  # Skip the skill's own source code (avoid scanning the scanner). In test mode
  # (SECRET_SCAN_FILES set) this is bypassed so fixtures under the skill dir
  # can be exercised by test/test-scan-secrets.sh.
  if [ -z "${SECRET_SCAN_FILES:-}" ]; then
    [[ "$f" == *"/scan-uncommitted-secrets/"* ]] && return 0
  fi
  # Intentional fixtures; exercised via test/test-scan-secrets.sh (SECRET_SCAN_FILES).
  if [ -z "${SECRET_SCAN_FILES:-}" ] && [[ "$f" == test/fixtures/secret-scan/* ]]; then
    return 0
  fi
  if [ -z "${SECRET_SCAN_FILES:-}" ]; then
    git check-ignore -q "$f" 2>/dev/null && return 0
  fi
  [[ ! -f "$f" ]] && return 0
  is_binary "$f" && return 0
  return 1
}

is_allowlisted_line() {
  local line="$1"
  [[ "$line" =~ FAKE-.+-FOR-TESTING ]] && return 0
  [[ "$line" =~ example\.(com|org|net) ]] && return 0
  [[ "$line" =~ @example\. ]] && return 0
  [[ "$line" =~ your-.*-key ]] && return 0
  [[ "$line" =~ \<YOUR_.*\> ]] && return 0
  [[ "$line" =~ changeme|placeholder|redacted|REDACTED ]] && return 0
  [[ "$line" =~ =[[:space:]]*[\"\']…[\"\'] ]] && return 0
  [[ "$line" =~ \$\{[A-Za-z_][A-Za-z0-9_]*\} ]] && return 0
  # Lockfile wheel hashes and digest pins are not PII/secrets
  [[ "$line" =~ sha256:[a-f0-9]{16,} ]] && return 0
  return 1
}

is_allowlisted_secret_value() {
  local val="$1"
  [[ "$val" =~ ^\$\{[A-Za-z_][A-Za-z0-9_]*\}$ ]] && return 0
  [[ "$val" == "…" ]] && return 0
  [[ "$val" == "..." ]] && return 0
  [[ "$val" =~ FAKE-.+-FOR-TESTING ]] && return 0
  [[ "$val" == "secret" ]] && return 0
  [[ "$val" == "changeme" ]] && return 0
  [[ "$val" == "placeholder" ]] && return 0
  [[ "$val" =~ ^paste- ]] && return 0
  [[ ${#val} -lt 8 ]] && return 0
  return 1
}

# Stricter allowlist for values found under an explicit credential key.
# Deliberately has NO length floor: a short value under a credential key
# (e.g. bearer_token: "sk-217") is treated as a real secret. Only true
# placeholders / interpolation are allowed through.
is_allowlisted_credential_value() {
  local val="$1"
  [[ "$val" =~ ^\$\{[A-Za-z_][A-Za-z0-9_]*\}$ ]] && return 0      # ${VAR}
  [[ "$val" =~ ^\$\{?[A-Za-z_][A-Za-z0-9__-]*\}?$ ]] && return 0  # $VAR / ${VAR}
  [[ "$val" == "…" ]] && return 0
  [[ "$val" == "..." ]] && return 0
  [[ "$val" =~ FAKE-.+-FOR-TESTING ]] && return 0
  [[ "$val" == "secret" || "$val" == "changeme" || "$val" == "placeholder" ]] && return 0
  [[ "$val" == "redacted" || "$val" == "REDACTED" ]] && return 0
  [[ "$val" =~ ^paste- ]] && return 0
  [[ "$val" == "<YOUR_"* || "$val" == *"YOUR_"*">" ]] && return 0
  [[ "$val" =~ your-.*-key ]] && return 0
  [[ "$val" =~ example\.(com|org|net) ]] && return 0
  # Boolean / null config values are not secrets (avoids FP once key matching
  # becomes case-insensitive, e.g. some_secret_enabled: "true").
  [[ "${val,,}" =~ ^(true|false|yes|no|on|off|none|null|0|1)$ ]] && return 0
  return 1
}

# Repo-local suppression driven by $ROOT/.secretscan-allow. Loaded only outside
# test mode (SECRET_SCAN_FILES unset). Two rule kinds:
#   path:<glob>  suppress all findings in file paths matching the glob
#   line:<regex> suppress any finding whose raw offending line matches the ERE
# Blank lines and "#" comments are ignored in the allowlist file.
is_suppressed() {
  local f="$1" ln="$2" pat
  for pat in "${PATH_PATS[@]:-}"; do
    [ -z "$pat" ] && continue
    [[ "$f" == $pat ]] && return 0
  done
  for pat in "${LINE_PATS[@]:-}"; do
    [ -z "$pat" ] && continue
    [[ "$ln" =~ $pat ]] && return 0
  done
  return 1
}

report() {
  local category="$1"
  local file="$2"
  local line_no="$3"
  local rule="$4"
  local line="$5"

  if is_suppressed "$file" "$line"; then
    SUPPRESSED=$((SUPPRESSED + 1))
    return 0
  fi

  if [ "$FINDINGS" -eq 0 ]; then
    echo ""
    echo "======================================================================"
    echo "  WARNING: SENSITIVE CONTENT DETECTED — DO NOT COMMIT"
    echo "======================================================================"
    echo ""
  fi
  FINDINGS=$((FINDINGS + 1))
  echo "[$category] $file:$line_no"
  echo "  rule: $rule"
  echo "  line: $line"
  echo ""
}

scan_line() {
  local f="$1"
  local line_no="$2"
  local line="$3"
  local skip_pii="$4"

  is_allowlisted_line "$line" && return 0

  if [[ "$line" =~ (AKIA[0-9A-Z]{16}) ]]; then
    report "API_KEY" "$f" "$line_no" "AWS access key id" "$line"
  fi

  if [[ "$line" =~ (ASIA[0-9A-Z]{16}) ]]; then
    report "API_KEY" "$f" "$line_no" "AWS temporary access key id" "$line"
  fi

  if [[ "$line" =~ (sk-or-v1-[a-zA-Z0-9_-]{10,}) ]]; then
    report "API_KEY" "$f" "$line_no" "OpenRouter/OpenAI-style key" "$line"
  fi

  if [[ "$line" =~ (sk-proj-[a-zA-Z0-9_-]{10,}) ]]; then
    report "API_KEY" "$f" "$line_no" "OpenAI project key" "$line"
  fi

  if [[ "$line" =~ (sk-[a-zA-Z0-9]{20,}) ]]; then
    report "API_KEY" "$f" "$line_no" "Secret key (sk- prefix)" "$line"
  fi

  if [[ "$line" =~ (ghp_[a-zA-Z0-9]{20,}) ]]; then
    report "TOKEN" "$f" "$line_no" "GitHub personal access token" "$line"
  fi

  if [[ "$line" =~ (ghs_[a-zA-Z0-9]{20,}) ]]; then
    report "TOKEN" "$f" "$line_no" "GitHub secret/token" "$line"
  fi

  if [[ "$line" =~ (gho_[a-zA-Z0-9]{20,}) ]]; then
    report "TOKEN" "$f" "$line_no" "GitHub OAuth token" "$line"
  fi

  if [[ "$line" =~ (ghu_[a-zA-Z0-9]{20,}) ]]; then
    report "TOKEN" "$f" "$line_no" "GitHub user token" "$line"
  fi

  if [[ "$line" =~ (ghr_[a-zA-Z0-9]{20,}) ]]; then
    report "TOKEN" "$f" "$line_no" "GitHub refresh token" "$line"
  fi

  if [[ "$line" =~ (github_pat_[a-zA-Z0-9_]{20,}) ]]; then
    report "TOKEN" "$f" "$line_no" "GitHub fine-grained PAT" "$line"
  fi

  if [[ "$line" =~ (glpat-[a-zA-Z0-9_-]{10,}) ]]; then
    report "TOKEN" "$f" "$line_no" "GitLab personal access token" "$line"
  fi

  if [[ "$line" =~ (xox[baprs]-[a-zA-Z0-9-]{10,}) ]]; then
    report "TOKEN" "$f" "$line_no" "Slack token" "$line"
  fi

  if [[ "$line" =~ (Bearer[[:space:]]+[a-zA-Z0-9\-._~+/]{20,}) ]]; then
    report "TOKEN" "$f" "$line_no" "Bearer token" "$line"
  fi

  if [[ "$line" =~ eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,} ]]; then
    report "TOKEN" "$f" "$line_no" "Possible JWT" "$line"
  fi

  if [[ "$line" =~ -----BEGIN[[:space:]](RSA[[:space:]]|OPENSSH[[:space:]]|EC[[:space:]]|)PRIVATE[[:space:]]KEY----- ]]; then
    report "SECRET" "$f" "$line_no" "Private key block" "$line"
  fi

  if [[ "$line" =~ (^|[^a-zA-Z0-9_])(api[_-]?key|apikey|secret[_-]?key|access[_-]?token|auth[_-]?token|bearer[_-]?token|bearer|client[_-]?secret|private[_-]?key|credential[_-]?s?)[[:space:]]*[:=][[:space:]]*[\"\']([^\"\']{8,})[\"\']([^a-zA-Z0-9_]|$) ]]; then
    report "SECRET" "$f" "$line_no" "Assigned API/secret key" "$line"
  fi

  # Credential-keyed assignment, length-agnostic. Catches short real secrets
  # that the {8,} rule above misses (e.g. bearer_token: "sk-217"). Only true
  # placeholders/interpolation are allowed (no length floor).
  if [[ "$line" =~ (^|[^a-zA-Z0-9_])(bearer[_-]?token|bearer|api[_-]?key|apikey|secret[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|private[_-]?key)[[:space:]]*[:=][[:space:]]*[\"\']([^\"\']+)[\"\']([^a-zA-Z0-9_]|$) ]]; then
    local cred_val="${BASH_REMATCH[3]}"
    if ! is_allowlisted_credential_value "$cred_val"; then
      report "SECRET" "$f" "$line_no" "Credential value under credential key (len ${#cred_val})" "$line"
    fi
  fi

  if [[ "$line" =~ (OS_WEBHOOK_SECRET|OPENCODE_SERVER_PASSWORD|ZAI_CODING_API_KEY|ZAI_API_KEY|OPENROUTER_API_KEY|MODEL_STUDIO_API_KEY|GH_ORCHESTRATION_AGENT_TOKEN|GITHUB_TOKEN)[[:space:]]*=[[:space:]]*\"([^\"]{8,})\" ]]; then
    local assigned_val="${BASH_REMATCH[2]}"
    if ! is_allowlisted_secret_value "$assigned_val"; then
      report "SECRET" "$f" "$line_no" "Hardcoded repo credential env var" "$line"
    fi
  fi

  if [[ "$line" =~ (OS_WEBHOOK_SECRET|OPENCODE_SERVER_PASSWORD|ZAI_CODING_API_KEY|ZAI_API_KEY|OPENROUTER_API_KEY|MODEL_STUDIO_API_KEY|GH_ORCHESTRATION_AGENT_TOKEN|GITHUB_TOKEN)[[:space:]]*=[[:space:]]*\'([^\']{8,})\' ]]; then
    local assigned_val="${BASH_REMATCH[2]}"
    if ! is_allowlisted_secret_value "$assigned_val"; then
      report "SECRET" "$f" "$line_no" "Hardcoded repo credential env var" "$line"
    fi
  fi

  if [[ "$line" =~ (OS_WEBHOOK_SECRET|OPENCODE_SERVER_PASSWORD|ZAI_CODING_API_KEY|ZAI_API_KEY|OPENROUTER_API_KEY|MODEL_STUDIO_API_KEY|GH_ORCHESTRATION_AGENT_TOKEN|GITHUB_TOKEN)[[:space:]]*=[[:space:]]*([^[:space:]#]+) ]]; then
    local bare_val="${BASH_REMATCH[2]}"
    if [[ "$bare_val" =~ ^[\"\'] ]]; then
      :
    elif [[ "$bare_val" =~ ^\$\{[A-Z0-9_]+\}$ ]] || is_allowlisted_secret_value "$bare_val"; then
      :
    elif [ ${#bare_val} -ge 8 ]; then
      report "SECRET" "$f" "$line_no" "Hardcoded repo credential env var (unquoted)" "$line"
    fi
  fi

  if [[ "$line" =~ --password[[:space:]]+[\"\']([^\"\']{4,})[\"\']([^a-zA-Z0-9_]|$) ]]; then
    report "PASSWORD" "$f" "$line_no" "Hardcoded CLI password flag" "$line"
  fi

  # Robust credential-assignment detector: key-name based, case-insensitive,
  # substring match. Catches UPPER_SNAKE and prefixed keys the format-specific
  # rules miss (POSTGRES_PASSWORD, DB_PASSWORD, AUTH_TOKEN, ...). The value is
  # checked against the strict credential allowlist (no length floor), so only
  # true placeholders/interpolation/booleans pass.
  if [[ "$line" =~ ^[[:space:]]*[\"\']?([A-Za-z0-9_][A-Za-z0-9_-]*)[\"\']?[[:space:]]*[:=][[:space:]]*[\"\']([^\"\']+)[\"\'] ]]; then
    local ckey="${BASH_REMATCH[1]}"
    local cval="${BASH_REMATCH[2]}"
    local ckey_l="${ckey,,}"
    if [[ "$ckey_l" =~ (password|passwd|pwd|token|secret|api[_-]?key|apikey|credential|private[_-]?key) ]]; then
      if ! is_allowlisted_credential_value "$cval"; then
        report "SECRET" "$f" "$line_no" "Credential assignment (key=$ckey)" "$line"
      fi
    fi
  fi

  # Same detector for UNQUOTED scalar values (e.g. POSTGRES_PASSWORD: dbpassword9090).
  if [[ "$line" =~ ^[[:space:]]*([A-Za-z0-9_][A-Za-z0-9_-]*)[[:space:]]*[:=][[:space:]]*([^[:space:]#\"\'#]+) ]]; then
    local ckey="${BASH_REMATCH[1]}"
    local cval="${BASH_REMATCH[2]}"
    local ckey_l="${ckey,,}"
    if [[ "$ckey_l" =~ (password|passwd|pwd|token|secret|api[_-]?key|apikey|credential|private[_-]?key) ]]; then
      if ! is_allowlisted_credential_value "$cval"; then
        report "SECRET" "$f" "$line_no" "Credential assignment, unquoted (key=$ckey)" "$line"
      fi
    fi
  fi

  # Credentials embedded in a connection string (user:pass@host), e.g.
  # DATABASE_URL: "postgresql://llmproxy:dbpassword9090@db:5432". Lines that
  # use ${VAR} interpolation are allowlisted at the line level already.
  if [[ "$line" =~ [a-zA-Z][a-zA-Z0-9+.-]*://[^:@/[:space:]]+:[^@/[:space:]]+@ ]]; then
    report "SECRET" "$f" "$line_no" "Credentials embedded in connection string" "$line"
  fi

  if [[ "$line" =~ (^|[^a-zA-Z0-9_])(password|passwd|pwd)[[:space:]]*[:=][[:space:]]*[\"\']([^\"\']{4,})[\"\']([^a-zA-Z0-9_]|$) ]]; then
    report "PASSWORD" "$f" "$line_no" "Hardcoded password assignment" "$line"
  fi

  if [[ "$line" =~ \"type\"[[:space:]]*:[[:space:]]*\"api\"[[:space:]]*,[[:space:]]*\"key\"[[:space:]]*:[[:space:]]*\"[^\"]{8,}\" ]]; then
    report "SECRET" "$f" "$line_no" "auth.json-style API key entry" "$line"
  fi

  if [ "$skip_pii" -eq 1 ]; then
    return 0
  fi

  if [[ "$line" =~ \b[0-9]{3}-[0-9]{2}-[0-9]{4}\b ]]; then
    report "PII" "$f" "$line_no" "Possible SSN (###-##-####)" "$line"
  fi

  if [[ "$line" =~ \b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b ]]; then
    if [[ ! "$line" =~ @([Ee]xample\.(com|org|net)|localhost|users\.noreply\.github\.com) ]]; then
      report "PII" "$f" "$line_no" "Email address" "$line"
    fi
  fi

  if [[ "$line" =~ \b(\+1[[:space:]-]?)?(\([0-9]{3}\)|[0-9]{3})[[:space:]-]?[0-9]{3}[[:space:]-]?[0-9]{4}\b ]]; then
    report "PII" "$f" "$line_no" "Possible phone number" "$line"
  fi
}

scan_file() {
  local f="$1"
  local skip_pii=0
  is_lockfile "$f" && skip_pii=1

  local line_no=0
  local line

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    scan_line "$f" "$line_no" "$line" "$skip_pii"
  done < "$f"
}

echo "Scanning changed/untracked files in: $ROOT"
echo "Files in scope: ${#FILES[@]}"
echo ""

# Load repo-local allowlist (suppressed under SECRET_SCAN_FILES test mode so
# fixtures are exercised deterministically without external masking).
if [ -z "${SECRET_SCAN_FILES:-}" ] && [ -f "$ROOT/.secretscan-allow" ]; then
  ALLOW_FILE="$ROOT/.secretscan-allow"
  while IFS= read -r _rule || [ -n "$_rule" ]; do
    _rule="${_rule#"${_rule%%[![:space:]]*}"}"
    _rule="${_rule%"${_rule##*[![:space:]]}"}"
    [ -z "$_rule" ] && continue
    [[ "$_rule" == \#* ]] && continue
    if [[ "$_rule" == path:* ]]; then
      _p="${_rule#path:}"; _p="${_p#"${_p%%[![:space:]]*}"}"
      PATH_PATS+=("$_p")
    elif [[ "$_rule" == line:* ]]; then
      _p="${_rule#line:}"; _p="${_p#"${_p%%[![:space:]]*}"}"
      LINE_PATS+=("$_p")
    fi
  done < "$ALLOW_FILE"
  if [ "${#PATH_PATS[@]}" -gt 0 ] || [ "${#LINE_PATS[@]}" -gt 0 ]; then
    echo "Allowlist active: $ALLOW_FILE (${#PATH_PATS[@]} path, ${#LINE_PATS[@]} line rules)"
    echo ""
  fi
fi

for f in "${FILES[@]}"; do
  if is_blocked_filename "$f"; then
    report "BLOCKED_FILE" "$f" "0" "Credential filename (must not be committed)" "$f"
    continue
  fi
  should_skip_file "$f" && continue
  scan_file "$f"
done

if [ "$FINDINGS" -gt 0 ]; then
  echo "======================================================================"
  echo "  FOUND $FINDINGS potential sensitive item(s)."
  echo "  Remove or redact before committing. Do not commit secrets or PII."
  echo "======================================================================"
  if [ "$SUPPRESSED" -gt 0 ]; then
    echo "  ($SUPPRESSED additional finding(s) suppressed via .secretscan-allow)"
  fi
  exit 1
fi

if [ "$SUPPRESSED" -gt 0 ]; then
  echo "No sensitive content detected ($SUPPRESSED finding(s) suppressed via .secretscan-allow)."
else
  echo "No sensitive content detected in changed/untracked files."
fi
exit 0
