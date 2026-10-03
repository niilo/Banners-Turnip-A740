# Adreno 740 black-box issue (programmable blending / input attachments)

Status: **CLOSED — investigation abandoned 2026-10-03 at the user's direction.**
Three hypotheses tested and falsified on real hardware. Kept as a record so the
work is not repeated; do not restart it without new information.
Related: `VITAplus/.scratch/plus-base/issues/08-uncharted-head-box.md`
Reported there as "Uncharted: Golden Abyss, black rectangle over Drake's head",
Adreno 740 (Ayaneo Pocket S, SM8550), also visible with `Banners-Turnip` r5 and
with the Balemuni Apex v2 ULTIMATE build.

## Why it is closed

Three leads were each strong enough to look right from the code, and each was
killed by an on-device A/B. The black box survived every one of them:

| # | Hypothesis | How it was tested | Result |
| --- | --- | --- | --- |
| 1 | `enable_tp_ubwc_flag_hint` mismatch on the feedback read | Two drivers, same Mesa `8fc4981`, flag off vs on | **No effect** |
| 2 | `support_scaled_attribute_formats` | Source inspection | **Feature does not exist in Vulkan Turnip** |
| 3 | SUBPASS_FENCE replacing CACHE_INVALIDATE for GMEM invalidation (2026-09-04 series) | Driver built from `2b6602eb`, pre-series, fence code verified absent | **No effect** |

Also already ruled out before this fork: raster-order access, LRZ
(`TU_DEBUG=nolrz`), sysmem vs GMEM, shader precision (`force-full-precision`).

Three plausible mechanisms, three failures. That is evidence the cause is not a
single flag or commit — more likely something structural that only a
frame-level capture would reveal. Going further needs **RenderDoc (or AGI) on
the device, capturing the offending draw and diffing the input-attachment
descriptor and shader output against the stock Qualcomm driver**. That is a
larger piece of work than flag-and-test, which is why it was stopped.

**Do not re-run these experiments.** The drivers that tested them have been
removed from the device; only the baseline `Turnip_a740-sr1.zip` remains.

## Symptom

A screen-aligned, flickering black rectangle over an occluded character's head,
present with the Balemuni Turnip driver and with `Banners-Turnip` r5. **Absent with
the stock Qualcomm driver.** So it is driver-dependent, not emulator-dependent:
Vita3K-Plus 20588fbf shows it too, and disabling programmable blending removes it.

## What the evidence points at

The symptom requires all three of:

1. **Programmable blending** (`direct_fragcolor` / `GL_EXT_shader_framebuffer_fetch`
   in Vita3K; an input attachment in Vulkan). With it disabled the box is gone but
   everything is black — so the path is needed, and the box is a *failed read*, not
   a missing feature.
2. **A render-feedback loop**, i.e. the same attachment is both a colour target and
   a subpass input.
3. **Something driver-specific**, because stock Qualcomm does not show it.

## Why this points at UBWC, not at shader math

`src/freedreno/vulkan/tu_cmd_buffer.cc`, `tu_emit_input_attachments()`:

```c
if (!gmem || !subpass->input_attachments[i / 2].patch_input_gmem ||
    !tiling->possible) {
   memcpy(&texture.map[i * FDL6_TEX_CONST_DWORDS], dst, sizeof(dst));
   continue;
}
/* patched for gmem */
tu_desc_set_tile_mode<CHIP>(dst, TILE6_2);
...
tu_desc_set_ubwc<CHIP>(dst, 0);       /* <-- UBWC disabled for the GMEM path */
```

For a feedback loop `tu_render_pass_patch_input_gmem()` (`tu_pass.cc`) sets
`patch_input_gmem = true` and `feedback_invalidate = true`, so the descriptor is
**rewritten to tiled mode with UBWC zeroed**, and UCHE is invalidated to force a
re-read. The pixel comes back through a *different* path than the one that wrote it
— the exact shape of "an area where the read gives 0".

That, plus the box flickering and being screen-aligned, is the signature of a
**tile-mode / UBWC-format mismatch on the feedback read**, not of a bad shader.

## The A740-specific variable: `enable_tp_ubwc_flag_hint`

This is the strongest lead and it is **specific to this GPU**.

Upstream `src/freedreno/common/freedreno_devices.py` sets
`enable_tp_ubwc_flag_hint = True` on **FD735** (line 1224) and **FD740v3** (Quest 3,
line 1371) — but **not** on **FD740** (line 1284, our chip_id `0x43050A01`).
`FD740v3` is the same `a7xx_base/a7xx_gen2` with the same `tile_max_*`, differing
essentially by this flag.

It is consumed in `tu_cmd_buffer.cc` (~2209):

```c
case REG_A6XX_TPL1_DBG_ECO_CNTL1:
   value = (value & ~A6XX_TPL1_DBG_ECO_CNTL1_TP_UBWC_FLAG_HINT) |
           (phys_dev->info->props.enable_tp_ubwc_flag_hint
               ? A6XX_TPL1_DBG_ECO_CNTL1_TP_UBWC_FLAG_HINT : 0);
   break;
```

`TPL1` is the texture processor. The bit tells the TP how to interpret
UBWC-compressed data. If the **writer** (RB, bit cleared) and the **reader** (TP,
bit set) disagree about a surface's format, the feedback read returns garbage or
zero — a black box.

### Why this is firmware-dependent

The flag has to match what the **system driver** does on the same device, because
both touch the same GPU. `patches/8g2_oneui.py` exists precisely because Samsung
One UI firmware sets the hint and Turnip must match it, or the UI flickers. An
Ayaneo Pocket S is not One UI, so the hint should stay **off** — which is what the
deployed `regular` variant does.

This predicts a testable failure mode: **the box should appear on FD740v3/FD735-class
hardware or under One UI firmware, and not on stock-FD740.** Untested here.
## Ruled out

| Lead | Verdict |
| --- | --- |
| `support_scaled_attribute_formats` (the one untested item in the VITA+ issue) | **Dead end.** No scaled-vertex-attribute feature exists anywhere in Vulkan Turnip — `grep` over `src/freedreno/` returns nothing. It is a Gallium/GL concept, so it cannot explain a Vulkan-side difference against the stock driver. The VITA+ issue's "next step 1" should be dropped. |
| Raster-order access (`support_rasterized_order_access`) | Already tested on-device; box persists. |
| LRZ | Already tested (`TU_DEBUG=nolrz`); box persists. |
| Sysmem vs GMEM | Already tested; box persists in both. |
| Shader precision | Already tested (`force-full-precision`); box persists. |
| `enable_tp_ubwc_flag_hint` | **Tested both ways on device (2026-09-04) — no effect. Dead.** |
| `support_scaled_attribute_formats` | **Does not exist in Vulkan Turnip.** Dead. |

## The A/B pair (deployed, awaiting the visual test)

Both arms are on the device at `/sdcard/Download/turnip-drivers/`. They are built
from the **same Mesa commit `8fc4981`** and differ by exactly one boolean, so any
difference in the box is attributable to that flag.

| File | `enable_tp_ubwc_flag_hint` on FD740 | sha256 |
| --- | --- | --- |
| `Turnip_a740-sr1.zip` | **off** (upstream default) | `a932553263710daa45d1cd09638ce47dd453b086be5d6431c0f7f2266a4eaf12` |
| `Turnip_a740-ubwc-hint-ON.zip` | **on** (via `patches/8g2_oneui.py`) | `332ea0ef499cb7fd6e0e21f67ae50ca0ec8b98026ee8d1827f9ed3b902f4c897` |

The hint-ON arm was produced with:

```bash
REUSE=1 make build-android VARIANT=8g2-oneui TAG=a740-ubwc-hint-on
```

`REUSE=1` reuses the NDK and Mesa already in `turnip_workdir/` instead of
re-downloading them, which turns a ~10 min build into a few minutes. The Mesa tree
is reset to HEAD before patching, so the only diff versus the baseline is:

```
-        [a7xx_base, a7xx_gen2],
+        [a7xx_base, a7xx_gen2, GPUProps(enable_tp_ubwc_flag_hint = True)],
```

(line 1290 — the FD740 entry). The only other differences are the inert A840v2
chip_id and the KGSL fixes every leg carries.

### How to read the result

| Observation | Conclusion |
| --- | --- |
| Box **gone** with hint ON | Hypothesis confirmed: the feedback read depends on the TP UBWC flag. Next step is to make it firmware-conditional, like `8g2_oneui.py`. |
| Box **still there** with hint ON | Hypothesis wrong or incomplete. Go to step 2 (stock-Mesa release) and step 3 (capture the draw). |
| **New** artefact (UI flicker, corruption) | Expected if the system driver does *not* set the hint on this firmware — which is the likely case on an Ayaneo device. That is evidence *for* the flag being firmware-dependent, not a fix. |

Test the same scene, same camera path, with only the driver swapped. If both
arms look identical, the UBWC flag is not the variable and the remaining
suspicion moves to the tile-mode rewrite in `tu_emit_input_attachments` itself.

## Next lead (2026-10-03): the SUBPASS_FENCE GMEM-invalidation rework

Now that the UBWC flag is dead, the strongest lead is a **Mesa change from
2026-09-04**, found in upstream history (Mesa is unshallowed locally: 230,728
commits).

A series rewrote GMEM invalidation for input-attachment reads:

| Commit | Date | Subject |
| --- | --- | --- |
| `33643dab065` | 2026-07-23 | `freedreno: Add SUBPASS_FENCE, SLICE_SUBPASS_FENCE` |
| `5efaa4a7225` | 2026-09-04 | `freedreno: Add subpass_fence_cleans_resolve property` |
| `b280f8885ff` | 2026-09-04 | `tu: Don't hardcode feedback_invalidate flushes` |
| `10b1ef466fa` | 2026-09-04 | `tu: Implement SUBPASS_SLICE_FENCE flush` |
| `cc1cf17c2e0` | 2026-09-04 | `tu: Use SUBPASS(_SLICE)_FENCE for by-region dependencies` |
| `99200197cc3` | 2026-09-04 | `tu: Use SUBPASS(_SLICE)_FENCE for GMEM invalidation` |

From the commit message of `99200197cc3`:

> SUPASS(_SLICE)_FENCE guarantees coherence for earlier writes to GMEM. This means
> that we can avoid a CACHE_INVALIDATE when using it for INPUT_ATTACHMENT_READ_BIT
> in GMEM.

So this series **removed the CACHE_INVALIDATE** that the feedback read used to
rely on, and substituted a fence. In `tu_flush_for_access` the code says so
itself:

```c
/* SUBPASS_SLICE_FENCE is a weaker version of:
 * - CACHE_INVALIDATE (only invalidate UCHE GMEM aperture)
 * - WAIT_FOR_IDLE (only make FS executions within a slice wait for RB done)
 */
```

and the emission is deliberately split by chip:

```c
if (emit_cache_invalidate_gmem)
   tu_emit_event_write<CHIP>(cmd_buffer, cs, FD_CACHE_INVALIDATE);
if (emit_subpass_slice_wait)
   tu_cs_emit_wfi(cs);
...
if (CHIP >= A8XX) {
   ... FD_SUBPASS_SLICE_FENCE ...
} else {
   tu_emit_event_write<CHIP>(cmd_buffer, cs, FD_SUBPASS_FENCE);
}
```

**Why the A740 is exposed.** On A8xx this is mitigated by
`subpass_fence_cleans_resolve = True`, which suppresses the
`CCU_CLEAN_BLIT_CACHE` emission "on newer HW". The A740 is A7xx and uses
`FD_SUBPASS_FENCE` — the older, weaker fence — and there is no equivalent
compensation visible for the resolve/blit-clean case. If the fence does not fully
establish UCHE coherence for the feedback read on this part, the read returns the
*previous* framebuffer contents for that region instead of what was just written.
That matches the symptom well: a screen-aligned region, flickering frame to frame,
absent with a vendor driver that keeps its own invalidation stronger.

**This is a hypothesis, not a conclusion.** It is consistent with the evidence, but
so was the UBWC flag, and that one was wrong. Treat it as the next thing to test,
not as the answer.

### The bisect arm (deployed, awaiting the visual test)

`Turnip_a740-prefence.zip` is built from **`2b6602eb4b2`** — the commit immediately
before `33643dab065`, so it predates *all* fence work. Verified in the built tree:

```
$ grep -c 'SUBPASS_FENCE\|SUBPASS_SLICE_FENCE' tu_cmd_buffer.cc
0
```

| Arm | Mesa | Fence code | Vulkan | sha256 |
| --- | --- | --- | --- | --- |
| `Turnip_a740-sr1.zip` | `8fc4981` (2026-10-03) | present | 1.4.363 | `a93255…4eaf12` |
| `Turnip_a740-ubwc-hint-ON.zip` | `8fc4981` | present | 1.4.363 | `332ea0…f4c897` |
| `Turnip_a740-prefence.zip` | `2b6602eb` (2026-07-23) | **absent** | 1.4.354 | `fe716c…69409` |

This fork's patches were confirmed to apply and pass every `apply_common.sh`
assertion on `2b6602eb` before building, so the arm is a clean baseline rather
than a degraded one.

### How to read the result

| Observation | Conclusion |
| --- | --- |
| Box **gone** with the pre-fence arm | The series is the cause. Bisect within it to find the single commit. |
| Box **still there** | The fence series is not it either. Next: capture the offending draw on device, and consider that the difference may be in the app's Vulkan feature-selection rather than in Turnip's invalidation. |

This arm is ~2 months of Mesa behind, so it is a **diagnostic**, not a shipping
candidate: it lacks every upstream fix since 2026-07-23.

## Two latent build bugs fixed while producing this arm

Both were found by the bisect and fixed in the same pass. They affected *every*
rebuild in an existing workdir, not just this experiment.

1. **`unzip` without `-o`** in `build_turnip.sh` (and `build_turnip_perf.sh`,
   `build_turnip_wayland.sh`). With the NDK already extracted, `unzip` prompts on
   every existing file; with stdin closed it aborts, so under `set -e` the second
   build in a workdir could never succeed.
2. **`git clone` into an existing `mesa/`** in `build_turnip.sh` fails fatally
   ("destination path 'mesa' already exists"). It now reuses the clone, resets the
   working tree (`checkout -f .` + `clean -qfd`) so the patch series always applies
   to a clean tree, and switches to `MESA_COMMIT` when one is requested — with a
   clear error if that commit cannot be fetched.

The Makefile gained `REUSE=1` for the same reason: it passes
`SKIP_SOURCE_DOWNLOAD=1` through to the container so iteration does not
re-download a 4 GB NDK.

## Provenance

Findings derived from Mesa `8fc4981` source and from
`VITAplus/.scratch/plus-base/issues/08-uncharted-head-box.md`, plus device
inspection (`ro.board.platform=kalama`, `SG8275`). No new patch is proposed yet:
the top suspect requires a hardware A/B, which is the user's call.