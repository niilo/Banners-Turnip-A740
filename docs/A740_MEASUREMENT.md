# Measuring the A740 on real hardware

How to collect data that can actually drive a decision on this driver. Companion
to `A740_PROGRAM.md`: §7 sets the bar (hypothesis, plan, sustained FPS, thermals,
regression check, reversible), this document is the procedure for meeting it.

Everything here was verified on the reference device, an **Ayaneo Pocket S**
(`ro.board.platform=kalama`, Android 13, SM8550). Sysfs paths differ per device —
if you are on something else, re-probe with §2 before trusting a number.

**These tests are manual by design.** Sustained-FPS measurement needs 15+ minutes
of an unattended phone at a fixed camera path. Automating it buys reproducibility
you do not need and costs the one thing you do — judgement about whether the
scene actually stresses the GPU.

---

## 1. What you already have

| Tool | Where | Status |
| :--- | :--- | :--- |
| Perf build (unstripped) | `make build-perf VARIANT=... TAG=...` | Fixed 2026-10-04; was `-Dstrip=true`, which made profiling impossible |
| GCM / suballoc arms | `VARIANT=a740-gcm`, `a740-suballoc`, `a740-gcm-suballoc` | Built, **unmeasured** |
| Precedent | `KGSL_ZERO_TIMEOUT_POLL.md` | The method that found a 91 %-of-submit stall |

---

## 2. Probe your device first (5 minutes, once)

Never assume thermal zone numbers. On the Pocket S they are *not* sequential:

```bash
adb shell 'for z in /sys/class/thermal/thermal_zone*; do \
  echo "$(cat $z/type 2>/dev/null) tz=$(basename $z)"; done' | sort
```

Verified on the Pocket S — the nodes that matter:

| Sensor | Path | Notes |
| :--- | :--- | :--- |
| GPU | `/sys/class/thermal/thermal_zone63` | `gpuss-0`. Throttle points: **95 °C** (×2), 115 °C, 125 °C |
| CPU big | `thermal_zone35` | `cpu-1-0` (Cortex-X3 prime cluster) |
| CPU little | `thermal_zone47` | `cpu-0-0` |
| DDR | `thermal_zone55` | Memory bandwidth — matters for sysmem-bound scenes |
| Battery | `thermal_zone103` | |

GPU telemetry (all world-readable as `adb shell`, uid 2000 — **no root needed**):

| Node | Gives you |
| :--- | :--- |
| `/sys/class/kgsl/kgsl-3d0/gpu_busy_percentage` | GPU busy % — the GPU-bound check |
| `/sys/class/kgsl/kgsl-3d0/gpu_clock_stats` | Time-in-frequency histogram. The energy-per-frame instrument |
| `/sys/class/kgsl/kgsl-3d0/gpu_available_frequencies` | 15 bins, 124.8 MHz – 860 MHz |
| `/sys/class/devfreq/3d00000.qcom,kgsl-3d0/cur_freq` | Instantaneous GPU clock |

`gpu_clock_stats` returns 15 integers, one per frequency bin, **cumulative since
boot**, low→high frequency order. Two reads and subtract gives time-in-state over
an interval — that is how you show a change lowered energy rather than just moved
clocks. The reset node (`reset_gpu_clock_stats`) needs root, so **always diff two
reads** rather than reading absolute values.
---

## 3. Two known limits of this setup

Both were tested, not assumed. Plan around them instead of rediscovering them.

### 3.1 `simpleperf` cannot profile a game on this device

`/system/bin/simpleperf` exists and works, but:

- The device is **not rooted** (`su: inaccessible or not found`).
- **Neither Dolphin nor GameNative is debuggable** — `run-as` returns
  `package not debuggable`, so `simpleperf --app <pkg>` cannot attach (it hangs).
- `kptr_restrict=2`, so kernel symbols are unavailable regardless.
- `perf_event_paranoid=-1` (permissive), but that is not the blocker: the problem
  is process ownership, not the perf subsystem.

**Consequence:** no symbolised in-driver profile of a running game on this device
as-is. Options, in order of effort:

1. **Use a debuggable build of the emulator.** A debug APK has
   `android:debuggable="true"`; `run-as` then works and `simpleperf --app`
   attaches. This is the only route to a real driver profile.
2. **Use the coarse-but-honest signals** in §5 — `gpu_clock_stats` and
   `gpu_busy_percentage` need no profiler and answer the question at frame level.
3. Root the device. Out of scope for a repeatable recipe; it also changes the
   thermal environment you are trying to measure.

The unstripped build from §1 is what makes option 1 worth doing.

### 3.2 No Termux

Not installed, so there is no in-terminal FPS logger on the device. Use each
emulator's own FPS counter (§4) — which is what a human would trust anyway — and
drive the run from the host over ADB (§5).

---

## 4. Which scenes, and for how long

**Do not test one scene.** Each app stresses a different part of the driver, and
the A740's weaknesses are not uniform. All four below are already installed:

| App | Package (version) | Stresses | Use it to test |
| :--- | :--- | :--- | :--- |
| **GameNative** | `app.gamenative` (1.2.1) | Controlled, repeatable workloads | The only *scientific* baseline |
| **Cemu** | `info.cemu.cemu` (0.5) | Heavy fragment, timed loops | **GCM** — fragment shaders are what hoisting helps |
| **Dolphin** | `org.dolphinemu.dolphinemu` (2609) | Vertex-heavy, tight CPU→GPU sync | Sync waits. Built-in FPS: Options → *Show FPS* |
| **PPSSPP / RetroArch** | `org.ppsspp.ppsspp`, `com.retroarch.aarch64` | CPU-bound, low GPU load | The control — should show **no** change |

GameNative is the one to trust for A/B. Dolphin and Cemu depend on the ROM/load
and will not reproduce exactly; they are for spotting a regression, not for
claiming a 4 % win.

**Duration — the number that matters:**

| Run | Length | Why |
| :--- | :--- | :--- |
| Warm-up | 2 min | Discard. Shader cache is cold; GCM legitimately makes first compile slower |
| **Measurement** | **15 min continuous** | Past the 95 °C GPU throttle, into the sustained regime |
| Repeat | x2 per arm | If the runs disagree by more than the effect, the effect is noise |

`A740_PROGRAM.md` §1 makes 10 minutes the floor. Fifteen, because on the Pocket S
the GPU throttles at 95 °C and a short run may never reach it — you would be
measuring peak FPS and calling it sustained.

---

## 5. Running it

### 5.1 Before the run

1. On the device: disable battery saver, set a fixed graphics preset, and leave
   the phone alone. Touching it invalidates the run.
2. Charge state: stay above ~60 %, or leave it on USB for the whole 15 min. A run
   that dies at 15 % is not comparable to one that does not.
3. Note the starting GPU clock so you can see the warm-up tail:
   ```bash
   adb shell 'cat /sys/class/devfreq/3d00000.qcom,kgsl-3d0/cur_freq'
   ```

### 5.2 Start the sampler (host, separate terminal)

```bash
OUT=a740-baseline-$(date +%Y%m%d-%H%M)
mkdir -p ~/a740-logs/$OUT

( while true; do
    printf '%s busy=%s clk=%s gpu=%s cpux=%s cpuL=%s ddr=%s batt=%s\n' \
      "$(date +%s)" \
      "$(adb shell 'cat /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage' | tr -d '\r')" \
      "$(adb shell 'cat /sys/class/devfreq/3d00000.qcom,kgsl-3d0/cur_freq' | tr -d '\r')" \
      "$(adb shell 'cat /sys/class/thermal/thermal_zone63/temp' | tr -d '\r')" \
      "$(adb shell 'cat /sys/class/thermal/thermal_zone35/temp' | tr -d '\r')" \
      "$(adb shell 'cat /sys/class/thermal/thermal_zone47/temp' | tr -d '\r')" \
      "$(adb shell 'cat /sys/class/thermal/thermal_zone55/temp' | tr -d '\r')" \
      "$(adb shell 'cat /sys/class/thermal/thermal_zone103/temp' | tr -d '\r')"
    sleep 5
  done ) > ~/a740-logs/$OUT/telemetry.log 2>&1 &
```

All nodes above were verified readable as uid 2000. This is `sleep 5` for ~180
iterations with 7 `adb shell` calls each — tens of thousands of round trips over
15 minutes. It works, but if it feels heavy, drop to `sleep 15`.

### 5.3 Frequency-residency snapshot (before and after)

```bash
snap() { adb shell 'cat /sys/class/kgsl/kgsl-3d0/gpu_clock_stats'; }
snap > ~/a740-logs/$OUT/clockstats_before.txt
# ... run the 15-minute measurement ...
snap > ~/a740-logs/$OUT/clockstats_after.txt

# Time-in-state per bin: subtract the two cumulative reads.
# Read as TWO files, not paste|awk: each line holds 15 values, so paste would
# present 30 columns and $1/$2 would compare bin 1 against bin 1 - always zero.
awk 'NR==FNR { for (i=1;i<=NF;i++) b[i]=$i; next }
     {       for (i=1;i<=NF;i++) { d[i]=$i-b[i]; T+=d[i] } }
     END {   for (i=1;i<=length(d);i++)
                printf "bin %2d  %8.1f s  %5.1f%%\n", i-1, d[i]/1e6, 100*d[i]/T }' \
  ~/a740-logs/$OUT/clockstats_before.txt ~/a740-logs/$OUT/clockstats_after.txt
```

Bin centres come from `gpu_available_frequencies` (15 values, 124.8 MHz to
860 MHz); map them in when the numbers matter rather than interpolating.

**Time-in-state is the closest thing on this device to a direct
energy-per-frame measurement.** If a change holds FPS while shifting residency
*down*, that is the §1 win — and it is invisible to an FPS counter.

### 5.4 FPS

Read the emulator's own counter and write it down per minute, by eye. Per-minute
is enough resolution to see the decay curve; the counters update continuously.

### 5.5 Stop

```bash
kill %1                      # the telemetry loop
adb shell dumpsys meminfo <package> | head -20 > ~/a740-logs/$OUT/meminfo.txt
```

`meminfo` is **mandatory for the suballoc arm** — that patch reserves 4x per pool
(`A740_PROGRAM.md` §4.2). Rising memory with flat FPS means it loses.
Repeat the **identical camera path**. In Dolphin, a save state in a repeatable
spot beats free-play. If the path cannot be repeated, the run is not comparable
and should not be recorded.
---

## 6. Recording the result

One row per run. This is what `patches/a740/SOURCE` needs before anything can be
promoted out of experiment status.

| Arm | Mesa sha | ZIP sha256 | Scene | FPS t=0 | FPS t=15 | GPU degC peak | Throttle? | MEM | Visual | Residency shift |
| :--- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| regular | `8fc4981` | | Cemu | | | | | | ok | |
| a740-gcm | `8fc4981` | | Cemu | | | | | | ok | |

Always record the **Mesa sha and the ZIP sha256**. Two arms built from different
commits are not an A/B — that confound has voided more driver benchmarks than any
other mistake. Both arms of a comparison must be the same commit.

### Reading it

| Observation | Conclusion |
| :--- | :--- |
| Higher FPS at t=0, same at t=15 | **Not a win.** This is the peak-vs-sustained trap in §1. |
| Same at t=0, higher at t=15, residency shifted down | **The win.** Fewer joules per frame. |
| Higher FPS and GPU hit 95 degC sooner | **A regression.** You moved into the thermal wall earlier. |
| `gpu_busy_percentage` < 70 % sustained | Scene is not GPU-bound. Pick another, or the number means nothing. |
| FPS flat, memory up 4x | The suballoc arm lost. |

That last row about `gpu_busy_percentage` is the first thing to check on any new
scene. A scene that leaves the GPU idle 30 % of the time cannot show a driver
change, and it is the most common way a careful test produces a meaningless
result.

---

## 7. Order of work

1. **`regular` baseline, GameNative + Cemu.** Establishes the harness and gives
   the control curve. Nothing else is interpretable without it.
2. **`a740-gcm` on Cemu.** Fragment-heavy, so the strongest candidate. Keep
   `GCM=0` in the environment as the second arm — `ir3_nir.c:338` caches the
   first lookup, so one binary serves both and the comparison is airtight.
3. **`a740-suballoc` on Dolphin.** Watch memory as hard as FPS.
4. **Profile properly** (needs a debuggable emulator build, §3.1). This is what
   refills §5 of the program document with new work.

Do **not** test the combined arm first. If `a740-gcm-suballoc` comes out neutral
you cannot tell which part cancelled which, and you will have spent a pair of
30-minute runs to learn nothing.

---

## 8. Reproducing

Logs are the evidence; keep them. `~/a740-logs/<arm>-<date>/` with
`telemetry.log`, `clockstats_{before,after}.txt`, `meminfo.txt` and your
per-minute FPS notes is enough for anyone — including future you — to re-derive
the conclusion without the device.