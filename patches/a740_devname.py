#!/usr/bin/env python3
"""
Fork identity: on an actual Adreno 740, report "Turnip (Banners A740)" instead
of Mesa's default "Turnip Adreno (TM) 740". Every other GPU keeps Mesa's string.

Why
  Upstream Turnip hardcodes the Vulkan deviceName in tu_device.cc:

      device->name = vk_asprintf(..., "Turnip Adreno (TM) %s%s", &fd_name[2], rt_suffix);

  That is per-GPU, not per-build, so every Turnip driver on an A740 reports the
  identical string. Balemuni's Apex build works around this by overriding
  deviceName, which is why it shows up as "Turnip (Balemuni Apex v2 Ultimate)"
  while ours shows up as the stock string. This does the same thing for this fork,
  so a driver list in AdrenoTools / BannerHub / a Vulkan overlay tells you which
  build is actually loaded.

  Scoped to fd_name == "FD740" on purpose. Earlier revisions matched every "FD*"
  device and claimed A740 identity on all of them. That is false on parts that
  merely resemble the 740 - the Ayaneo Pocket S reports an Adreno A32 (fd_name
  "FDA32", chip_id 0x43050a00) while persist.sys.fake.gpu makes the stock driver
  advertise "Adreno (TM) 740". Labelling that GPU as a Banners A740 sends an
  overlay looking for a 740 that is not there. Mesa already selects the correct
  chip entry for it (its own magic registers, from blob v676.0), so nothing else
  needs changing; only this string was wrong.

  Cost of the scoping: on a non-740 GPU this build no longer announces itself, so
  a driver list shows the stock name there. That is the honest answer - it is a
  build for the A740, and it is not running as one.

Scope: cosmetic identification only. Nothing keys off the string except the
  disk shader-cache directory name (disk_cache_create(device->name, ...)), so
  the first run after installing recompiles shaders once and is then cached.
  It does not change behaviour, features, or performance.

Idempotent - safe to run multiple times. Also migrates the earlier
every-FD-device form, which an already-patched tree may still carry.
"""
import re
import sys

DEVICE_CC = "src/freedreno/vulkan/tu_device.cc"
NAME = "Turnip (Banners A740)"
CHIP = "FD740"
# Must match the marker comment the replacement below writes, verbatim. If these
# drift apart the idempotency guard silently stops working and a second run fails
# with "could not find the FD-name branch" instead of skipping cleanly.
MARKER = "Banners A740: identify this fork by build, not just by GPU."

with open(DEVICE_CC, "r") as f:
    content = f.read()


def fork_branch(indent):
    """The FD740-only override, as C.

    Ends on the opening brace of the `} else if (...) {` that hands every other FD
    device back to Mesa, with no trailing newline: both call sites splice the
    original text (which starts with a newline) straight after it.
    """
    call = f"{indent}   device->name = vk_asprintf("
    pad = " " * len(call)
    return (
        f"{indent}if (strcmp(fd_name, \"{CHIP}\") == 0) {{\n"
        f"{indent}   /* {MARKER}\n"
        f"{indent}    * Mesa's default is \"Turnip Adreno (TM) %s%s\" with &fd_name[2],\n"
        f"{indent}    * which every Turnip build on this GPU shares. Purely cosmetic; the\n"
        f"{indent}    * name is also used for the disk shader-cache directory, so the first\n"
        f"{indent}    * run after this recompiles once. Scoped to {CHIP} so that parts which\n"
        f"{indent}    * merely resemble it (e.g. FDA32) keep Mesa's own name.\n"
        f"{indent}    * See docs/A740_PROGRAM.md.\n"
        f"{indent}    */\n"
        f"{call}&instance->vk.alloc,\n"
        f"{pad}VK_SYSTEM_ALLOCATION_SCOPE_INSTANCE,\n"
        f"{pad}\"{NAME}%s\", rt_suffix);\n"
        f"{indent}}} else if (strncmp(fd_name, \"FD\", 2) == 0) {{"
    )


def mesa_branch(indent):
    """Mesa's own FD-device branch body, for the migration path.

    The every-FD-device revision consumed that whole branch rather than adding
    alongside it, so migrating back means restoring it. Reproduced rather than
    recovered from the file, because by then the file no longer holds it.
    """
    call = f"{indent}   device->name = vk_asprintf("
    pad = " " * len(call)
    return (
        "\n"
        f"{call}&instance->vk.alloc,\n"
        f"{pad}VK_SYSTEM_ALLOCATION_SCOPE_INSTANCE,\n"
        f"{pad}\"Turnip Adreno (TM) %s%s\", &fd_name[2],\n"
        f"{pad}rt_suffix);\n"
    )


def guard(new_content, what):
    """Refuse to write something subtly wrong.

    This is C++, so compile() would reject it outright; what we can check cheaply
    is that the file is still textually intact, that parens and quotes balance,
    and that the branch we meant to add is the one that is there. A real compiler
    check happens in the build.
    """
    if new_content.count("(") != new_content.count(")"):
        print(f"FATAL: unbalanced parentheses after {what}", file=sys.stderr)
        sys.exit(1)
    if new_content.count('"') % 2:
        print(f"FATAL: unbalanced quotes after {what}", file=sys.stderr)
        sys.exit(1)
    if NAME not in new_content:
        print(f"FATAL: the new deviceName did not land ({what})", file=sys.stderr)
        sys.exit(1)
    if new_content.count(MARKER) != 1:
        print(f"FATAL: expected exactly one fork-name branch ({what})", file=sys.stderr)
        sys.exit(1)
    # Every other FD device must still fall through to Mesa's own string, so the
    # original branch has to survive alongside ours rather than be replaced.
    if '"Turnip Adreno (TM) %s%s", &fd_name[2]' not in new_content:
        print(f"FATAL: Mesa's own FD deviceName branch was lost ({what})", file=sys.stderr)
        sys.exit(1)


# Already scoped: nothing to do.
if MARKER in content and f'strcmp(fd_name, "{CHIP}") == 0' in content:
    print(f"  deviceName override already present, skipping ({CHIP} only)")
    sys.exit(0)

# Migrate a tree carrying the every-FD-device revision: that one consumed the whole
# FD branch, so the branch has to be rebuilt around it rather than edited.
old = re.search(
    r'( *)if \(strncmp\(fd_name, "FD", 2\) == 0\) \{\s*\n'
    r'(?:\s*/\*(?:(?!\*/).)*\*/\s*\n)?'
    r'\s*device->name = vk_asprintf\(&instance->vk\.alloc,\s*\n'
    r'\s*VK_SYSTEM_ALLOCATION_SCOPE_INSTANCE,\s*\n'
    r'\s*"Turnip \(Banners A740\)%s", rt_suffix\);\s*\n'
    r'\1\}\s*else\s*\{',
    content,
    re.DOTALL,
)
if old:
    indent = old.group(1)
    # The match consumed the old `} else {`, so all three branches have to be
    # re-emitted: ours, Mesa's FD body, and the `} else {` that introduces the
    # non-FD branch whose body still follows in content[old.end():].
    new_content = (
        content[:old.start()]
        + fork_branch(indent)
        + mesa_branch(indent)
        + f"{indent}}} else {{"
        + content[old.end():]
    )
    guard(new_content, "migration")
    with open(DEVICE_CC, "w") as f:
        f.write(new_content)
    print(f'  deviceName scoped to {CHIP} (was every FD* device)')
    sys.exit(0)

# Fresh tree: Mesa's branch is untouched, so add ours in front of it. Anchor on
# the condition line, which is unique and survives unrelated edits below it.
anchor = re.search(
    r'( *)if \(strncmp\(fd_name, "FD", 2\) == 0\) \{',
    content,
)
if not anchor:
    print(
        f"FATAL: could not find the FD-name branch in {DEVICE_CC}.\n"
        "       Upstream changed the deviceName code - update this script.",
        file=sys.stderr,
    )
    sys.exit(1)

if MARKER in content:
    print(
        f"FATAL: {DEVICE_CC} carries the fork marker but not the expected\n"
        "       FD740 branch or the older every-FD form. Update this script.",
        file=sys.stderr,
    )
    sys.exit(1)

# fork_branch already re-emits the condition it replaces, so consume the matched
# line rather than splicing in front of it - otherwise the condition appears twice.
new_content = content[:anchor.start()] + fork_branch(anchor.group(1)) + content[anchor.end():]
guard(new_content, "patching")

with open(DEVICE_CC, "w") as f:
    f.write(new_content)

print(f'  deviceName: "{NAME}%s" on {CHIP} only (was "Turnip Adreno (TM) %s%s" on every FD device)')