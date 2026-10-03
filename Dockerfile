# Development image for Banners-Turnip.
#
# One image that can build ALL legs, because the three legs need three different
# toolchains and you will eventually want to run more than one of them:
#
#   Android / perf  (bionic)   Android NDK r29 - downloaded by the build script
#   Wayland         (bionic)   NDK r29 + clang/lld + Termux sysroot from the network
#   Linux runtime   (glibc)    aarch64-linux-gnu-gcc + Arch Linux ARM sysroot
#
# Base is ubuntu:24.04 to match the CI runners (.github/workflows uses ubuntu-24.04
# and ubuntu-latest, which is 24.04), so a container build and a CI build see the same
# glibc and the same apt package versions.
#
# Build:  docker build -t banners-turnip-dev .
# Run:    docker compose run --rm dev    (or: make shell)
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

# Common to every leg (union of the apt-get lines in turnip_build_combined.yml):
#   ninja-build flex bison glslang-tools curl zip patch unzip
# Android/perf leg also wants: patchelf perl git python3-pip
# Wayland leg adds:            ccache pkg-config clang lld llvm binutils
# Linux leg adds:              cmake the aarch64 cross toolchain, tar zstd xz-utils
# Developer tooling:           shellcheck (make lint) build-essential (host tools)
#
# binutils is required because the Wayland leg's native meson file calls llvm-ar,
# and build-essential because the Linux leg builds a host wayland-scanner with gcc.
RUN apt-get update && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates curl git patch unzip zip tar zstd xz-utils \
        ninja-build flex bison glslang-tools pkg-config cmake build-essential \
        patchelf perl \
        ccache clang lld llvm binutils \
        gcc-aarch64-linux-gnu g++-aarch64-linux-gnu binutils-aarch64-linux-gnu \
        python3 python3-pip python3-yaml \
        shellcheck \
    && rm -rf /var/lib/apt/lists/*

# Ubuntu 24.04 ships meson 1.3.2, but Mesa 26.x requires >= 1.5 - this is exactly why
# the workflows pip-install meson. --break-system-packages is required on 24.04
# (PEP 668 externally-managed environment), same as CI does.
RUN pip3 install --no-cache-dir --break-system-packages \
        'meson>=1.5' \
        mako \
        pyyaml \
        packaging

# gitleaks: the secret scanner, pinned so a local run and a CI run are the same
# scanner. Not in apt or pip - a versioned static binary from its own releases is the
# supported install path. The SHA256 of each archive is pinned below: an unverified
# download is not a dependency, it is a new way to be compromised.
#
# To bump: change GITLEAKS_VERSION, download both archives, update the sums, and
# confirm the values against the release's checksum file (NOT against the download
# you just made - that proves nothing).
ARG GITLEAKS_VERSION=8.28.0
ARG TARGETARCH=amd64
RUN set -eux; \
    # gitleaks names its archives x64/arm64; Docker names the platform amd64/arm64.
    case "${TARGETARCH}" in \
      amd64) asset="x64";   sum="a65b5253807a68ac0cafa4414031fd740aeb55f54fb7e55f386acb52e6a840eb";; \
      arm64) asset="arm64"; sum="eff65261156100e5d94a6b3dec313d532fddfe19ae1590bf7a2b4f2699128356";; \
      *) echo "unsupported TARGETARCH for the gitleaks step: ${TARGETARCH}" >&2; exit 1;; \
    esac; \
    url="https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_${asset}.tar.gz"; \
    curl -fsSL --retry 5 --retry-all-errors "$url" -o /tmp/gl.tar.gz; \
    echo "${sum}  /tmp/gl.tar.gz" | sha256sum -c --strict - || { echo "gitleaks checksum mismatch" >&2; exit 1; }; \
    tar -xzf /tmp/gl.tar.gz -C /usr/local/bin gitleaks; \
    rm -f /tmp/gl.tar.gz; \
    chmod 755 /usr/local/bin/gitleaks; \
    gitleaks version

# Run as the invoking host user (compose passes $UID:$GID) so files written into the
# bind-mounted repo stay owned by you, not by root. uid/gid are baked in as 1000,
# which matches the default host user; compose overrides per-run.
ARG UID=1000
ARG GID=1000
RUN groupadd -g "$GID" -o turnip 2>/dev/null || true \
    && useradd -m -u "$UID" -g "$GID" -o -s /bin/bash turnip 2>/dev/null || true

# A non-root git identity. The build scripts commit inside the Mesa tree
# (build_turnip_wayland.sh does `git commit -am ...`), which fails without one.
RUN git config --global user.name  "Banners Turnip Dev" \
    && git config --global user.email "dev@banners-turnip.local" \
    && git config --global init.defaultBranch main \
    && git config --global advice.detachedHead false

# ccache is used by the Wayland and Android legs (meson c = ['ccache', ...]).
# CI sets 2G; match that so a local build caches about as well.
ENV CCACHE_DIR=/cache/ccache \
    CCACHE_MAXSIZE=2G \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8
RUN mkdir -p /cache/ccache && chmod 777 /cache/ccache

# Fails the build early if a tool the recipes hard-require is missing, rather than
# 15 minutes into a Mesa build. Mirrors the deps= list in build_turnip.sh.
RUN set -eu; \
    for t in git meson ninja patchelf unzip curl pip flex bison zip \
             glslang glslangValidator pkg-config cmake gcc g++ aarch64-linux-gnu-gcc \
             gitleaks; do \
        command -v "$t" >/dev/null 2>&1 || { echo "MISSING required tool: $t" >&2; exit 1; }; \
    done; \
    echo "meson        $(meson --version)"; \
    echo "aarch64-gcc  $(aarch64-linux-gnu-gcc --version | head -1)"; \
    echo "clang        $(clang --version | head -1)"; \
    echo "shellcheck   $(shellcheck --version | grep version: )"; \
    echo "gitleaks     $(gitleaks version 2>/dev/null | head -1)"; \
    echo "all required tools present"

WORKDIR /work
USER turnip

# Default to an interactive shell. Override the command for one-shot builds:
#   docker compose run --rm dev ./build_turnip_linux.sh
CMD ["bash"]
