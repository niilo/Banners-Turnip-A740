#!/usr/bin/env python3
"""
Fork identity: report this build as "Turnip (Banners A740)" instead of Mesa's
default "Turnip Adreno (TM) 740".

Why
  Upstream Turnip hardcodes the Vulkan deviceName in tu_device.cc:

      device->name = vk_asprintf(..., "Turnip Adreno (TM) %s%s", &fd_name[2], rt_suffix);

  That is per-GPU, not per-build, so every Turnip driver on an A740 reports the
  identical string. Balemuni's Apex build works around this by overriding
  deviceName, which is why it shows up as "Turnip (Balemuni Apex v2 Ultimate)"
  while ours shows up as the stock string. This does the same thing for this fork,
  so a driver list in AdrenoTools / BannerHub / a Vulkan overlay tells you which
  build is actually loaded.

Scope: cosmetic identification only. Nothing keys off the string except the
  disk shader-cache directory name (disk_cache_create(device->name, ...)), so
  the first run after installing recompiles shaders once and is then cached.
  It does not change behaviour, features, or performance.

Idempotent - safe to run multiple times.
"""
import re
import sys

DEVICE_CC = "src/freedreno/vulkan/tu_device.cc"
NAME = "Turnip (Banners A740)"
# Must match the marker comment the replacement below writes, verbatim. If these
# drift apart the idempotency guard silently stops working and a second run fails
# with "could not find the FD-name branch" instead of skipping cleanly.
MARKER = "Banners A740: identify this fork by build, not just by GPU."

with open(DEVICE_CC, "r") as f:
    content = f.read()

if MARKER in content:
    print(f"  deviceName override already present, skipping ({NAME})")
    sys.exit(0)

# Anchor on the format string, not a line number: it is unique, it is the thing we
# are changing, and it survives unrelated edits above it in the file.
anchor = re.search(
    r'( *)device->name = vk_asprintf\(&instance->vk\.alloc,\s*\n'
    r'( *)VK_SYSTEM_ALLOCATION_SCOPE_INSTANCE,\s*\n'
    r'( *)"Turnip Adreno \(TM\) %s%s", &fd_name\[2\],\s*\n'
    r'( *)rt_suffix\);',
    content,
)
if not anchor:
    print(
        f"FATAL: could not find the FD-name branch in {DEVICE_CC}.\n"
        "       Upstream changed the deviceName code - update this script.",
        file=sys.stderr,
    )
    sys.exit(1)

indent = anchor.group(1)
# Replace only the format string, keeping the rt_suffix behaviour: an app that
# needs to know raytracing is disabled still gets told.
replacement = (
    f"{indent}/* Banners A740: identify this fork by build, not just by GPU.\n"
    f"{indent} * Mesa's default is \"Turnip Adreno (TM) %s%s\" with &fd_name[2],\n"
    f"{indent} * which every A740 Turnip build shares. Purely cosmetic; the name is\n"
    f"{indent} * also used for the disk shader-cache directory, so the first run\n"
    f"{indent} * after this recompiles once. See docs/A740_PROGRAM.md.\n"
    f"{indent} */\n"
    f"{indent}device->name = vk_asprintf(&instance->vk.alloc,\n"
    f"{indent}                      VK_SYSTEM_ALLOCATION_SCOPE_INSTANCE,\n"
    f'{indent}                      "{NAME}%s", rt_suffix);'
)

new_content = content[:anchor.start()] + replacement + content[anchor.end():]

# Guard the result. This is a C++ file, so `compile()` (Python) would reject it
# immediately; what we actually want is that the file is still textually intact
# and that the replacement carries balanced parens for the call it rewrote. A
# real compiler check happens in the build itself.
if new_content.count("(") != new_content.count(")"):
    print("FATAL: unbalanced parentheses after patching", file=sys.stderr)
    sys.exit(1)
if new_content.count('"') % 2:
    print("FATAL: unbalanced quotes after patching", file=sys.stderr)
    sys.exit(1)
if NAME not in new_content:
    print("FATAL: the new deviceName did not land", file=sys.stderr)
    sys.exit(1)

with open(DEVICE_CC, "w") as f:
    f.write(new_content)

print(f'  deviceName: "{NAME}%s" (was "Turnip Adreno (TM) %s%s")')