# Development setup

How to work on this repo locally: the container, the `make` targets, and the
things that will otherwise surprise you. For *how the driver is built*, see
[`AGENTS.md`](../AGENTS.md) — this document is about the developer loop.

---

## TL;DR

```bash
make image            # build the dev container (one time, ~2 min)
make lint             # static checks - run this after every change
make test             # apply the patches to real Mesa, no compile (needs network)
make shell            # interactive shell inside the container
make build-linux      # build one leg (10-40 min)
make clean            # remove build output
```

Requires Docker with Compose v2. Nothing else on the host.

---

## Why a container

The three build legs need three different toolchains — the Android NDK, clang/lld
plus a Termux sysroot, and an `aarch64-linux-gnu` cross compiler. Installing all
of those on a workstation is a good way to end up with a broken cross setup and no
idea which piece is at fault.

The container installs all three, based on **ubuntu:24.04** to match the CI
runners, so a local build and a CI build see the same glibc and the same apt
package versions. It also pip-installs `meson>=1.5`: Ubuntu 24.04 ships meson
1.3.2, and Mesa 26.x refuses to configure with it. That is not a workaround, it is
exactly what the workflows do.

You do not need to install anything on the host.

### Requirements

| Need | Notes |
| :--- | :--- |
| Docker + Compose v2 | `docker compose version`. Podman also works with minor changes. |
| ~40 GB free disk | A single leg is several GB; all three plus the NDK is 30-40 GB. `make doctor` reports this. |
| Network | The NDK, the Mesa tree and two package mirrors are downloaded at build time. |

On SELinux hosts (Fedora, RHEL) the compose file's `:z` mount labels are what let
the container read the checkout. They are harmless elsewhere.

---

## The `make` targets

Run `make help` for the full list. The important ones:

### Checks

| Target | What it does | Network |
| :--- | :--- | :--- |
| `make check` | lint **and** the staged secret scan — everything fast. **Run this before every commit.** | no |
| `make lint` | shellcheck, python compile, workflow YAML + variant-matrix consistency, referenced-patch existence, recipe invariants | no |
| `make secrets` | scan **staged** changes for secrets (what the pre-commit hook runs) | no |
| `make secrets-history` | scan **every commit** for secrets (what CI runs) | no |
| `make test [VARIANT]` | Clones real Mesa, applies the common patches, `EXTRA_PATCH` and `EXTRA_SCRIPT`, asserts the tree still parses. Reports fuzzy hunks and non-idempotent scripts. | yes (~250 MB, cached) |
| `make doctor` | Which legs this machine can build, and how much disk is left | no |
| `make hooks` | install the pre-commit hook for this clone (once) | no |

`make check` is the pre-commit gate and takes about a second. `make test` is the
one that catches a patch that has drifted from upstream — much cheaper than
finding out 20 minutes into a Mesa compile.

`make test` defaults to the commit in `mesa_hash.txt`. Point it anywhere:

```bash
make test 8g2-oneui                                            # one variant
make test regular 4f554dafa8dcd81048916f1382f561ed134db8ec     # one variant, one commit
./scripts/test-patches.sh                                      # all four variants
```

The Mesa checkout is cached in `.cache/mesa-test` and reused, so only the first
run downloads.

### Builds

Each leg builds one driver variant. `VARIANT` selects which; `TAG` names the ZIP.

```bash
make build-android                          # regular variant, NDK r29 / bionic
make build-linux   VARIANT=a8xx             # a8xx variant, glibc aarch64
make build-wayland VARIANT=710-720-test
make build-perf   VARIANT=8g2-oneui
```

Knobs:

| Variable | Default | Meaning |
| :--- | :--- | :--- |
| `VARIANT` | `regular` | `regular`, `a8xx`, `710-720-test`, `8g2-oneui` |
| `MESA_COMMIT` | `mesa_hash.txt`, else `mesa/main` HEAD | The Mesa commit to build |
| `TAG` | `dev-<short sha>` | Tag embedded in the ZIP name |
| `PACKAGE_VERSION` | `1` | `meta.json` `packageVersion` (CI uses the daily build number) |
| `KEEP_SYMBOLS` | *(unset)* | `1` on the Linux leg → `debugoptimized`, unstripped |

A typo'd `VARIANT` fails immediately with the list of valid names, rather than
after downloading an NDK.

The Wayland and Linux legs require a pinned 40-hex commit and refuse to guess;
`make` resolves one for you.

### Verifying and collecting

```bash
make verify KIND=linux ZIP=linux_workdir/Turnip-dev-abc1234-Linux.zip
make collect        # copy every built ZIP into ./dist
```

`make verify` runs the same `verify_driver_zip.py` the release workflow uses, so
a locally verified ZIP is a ZIP the release will accept.

### Cleanup

```bash
make clean       # build output only
make distclean   # also .cache and the built images
```

**`clean` deliberately does not `rm -rf turnip_workdir/`.** That directory holds
two *tracked* files (`tu_gen8.patch`, `tu_gen8_clean.patch`). It removes the
ignored contents and keeps those, then prints what is left.

---

## Layout and where things go

```
build_turnip.sh           Android leg      -> turnip_workdir/
build_turnip_perf.sh      Perf leg         -> turnip_workdir/
build_turnip_wayland.sh   Wayland leg      -> wayland_workdir/
build_turnip_linux.sh     Linux leg        -> linux_workdir/
patches/                  the actual product of this repo
scripts/                  developer tooling (lint, test, doctor)
.github/workflows/        CI; the variant matrix lives here
```


## Secrets

This repo needs no developer credentials — CI uses only the built-in
`GITHUB_TOKEN`. So there is never a reason to write a token into a file.

Three layers, all using [gitleaks](https://github.com/gitleaks/gitleaks):

```bash
make hooks              # once per clone: pre-commit gate
make secrets            # scan staged changes
make secrets-history    # scan every commit (what CI runs on each push)
```

The **pre-commit hook** also blocks staged build output, losing the tracked
fixtures, and the build scripts losing their executable bits. It needs no network
and no Mesa checkout, so it stays fast.

Two properties worth knowing:

- **Findings are redacted** in the terminal, in CI logs, and in any report file. If
  you paste scanner output into an issue, check the value is not in it.
- **The hook fails closed.** With gitleaks missing, it *blocks* the commit rather
  than skipping the scan. `--no-verify` is available, but CI scans the same commit
  anyway.

If something trips, assume it is real until proven otherwise: revoke the
credential first, because removing a line in a new commit does not remove it from
history. Then narrow-allow genuine false positives in `.gitleaks.toml` — never
blanket-allow a rule. `AGENTS.md` §8 has the full procedure, and §9 covers the
wider rules for agents and automated tooling working in this repo.

Run the scan yourself before every commit, in the same session as the edit — the
hook and CI are backstops, not the plan. Read `git diff --cached` first so you
know what you are committing; an unreviewed file is how a stray key gets in.

---

## Running without Docker

Set `DOCKER=0` to run on the host:

```bash
DOCKER=0 make lint
DOCKER=0 ./scripts/doctor.sh          # what is missing
```

`make doctor` tells you exactly which package provides each missing tool. You do
not need the whole matrix — only the toolchain for the leg you intend to run.
On Ubuntu 24.04 that is:

```bash
sudo apt-get install -y ninja-build unzip flex bison glslang-tools curl zip patch \
    python3-pip shellcheck
pip3 install --break-system-packages 'meson>=1.5' mako pyyaml packaging

# Wayland leg
sudo apt-get install -y ccache pkg-config clang lld llvm binutils

# Linux leg
sudo apt-get install -y cmake gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
    binutils-aarch64-linux-gnu tar zstd xz-utils
```

---

## Gotchas

**`turnip_workdir/` contains tracked files.** Two `.patch` fixtures are repo
content that happen to sit in a build directory. This has two consequences:
`make clean` is written to preserve them, and you must never bind-mount over the
whole directory (you would hide them and `git status` would report them deleted).
`make lint` asserts they are still tracked.

**`/tmp` is not shared with the host.** `build_turnip.sh` installs to
`/tmp/turnip-$1`. Inside the container that is container-local; the ZIP is copied
into the work directory afterwards, so nothing is lost.

**The NDK is downloaded, not baked into the image.** It is ~4 GB unpacked, so it
is fetched by the build script on first use and kept in the leg's work directory.
Only the toolchain-neutral host tools are in the image.

**A green Android build does not mean a patch is correct.** `build_turnip.sh`
warns and continues on a rejected hunk; the Wayland and Linux legs die. Test all
three, or at least `make test` plus one real leg.

**Fuzzy hunks are a warning, not a pass.** `make test` reports
"applied with fuzz". A fuzzed hunk means the patch no longer matches upstream
exactly — rebase it, even though the build is green.

**CI writes its own commits.** `docs: update build info` and
`chore: update tracked hashes` are generated. Do not hand-write them.

**Branch name.** This fork is on `A740`, but the README auto-update step in
`turnip_build_combined.yml` pushes to `A8xx`. See `AGENTS.md` §6.

Everything a build produces is gitignored. Finished ZIPs stay in their leg's
work directory so you can grab them with `make collect`.

---
