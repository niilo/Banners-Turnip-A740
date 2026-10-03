#!/usr/bin/env python3
"""
A740 experiment: raise the Turnip suballocator block size from 128 KB to 512 KB.

Hypothesis (energy per frame)
  `pipeline_suballoc` and `kgsl_profiling_suballoc` carve their buffers out of a
  small number of large BOs. Larger blocks mean fewer BO allocations and fewer
  allocator round trips on the CPU side while the GPU waits, which is a
  steady-state win rather than a burst one - exactly what sustained performance
  needs (docs/A740_PROGRAM.md §1).

Measured: NO. An experiment, not a proven win (AGENTS.md §3).

What it touches
  src/freedreno/vulkan/tu_device.cc, upstream, two sites:

      tu_bo_suballocator_init(&device->pipeline_suballoc, device, 128 * 1024, ...);
      tu_bo_suballocator_init(&device->kgsl_profiling_suballoc, device,
                              128 * 1024, ...);

  Only those two literals change. `autotune_suballoc` (128 KiB) and
  `trace_suballoc` (512 KiB) are left alone: trace already uses 512 KiB upstream,
  which is why the value is not arbitrary, and autotune is not in this path.

The known cost - read this before believing a win
  Upstream's own comment in src/freedreno/vulkan/tu_suballoc.cc says:

    "fragmentation can be an issue for default_size > PAGE_SIZE and small
     allocations. Also, excessive BO reallocation may happen for workloads where
     default size < working set size."

  128 KiB is 32 pages; 512 KiB is 128 pages. So this moves further from PAGE_SIZE
  and multiplies the idle reserve by 4. If a title's working set is small, the
  larger block can allocate far more memory than it uses - which is memory, and
  on a phone that is not free. A win on one title can be a regression on another.

Before you accept a win
  1. 10+ minutes continuous, same scene and camera path.
  2. Watch memory use, not just FPS. Rising reserved memory with flat FPS means
     this is costing more than it saves.
  3. Check a title with a LARGE pipeline-cache working set too, since that is the
     reallocation case the comment warns about.

Idempotent - safe to run multiple times.
"""
import re
import sys

DEVICE_CC = "src/freedreno/vulkan/tu_device.cc"
OLD = "128 * 1024"
NEW = "512 * 1024"
# Substring used for the idempotency check. Kept free of comment delimiters so it
# also works as the first line of the block comment written into the C file.
MARKER_TEXT = "Banners A740: suballocator blocks 128 KB -> 512 KB"

with open(DEVICE_CC, "r") as f:
    content = f.read()

if MARKER_TEXT in content:
    print("  suballocator blocks already raised, skipping")
    sys.exit(0)

# Match each named initialiser by the name + "device," prefix plus ANY whitespace,
# then the size literal. Upstream wraps these differently:
#
#   tu_bo_suballocator_init(
#      &device->pipeline_suballoc, device, 128 * 1024,     <- name/size on one line
#   tu_bo_suballocator_init(&device->kgsl_profiling_suballoc, device,
#                           128 * 1024, TU_BO_...          <- size on the next line
#
# so \s* has to span the newline. Anchoring on the name rather than on a literal
# "128 * 1024" keeps autotune_suballoc (also 128 KiB, not ours) untouched.
sites = [
    ("&device->pipeline_suballoc", "pipeline_suballoc"),
    ("&device->kgsl_profiling_suballoc", "kgsl_profiling_suballoc"),
]

for ident, name in sites:
    pat = re.compile(
        re.escape(ident) + r",\s*device,\s*" + re.escape(OLD) + r"(?![\d\w])"
    )
    # Plain replacement string, NOT re.escape'd: escaping is for PATTERNS. Using
    # re.escape here would inject literal backslashes into the C source.
    content, n = pat.subn(ident + ", device, " + NEW, content, count=1)
    if n != 1:
        print(
            f"FATAL: expected 1 match for {name}, found {n}.\n"
            f"       Upstream changed the suballocator init - update this script.",
            file=sys.stderr,
        )
        sys.exit(1)

# Assert each named site directly. Two things make a global count wrong here:
# upstream already uses 512 KiB for trace_suballoc (so "how many 512 * 1024 in the
# file" is 3, not 2), and kgsl_profiling_suballoc's size sits on the NEXT line, so
# the exact single-line string f"{ident}, device, {NEW}" does not exist for it
# either. Match with the same whitespace-tolerant regex instead.
for ident, name in sites:
    verify = re.compile(
        re.escape(ident) + r",\s*device,\s*" + re.escape(NEW) + r"(?![\d\w])"
    )
    if not verify.search(content):
        print(
            f"FATAL: {name} was not changed to {NEW} - "
            "the substitution did not land where intended.",
            file=sys.stderr,
        )
        sys.exit(1)

# autotune_suballoc must be untouched: it is also 128 KiB upstream and is not in
# this path, so silently changing it would be an unrelated behaviour change.
if re.search(r"&suballoc, device,\s*" + re.escape(NEW), content):
    print(
        "FATAL: autotune_suballoc was also changed - it is not part of this "
        "experiment.",
        file=sys.stderr,
    )
    sys.exit(1)

# Record why, at the site, so the next reader does not "fix" it back to 128.
#
# ONE self-contained block comment. The marker opens AND closes its own /* */, so
# the continuation lines must not be bare "* ..." - the compiler reads those as
# code and fails with "use of undeclared identifier 'UNMEASURED'". That is a real
# build break, which is why the emitted text is checked for a closed comment.
comment_lines = [
    "Banners A740: suballocator blocks 128 KB -> 512 KB.",
    "UNMEASURED on A740 - an experiment, not a proven win.",
    "Upstream warns (tu_suballoc.cc) that default_size > PAGE_SIZE fragments",
    "with small allocations, and that this reserves 4x the memory.",
    "See patches/a740_suballoc.py.",
]
first = content.find("&device->pipeline_suballoc, device,")
line_start = content.rfind("\n", 0, first) + 1
indent = content[line_start:first]
inserted = f"{indent}/* {comment_lines[0]}\n"
for _line in comment_lines[1:]:
    inserted += f"{indent} * {_line}\n"
inserted += f"{indent} */\n"
content = content[:line_start] + inserted + content[line_start:]

# Balance-check the text we inserted, not the whole file: a global paren/brace count
# is skewed by unrelated code in tu_device.cc and would fail on a correct patch.
if inserted.count("(") != inserted.count(")") or inserted.count("{") != inserted.count("}"):
    print("FATAL: unbalanced braces/parens in the inserted comment block", file=sys.stderr)
    sys.exit(1)
# Must be a closed /* */ block, or its body is compiled as code.
if inserted.count("/*") != inserted.count("*/"):
    print("FATAL: the inserted comment is not a closed /* */ block", file=sys.stderr)
    sys.exit(1)
if MARKER_TEXT not in inserted:
    print("FATAL: the idempotency marker is missing from the inserted comment", file=sys.stderr)
    sys.exit(1)

with open(DEVICE_CC, "w") as f:
    f.write(content)

print(f"  suballoc: pipeline_suballoc + kgsl_profiling_suballoc {OLD} -> {NEW} (4x reserve)")