#!/usr/bin/env python3
"""
A740 experiment: enable IR3 Global Code Motion (GCM) by default.

Hypothesis (energy per frame)
  Full global value numbering eliminates provably-redundant computation and
  relocates loop-invariant work. Fewer instructions executed per draw is the
  primary energy lever in `docs/A740_PROGRAM.md` §1, so if this shrinks hot
  shaders it should hold frame rate longer at a given clock - or reach the same
  frame rate at a lower one.

  The second argument of `nir_opt_gcm(shader, value_number)` is NOT "hoisting".
  Mode 1 sets value_number=true = FULL GVN. Mode 2 is the weak GVN that only
  moves identical ALU across an if/else. Earlier notes in this file and in
  A740_PROGRAM.md called mode 1 "hoisting"; that was wrong. Mesa's own comment
  in nir_opt_gcm.c says full GVN "can be too aggressive, moving values far away
  and extending their live ranges" - a register pressure cost that matters on a
  part with only 32 KiB cs_shared_mem_size.

  MEASURED 2026-10-09: CORRECTNESS FAILURE. On an Adreno A32 (not an A740),
  MotorStorm: Pacific Rift under armx3 ran clean on the GCM-off arm and showed
  periodic full-screen black on the GCM-on arm, same session and ISO, the only
  build difference being this default. No FPS or thermal data: the telemetry
  captures taken alongside were unusable. Visual correctness disqualifies it
  regardless of speed. Full record in patches/a740/SOURCE.

  Unmeasured on a real A740. Do not ship as a default.

What it touches
  src/freedreno/ir3/ir3_nir.c, upstream:

      static int gcm = -1;
      if (gcm == -1)
         gcm = debug_get_num_option("GCM", 0);
      if (gcm == 1)
         progress |= OPT(s, nir_opt_gcm, true);

  Upstream default is 0 (off). We flip the default to 1. Note the env var still
  wins: `static int gcm = -1` caches the first lookup, so GCM=0 in the
  environment still selects "off" - this build is a default, not a lock.

Why hoisting=true (mode 1) and not mode 2
  Mode 2 passes hoisting=false. Hoisting is the aggressive form and the one that
  actually removes work from loops, which is the point. The known cost is
  register pressure, and on the A740 `cs_shared_mem_size` is only 32 * 1024 (vs
  64 KiB on A8xx), so occupancy is already capped - watch for spills.

Before you accept a win
  1. 10+ minutes continuous on the same scene and camera path. A short run cannot
     see the sustained effect that is the whole point.
  2. Check it is not just compile-time: GCM moves work, so first-run shader
     compile is slower and the shader cache is cold.
  3. Watch for register spills and any visual change.

Idempotent - safe to run multiple times.
"""
import re
import sys

NIR_C = "src/freedreno/ir3/ir3_nir.c"
NAME = "Banners A740: GCM on by default"
# Substring for the idempotency check, kept free of comment delimiters so the same
# text can serve as the first line of the block comment written into the C file.
MARKER_TEXT = "Banners A740: GCM on by default"

with open(NIR_C, "r") as f:
    content = f.read()

if MARKER_TEXT in content:
    print("  GCM already enabled, skipping")
    sys.exit(0)

# Anchor on the whole stanza, not just the default value: changing only "0" would
# also match an unrelated debug_get_num_option("...", 0) somewhere else.
# NOTE: every "(" and ")" inside the pattern is literal and must be escaped - these
# are Python regexes, not globs.
m = re.search(
    r'( *)static int gcm = -1;\n'
    r' *if \(gcm == -1\)\n'
    # Group 1 is the indent, group 2 is the literal default "0" that gets replaced
    # to 1. Every paren in the SOURCE must be escaped (\( and \)); only the capture
    # parens stay bare. "debug_get_num_option(\"GCM\", 0);" therefore appears as
    # debug_get_num_option\(\"GCM\", )(0)(\);
    r' *gcm = debug_get_num_option\(\"GCM\", (0)\);\n'
    r' *if \(gcm == 1\)\n'
    r' *progress \|= OPT\(s, nir_opt_gcm, true\);\n',
    content,
)
if not m:
    print(
        f"FATAL: could not find the GCM stanza in {NIR_C}.\n"
        "       Upstream changed the ir3 GCM option - update this script.",
        file=sys.stderr,
    )
    sys.exit(1)

indent = m.group(1)
# ONE self-contained block comment, like a740_suballoc.py: a self-closing marker
# followed by bare "* ..." continuation lines would be read as code by the
# compiler. See patches/a740_suballoc.py for the same bug and the guard.
comment_lines = [
    "Banners A740: GCM on by default.",
    "Upstream default is 0 (off). Hypothesis, risks and the measurement plan are",
    "in patches/a740_gcm.py. UNMEASURED on A740 hardware - an experiment, not a",
    "proven win. The GCM env var still overrides this default.",
]
comment = f"{indent}/* {comment_lines[0]}\n"
for _line in comment_lines[1:]:
    comment += f"{indent} * {_line}\n"
comment += f"{indent} */\n"
new = comment + m.group(0).replace(
    'debug_get_num_option("GCM", 0)', 'debug_get_num_option("GCM", 1)'
)
new_content = content[:m.start()] + new + content[m.end():]

# The whole point is that the default flipped; fail loudly if it did not.
if 'debug_get_num_option("GCM", 1)' not in new_content:
    print("FATAL: the GCM default did not change", file=sys.stderr)
    sys.exit(1)
# Balance-check only the block we rewrote, not the whole file: a global paren or
# brace count is skewed by unrelated text elsewhere in ir3_nir.c and would fail on
# a correct patch.
if new.count("(") != new.count(")") or new.count("{") != new.count("}"):
    print("FATAL: unbalanced braces/parens in the replacement block", file=sys.stderr)
    sys.exit(1)

with open(NIR_C, "w") as f:
    f.write(new_content)

print('  GCM: debug_get_num_option("GCM", 0) -> 1 (hoisting on; env var still overrides)')