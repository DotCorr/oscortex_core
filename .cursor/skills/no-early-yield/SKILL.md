---
name: no-early-yield
description: >-
  Forbids stopping mid-rung: finish the assigned binary exit criterion and
  prove it with a harness PASS. Use when marking DESIGN or NEXT done, closing
  a leftover, writing a stub or listing-only surface, yielding on FAIL,
  shipping OSXStudio/STUDIO, updating known-gaps, finishing a platform C
  module on the host, or any oscortex milestone or rung. Triggers: leftover,
  leftover to USB3, listing only, not a builder, Identify not this file,
  I'll fix comments later, early yield, stub PASS, host harness PASS,
  osgfx, oschrome, osmedia, plug it in, Mac .a, in core/plat,
  reflection, reflective OS, next target, guest OS, DCDart, @bare,
  C++, feels like Android, osgfx.h fence.
---

# No Early Yield

## Instructions

Do not stop because a later rung is hard. Finish the assigned binary exit criterion. If blocked, iterate or use an allowed workaround, then prove it with a harness PASS.

"Leftover" is not a stopping condition. Either implement the next named rung in the same session or leave status OPEN in known-gaps with a binary next step — never "PASS" a milestone you did not implement.

Do not mark a design NEXT item done if you only wrote a stub (STUDIO listing is not OSXStudio).

Do not yield mid-FAIL ("I'll fix comments later").

Unlimited iteration is expected. Stop only on harness PASS for the assigned rung, or a hard language/hardware blocker cited to a GAP with what would unblock it.

Platform C modules (osgfx, oschrome, osmedia, …) are **not done** when a host harness PASSes. Done = the **running OS** (`kernel.elf` / sit-in) **calls** them (linked for kernel.elf’s target, wm or a platform process on the image invokes the C ABI). Do not wait for the owner to say “plug it in.” That is the next target as soon as the .h exists. “In core/plat” ≠ integrated. Copying a Mac .a is not the call. Do not stack another host-only module and mark the rung complete. Same-effort plug-in, reflective-OS identity, and the idle next-target ladder: `.cursor/skills/plug-the-os/SKILL.md`.

Language fence: DCDart (`@bare`) for kernel/wm/shell; C for clang-guest modules; C++ only behind `osgfx.h`. See `.cursor/skills/plug-the-os/SKILL.md`.

This is a reflective OS. Studio/WM exhibit live surfaces, pids, names; later emit. Do not describe gcc-in-the-image as the identity. Do not forget reflection when picking the next target.

Next-target when idle: plat/* not called from kernel.elf/sit-in → plug; else DE chrome; else GPU; do not stack another host-only module.

Never say “guest OS.”

oscortex_core extras: no help-line goldens, no last .bss theft, no commit unless asked, @bare rules.

## Examples

**Forbidden — listing only, not a builder.** `STUDIO.ELF` lists planted `APPS.TXT`. That is a stub. Do not mark OSXStudio / DESIGN NEXT done.

**Forbidden — leftover to USB3.** A later device is hard. Either implement the next named rung now or leave known-gaps OPEN with one binary next step. Do not PASS the current milestone as if the leftover were finished.

**Forbidden — Identify not this file.** Naming a different file or a later rung is not an exit. Stay on the assigned criterion until harness PASS.

**Forbidden — mid-FAIL yield.** Harness FAIL plus "I'll fix comments later" is a yield. Keep iterating.

**Forbidden — host C module, waiting.** A Mac/host harness PASS for osgfx, oschrome, or osmedia is not done. Do not stop for “now plug it in.” The running OS must call the C ABI.

**Allowed stop.** Assigned harness PASS, or a hard language/hardware blocker cited to a GAP plus what would unblock it.
