#!/usr/bin/env bash
# Secret scanning. Run on every commit - by the hook in .githooks/, by `make
# secrets`, and by CI (.github/workflows/ci.yml).
#
# Two scopes, because they answer different questions:
#
#   staged   Only what this commit is about to add. This is the pre-commit gate and
#            the fast one: it never fails on something an old commit already did.
#   history  Every commit, reachable. Run this in CI, and before you push a branch
#            that came from somewhere else.
#
# Findings are redacted by default. The gate reports WHICH rule fired and WHERE,
# never the secret value - a scanner that prints the secret has leaked it again.
#
# Exit: 0 clean, 1 leak found, 2 the scanner itself is missing or broken.
set -uo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo" || exit 1

red=$'\033[0;31m'; green=$'\033[0;32m'; dim=$'\033[2m'; nocolor=$'\033[0m'

# Pin the version so a local run and a CI run are the same scanner.
GITLEAKS_VERSION="${GITLEAKS_VERSION:-8.28.0}"
gl="$(command -v gitleaks 2>/dev/null || true)"
if [ -z "$gl" ]; then
	# The image installs it here; a host checkout may not have it.
	[ -x "/usr/local/bin/gitleaks" ] && gl="/usr/local/bin/gitleaks"
fi

scope="${1:-staged}"
case "$scope" in
	staged|history) ;;
	*)
		echo "usage: $0 [staged|history]" >&2
		exit 2
		;;
esac

if [ -z "$gl" ]; then
	echo "${red}error${nocolor} gitleaks not found."
	echo "  container: make shell   (gitleaks $GITLEAKS_VERSION is in the dev image)"
	echo "  host:      install gitleaks $GITLEAKS_VERSION, or DOCKER=1 make secrets"
	exit 2
fi

echo "${dim}scanner: $("$gl" version 2>/dev/null | head -1)  scope: $scope${nocolor}"

# --redact everywhere, including the report file: a report is an artifact that gets
# uploaded to CI and pasted into issues, so it must never carry the value either.
report="$(mktemp)"
trap 'rm -f "$report"' EXIT

rc=0
case "$scope" in
	staged)
		# --no-banner, --redact: never echo the finding's secret.
		if "$gl" protect --no-banner --redact --verbose \
			--report-format json --report-path "$report" --staged >/dev/null 2>&1; then
			echo "${green}no secrets in staged changes${nocolor}"
		else
			rc=1
		fi
		;;
	history)
		if "$gl" detect --no-banner --redact --verbose \
			--report-format json --report-path "$report" >/dev/null 2>&1; then
			echo "${green}no secrets in git history${nocolor}"
		else
			rc=1
		fi
		;;
esac

if [ "$rc" != 0 ]; then
	# Summarise from the JSON report with python so the output is stable and the
	# secret value never appears - only rule, file, and line.
	if command -v python3 >/dev/null 2>&1 && [ -s "$report" ]; then
		python3 - "$report" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception as e:
    print(f"  (could not parse gitleaks report: {e})")
    sys.exit(0)
# de-dup: one line of guidance per (rule, file)
seen = set()
for f in data:
    rule = f.get("RuleID", "?")
    path = f.get("File", "?")
    line = f.get("StartLine", "?")
    key = (rule, path)
    if key in seen:
        continue
    seen.add(key)
    print(f"  {rule}  {path}:{line}")
print(f"  {len(data)} finding(s) in {len(seen)} file(s). Values redacted.")
PY
	fi
	cat <<EOF

${red}secret(s) detected${nocolor} in the ${scope} scope.

  Do NOT "fix" this by committing an allowlist entry for a real secret.
  If the value is a live credential, revoke/rotate it FIRST - deleting the line in
  the next commit does not remove it from history, and anyone who has already
  cloned this repository still has it.

  A false positive (a documented example key, a regex in a test fixture) is
  allowed narrowly in .gitleaks.toml, with a comment saying why it is safe.

  See AGENTS.md section 8.
EOF
	exit 1
fi

exit 0