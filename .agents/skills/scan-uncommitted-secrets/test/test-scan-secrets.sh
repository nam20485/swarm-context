#!/usr/bin/env bash
# Regression tests for scan-uncommitted-secrets.
# Drives scripts/scan.sh via SECRET_SCAN_FILES against fixtures and asserts
# which fixtures are blocked (contain secrets) vs clean (placeholders only).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAN="$ROOT/scripts/scan.sh"
FIX="$ROOT/test/fixtures/secret-scan"
OUT="$(mktemp)"

pass=0
fail=0

expect_blocked() {
  local file="$1" desc="$2"
  if SECRET_SCAN_FILES="$FIX/$file" bash "$SCAN" >"$OUT" 2>&1; then
    echo "FAIL: $desc — expected block, scanner passed"
    cat "$OUT"
    fail=$((fail + 1))
  else
    echo "ok (blocked): $desc"
    pass=$((pass + 1))
  fi
}

expect_clean() {
  local file="$1" desc="$2"
  if SECRET_SCAN_FILES="$FIX/$file" bash "$SCAN" >"$OUT" 2>&1; then
    echo "ok (clean): $desc"
    pass=$((pass + 1))
  else
    echo "FAIL: $desc — expected clean, scanner blocked"
    cat "$OUT"
    fail=$((fail + 1))
  fi
}

echo "== scan-uncommitted-secrets regression tests =="
expect_blocked bearer-token.yml "short bearer_token secret (sk-217)"
expect_blocked short-creds.yml  "short values under credential keys"
expect_blocked compose-creds.yml "postgres password + DATABASE_URL connection string"
expect_clean   placeholders.yml "placeholders / interpolation / redaction"
expect_clean   compose-clean.yml "interpolation, booleans, non-secret config"
expect_blocked appsettings-secret.json "quoted password under credential key in JSON (application/json mime, regression: was skipped as binary)"
expect_clean   appsettings-safe.json   "JSON with interpolated env-var placeholders is clean"

# --- repo-local allowlist (.secretscan-allow) feature --------------------
# Uses a real temp git repo (no SECRET_SCAN_FILES) so the allowlist loader runs.
test_allowlist() {
  local tdir fixture
  tdir="$(mktemp -d)"
  fixture="$tdir/TokenizerEngine.cs"
  git -C "$tdir" init -q
  git -C "$tdir" config user.email t@t.t
  git -C "$tdir" config user.name t
  # Mirror the real ML-tokenizer false positives: keys containing "token".
  printf '            _tokenizer = tokenizer;\n        _tokenizersPath = Path.Combine(appData, "Tokenizers");\n' > "$fixture"

  # Control: WITHOUT .secretscan-allow these two lines MUST be blocked.
  if (cd "$tdir" && bash "$SCAN") >"$OUT" 2>&1; then
    echo "FAIL: allowlist control — expected block without .secretscan-allow, scanner passed"
    cat "$OUT"; fail=$((fail + 1))
  else
    echo "ok (blocked): allowlist control (no .secretscan-allow)"
    pass=$((pass + 1))
  fi

  # With .secretscan-allow the same lines MUST pass.
  cat > "$tdir/.secretscan-allow" <<'EOF'
line:_tokenizer[[:space:]]*=
line:_tokenizersPath[[:space:]]*=
EOF
  if (cd "$tdir" && bash "$SCAN") >"$OUT" 2>&1; then
    echo "ok (clean): allowlist suppresses tokenizer false positives"
    pass=$((pass + 1))
  else
    echo "FAIL: allowlist — expected clean with .secretscan-allow, scanner blocked"
    cat "$OUT"; fail=$((fail + 1))
  fi
  rm -rf "$tdir"
}
test_allowlist

echo ""
echo "pass=$pass fail=$fail"
rm -f "$OUT"
[ "$fail" -eq 0 ]
