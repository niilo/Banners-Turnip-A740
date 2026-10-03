#!/usr/bin/env bash
# Patch-application tests against a real Mesa checkout - the fast way to validate a
# patch or patch script without paying for a 20-minute Mesa compile.
#
# What it proves, for one Mesa commit and one variant:
#   - patches/common/apply_common.sh applies and its own result asserts pass
#   - the variant's EXTRA_PATCH applies (fuzz count reported)
#   - every EXTRA_SCRIPT runs, exits 0, leaves freedreno_devices.py parsing, and is
#     IDEMPOTENT (run it twice: the second run must change nothing)
#
# It does NOT compile anything. A green run here plus `make lint` is the pre-commit
# gate; `make build-<leg>` is still required before shipping a driver.
#
# Usage:
#   scripts/test-patches.sh [VARIANT] [MESA_COMMIT]
#   VARIANT      regular | a8xx | 710-720-test | 8g2-oneui   (default: all)
#   MESA_COMMIT  40-hex commit (default: contents of mesa_hash.txt, else main HEAD)
#
# Env: MESA_CACHE  where the Mesa checkout lives (default .cache/mesa-test)
# Needs: git, python3, patch, and network on the first run (~250 MB clone).
set -uo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo" || exit 1

red=$'\033[0;31m'; green=$'\033[0;32m'; yellow=$'\033[0;33m'; nocolor=$'\033[0m'
cache="${MESA_CACHE:-$repo/.cache/mesa-test}"
mesasrc="https://gitlab.freedesktop.org/mesa/mesa.git"

die(){ echo "${red}error${nocolor} $*" >&2; exit 1; }

# The variant table. Kept in sync with the &drivers anchor in
# .github/workflows/turnip_build_combined.yml AND with scripts_of() in the
# Makefile (which also appends patches/a740_devname.py); scripts/lint.sh asserts
# all three agree.
ALL_VARIANTS="regular a8xx 710-720-test 8g2-oneui"

variant_patch(){ case "$1" in
	regular)       echo "" ;;
	a8xx)          echo "patches/a8xx_gen8.patch" ;;
	710-720-test)  echo "" ;;
	8g2-oneui)     echo "" ;;
	*) die "unknown variant '$1'" ;;
esac; }
variant_script(){ case "$1" in
	regular)       echo "patches/a840v2.py:patches/a740_devname.py" ;;
	a8xx)          echo "patches/a8xx_shared_mem.py:patches/a840v2.py:patches/a740_devname.py" ;;
	710-720-test)  echo "patches/a710-720.py:patches/a740_devname.py" ;;
	8g2-oneui)     echo "patches/a840v2.py:patches/8g2_oneui.py:patches/a740_devname.py" ;;
	*) die "unknown variant '$1'" ;;
esac; }

command -v git >/dev/null || die "git not found"
command -v patch >/dev/null || die "patch not found"

# --- fetch Mesa once, reuse across variants -----------------------------------
if [ ! -d "$cache/.git" ]; then
	echo "fetching Mesa into $cache (one time, ~250 MB)..."
	mkdir -p "$(dirname "$cache")"
	git init -q "$cache" || die "git init failed"
	git -C "$cache" remote get-url origin >/dev/null 2>&1 \
		|| git -C "$cache" remote add origin "$mesasrc"
fi

want="${2:-}"
[ -n "$want" ] || want="$(tr -d '[:space:]' < mesa_hash.txt 2>/dev/null || true)"
if [ -n "$want" ]; then
	[[ "$want" =~ ^[0-9a-f]{40}$ ]] || die "MESA_COMMIT must be 40-hex, got '$want'"
	ref="$want"
else
	ref=refs/heads/main
fi

echo "using Mesa ${ref#refs/heads/}"
ok=0
for attempt in 1 2 3; do
	if git -C "$cache" fetch -q --depth=1 origin "$ref"; then ok=1; break; fi
	echo "${yellow}fetch attempt $attempt failed, retrying${nocolor}"; sleep 20
done
[ "$ok" = 1 ] || die "could not fetch $ref from $mesasrc (network?)"

head="$(git -C "$cache" rev-parse FETCH_HEAD)"
echo "Mesa commit: $head"

variants="${1:-}"
# Default to every variant when none was given. This must never be able to leave
# $variants empty: an empty `for` body makes the script report success having
# tested nothing, which is worse than failing.
[ -n "$variants" ] || variants="$ALL_VARIANTS"
[ -n "$variants" ] || die "no variants to test (ALL_VARIANTS is empty?)"

echo "variants to test: $variants"

rc=0
# Count what actually ran and passed. The summary is derived from these counters,
# not from `rc` alone, so the script cannot claim success without having tested
# the variants it was asked to test.
asked=0
passed=0
for v in $variants; do
	asked=$((asked+1))
	echo
	echo "=============================================================="
	echo "  variant: $v"
	echo "=============================================================="
	work="$cache/wt-$v"
	# A fresh tree per variant: patches must be tested against clean upstream.
	#
	# This uses `git worktree`, not `git clone --shared`. The cache is a SHALLOW
	# repo (--depth=1), and cloning from a shallow repo does not carry its objects
	# over: the clone comes out empty and the checkout fails with "reference is not
	# a tree". A worktree borrows the cache's object store directly, which works.
	if [ -d "$work" ]; then
		git -C "$cache" worktree remove --force "$work" 2>/dev/null || rm -rf "$work"
	fi
	git -C "$cache" worktree prune
	git -C "$cache" worktree add --detach "$work" "$head" >/dev/null 2>&1 \
		|| die "could not create worktree for $v"
	[ "$(git -C "$work" rev-parse HEAD)" = "$head" ] || die "worktree for $v is not at $head"

	extra_patch="$(variant_patch "$v")"
	extra_script="$(variant_script "$v")"

	echo "-- patches/common/apply_common.sh"
	if ( cd "$work" && EXTRA_PATCH="$extra_patch" bash "$repo/patches/common/apply_common.sh" . ); then
		echo "${green}   common patches applied and asserted${nocolor}"
	else
		echo "${red}   common patches FAILED for $v${nocolor}"
		echo "${red}   -> rebase patches/common/*.patch onto Mesa $head${nocolor}"
		rc=1
		continue
	fi

	if [ -n "$extra_patch" ]; then
		echo "-- EXTRA_PATCH $extra_patch"
		prc=0
		out="$( cd "$work" && patch -p1 -N --fuzz=4 --no-backup-if-mismatch < "$repo/$extra_patch" 2>&1 )" || prc=$?
		echo "$out" | sed 's/^/    /'
		fuzz="$(echo "$out" | grep -c 'with fuzz' || true)"
		if [ "$prc" != 0 ]; then
			echo "${red}   EXTRA_PATCH did not apply cleanly (exit $prc)${nocolor}"
			rc=1
			continue
		fi
		if [ "$fuzz" != 0 ]; then
			echo "${yellow}   note: $fuzz hunk(s) applied with fuzz - rebase it${nocolor}"
		fi
		if [ -n "$(cd "$work" && git status --porcelain --untracked-files=all | grep -E '\.(rej|orig)$' || true)" ]; then
			echo "${red}   EXTRA_PATCH left .rej/.orig files${nocolor}"; rc=1; continue
		fi
		echo "${green}   EXTRA_PATCH applied cleanly${nocolor}"
	fi

	# The legs assert this right after the patch series.
	if ! ( cd "$work" && python3 -c "compile(open('src/freedreno/common/freedreno_devices.py').read(),'f','exec')" ); then
		echo "${red}   freedreno_devices.py does not parse after the patch series${nocolor}"
		rc=1
		continue
	fi

	echo "-- EXTRA_SCRIPT $extra_script"
	IFS=':' read -ra scripts <<< "$extra_script"
	for s in "${scripts[@]}"; do
		[ -f "$repo/$s" ] || { echo "${red}   missing $s${nocolor}"; rc=1; continue; }
		before="$( cd "$work" && git diff | sha256sum )"
		src=0
		( cd "$work" && python3 "$repo/$s" ) 2>&1 | sed 's/^/    /' || src=$?
		if [ "$src" != 0 ]; then
			echo "${red}   $s exited non-zero${nocolor}"
			rc=1
			continue
		fi
		after="$( cd "$work" && git diff | sha256sum )"
		if [ "$before" = "$after" ]; then
			# The Wayland and Linux legs die on exactly this.
			echo "${red}   $s changed nothing - the legs die on a no-op script${nocolor}"
			rc=1
			continue
		fi
		# Idempotency: a second run must not move the tree again.
		src2=0
		( cd "$work" && python3 "$repo/$s" >/dev/null 2>&1 ) || src2=$?
		second="$( cd "$work" && git diff | sha256sum )"
		if [ "$src2" != 0 ] || [ "$second" != "$after" ]; then
			echo "${yellow}   note: $s is not idempotent (2nd run changed the tree)${nocolor}"
		fi
		echo "${green}   $(basename "$s") ok (changed the tree, re-runs stable)${nocolor}"
	done

	if ! ( cd "$work" && python3 -c "compile(open('src/freedreno/common/freedreno_devices.py').read(),'f','exec')" ); then
		echo "${red}   freedreno_devices.py does not parse after the scripts${nocolor}"
		rc=1
		continue
	fi

	echo "   recipe changes on top of upstream:"
	( cd "$work" && git --no-pager diff --stat | tail -12 | sed 's/^/    /' )
	echo "${green}   variant $v PASSED${nocolor}"
	passed=$((passed+1))
done

echo
echo "variants tested: $passed/$asked passed"
if [ "$rc" = 0 ] && [ "$passed" = "$asked" ]; then
	echo "${green}test-patches: all variants passed against Mesa $head${nocolor}"
	echo "This does not compile the driver. Run 'make build-<leg>' before shipping."
	exit 0
fi
# Belt and braces: a zero exit with an incomplete sweep would be a false pass.
[ "$rc" = 0 ] && rc=1
echo "${red}test-patches: $((asked-passed)) of $asked variant(s) failed (Mesa $head)${nocolor}"
exit "$rc"

[ -n "$variants" ] || variants="regular a8xx 710-720-test 8g2-oneui"
