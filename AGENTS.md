# AGENTS.md — working agreements for this repository

This repo is **not** Mesa. It is a *recipe* repo: it patches and compiles someone
else's tree (https://gitlab.freedesktop.org/mesa/mesa) into Turnip driver ZIPs.
There is no C/C++ source here to "fix". If you are about to edit a `.cc` file,
you are in the wrong checkout — Mesa is cloned into `*/mesa` at build time.

Read this before your first change. It is short on purpose.

---

## 0. The point of this fork

**This fork builds one driver, for one GPU: the Adreno 740 (Snapdragon 8 Gen 2,
SM8550).** Mesa calls it `FD740`, chip_id `0x43050A01` / `0xFFFF43050A01`, and it
is an **A7xx-generation** part (`CHIP.A7XX`, `a7xx_base`/`a7xx_gen2`).

The other variants are inherited from upstream and kept working, but they are not
the target. If a change cannot be justified for the A740, say so explicitly and
keep it out of the default variant.

### The metric is energy per frame

We optimise for **sustained** performance — the frame rate still held in minute
twenty — not peak FPS. These are different problems:

- Overclocking raises peak FPS and **lowers** sustained FPS, because it reaches the
  thermal limit sooner.
- Fewer instructions per frame beat faster instructions, because a removed ALU op
  saves energy every frame.
- Sysmem traffic costs real watts; GMEM is on-chip and cheap.

**A change that raises peak FPS while pulling sustained FPS down is a regression
for this fork, even if a benchmark says otherwise.** Do not add `PWR_MAX`-style
power pinning, do not force GMEM unconditionally, and do not touch the A740 magic
registers for performance — they are correctness workarounds.

Full rationale, the verified candidate list, and the decision bar:
**[docs/A740_PROGRAM.md](docs/A740_PROGRAM.md)**. Read it before proposing any
performance change.

### Known open defect: black boxes with programmable blending

A screen-aligned black rectangle over an occluded character (Uncharted via
Vita3K, and other framebuffer-fetch titles) appears with Turnip on the A740 but
**not** with the stock Qualcomm driver. It needs programmable blending
(subpass input / render feedback).

**This is closed.** Three hypotheses were tested on real hardware and all three
were falsified; the investigation was abandoned rather than continue guessing.

| Dead lead | Why |
| :--- | :--- |
| `enable_tp_ubwc_flag_hint` | Built both ways on device — no effect. |
| `support_scaled_attribute_formats` | Does not exist in Vulkan Turnip; it is a GL concept. |
| SUBPASS_FENCE invalidation (2026-09-04 series) | Pre-series driver built and tested — no effect. |

Record and next step (a frame capture, not a flag test):
**[docs/A740_BLACK_BOX.md](docs/A740_BLACK_BOX.md)**.

Do **not** reopen this by trying another flag. Three plausible mechanisms failed
on device; the remaining work is RenderDoc/AGI capture of the offending draw,
diffed against the stock Qualcomm driver. Any change to the UBWC or feedback path
made without that evidence will produce flickering or corrupted frames.

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
make check     # lint + secret scan: everything fast. Run this before every commit.
make test      # patch-application dry runs against real Mesa (needs network)
```

- `make check` is the **hard gate**. The scripts are currently shellcheck-clean at
  `-S warning`; keep them that way. New shell code follows the style in
  `patches/common/apply_common.sh`: tabs for indentation, `set -eu` (or
  `-eo pipefail`), `die()` for fatal errors, `log()` for progress.
- Run `make hooks` once per clone to get the pre-commit gate. It checks secrets,
  staged build output, the tracked fixtures, and the build scripts' executable
  bits — all without network or a Mesa checkout. See §8.
- Do **not** commit build output. See §5.
- `patches/*/SOURCE` files are provenance records — upstream author, commit,
  date, and *why*. If you rebase a patch, update its `SOURCE` entry. That file
  is how a reader knows whether a patch is still needed.

### Performance changes specifically

A patch that claims to improve performance must, in its `SOURCE` entry, state:

1. **The hypothesis in energy-per-frame terms** — not "feels faster".
2. **The measurement plan** — scene, camera path, duration. Sustained means
   10+ minutes continuous; a short run cannot see the effect that matters.
3. **Whether it was measured on an A740**, and what the sustained-FPS and thermal
   numbers were. If it was not measured, say so and keep it opt-in.

Do not mark something a default performance win without (3). An unmeasured perf
patch is a documented experiment.

Corollary: every performance change must be **reversible**. Land it behind a
named knob or its own variant script, never tangled into the common series where
turning it back means an archaeology exercise.

### Commit messages

Conventional Commits, matching existing history:

```
fix(kgsl): <what the fix is, not which file changed>
feat(a8xx): <what>
docs: update build info [v<version>]
chore: update tracked hashes
```

The `docs:`/`chore:` messages are written by CI. **Do not hand-write them** —
you would fight the auto-updater.

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

- **Never hardcode a branch name.** This fork ships `A740`; upstream ships `A8xx`.
  The README auto-update step and the release body both used to hardcode `A8xx`,
  which broke on this branch. They now derive the branch from `github.ref_name` /
  `GITHUB_REF_NAME` / the local git branch. If you add a workflow step that
  fetches, checks out, or pushes, take the branch from the environment - do not
  type a name.
- **`8g2-oneui` does not apply to most A740 hardware.** It enables
  `enable_tp_ubwc_flag_hint`, which only matches Samsung One UI firmware. On an
  Ayaneo or other non-One-UI device the hint must stay off (the `regular`
  variant). See `docs/A740_BLACK_BOX.md` and `patches/8g2_oneui.py`.
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

---

## 8. Secrets: never commit one

This repo's CI uses **only** the built-in `GITHUB_TOKEN`; it needs no developer
credentials. That is a property worth protecting, because a leaked token in a
patch or a build script is the one mistake here that reaches outside the repo.

**Everything is scanned. There is no way to opt out quietly.**

| Where | What it scans | When |
| :--- | :--- | :--- |
| `.githooks/pre-commit` | staged changes | every `git commit` (run `make hooks` once) |
| `scripts/scan-secrets.sh staged` | staged changes | `make secrets`, and via the hook |
| `scripts/scan-secrets.sh history` | every reachable commit | `make secrets-history`, and CI |
| `.github/workflows/ci.yml` | full history | every push and PR |

```bash
make hooks              # once per clone: install the pre-commit hook
make check              # lint + staged secret scan - the pre-commit gate
```

### Rules

- **Never paste a credential into any file.** Not a patch, not a build script, not
  a test fixture, not a comment. If a driver recipe needs a token, it reads it from
  `${{ secrets.* }}` or the environment — never a literal.
- **Findings are redacted everywhere**, including the CI log and any report file.
  If you paste scanner output into an issue or a commit message, check that the
  value is not in it. A scanner that prints the secret has leaked it again.
- **The hook fails closed.** If gitleaks is missing, the commit is *blocked*, not
  waved through. A gate that skips itself when its tool is absent is not a gate.
- **`--no-verify` is a deliberate act.** CI scans the same commit, so bypassing the
  hook only delays the failure. If you must use it, say why in the commit body.

### If something trips

1. **Treat it as real until proven otherwise.** If it is a live credential,
   **revoke/rotate it first**. That is the only step that actually fixes it.
2. Then remove it from the working tree.
3. Do **not** stop there. The value is still in history, and anyone who has cloned
   this repository still has it. Removing it in a new commit does not remove it.
   Rewrite history (`git filter-repo`) or, for a public repo, rotate and accept that
   the old value is dead.
4. Do **not** "fix" it by adding an allowlist entry. See below.

### False positives

A real false positive (a documented example key, a credential-shaped string in a
fixture) goes in `.gitleaks.toml`, and narrowly:

- Scope it to the literal value or the one path. Never blanket-allow a rule.
- Say in the comment why it is not a secret.
- Prefer changing the content to something that is not credential-shaped.

Before adding an exception, check that it is genuinely not a secret. Every
allowlist entry is a hole in the gate, and a future reader cannot tell which ones
were justified.

Current state: the full history (3,530 commits at the time of writing) is clean
with gitleaks' default rules and no exceptions. Keep it that way — that is what
makes the gate strict instead of grandfathered.

### `.env` and local files

There is no `.env` in this repo and nothing reads one. If you add one for your own
convenience, keep it out of git (`make secrets` will catch it, but do not rely on
the catch). If you ever add a `.env.example` for documentation, use obviously fake
values.
