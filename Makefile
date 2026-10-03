# Banners-Turnip developer entry points.
#
# Everything works with or without Docker. With Docker (the default), commands run
# inside the dev image so you do not have to install the cross toolchains on your
# host. Set DOCKER=0 to run natively.
#
#   make help          list targets
#   make doctor        what is installed / missing, and how much disk is left
#   make lint          static checks (fast, no network)  <- run this always
#   make test          patch application against real Mesa (needs network)
#   make shell         interactive shell in the container
#   make build-<leg>   run one leg; see `make help` for the variables
#
# See docs/DEVELOPMENT.md and AGENTS.md.

SHELL := /bin/bash
.DEFAULT_GOAL := help

DOCKER ?= 1
COMPOSE := docker compose
IMAGE := banners-turnip-dev

# --- build knobs (override on the command line) -------------------------------
# VARIANT: regular | a8xx | 710-720-test | 8g2-oneui   (mirrors the CI matrix)
VARIANT ?= regular
# MESA_COMMIT: 40-hex. Empty = the commit in mesa_hash.txt, else mesa/main HEAD.
MESA_COMMIT ?=
# TAG: release-style tag used for the ZIP name, e.g. v26.3.0-20261002
TAG ?= dev-$(shell git rev-parse --short HEAD 2>/dev/null || echo local)
# META_NAME: the driver name shown in AdrenoTools / BannerHub / Winlator driver
# lists (meta.json "name"). Separate from the Vulkan deviceName, which
# patches/a740_devname.py sets to "Turnip (Banners A740)" for apps that report
# VkPhysicalDeviceProperties. The variant suffix is appended automatically, so the
# four variants stay distinguishable in a list.
META_NAME ?= Banners Turnip A740
# PACKAGE_VERSION: meta.json packageVersion (CI uses the daily build number)
PACKAGE_VERSION ?= 1
# KEEP_SYMBOLS=1 for the Linux leg: debugoptimized, unstripped.
KEEP_SYMBOLS ?=
# REUSE=1 on build-android / build-perf: skip the NDK and Mesa download and reuse
# what is already in turnip_workdir/. Turns a ~10 min rebuild into a few minutes
# when iterating on a patch. The Mesa tree is reset to HEAD before patching, so this
# is safe; it is NOT safe if turnip_workdir/mesa is missing.
REUSE ?=

# --- the variant table, kept identical to the &drivers anchor in ---------------
# .github/workflows/turnip_build_combined.yml. scripts/lint.sh asserts the two agree.
#
# This is pure make rather than a shell `case`: make counts parentheses when it
# parses a function body, so a `case` label like `regular)` ends the function early.
#
# The lookup is two steps on purpose. `$($(prefix_$(VARIANT)))` looks like it should
# work but does not: make treats the inner reference as a *name*, not as a value to
# re-expand, so it searches for a variable literally called "-A8xx". Naming the
# intermediate (`name`) and then expanding it works, dashes in the variant name
# included.
# --- A740 experiment variants --------------------------------------------------
# Opt-in performance experiments (docs/A740_PROGRAM.md §4). NOT part of the CI
# matrix and NOT defaults: each is UNMEASURED on A740 hardware and each must pass
# the AGENTS.md §3 bar (hypothesis + 10 min sustained run + device check) before it
# can be promoted. They exist so the measurement can be done, and so it is
# reversible by deleting the variant.
#
# Each is a separate variant rather than a flag so one experiment cannot silently
# ride along with another, and so a build can be identified on the device by its
# driver name.
scripts_a740-gcm        := patches/a840v2.py:patches/a740_devname.py:patches/a740_gcm.py
scripts_a740-suballoc   := patches/a840v2.py:patches/a740_devname.py:patches/a740_suballoc.py
scripts_a740-gcm-suballoc := patches/a840v2.py:patches/a740_devname.py:patches/a740_gcm.py:patches/a740_suballoc.py
suffix_a740-gcm          := -A740-GCM
suffix_a740-suballoc     := -A740-Suballoc
suffix_a740-gcm-suballoc := -A740-GCM-Suballoc
patch_a740-gcm        :=
patch_a740-suballoc   :=
patch_a740-gcm-suballoc :=

VARIANTS := regular a8xx 710-720-test 8g2-oneui a740-gcm a740-suballoc a740-gcm-suballoc

# The CI matrix does not contain the a740-* experiments, so the three-way table
# check in scripts/lint.sh only covers the four released variants. Guard the extra
# ones here instead: every experiment must be listed, and no experiment may point
# at a patch script that does not exist.

suffix_regular       :=
suffix_a8xx          := -A8xx
suffix_710-720-test  := -710-720-Test
suffix_8g2-oneui     := -8G2-OneUI
suffix_name = suffix_$(VARIANT)
suffix_of = $($(suffix_name))

patch_regular        :=
patch_a8xx           := patches/a8xx_gen8.patch
patch_710-720-test   :=
patch_8g2-oneui      :=
patch_name = patch_$(VARIANT)
patch_of = $($(patch_name))

# The variant table, kept identical to the &drivers anchor in ---------------
# .github/workflows/turnip_build_combined.yml. scripts/lint.sh asserts the two agree.
#
# NOTE: scripts_of() appends patches/a740_devname.py, a fork-local cosmetic
# override (Vulkan deviceName). It is NOT part of the upstream matrix: the
# variant -> patch/suffix mapping here must stay identical to CI, with only the
# devname script added on top.

scripts_regular       := patches/a840v2.py:patches/a740_devname.py
scripts_a8xx          := patches/a8xx_shared_mem.py:patches/a840v2.py:patches/a740_devname.py
scripts_710-720-test  := patches/a710-720.py:patches/a740_devname.py
scripts_8g2-oneui     := patches/a840v2.py:patches/8g2_oneui.py:patches/a740_devname.py
scripts_name = scripts_$(VARIANT)
scripts_of = $($(scripts_name))

# Guard: every build target depends on this, so a typo'd VARIANT fails in a second
# rather than after downloading an NDK.
#
# The variable and the phony target deliberately have DIFFERENT names. A .PHONY
# entry with no recipe of its own is a target, not the expansion of the same-named
# variable - naming both `validate_variant` makes make run the empty rule and skip
# the check entirely.
ifneq ($(filter $(VARIANT),$(VARIANTS)),)
VALIDATE_OK = true
else
VALIDATE_OK = false
endif

validate_variant:
ifeq ($(VALIDATE_OK),true)
	@true
else
	@echo "error: VARIANT='$(VARIANT)' is not one of: $(VARIANTS)" >&2; \
	 echo "       (matrix: .github/workflows/turnip_build_combined.yml)" >&2; \
	 exit 2
endif

# Resolve MESA_COMMIT: explicit value > mesa_hash.txt > mesa/main HEAD.
# The Wayland/Linux recipes validate the 40-hex form themselves and die with a clear
# message, so failing here first just saves a container start.
require_commit = $(shell \
	if [ -n "$(MESA_COMMIT)" ]; then echo "$(MESA_COMMIT)"; \
	elif [ -s mesa_hash.txt ]; then tr -d '[:space:]' < mesa_hash.txt; \
	else git ls-remote https://gitlab.freedesktop.org/mesa/mesa HEAD | awk '{print $$1}'; fi)

# Run a command inside the dev container, or natively when DOCKER=0.
in_container = $(if $(filter 1,$(DOCKER)),$(COMPOSE) run --rm -T dev,)

.PHONY: help doctor lint test secrets secrets-history shell image clean distclean collect \
        build-android build-perf build-wayland build-linux verify resolve-mesa \
        print-commit validate_variant hooks check

help:
	@echo "Banners-Turnip - make targets"
	@echo
	@echo "  Setup / environment"
	@echo "    make image            build the dev container image ($(IMAGE))"
	@echo "    make shell            interactive shell in the container"
	@echo "    make doctor           show toolchain availability and free disk"
	@echo "    DOCKER=0 <target>     run on the host instead of in the container"
	@echo
	@echo "  Checks"
	@echo "    make lint             shellcheck + python compile + workflow matrix"
	@echo "    make secrets          scan STAGED changes for secrets (pre-commit gate)"
	@echo "    make secrets-history  scan every commit for secrets (what CI runs)"
	@echo "    make check            lint + secrets: everything fast, before you commit"
	@echo "    make test [VARIANT]   patch application against real Mesa (network)"
	@echo "    make hooks            install the pre-commit hook in this clone"
	@echo
	@echo "  Builds   (VARIANT=$(VARIANT) TAG=$(TAG))"
	@echo "    make build-android    NDK r29 bionic driver (AdrenoTools ZIP)"
	@echo "    make build-perf       same, unstripped, for profiling"
	@echo "    make build-wayland    bionic driver for Bannerlator Wayland containers"
	@echo "    make build-linux      glibc aarch64 ICD for the Linux runtime"
	@echo
	@echo "  Release helpers"
	@echo "    make resolve-mesa     print the current mesa/main HEAD (40-hex)"
	@echo "    make verify           verify a ZIP  (KIND=android|wayland|linux ZIP=...)"
	@echo "    make collect          copy all built ZIPs into ./dist"
	@echo
	@echo "  Cleanup"
	@echo "    make clean            remove build output (keeps tracked patch fixtures)"
	@echo "    make distclean        also remove the Mesa test cache and built images"
	@echo
	@echo "  Variants: $(VARIANTS)"
	@echo "  Examples:"
	@echo "    make build-linux VARIANT=a8xx MESA_COMMIT=4f554dafa8dcd81048916f1382f561ed134db8ec"
	@echo "    make test 8g2-oneui"

image:
	$(COMPOSE) build

shell:
	$(COMPOSE) run --rm dev

# --- legs ----------------------------------------------------------------------
# Each leg builds one driver variant. EXTRA_PATCH/EXTRA_SCRIPT come from the variant
# table above, so `make build-linux VARIANT=a8xx` reproduces the CI job for a8xx.

build-android: validate_variant
	$(call in_container) env \
		BUILD_VERSION="$(TAG)" \
		MESA_COMMIT="$(MESA_COMMIT)" \
		EXTRA_PATCH="$(call patch_of,$(VARIANT))" \
		EXTRA_SCRIPT="$(call scripts_of,$(VARIANT))" \
		BUILD_SUFFIX="$(call suffix_of,$(VARIANT))" \
		META_NAME="$(META_NAME)$(call suffix_of,$(VARIANT))" \
		META_DESC="" \
		$(if $(filter 1,$(REUSE)),SKIP_SOURCE_DOWNLOAD=1,) \
		./build_turnip.sh

build-perf: validate_variant
	$(call in_container) env \
		BUILD_VERSION="$(TAG)" \
		MESA_COMMIT="$(MESA_COMMIT)" \
		EXTRA_PATCH="$(call patch_of,$(VARIANT))" \
		EXTRA_SCRIPT="$(call scripts_of,$(VARIANT))" \
		BUILD_SUFFIX="$(call suffix_of,$(VARIANT))" \
		META_NAME="$(META_NAME)$(call suffix_of,$(VARIANT))" \
		./build_turnip_perf.sh

# The Wayland and Linux legs require a pinned 40-hex Mesa commit and refuse to guess.
build-wayland: validate_variant
	$(call in_container) env \
		MESA_COMMIT="$(call require_commit)" \
		ZIP_NAME="Turnip-$(TAG)$(call suffix_of,$(VARIANT))-Wayland.zip" \
		META_NAME="$(META_NAME)$(call suffix_of,$(VARIANT))-Wayland" \
		PACKAGE_VERSION="$(PACKAGE_VERSION)" \
		VARIANT="$(VARIANT)" \
		EXTRA_PATCH="$(call patch_of,$(VARIANT))" \
		EXTRA_SCRIPT="$(call scripts_of,$(VARIANT))" \
		./build_turnip_wayland.sh

build-linux: validate_variant
	$(call in_container) env \
		MESA_COMMIT="$(call require_commit)" \
		ZIP_NAME="Turnip-$(TAG)$(call suffix_of,$(VARIANT))-Linux.zip" \
		META_NAME="$(META_NAME)$(call suffix_of,$(VARIANT))-Linux" \
		PACKAGE_VERSION="$(PACKAGE_VERSION)" \
		VARIANT="$(VARIANT)" \
		KEEP_SYMBOLS="$(KEEP_SYMBOLS)" \
		EXTRA_PATCH="$(call patch_of,$(VARIANT))" \
		EXTRA_SCRIPT="$(call scripts_of,$(VARIANT))" \
		./build_turnip_linux.sh

resolve-mesa:
	@$(MAKE) --no-print-directory print-commit

print-commit:
	@echo "$(call require_commit)"

# Verify a ZIP exactly as the combined workflow does.
verify:
	@if [ -z "$(ZIP)" ]; then \
		echo "usage: make verify KIND=android|wayland|linux ZIP=path/to.zip" >&2; exit 2; \
	fi
	$(call in_container) python3 .github/scripts/verify_driver_zip.py \
		--kind "$(KIND)" --zip "$(ZIP)" --variant "$(VARIANT)" \
		--expect-name "$(META_NAME)$(call suffix_of,$(VARIANT))" \
		$(if $(filter wayland,$(KIND)),--layer-abi patches/wayland/layer-abi,) \
		$(if $(filter linux,$(KIND)),--readelf aarch64-linux-gnu-readelf,) \
		--report "report-$(KIND)-$(VARIANT).json"

collect:
	@mkdir -p dist
	@find turnip_workdir wayland_workdir linux_workdir -maxdepth 1 -name 'Turnip-*.zip' \
		-exec cp -v {} dist/ \; 2>/dev/null || true
	@ls -la dist/ 2>/dev/null || echo "no ZIPs found yet - run a build first"

# --- cleanup -------------------------------------------------------------------
# Deliberately NOT `rm -rf turnip_workdir`: that directory contains two tracked files
# (tu_gen8.patch, tu_gen8_clean.patch). Remove the ignored contents and keep them.
clean:
	@echo "Removing build output (tracked patch fixtures are preserved)..."
	@for d in turnip_workdir wayland_workdir linux_workdir; do \
		if [ -d "$$d" ]; then \
			find "$$d" -mindepth 1 -maxdepth 1 \
				! -name 'tu_gen8.patch' ! -name 'tu_gen8_clean.patch' \
				-exec rm -rf {} + ; \
		fi; \
	done
	@rm -f report-*.json
	@rm -rf release-info
	@git status --porcelain -- turnip_workdir | sed 's/^/  remaining in turnip_workdir: /' || true
	@echo "clean done. Free disk: $$(df -h . | tail -1 | awk '{print $$4}')"

distclean: clean
	rm -rf .cache
	-$(COMPOSE) down --rmi local 2>/dev/null || true


lint:
	$(call in_container) ./scripts/lint.sh

# --- secrets -------------------------------------------------------------------
# staged: only what this commit is about to add. Safe to run constantly - it never
# fails on something an older commit already did.
secrets:
	$(call in_container) ./scripts/scan-secrets.sh staged

# history: every reachable commit. What CI runs. Use before pushing a branch that
# came from somewhere else, and whenever the staged scan trips on something odd.
secrets-history:
	$(call in_container) ./scripts/scan-secrets.sh history

# Everything that is fast enough to run before every single commit. This is the
# agent-facing contract: if `make check` passes, the commit is worth making.
check:
	$(call in_container) ./scripts/lint.sh
	$(call in_container) ./scripts/scan-secrets.sh staged

# Install the pre-commit hook for THIS clone. core.hooksPath is per-clone and not
# committed, so every developer opts in - hence it being a target rather than a
# committed config.
hooks:
	@chmod +x .githooks/pre-commit
	@git config core.hooksPath .githooks
	@echo "pre-commit hook installed for this clone (core.hooksPath=.githooks)"
	@echo "It blocks secrets, staged build output, and mode regressions. Bypass: --no-verify"

test: validate_variant
	$(call in_container) ./scripts/test-patches.sh $(VARIANT) $(MESA_COMMIT)

doctor:
	@$(call in_container) ./scripts/doctor.sh || true
