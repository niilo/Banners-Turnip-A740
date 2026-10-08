#!/bin/bash -e

green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'
deps="git meson ninja patchelf unzip curl pip flex bison zip glslang glslangValidator"
workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r29"
ndk="$workdir/$ndkver/toolchains/llvm/prebuilt/linux-x86_64/bin"
sdkver="34"
mesasrc="https://gitlab.freedesktop.org/mesa/mesa"
srcfolder="mesa"

run_all(){
	# TAG arrives already prefixed ("v26.3.0-..."); strip it so names do not double it
	# into "Vv...". CI overrides BUILD_VERSION with the run number, which has no 'v'.
	BUILD_VERSION="${BUILD_VERSION#v}"
	echo -e "${green}====== Begin building TU Perf V${BUILD_VERSION}! ======${nocolor}"
	check_deps
	prepare_workdir
	build_lib_for_android main
}

check_deps(){
	echo "Checking system for required Dependencies ..."
	for deps_chk in $deps; do
		if command -v "$deps_chk" >/dev/null 2>&1 ; then
			echo -e "$green - $deps_chk found $nocolor"
		else
			echo -e "$red - $deps_chk not found, can't continue. $nocolor"
			deps_missing=1
		fi
	done

	if [ "$deps_missing" == "1" ]; then
		echo "Please install missing dependencies" && exit 1
	fi

	echo "Installing python Mako dependency..."
	pip install mako &> /dev/null || true
}

prepare_workdir(){
	echo "Preparing work directory..."
	mkdir -p "$workdir" && cd "$_"

	if [ "${SKIP_SOURCE_DOWNLOAD}" = "1" ]; then
		echo "Skipping NDK + Mesa download (reusing existing source)..."
		# Reset to a clean tree, not just checkout: the patch series must apply to a
		# tree the last run did not touch, or a half-patched tree silently rebuilds
		# into a subtly wrong driver.
		if [ -d "$srcfolder/.git" ]; then
			echo "Resetting Mesa source tree..."
			git -C "$srcfolder" checkout -f . && git -C "$srcfolder" clean -qfd
		fi
		return
	fi

	echo "Downloading android-ndk from google server..."
	curl -sL https://dl.google.com/android/repository/"$ndkver"-linux.zip --output "$ndkver"-linux.zip &> /dev/null

	echo "Extracting android-ndk..."
	# -o overwrites without prompting: without it unzip aborts on an existing NDK
	# when stdin is closed, so a rebuild in a used workdir would never succeed.
	unzip -q -o "$ndkver"-linux.zip &> /dev/null

	echo "Downloading mesa source..."
	# git clone into an existing mesa/ fails fatally ("destination path 'mesa' already
	# exists"), so a second build in a used workdir could never start. Reuse the
	# clone and reset it. A requested commit needs a fetch, so only do that when one
	# was actually asked for.
	if [ -d "$srcfolder/.git" ]; then
		echo "Reusing existing Mesa clone, resetting to a clean tree..."
		git -C "$srcfolder" checkout -f . && git -C "$srcfolder" clean -qfd
		if [ -n "${MESA_COMMIT:-}" ]; then
			echo "Switching to MESA_COMMIT=$MESA_COMMIT ..."
			git -C "$srcfolder" fetch --depth=1 origin "$MESA_COMMIT" \
				|| { echo "cannot fetch $MESA_COMMIT" >&2; exit 1; }
			git -C "$srcfolder" checkout -f FETCH_HEAD
		fi
		return
	fi
	git clone $mesasrc --depth=1 -b main $srcfolder
}

build_lib_for_android(){
	cd "$workdir/$srcfolder"
	echo "==== Building Mesa on $1 branch (performance build — A6xx/A7xx) ===="

	# KGSL fixes every leg ships (patches/common/SOURCE); fails the build if one does not land.
	bash ../../patches/common/apply_common.sh . || { echo -e "${red}patches/common did not apply, aborting!${nocolor}"; exit 1; }

	# The variant's own patch and scripts. Without these the perf build silently
	# differs from the driver it is meant to profile: EXTRA_SCRIPT carries
	# a740_devname.py (and a740_gcm.py on the GCM arm), so skipping it produced a
	# binary with no "Banners" marker - a different driver from the release ZIP.
	if [ -n "${EXTRA_PATCH:-}" ]; then
		IFS=':' read -ra PATCHES <<< "$EXTRA_PATCH"
		for p in "${PATCHES[@]}"; do
			[ -f "../../$p" ] || { echo -e "${red}EXTRA_PATCH $p does not exist${nocolor}"; exit 1; }
			echo "applying $p"
			patch -p1 -N --fuzz=3 --no-backup-if-mismatch < "../../$p" \
				|| { echo -e "${red}$p did not apply cleanly, aborting!${nocolor}"; exit 1; }
		done
	fi

	# Fail-hard on a no-op script, like the Wayland and Linux legs: a script that
	# changed nothing means the anchor moved or the build is not what it claims.
	if [ -n "${EXTRA_SCRIPT:-}" ]; then
		IFS=':' read -ra SCRIPTS <<< "$EXTRA_SCRIPT"
		for s in "${SCRIPTS[@]}"; do
			[ -f "../../$s" ] || { echo -e "${red}EXTRA_SCRIPT $s does not exist${nocolor}"; exit 1; }
			before="$(git diff | sha256sum)"
			echo "running $s"
			python3 "../../$s" || { echo -e "${red}$s failed, aborting!${nocolor}"; exit 1; }
			after="$(git diff | sha256sum)"
			[ "$after" != "$before" ] || { echo -e "${red}$s changed nothing, aborting!${nocolor}"; exit 1; }
		done
		python3 -c "compile(open('src/freedreno/common/freedreno_devices.py').read(),'f','exec')" \
				|| { echo -e "${red}freedreno_devices.py does not parse after the scripts${nocolor}"; exit 1; }
	fi

	# NDK r29 compatibility fixes
	sed -i 's/typedef const native_handle_t\* buffer_handle_t;/typedef void\* buffer_handle_t;/g' include/android_stub/cutils/native_handle.h || true
	sed -i 's/, hnd->handle/, (void \*)hnd->handle/g' src/util/u_gralloc/u_gralloc_fallback.c || true
	sed -i -E 's/([a-z_]+)->handle->/((const native_handle_t *)\1->handle)->/g' src/vulkan/runtime/vk_android.c || true

	mkdir -p "$workdir/bin"
	ln -sf "$ndk/clang" "$workdir/bin/cc"
	ln -sf "$ndk/clang++" "$workdir/bin/c++"
	export PATH="$workdir/bin:$ndk:$PATH"
	export CC=clang
	export CXX=clang++
	export AR=llvm-ar
	export RANLIB=llvm-ranlib
	export STRIP=llvm-strip
	export OBJDUMP=llvm-objdump
	export OBJCOPY=llvm-objcopy
	export LDFLAGS="-fuse-ld=lld -flto=thin"
	export CFLAGS="-D__ANDROID__ -O3 -fno-plt -flto=thin -Wno-error -Wno-deprecated-declarations -Wno-incompatible-pointer-types-discards-qualifiers -Wno-incompatible-pointer-types"
	export CXXFLAGS="-D__ANDROID__ -O3 -fno-plt -flto=thin -Wno-error -Wno-deprecated-declarations -Wno-incompatible-pointer-types-discards-qualifiers -Wno-incompatible-pointer-types"

	GITHASH=$(git rev-parse --short HEAD)

	echo "Generating build files..."
	cat <<EOF >"android-aarch64.txt"
[binaries]
ar = '$ndk/llvm-ar'
c = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang']
cpp = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
c_ld = '$ndk/ld.lld'
cpp_ld = '$ndk/ld.lld'
strip = '$ndk/llvm-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=$ndk/pkg-config', '/usr/bin/pkg-config']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

	cat <<EOF >"native.txt"
[build_machine]
c = ['ccache', 'clang']
cpp = ['ccache', 'clang++']
ar = 'llvm-ar'
strip = 'llvm-strip'
c_ld = 'ld.lld'
cpp_ld = 'ld.lld'
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

	# UNSTRIPPED on purpose: this is the profiling build. With -Dstrip=true the
# shipped .so carries no symbol table and simpleperf can only report driver
# offsets (+9ea920), which is useless - the KGSL_ZERO_TIMEOUT_POLL investigation
# could name functions (wait_timestamp_safe, vk_sync_timeline_gc_locked) only
# because it had symbols. Debug info costs size, not speed: -O3 + ThinLTO still
# apply, so this arm stays comparable to the release build. The perf ZIP is never
# published - release ZIPs come from the other legs.
# NOTE: this note must stay ABOVE the meson invocation. A comment between
# backslash continuations swallows every argument after it, including -Dstrip
# itself (verified with printf), which would silently drop the flag.
meson setup build-android-aarch64 \
		--cross-file "android-aarch64.txt" \
		--native-file "native.txt" \
		--prefix /tmp/turnip-$1 \
		-Dbuildtype=release \
		-Db_ndebug=true \
		-Dstrip=false \
		-Dplatforms=android \
		-Dvideo-codecs= \
		-Dplatform-sdk-version="$sdkver" \
		-Dandroid-stub=true \
		-Dgallium-drivers= \
		-Dvulkan-drivers=freedreno \
		-Dvulkan-beta=true \
		-Dfreedreno-kmds=kgsl \
		-Degl=disabled \
		-Dplatform-sdk-version=36 \
		-Dandroid-libbacktrace=disabled \
		--reconfigure

	echo "Compiling build files..."
	ninja -C build-android-aarch64 install

	if ! [ -f /tmp/turnip-$1/lib/libvulkan_freedreno.so ]; then
		echo -e "${red}Build failed!${nocolor}" && exit 1
	fi

	echo "Making the archive..."
	cd /tmp/turnip-$1/lib

	_zip_name="mesa-turnip-perf-$1.zip"

	cat <<EOF >"meta.json"
{
  "schemaVersion": 1,
  "name": "Banners Turnip Perf ${GITHASH}",
  "description": "A6xx/A7xx performance build — Mesa main (git ${GITHASH}). O3 + ThinLTO. KGSL.",
  "author": "The412Banner",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "Vulkan 1.4.335",
  "minApi": 28,
  "libraryName": "libvulkan_freedreno.so"
}
EOF
	zip -q "/tmp/${_zip_name}" libvulkan_freedreno.so meta.json
	cd - > /dev/null

	if ! [ -f "/tmp/${_zip_name}" ]; then
		echo -e "${red}Failed to pack the archive!${nocolor}"
	else
		cp "/tmp/${_zip_name}" "$workdir/"
		echo -e "${green}Build completed successfully! → ${_zip_name}${nocolor}"
	fi
}

run_all
