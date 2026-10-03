#!/usr/bin/env bash
# Report what this machine (or container) can actually build, and how much room is left.
# Read-only: it installs nothing and builds nothing.
#
# The legs need different toolchains. This prints a matrix so you can tell at a glance
# which leg is runnable, instead of discovering it 15 minutes into a Mesa build.
set -uo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo" || exit 1

red=$'\033[0;31m'; green=$'\033[0;32m'; yellow=$'\033[0;33m'; dim=$'\033[2m'; nocolor=$'\033[0m'

have(){ command -v "$1" >/dev/null 2>&1; }

# Present a check line: name, required version (optional), why it is needed.
check(){
	local name="$1" why="$2" want="${3:-}"
	if have "$name"; then
		local got=""
		case "$name" in
			meson)      got="$(meson --version 2>/dev/null)" ;;
			ninja)      got="$(ninja --version 2>/dev/null)" ;;
			shellcheck) got="$(shellcheck --version 2>/dev/null | awk '/version:/{print $2}')" ;;
			clang)      got="$(clang --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)" ;;
			*)          got="" ;;
		esac
		# A `want` of "1.5" is a MINIMUM, not an exact match: compare numerically on the
		# major.minor fields that were asked for, so 1.12.1 satisfies "1.5".
		if [ -n "$want" ] && [ -n "$got" ]; then
			if ! printf '%s\n%s\n' "$want" "$got" \
				| awk -v w="$want" -v g="$got" '
					BEGIN { n = split(w, wf, "."); split(g, gf, "."); ok = 1 }
					END {
						for (i = 1; i <= n; i++) {
							if (gf[i] + 0 > wf[i] + 0) break
							if (gf[i] + 0 < wf[i] + 0) { ok = 0; break }
						}
						exit ok ? 0 : 1
					}'; then
				printf '  %s%-22s%s %s %s(too old, need %s)%s  %s%s%s\n' \
					"$red" "$name" "$nocolor" "$got" "$dim" "$want" "$nocolor" "$dim" "$why" "$nocolor"
				return 1
			fi
			printf '  %s%-22s%s %-10s %s%s%s\n' "$green" "$name" "$nocolor" "$got" "$dim" "$why" "$nocolor"
			return 0
		fi
		printf '  %s%-22s%s %-10s %s%s%s\n' "$green" "$name" "$nocolor" "found" "$dim" "$why" "$nocolor"
		return 0
	fi
	printf '  %s%-22s%s %-10s %s%s%s\n' "$red" "$name" "$nocolor" "MISSING" "$dim" "$why" "$nocolor"
	return 1
}

echo "== container / host =="
if [ -f /.dockerenv ]; then
	echo "  running inside a container"
else
	echo "  running on the host (use 'make shell' for the pinned toolchain)"
fi
echo "  repo: $repo"
echo "  branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
echo

echo "== base tools (every leg) =="
base=0
check git      "clone Mesa, apply patches"          || base=1
check patch    "apply the .patch series"            || base=1
check python3  "run the patch scripts"              || base=1
check ninja    "build"                              || base=1
check meson    "Mesa 26.x needs >= 1.5"  "1.5"      || base=1
check flex     "glslang/IR parsers"                 || base=1
check bison    "glslang/IR parsers"                 || base=1
check glslangValidator "compile shaders"            || base=1
check zip      "package the driver"                 || base=1
check unzip    "unpack the NDK"                     || base=1
check curl     "download the NDK / sysroots"        || base=1
echo

echo "== Android leg (build_turnip.sh) =="
# The NDK itself is downloaded by the recipe, so it is not a prerequisite here.
android=0
check patchelf "deps list in build_turnip.sh"       || android=1
check ccache   "meson c = ['ccache', ...]"          || android=1
have clang && echo "  ${green}$(printf '%-22s' clang)${nocolor} found      ${dim}bionic host compiler${nocolor}" \
                || { echo "  ${red}$(printf '%-22s' clang)${nocolor} MISSING    ${dim}NDK leg wants clang for host tools${nocolor}"; android=1; }
echo

echo "== Wayland leg (build_turnip_wayland.sh) =="
wayland=0
check clang "NDK cross + host tools"                || wayland=1
check lld   "linker (c_ld/cpp_ld = 'lld')"          || wayland=1
check pkg-config "cross pkg-config"                 || wayland=1
check ccache    "compiler cache"                    || wayland=1
# The native meson file uses ar = 'llvm-ar', strip = 'llvm-strip'. There is no
# binary called "llvm" to test for; on 24.04 these are symlinks into llvm-18.
for t in llvm-ar llvm-strip llvm-ranlib; do
	check "$t" "native meson ar/strip/ranlib"      || wayland=1
done
echo

echo "== Linux leg (build_turnip_linux.sh) =="
linux=0
check aarch64-linux-gnu-gcc "cross compiler"       || linux=1
check aarch64-linux-gnu-g++  "cross C++"           || linux=1
check aarch64-linux-gnu-ar   "cross ar"            || linux=1
check cmake      "native cmake (hardcoded path)"    || linux=1
check pkg-config "sysroot pkg-config"               || linux=1
# The recipe also wants tar with zstd, xz and a network route to mirror.archlinuxarm.org.
have tar && echo "  ${green}$(printf '%-22s' tar-with-zstd)${nocolor} found      ${dim}Arch ARM sysroot unpack${nocolor}" \
             || { echo "  ${red}$(printf '%-22s' tar-with-zstd)${nocolor} MISSING${nocolor}"; linux=1; }
echo

echo "== dev tooling =="
check shellcheck "make lint"                        || true
check gitleaks   "make secrets / pre-commit hook"   || true
echo

echo "== disk =="
avail_mb="$(df -BM --output=avail . 2>/dev/null | tail -1 | tr -dc '0-9')"
if [ -n "$avail_mb" ]; then
	# Thresholds are MiB. Empirically: one leg is several GB (NDK ~4 GB unpacked,
	# plus a Mesa checkout, a ninja build dir and - for the Linux leg - an Arch ARM
	# sysroot); all three legs plus the NDK is ~30-40 GB.
	if   [ "$avail_mb" -lt 15000 ]; then
		echo "  ${red}$(df -h --output=avail . | tail -1 | tr -d ' ')${nocolor} free - too little for a full three-leg run"
	elif [ "$avail_mb" -lt 40000 ]; then
		echo "  ${yellow}$(df -h --output=avail . | tail -1 | tr -d ' ')${nocolor} free - enough for one leg, tight for all three"
	else
		echo "  ${green}$(df -h --output=avail . | tail -1 | tr -d ' ')${nocolor} free - comfortable"
	fi
fi
for d in turnip_workdir wayland_workdir linux_workdir; do
	[ -d "$d" ] && echo "  $(du -sh "$d" 2>/dev/null | cut -f1)  $d"
done
echo

echo "== summary =="
if   [ "$base" = 0 ] && [ "$android" = 0 ] && [ "$wayland" = 0 ] && [ "$linux" = 0 ]; then
	echo "  ${green}all legs buildable${nocolor}"
else
	[ "$base" = 0 ]     || echo "  ${red}base tools missing${nocolor}      - run inside the container: make shell"
	[ "$android" = 0 ]  || echo "  ${red}Android leg incomplete${nocolor}"
	[ "$wayland" = 0 ]  || echo "  ${yellow}Wayland leg incomplete${nocolor}  (the recipes download the NDK and Termux sysroot themselves)"
	[ "$linux" = 0 ]    || echo "  ${yellow}Linux leg incomplete${nocolor}    (apt install the aarch64-linux-gnu-* cross toolchain)"
fi
exit 0
