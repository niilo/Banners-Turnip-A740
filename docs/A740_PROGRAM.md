# The A740 program

**This fork builds one driver, for one GPU: the Adreno 740 (Snapdragon 8 Gen 2).**

Everything else in this repo exists to serve that. The A8xx, 710/720/722 and
One-UI variants are inherited from upstream `The412Banner/Banners-Turnip` and are
kept working, but they are not the point of this fork.

```
SoC        Snapdragon 8 Gen 2 (SM8550) / 8+ Gen 2 variants
GPU        Adreno 740, Mesa name FD740
chip_id    0x43050A01 (KGSL), 0xFFFF43050A01 (no-speedbin fallback)
arch       A6xx, A7xx generation (a7xx_base, a7xx_gen2), CHIP.A7XX
CPU        Arm Cortex-X3 prime
```

---

## 1. What we optimise for

Not peak FPS. **Sustained** performance: the frame rate you still hold in minute
twenty, after the phone has been running flat out and the SoC is at its thermal
limit.

Those are different problems, and the usual optimisations do not transfer:

| | Peak FPS | Sustained FPS (our goal) |
| :--- | :--- | :--- |
| Governed by | burst clock headroom, cold caches | thermal design power, sustained power draw |
| Failure mode | a slow start | **frame-rate collapse partway through** |
| Overclocking | helps | **hurts** — it moves you into the thermal limit sooner |
| Fix | raise clocks | **lower energy per frame** |

So the metric is **energy per frame**, not frames per second. A change is only an
improvement if it holds frame rate *longer*, even if it is neutral at t=0.

### Performance per watt is the primary metric

Every candidate change is judged on energy per frame. Concretely:

- **Fewer instructions beats faster instructions.** An ALU op removed saves
  energy every frame forever.
- **Less memory traffic.** GMEM is on-chip and cheap; sysmem is off-chip and
  costs real watts.
- **Fewer redundant passes.** A shader that runs once instead of twice is a
  direct energy win.
- **Idle is not free either.** Work that keeps the GPU busier at the same FPS
  costs watts for nothing.

---

## 2. The A740's specific situation

This is an unusual GPU and it shapes the whole strategy.

**The A740 is an A7xx-generation part reported with an A740-specific magic-register
set.** Mesa's entry:

```python
A6xxGPUInfo(
    CHIP.A7XX, [a7xx_base, a7xx_gen2],
    num_ccu = 6, tile_align_w = 96, tile_align_h = 32,
    tile_max_w = 2016, tile_max_h = 2032,
    num_vsc_pipes = 32, cs_shared_mem_size = 32 * 1024,
    wave_granularity = 2, fibers_per_sp = 128 * 2 * 16,
    highest_bank_bit = 16,
    magic_regs = a740_magic_regs, raw_magic_regs = a740_raw_magic_regs,
)
```

Those magic registers (`TPL1_DBG_ECO_CNTL`, `UCHE_CACHE_WAYS`, the
`SP_CHICKEN_BITS` family) are how upstream Mesa works around silicon quirks on
this part. **Changing them is high risk**: they are correctness workarounds, not
performance tuning, and an energy win that comes from disabling one is usually an
artefact you pay for in glitches.

Note `cs_shared_mem_size = 32 * 1024`. The A8xx line has 64 KB; the A740 does
not. Occupancy is capped by this, and anything that inflates shared-memory demand
costs occupancy directly — which costs energy per frame, because lower occupancy
means more memory traffic and less latency hiding.
---

## 3. What is already in place

Carried over from upstream and verified against Mesa `4f554da`:

| Change | Where | Why |
| :--- | :--- | :--- |
| `enable_tp_ubwc_flag_hint` | `patches/8g2_oneui.py` | A740-specific. **Correctness, not speed** — without it the UI flickers next to a system driver that sets the hint. |
| deviceName override | `patches/a740_devname.py` | Identity: on an A740, reports `Turnip (Banners A740)` so a driver list or Vulkan overlay shows *this build* is loaded. Scoped to `fd_name == "FD740"`, so parts that merely resemble the 740 — e.g. the Ayaneo Pocket S's Adreno A32, which `persist.sys.fake.gpu` makes the stock driver advertise as a 740 — keep Mesa's own name. Cosmetic, but the name also keys the disk shader-cache directory, so the first run recompiles once. |

The two KGSL correctness fixes this fork used to patch are **not** in this table
any more: Mesa main carries both as of `1da50a1b940` (syncobj merge) and
`e984ef294ea` (zero-timeout poll), verified present at our pin `3172302832`, and
both local patches were deleted on 2026-10-08. They were not dropped for being
redundant-in-principle — upstream's versions are the same fixes, and the syncobj
one adds the error handling ours asserted instead of checking. See
[`patches/common/SOURCE`](../patches/common/SOURCE) for the record.

The zero-timeout fix has a direct performance dimension: a wait that blocks
instead of returning `VK_TIMEOUT` stalls the queue, and a stalled queue wastes the
thermal budget it was holding. It is still worth knowing it is there, because the
fix now arrives with a Mesa update rather than from us — a driver built before
`e984ef294ea` pays that stall on every frame.

`PWR_MAX` (`patches/apply_mtr_pwr_max.py`) and force-GMEM
(`patches/apply_mtr_gmem_force.py`) exist in this repo but are **not** wired into
any shipped variant. See §6 — one of them is actively counter to this goal.

---

## 4. Candidate optimisations, verified against Mesa

Each was checked against the real Mesa tree, not taken on trust.

### 4.1 IR3 Global Code Motion — `GCM=1`  ✅ verified

`src/freedreno/ir3/ir3_nir.c`:

```c
static int gcm = -1;
if (gcm == -1)
   gcm = debug_get_num_option("GCM", 0);
if (gcm == 1)
   progress |= OPT(s, nir_opt_gcm, true);   /* hoisting = true */
else if (gcm == 2)
   progress |= OPT(s, nir_opt_gcm, false);  /* hoisting = false */
```

Upstream default is **0 (off)**. `GCM=1` enables `nir_opt_gcm` with hoisting, which
lifts loop-invariant and common subexpressions out of shader hot paths.

**Assessment: the strongest lead in this list.** It reduces instructions executed
per draw — the primary energy lever. Two caveats:

- `hoisting=true` is the aggressive form; it can increase register pressure. On a
  part where occupancy already depends on `cs_shared_mem_size`, watch for spills.
- It moves work out of loops, so the win scales with how loop-heavy the shader is.
  Expect gains on compute/geometry-heavy scenes, less on trivial shaders.

**Test it as a runtime env var first** (`GCM=1`), before patching anything. It is
already plumbed upstream — no patch needed to evaluate it.

### 4.2 Suballocator block sizes 128 KB → 512 KB  ✅ verified

`src/freedreno/vulkan/tu_device.cc`:

```c
tu_bo_suballocator_init(
   &device->pipeline_suballoc, device, 128 * 1024, ..., "pipeline_suballoc");
if (is_kgsl(...))
   tu_bo_suballocator_init(&device->kgsl_profiling_suballoc, device,
                           128 * 1024, ..., "kgsl_profiling_suballoc");
```

Both are `128 * 1024` upstream, exactly as described. Also present:
`autotune_suballoc` at `128 * 1024` (`tu_autotune.cc:1666`) and `trace_suballoc`
at `512 * 1024` (`tu_device.cc:2263`) — upstream already uses 512 KB in one place,
so the value is not arbitrary.

**Assessment: plausible, low-risk, must be measured.** Larger blocks mean fewer
suballocator round trips and less fragmentation in the GPU-CPU context switch
path — a CPU-side win, so it helps steady-state more than a burst. It also costs
memory (up to 4x the reserve per pool). This is a **classic sustained-performance
optimisation**: fewer allocator operations over a long session.

Patch it as a variant script, changing only the two `128 * 1024` literals, and
assert the result.

### 4.3 Shader cache 1 GB → 4 GB  ⚠️ mischaracterised

Upstream does **not** hardcode 1 GB. `tu_device.cc:1902` calls:

```c
device->vk.disk_cache = disk_cache_create(device->name, buf, 0);
```

and `src/util/disk_cache.c` reads `MESA_SHADER_CACHE_MAX_SIZE` (or the deprecated
`MESA_GLSL_CACHE_MAX_SIZE`) from the environment, falling back to a compile-time
default.

**So this is a runtime environment variable, not a code change.** Patching a
constant would be patching the wrong thing.

**Assessment: mostly a first-run/compilation-stutter fix, not a steady-state win.**
It helps when shaders are evicted and recompiled during play. It does nothing once
the cache is warm. Keep it as a documented runtime setting, not a patch. It costs
disk and a little power for cache maintenance.

### 4.4 "Zelda artifact fixes"  ❌ already upstream

`tu_dont_care_as_load` and `tu_allow_oob_indirect_ubo_loads` are **already in
upstream Mesa**, in `src/freedreno/vulkan/00-turnip-defaults.conf`, scoped per
engine (`DXVK`, `vkd3d`, Kex Engine).

**Nothing to port.** Porting them as unconditional globals would *lose* the
per-engine scoping and could regress non-matching titles. Our Linux leg already
compiles these defaults in (`-Dxmlconfig=disabled`, reasoning documented at
`build_turnip_linux.sh:316`).

### 4.5 Cortex-X3 CPU tuning  ⚠️ not driver work
---

## Experiments to measure (added 2026-10-04)

Both candidates from §4 now exist as **opt-in variants**, so the measurement in §7
can actually be run. Neither is a default; neither is claimed to be a win.

**The procedure is in [A740_MEASUREMENT.md](A740_MEASUREMENT.md)** — device-specific
sysfs paths, which scenes to use, run duration, and how to read the result. Start
there; it is written against the Ayaneo Pocket S and records two hard limits of
that setup (no root, so `simpleperf` cannot attach to a game; no Termux, so FPS
comes from the emulator's own counter).

| Variant | Script | Change |
| :--- | :--- | :--- |
| `a740-gcm` | `patches/a740_gcm.py` | `debug_get_num_option("GCM", 0)` → `1` in `ir3_nir.c` (hoisting on) |
| `a740-suballoc` | `patches/a740_suballoc.py` | `pipeline_suballoc` + `kgsl_profiling_suballoc` 128 KB → 512 KB in `tu_device.cc` |
| `a740-gcm-suballoc` | both | the combination, so the two effects can be separated |

```bash
make build-android VARIANT=a740-gcm TAG=exp-gcm
make build-android VARIANT=a740-suballoc TAG=exp-suballoc
make build-android VARIANT=a740-gcm-suballoc TAG=exp-both
```

They are separate variants rather than one flag so a) one experiment cannot ride
along with another, and b) a build on the device is identifiable by its driver
name (`Banners Turnip A740-A740-GCM`, etc.).

**Built and on the device: `Turnip-A740-EXP1-GCM-Suballoc.zip`** (the combined
arm, sha256 `06e71ead…b500d`), alongside the `regular` baseline
`Turnip-Banners-A740.zip`. Same Mesa `8fc4981`, so the only difference is these two
changes.

### How to measure

Test each arm against the `regular` baseline on the same scene and camera path.
To isolate one change, use the single-experiment variants rather than the combined
one — if the combination is neutral you cannot tell which part cancelled the other.

```bash
# GCM alone - note the register-pressure caveat in §4.1
make build-android VARIANT=a740-gcm TAG=exp-gcm
# Suballoc alone - watch MEMORY, not just FPS
make build-android VARIANT=a740-suballoc TAG=exp-suballoc
```

What to record for each arm:

| Measure | Why |
| :--- | :--- |
| FPS at t=0 **and** after 10+ min | The gap between them is the whole question. A t=0-only win is not this fork's win. |
| Thermal behaviour / clock | Confirms you stayed off the thermal wall rather than reaching it sooner. |
| Memory use (suballoc arm) | §4.2: 4x the reserve. Rising memory with flat FPS means it costs more than it saves. |
| Visual correctness | GCM changes register allocation. Any artefact is a fail, not a trade-off. |
| First-run compile time | GCM moves work into the shader compiler. A cold-cache penalty is expected and should not be mistaken for a regression. |

`GCM=0` in the environment still disables GCM on a patched build — the patch
changes the *default*, it does not lock the value. That makes a single binary
usable for both arms of the GCM test if you prefer an env-var A/B over two builds.

### If one wins

Do not merge it into `regular`. Per §7 it needs a source entry stating the
hypothesis, the measurement plan, and the actual measured numbers on A740 —
`patches/a740/SOURCE` is where that record belongs.

---

## 5. Optimisations of our own worth pursuing

Aimed at energy per frame, which the borrowed list above mostly misses.

### 5.1 GMEM over sysmem, carefully

`use_sysmem_rendering()` decides on-chip tile memory vs system memory. Sysmem
costs real watts in off-chip traffic.

`patches/apply_mtr_gmem_force.py` forces GMEM by injecting `return false;`. That
is **too blunt for this fork**: sysmem exists because large render targets do not
fit in GMEM, and forcing GMEM can fail to allocate or push work into per-tile
reads that cost more than they save.

**Better:** keep the heuristic, and reduce the *conditions* that select sysmem —
smaller render targets, fewer MSAA passes, avoiding needless depth prepasses.

### 5.2 Trim overdraw and redundant passes

Energy per frame scales with fragments shaded. In order of leverage:

1. **Depth prepass when profitable** — avoids shading occluded fragments. Costs
   bandwidth, so it is a win only for overdraw-heavy scenes; measure per title.
2. **Early-Z / early test** — check whether the A740 magic regs are already
   optimal here and do not disturb them (§2).
3. **Shader complexity** — `GCM=1` (§4.1) attacks the same axis from the compiler
   side and composes well with this.

### 5.3 Shader cache discipline (compile-time energy)

Compilation stutter costs both frames and watts. Keeping the disk cache warm
(§4.3) and avoiding pipeline-cache misses is *energy-per-session* work: a stutter
is a frame that took 10x longer, and longer means more heat at the same FPS.

### 5.4 Reduce fixed per-frame cost

`pipeline_suballoc` (§4.2) is the same idea. Every CPU-side round trip through
the allocator is work the GPU waits on; removing them lets the GPU hold frame rate
at a lower clock — exactly the sustained-perf win we want.

---

## 6. Anti-goals

Explicitly **not** doing these, because they fight §1:

| Anti-goal | Why |
| :--- | :--- |
| Overclocking / locking max clock | Moves you into the thermal limit sooner. Peak FPS up, sustained FPS down, watts up. |
| `PWR_MAX` power constraint | Same reason. It pins the GPU at maximum power, guaranteeing the thermal wall. Right for a short burst, wrong for a long session. |
| Forcing GMEM unconditionally | Breaks large render targets; can cost more energy than it saves (§5.1). |
| Touching A740 magic regs for perf | Correctness workarounds (§2). Disabling one to save power trades a visible artefact for an invisible gain. |
| Porting per-engine driconf rules globally | Loses scoping; regresses titles the rule was not written for (§4.4). |

A change that raises peak FPS while pulling sustained FPS down is a **regression**
for this fork, even if a benchmark shows a win.

---

## 7. How we decide

**Nothing ships on a hunch.** The bar:

1. **A hypothesis**, stated in energy-per-frame terms. "Fewer ALU ops per draw"
   — not "feels faster".
2. **A measurement plan before the change.** Same scene, same camera path, 10+
   minutes continuous. Short runs hide exactly the effect we care about.
3. **A sustained-FPS number**, plus thermal behaviour, plus watts if measurable.
4. **A device regression check** — the `8g2_oneui` UBWC hint and the KGSL fixes
   must still hold. Visual glitches are a fail.
5. **Reversibility.** Every perf change lands behind a clearly named knob or its
   own variant script, so a regression is one edit to remove.

If a change cannot be measured on real A740 hardware, it stays a documented
experiment, not a default.

---

## 8. Provenance

`Balemuni/Balemunis-Aurora` ("Apex Universal V2") was reviewed as a source of
ideas. It is a **binary distribution — a README and two prebuilt ZIPs, with no
patches or source**. So nothing was copied. Its claims were checked against Mesa
`4f554da` individually, and §4 records the verdicts: GCM and the suballocator
sizes are real and worth testing; the shader-cache claim is an env var, not a
patch; the Zelda fixes are already upstream; the CPU tuning is not driver work.

The useful outcome of the review is §4 — knowing which of its claims are worth
reproducing, and which are already upstream or mischaracterised.

The "ULTIMATE SD8Gen2" edition advertises "instruction-level tuning for Cortex-X3
prime cores". CPU instruction selection is the host app's and the OS's business —
Turnip does not control it, and a Vulkan driver cannot tune a CPU core. Anything
real here is a userspace/emulator change outside this repo.