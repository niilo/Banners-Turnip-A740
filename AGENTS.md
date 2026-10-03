# AGENTS.md — working agreements for this repository

This repo is **not** Mesa. It is a *recipe* repo: it patches and compiles someone
else's tree (https://gitlab.freedesktop.org/mesa/mesa) into Turnip driver ZIPs.
There is no C/C++ source here to "fix". If you are about to edit a `.cc` file,
you are in the wrong checkout — Mesa is cloned into `*/mesa` at build time.

Read this before your first change. It is short on purpose.

---

## 1. What gets built

Four driver variants, each shipped as **three ZIPs**, all from **one** Mesa commit:

| Variant | `suffix` | `EXTRA_PATCH` | `EXTRA_SCRIPT` |
| :--- | :--- | :--- | :--- |
| `regular` | *(none)* | *(none)* | `patches/a840v2.py` |
| `a8xx` | `-A8xx` | `patches/a8xx_gen8.patch` | `patches/a8xx_shared_mem.py:patches/a840v2.py` |
| `710-720-test` | `-710-720-Test` | *(none)* | `patches/a710-720.py` |
| `8g2-oneui` | `-8G2-OneUI` | *(none)* | `patches/a840v2.py:patches/8g2_oneui.py` |

Three build *legs*, which differ only in libc and what they link against:

| Leg | Script | libc | Cross toolchain | Output dir |
| :--- | :--- | :--- | :--- | :--- |
| Android (AdrenoTools) | `build_turnip.sh` | bionic | Android NDK r29 | `turnip_workdir/` |
| Wayland (on bionic) | `build_turnip_wayland.sh` | bionic | NDK r29 @ API 29 + Termux sysroot | `wayland_workdir/` |
| Linux runtime | `build_turnip_linux.sh` | glibc | `aarch64-linux-gnu-gcc` + Arch ARM sysroot | `linux_workdir/` |
| Perf (Android, unstripped) | `build_turnip_perf.sh` | bionic | Android NDK r29 | `turnip_workdir/` |

A process can only load a driver matching its own libc. Never move a `.so`
between legs, and never "helpfully" copy one leg's artifact into another's ZIP.

The authoritative variant table lives in `.github/workflows/turnip_build_combined.yml`
(the `&drivers` YAML anchor, reused by all three legs). **That file wins** over
this table. If they disagree, fix this file.

---

## 2. The rule that matters most

> **Never edit Mesa directly, and never let a patch apply "with fuzz" silently.**

The recipe layers, in order, inside a Mesa tree:

1. `patches/common/apply_common.sh` — KGSL fixes **every** leg ships.
2. The Wayland leg's own source edits (`build_turnip_wayland.sh`).
3. The Linux leg's own patches (`patches/linux/*.patch`).
4. `EXTRA_PATCH` then `EXTRA_SCRIPT` — the per-variant driver.
5. NDK r29 `sed` fixups.

Consequences you must respect:

- **`patches/common/apply_common.sh` asserts its own result.** After applying each
  patch it greps the Mesa tree for the exact string it expects. If an assert
  fails, the patch no longer matches this Mesa and **the build correctly dies**.
  Do not "fix" that by deleting the assert. Rebase the patch, or delete it if
  upstream Mesa now carries the fix (and say so in the `SOURCE` file).
- **`apply_common.sh` is A8xx-aware.** It only pulls in Max's WinNative series
  when `EXTRA_PATCH` matches `*a8xx_gen8*`, and it asserts the A6xx/A7xx tree did
  **not** get `tu_mesh.cc`. So `a8xx` variants must keep `EXTRA_PATCH` pointing at
  a gen8 patch file. Do not rename those files casually.
- **The Wayland and Linux legs are fail-hard; `build_turnip.sh` is lenient.**
  `build_turnip.sh` logs a warning and keeps going on a rejected hunk. The other
  two `die`. So a patch that "works on the Android leg" may still be broken — a
  green Android build is **not** evidence a patch is correct. Verify all three.
- **Python patch scripts must be idempotent and must actually change something.**
  The Wayland and Linux legs hash `git diff` before and after each script and
  `die` if it is unchanged. A script that no-ops on today's Mesa fails the build.
  Every one of these scripts is documented as "safe to run multiple times" —
  keep them that way.

---

## 3. Before you commit

```bash
make lint     # shellcheck + python compile + workflow YAML parse
make test     # patch-application dry runs against real Mesa (needs network)
```

- `make lint` is a **hard gate**. The scripts are currently shellcheck-clean at
  `-S warning`; keep them that way. New shell code follows the style in
  `patches/common/apply_common.sh`: tabs for indentation, `set -eu` (or
  `-eo pipefail`), `die()` for fatal errors, `log()` for progress.
- Do **not** commit build output. See §5.
- `patches/*/SOURCE` files are provenance records — upstream author, commit,
  date, and *why*. If you rebase a patch, update its `SOURCE` entry. That file
  is how a reader knows whether a patch is still needed.

### Commit messages

Conventional Commits, matching existing history:

```
fix(kgsl): <what the fix is, not which file changed>
feat(a8xx): <what>
docs: update build info [v<version>]
chore: update tracked hashes
```

The `docs:`/`chore:` messages are written by CI. **Do not hand-write them** —
you would fight the auto-updater. The README auto-update step in
`turnip_build_combined.yml` has `A8xx` hardcoded in four places
(`git fetch/checkout/pull/push origin A8xx`), but **this branch is `A740`** —
see §6.

---


## 4. Where things are allowed to change

| Path | Touch it? |
| :--- | :--- |
| `build_turnip*.sh` | Yes — the recipes. Keep the env-var contract in each file's header comment in sync with any change. |
| `patches/**` | Yes — the actual product of this repo. |
| `.github/workflows/*.yml` | Yes, carefully. `turnip_build_combined.yml` is the release pipeline. |
| `turnip_workdir/mesa`, `wayland_workdir/mesa`, `linux_workdir/mesa` | **No.** Disposable checkouts. Edits vanish on the next build. |
| `turnip_workdir/tu_gen8.patch`, `turnip_workdir/tu_gen8_clean.patch` | **No.** Tracked repo content that happens to live in a build dir. |
| `mesa_hash.txt`, `steven_last_tag.txt`, `perf_build_number.txt` | **No.** CI-owned state files. |

`turnip_workdir/` is a build directory that contains two *tracked* files. That is
deliberate and fragile:

- `make clean` removes build output but **preserves** those two files.
- Never bind-mount over `turnip_workdir/` as a whole — you would hide tracked
  content and `git status` would show the fixtures as deleted.

---

## 5. Build outputs and disk

A single leg is **several GB**: an NDK (~4 GB unpacked), a Mesa checkout, a ninja
build dir, and for the Linux leg a whole Arch Linux ARM sysroot. Three legs plus
the NDK is easily **30–40 GB**.

- Build dirs: `turnip_workdir/`, `wayland_workdir/`, `linux_workdir/` — all
  gitignored, all safe to delete with `make clean`.
- Finished ZIPs land in the leg's work dir; `make collect` gathers them.
- **Check free space before a three-leg run** (`make doctor` does this).

---

## 6. Known traps

- **Branch name.** This fork is on `A740`, but `turnip_build_combined.yml`'s
  README auto-update step pushes to `A8xx` (lines ~474–493). On this branch that
  step fails. Either keep the branch as `A8xx` or fix those four references.
  Related: `release_body.py --ref` defaults to `A8xx` because patch links in
  release notes point at it.
- **`meson` version.** Ubuntu 24.04 ships meson 1.3.2; Mesa 26.x needs **≥1.5**.
  The container and CI both pip-install it. If a build fails in `meson setup`
  with a version error, this is why.
- **`build_turnip.sh` writes to `/tmp`** (`--prefix /tmp/turnip-$1`). Inside a
  container, `/tmp` is not shared with the host — that is fine, the ZIP is copied
  into the work dir, but do not expect to find the prefix dir on the host.
- **`build_turnip.sh` hardcodes `-Dplatform-sdk-version=36`** while declaring
  `sdkver=34` earlier and passing `34` in the first occurrence. The last flag
  wins. This is upstream behaviour, not a typo to "fix" casually — the Android
  leg has shipped this way.
- **The Linux leg needs network access to `mirror.archlinuxarm.org`** and to
  Termux's package index for the Wayland leg. Builds fail confusingly offline.
- Several root-level `*.patch` files (`39751.patch`, `quest3.patch`,
  `vk_sync_timeline.patch`, `tu_gen8_infra.patch`, …) are **not referenced by any
  workflow or script**. They are kept as history. Do not assume a patch is live
  because it is in the repo root — grep for it first.

---

## 7. Running things

Everything is wrapped by the `Makefile` (see `docs/DEVELOPMENT.md`). With Docker:

```bash
make shell                  # interactive shell in the dev container
make lint                   # static checks (no network)
make build-android VARIANT=regular
make build-linux   VARIANT=a8xx MESA_COMMIT=4f554da...
make verify       KIND=linux ZIP=linux_workdir/Turnip-....zip
```

Without Docker you need the toolchain for the specific leg only — the
`Makefile` will tell you what is missing. `make doctor` prints the full matrix.

The legs are slow (10–40 min each, Mesa is large). Prefer validating a change
with `make test` — it exercises patch application against a real Mesa checkout
without a full compile.
