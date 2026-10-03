#!/usr/bin/env bash
# Static checks for the recipe repo. No network, no Mesa checkout, no compiler:
# this is the fast gate you run on every change.
#
#   1. shellcheck on every shell script (hard gate at -S warning)
#   2. python compile check on every .py (catches syntax errors in patch scripts)
#   3. workflow YAML parses, and its variant matrix still matches AGENTS.md
#   4. every patch/script a workflow references actually exists on disk
#   5. the recipe invariants apply_common.sh relies on still hold
#
# Exits non-zero on the first failing category, with the failing file named.
set -uo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo" || exit 1

red=$'\033[0;31m'; green=$'\033[0;32m'; yellow=$'\033[0;33m'; nocolor=$'\033[0m'
fails=0

fail(){ echo "${red}FAIL${nocolor}  $*"; fails=$((fails+1)); LINT_CHECKS=$(( ${LINT_CHECKS:-0} + 1 )); }
ok(){   echo "${green}ok${nocolor}    $*"; LINT_CHECKS=$(( ${LINT_CHECKS:-0} + 1 )); }
warn(){ echo "${yellow}warn${nocolor}  $*"; }

# --- preflight ----------------------------------------------------------------
# git drives every file list below. Without it the checks silently pass on empty
# input, which is worse than failing.
if ! command -v git >/dev/null 2>&1; then
	echo "${red}error${nocolor} git is required by this script (and by the build itself)."
	echo "  In the container it is already present; on the host: apt-get install git"
	exit 2
fi

# --- 1. shellcheck ------------------------------------------------------------
sh_files=$(git ls-files '*.sh')
if command -v shellcheck >/dev/null 2>&1; then
	# -S warning is the gate. SC1091 (not following sourced files) does not apply:
	# these scripts source nothing but pass paths as arguments.
	if out=$(shellcheck -S warning --color=never $sh_files 2>&1); then
		ok "shellcheck clean: $(echo "$sh_files" | wc -w) script(s)"
	else
		fail "shellcheck findings:"
		echo "$out" | sed 's/^/    /'
	fi
else
	warn "shellcheck not installed - skipping (apt-get install shellcheck)"
fi

# Also require the build scripts to stay executable.
for s in build_turnip.sh build_turnip_perf.sh build_turnip_wayland.sh build_turnip_linux.sh; do
	[ -x "$s" ] || fail "$s is not executable (the workflows chmod +x it; keep it that way)"
done

# --- 2. python syntax ---------------------------------------------------------
py_files=$(git ls-files '*.py')
if [ -n "$py_files" ]; then
	bad=0
	for f in $py_files; do
		if ! python3 -m py_compile "$f" 2>/tmp/pyc.$$; then
			fail "python syntax error in $f"
			sed 's/^/    /' /tmp/pyc.$$ >&2
			bad=1
		fi
	done
	rm -f /tmp/pyc.$$
	[ "$bad" = 0 ] && ok "python compiles: $(echo "$py_files" | wc -w) script(s)"
fi

# --- 3. workflows parse, and the variant matrix is intact ---------------------
wf=".github/workflows/turnip_build_combined.yml"
if python3 - "$wf" <<'PY' 2>&1
import sys
try:
    import yaml
except ImportError:
    print("    PyYAML not installed - skipping YAML parse"); sys.exit(0)
d = yaml.safe_load(open(sys.argv[1]))
jobs = d["jobs"]
for need in ("resolve", "build", "wayland", "linux"):
    assert need in jobs, f"job '{need}' disappeared from the combined workflow"
drivers = jobs["build"]["strategy"]["matrix"]["include"]
assert len(drivers) == 4, f"expected 4 variants, found {len(drivers)}"
names = sorted(v["variant"] for v in drivers)
expected = sorted(["regular", "a8xx", "710-720-test", "8g2-oneui"])
assert names == expected, f"variant names changed: {names} != {expected}"
# wayland and linux must reuse the very same matrix (the &drivers anchor).
for leg in ("wayland", "linux"):
    got = sorted(v["variant"] for v in jobs[leg]["strategy"]["matrix"]["include"])
    assert got == expected, f"{leg} leg variants drifted: {got} != {expected}"
print(f"    matrix ok: {', '.join(names)}")
PY
then ok "combined workflow parses; 4 variants consistent across all legs"
else fail "combined workflow matrix check"; fi

# --- 4. referenced patches exist ----------------------------------------------
# A renamed or deleted patch that a workflow still names is a silent broken build.
missing=0
refs=$(grep -rhoE 'patches/[A-Za-z0-9_./-]+\.(patch|py|sh)' .github/workflows .github/scripts 2>/dev/null | sort -u)
for r in $refs; do
	if [ ! -e "$r" ]; then fail "workflow references missing file: $r"; missing=1; fi
done
[ "$missing" = 0 ] && ok "all $(echo "$refs" | wc -w) workflow-referenced patch files exist"

# --- 5. recipe invariants ------------------------------------------------------
# apply_common.sh hardcodes "exactly 6 patches" in a8xx-winnative and asserts each
# one reached the tree. A 7th file would silently never be applied.
n_winnative=$(ls patches/a8xx-winnative/0*.patch 2>/dev/null | wc -l)
[ "$n_winnative" = 6 ] || fail "a8xx-winnative has $n_winnative patches, apply_common.sh asserts 6"
[ "$n_winnative" = 6 ] && ok "a8xx-winnative series intact (6 patches)"

# The tracked fixtures inside the gitignored build dir must stay tracked.
for f in turnip_workdir/tu_gen8.patch turnip_workdir/tu_gen8_clean.patch; do
	git ls-files --error-unmatch "$f" >/dev/null 2>&1 \
		|| fail "$f is no longer tracked - AGENTS.md §4 says these are repo content"
done
[ "$fails" = 0 ] && ok "tracked build-dir fixtures still tracked"

# Every SOURCE provenance file must exist next to the patches it documents.
for d in patches/common patches/linux patches/wayland; do
	[ -f "$d/SOURCE" ] || fail "$d/SOURCE missing (provenance record)"
done
[ "$fails" = 0 ] && ok "patch SOURCE provenance files present"

# --- 6. the gate itself --------------------------------------------------------
# ok() and fail() both increment LINT_CHECKS, so it counts checks that actually
# produced a verdict. If a category silently no-ops (empty file list, skipped
# loop), the total drops and lint fails instead of reporting a hollow pass.
expected_checks=7
actual=${LINT_CHECKS:-0}
if [ "$actual" -lt "$expected_checks" ]; then
	fail "only $actual of $expected_checks check categories reported a result - lint did not fully run"
fi

echo
if [ "$fails" = 0 ]; then
	echo "${green}lint: all checks passed ($actual verdicts)${nocolor}"
else
	echo "${red}lint: $fails check(s) failed ($actual verdicts)${nocolor}"
fi
exit $(( fails > 0 ? 1 : 0 ))
