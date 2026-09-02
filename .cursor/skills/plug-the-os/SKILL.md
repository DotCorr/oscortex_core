---
name: plug-the-os
description: >-
  Forbids waiting for the owner to say “please plug it in,” shipping a
  host-only C module as if it were the OS, or forgetting this is a
  reflective OS. Use when adding or finishing osgfx, oschrome, osmedia,
  or any core/plat module; when a Mac harness, Mac libskia, or .h in
  core/plat is treated as integrated; when idle and picking a next
  target; when describing oscortex as a guest OS or Unix userspace;
  when writing DE/wm/shell/widget logic or choosing C vs C++ vs DCDart.
  Triggers: leftover host-only, “in core/”, Mac libskia, waiting for
  owner, forget reflection, another platform module, please plug it in,
  now link it, guest OS, DCDart, @bare, C++, feels like Android,
  osgfx.h fence, widget logic, DE chrome.
---

# Plug The OS

Sibling of `no-early-yield`. Does not replace it. Host harness PASS is
still not an exit. This skill is the **same-effort** rule: if you add a
C module, you target the running OS in the same slice.

## Instructions

Do not wait for “now link it.” If you add a C module (osgfx, oschrome, osmedia), the **same effort** targets the OS: compile for kernel.elf’s triple, link into the image, make wm or a platform process **call** it. A Mac harness PASS is not “integrated.”

`.h` in core/plat/ does not run. “In core/” ≠ Android. Android calls the library from the running system.

Do not lecture instead of trying. Do not invent “built for Mac so we can’t.” C targets oscortex. Rebuild for that target.

**DCDart** (`@bare`) is the OS language: kernel, wm policy, shell. **C** is for freestanding apps (osframe), headers, and small modules that clang guests need (osxui, osgfx.h). **C++ only for compatibility** with libraries that are C++ (Skia, Chromium/CEF, FFmpeg’s C API is C — prefer C wrappers). Do not write new DE/wm/widget logic in C++ because it “feels like Android.” If DCDart can do it, DCDart does it. C ABI (`osgfx.h`) is the fence: C++ stays behind the fence.

**GPU is used two ways. Do not mix them.** (1) **Implicit** — UI / osgfx / wm decide GPU vs CPU Skia. Apps do not pick. That is the compositor path. (2) **Explicit** — `osgpu.h` is a C header, like osframe, for apps that need a GPU (games): create, submit a clear or triangle, optional readback. UI never requires the app to call osgpu. Games call osgpu. DCDart does not become C++. C++ only behind the fence if the impl is Vulkan/virgl.

**Reflective OS:** Studio/WM exhibit and emit; not gcc-in-the-image as the identity. Window management should be able to show live surfaces/pids/names. Do not “forget reflection” and describe a Unix userspace.

Never say “guest OS.” oscortex in QEMU is the OS.

No early yield. Finish the assigned binary exit criterion and prove it with a harness PASS. See `.cursor/skills/no-early-yield/SKILL.md`.

## Next-target ladder (when idle)

1. any plat/* not called from kernel.elf/sit-in → plug it
2. DE chrome (close/min/start/notify)
3. GPU if 2D-only
4. do not add another host-only module

Do not skip (1) to start another host-only plat module.

## Examples

**Forbidden — waiting for owner.** Host osgfx/oschrome/osmedia PASS, then stop until someone says “please plug it in.” Plug it: kernel.elf triple, link, wm or a platform process calls it.

**Forbidden — leftover host-only / “in core/”.** A `.h` or `.a` under `core/plat/` is not the OS. “In core/” is not Android. The running image must call the ABI.

**Forbidden — Mac libskia as the OS.** A Mac `.a` or host Graphite paint is not sit-in. Rebuild C for oscortex. Do not invent “built for Mac so we can’t.”

**Forbidden — another platform module.** plat/* already uncalled from kernel.elf/sit-in. Do not add another host-only module. Climb the ladder.

**Forbidden — forget reflection.** Describing a Unix userspace, gcc-in-the-image as the identity, or WM that cannot show live surfaces/pids/names. Studio/WM exhibit and emit.

**Forbidden — “guest OS.”** oscortex in QEMU is the OS.

**Forbidden — mix the two GPU uses.** An app picking GPU vs CPU for UI chrome, or wm/osgfx requiring `osgpu.h`. Implicit is compositor policy. Explicit is `osgpu.h` for games.

**Forbidden — C++ because it feels like Android.** New DE/wm/widget logic in C++. If DCDart can do it, DCDart does it. C++ stays behind the `osgfx.h` fence (Skia, Chromium/CEF).

**Allowed.** Same effort that added the C module also compiles it for kernel.elf’s triple, links it into the image, and has wm or a platform process call it. Idle work takes the next-target ladder in order.
