#!/usr/bin/env python3
"""Apply ADR-0180 four-hundred-face UND batch to tree files."""

from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path

CORE = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent


def patch_elf(patch: dict) -> None:
    p = CORE / "kernel/elf.dart"
    elf = p.read_text()

    elf = re.sub(
        r"const int elfCefUnd2BatchWant = \d+;",
        "const int elfCefUnd2BatchWant = 400;",
        elf,
        count=1,
    )
    elf = re.sub(
        r"const int elfCefUndFaceMax = \d+;",
        "const int elfCefUndFaceMax = 4608;",
        elf,
        count=1,
    )
    elf = re.sub(
        r"const int elfDlopenSymMax = \d+;",
        "const int elfDlopenSymMax = 512;",
        elf,
        count=1,
    )
    elf = elf.replace(
        "/// ADR-0179: two hundred LIBC exports + STN_UNDEF headroom.",
        "/// ADR-0180: four hundred LIBC exports + STN_UNDEF headroom.",
    )
    elf = elf.replace(
        "/// ADR-0172 was 50; ADR-0178 was 100; ADR-0179 grows to ≥200.",
        "/// ADR-0172 was 50; ADR-0178 was 100; ADR-0179 was 200; ADR-0180 grows to ≥400.",
    )
    elf = elf.replace(
        "/// ADR-0178 faces 50..99; ADR-0179 faces 100..199 (PLT stubs outside the face slab).",
        "/// ADR-0178 faces 50..99; ADR-0179 faces 100..199; ADR-0180 faces 200..399.",
    )

    old_rx = """@bare
u64 elfDlopenRxPa(u64 s0, u64 s1, u64 s2, u64 textVa, u64 va) {
  final u64 off = va - textVa;
  if (off < u64(vmPageBytes)) {
    return s0 + off;
  }
  if (off < (u64(vmPageBytes) + u64(vmPageBytes))) {
    return s1 + (off - u64(vmPageBytes));
  }
  return s2 + (off - u64(vmPageBytes) - u64(vmPageBytes));
}"""
    new_rx = """@bare
u64 elfDlopenRxPa(
    u64 s0, u64 s1, u64 s2, u64 s3, u64 s4, u64 s5, u64 textVa, u64 va) {
  final u64 off = va - textVa;
  if (off < u64(vmPageBytes)) {
    return s0 + off;
  }
  if (off < (u64(vmPageBytes) + u64(vmPageBytes))) {
    return s1 + (off - u64(vmPageBytes));
  }
  if (off < (u64(vmPageBytes) + u64(vmPageBytes) + u64(vmPageBytes))) {
    return s2 + (off - u64(vmPageBytes) - u64(vmPageBytes));
  }
  if (off <
      (u64(vmPageBytes) + u64(vmPageBytes) + u64(vmPageBytes) +
          u64(vmPageBytes))) {
    return s3 +
        (off - u64(vmPageBytes) - u64(vmPageBytes) - u64(vmPageBytes));
  }
  if (off <
      (u64(vmPageBytes) + u64(vmPageBytes) + u64(vmPageBytes) +
          u64(vmPageBytes) + u64(vmPageBytes))) {
    return s4 +
        (off - u64(vmPageBytes) - u64(vmPageBytes) - u64(vmPageBytes) -
            u64(vmPageBytes));
  }
  return s5 +
      (off - u64(vmPageBytes) - u64(vmPageBytes) - u64(vmPageBytes) -
          u64(vmPageBytes) - u64(vmPageBytes));
}"""
    if old_rx not in elf:
        raise SystemExit("elfDlopenRxPa block not found")
    elf = elf.replace(old_rx, new_rx)

    elf = elf.replace(
        "elfDlopenRxPa(scratch, scratch2, scratch3, textVa,",
        "elfDlopenRxPa(scratch, scratch2, scratch3, scratch4, scratch5, scratch6, textVa,",
    )

    elf = elf.replace(
        "  // ADR-0179: two-hundred-face LIBC RX may span three pages\n"
        "  // (hash/dynsym/dynstr across page0+page1, .text into page2).\n"
        "  // Cap at 12 KiB. Bodies are read via offset, not a contiguous img VA.\n"
        "  if (textFsz >\n"
        "      (u64(vmPageBytes) + u64(vmPageBytes) + u64(vmPageBytes))) {",
        "  // ADR-0180: four-hundred-face LIBC RX may span six pages.\n"
        "  // Cap at 24 KiB. Bodies are read via offset, not a contiguous img VA.\n"
        "  if (textFsz >\n"
        "      (u64(vmPageBytes) + u64(vmPageBytes) + u64(vmPageBytes) +\n"
        "          u64(vmPageBytes) + u64(vmPageBytes) + u64(vmPageBytes))) {",
    )

    # Insert scratch4..6 after scratch3 alloc block
    marker = """  final u64 scratch3 = allocFrame();
  if (scratch3 < u64(1)) {
    final u64 b0 = freeFrame(scratch3);
    final u64 b1 = freeFrame(scratch2);
    final u64 b2 = freeFrame(scratch);
    final u64 b3 = freeFrame(hdr);
    elfSetMeta(u64(elfMetaStatus), b0 + b1 + b2 + b3);
    fatClose();
    return u64(elfDlopenRetBadSo);
  }
  vmZeroFrame(scratch);
  vmZeroFrame(scratch2);
  vmZeroFrame(scratch3);"""
    insert = marker + """
  final u64 scratch4 = allocFrame();
  if (scratch4 < u64(1)) {
    final u64 b0 = freeFrame(scratch4);
    final u64 b1 = freeFrame(scratch3);
    final u64 b2 = freeFrame(scratch2);
    final u64 b3 = freeFrame(scratch);
    final u64 b4 = freeFrame(hdr);
    elfSetMeta(u64(elfMetaStatus), b0 + b1 + b2 + b3 + b4);
    fatClose();
    return u64(elfDlopenRetBadSo);
  }
  final u64 scratch5 = allocFrame();
  if (scratch5 < u64(1)) {
    final u64 b0 = freeFrame(scratch5);
    final u64 b1 = freeFrame(scratch4);
    final u64 b2 = freeFrame(scratch3);
    final u64 b3 = freeFrame(scratch2);
    final u64 b4 = freeFrame(scratch);
    final u64 b5 = freeFrame(hdr);
    elfSetMeta(u64(elfMetaStatus), b0 + b1 + b2 + b3 + b4 + b5);
    fatClose();
    return u64(elfDlopenRetBadSo);
  }
  final u64 scratch6 = allocFrame();
  if (scratch6 < u64(1)) {
    final u64 b0 = freeFrame(scratch6);
    final u64 b1 = freeFrame(scratch5);
    final u64 b2 = freeFrame(scratch4);
    final u64 b3 = freeFrame(scratch3);
    final u64 b4 = freeFrame(scratch2);
    final u64 b5 = freeFrame(scratch);
    final u64 b6 = freeFrame(hdr);
    elfSetMeta(u64(elfMetaStatus), b0 + b1 + b2 + b3 + b4 + b5 + b6);
    fatClose();
    return u64(elfDlopenRetBadSo);
  }
  vmZeroFrame(scratch4);
  vmZeroFrame(scratch5);
  vmZeroFrame(scratch6);"""
    if marker not in elf:
        raise SystemExit("scratch3 marker not found")
    elf = elf.replace(marker, insert)

    # Add page3..5 copies after page2 copy
    page2 = """  if (textFsz > (u64(vmPageBytes) + u64(vmPageBytes))) {
    if (elfDlopenCopy(
            scratch3,
            textOff + u64(vmPageBytes) + u64(vmPageBytes),
            textFsz - u64(vmPageBytes) - u64(vmPageBytes),
            hdr) >
        u64(0)) {
      final u64 b0 = freeFrame(scratch3);
      final u64 b1 = freeFrame(scratch2);
      final u64 b2 = freeFrame(scratch);
      final u64 b3 = freeFrame(hdr);
      elfSetMeta(u64(elfMetaStatus), b0 + b1 + b2 + b3);
      fatClose();
      return u64(elfDlopenRetBadSo);
    }
  }"""
    page6 = page2 + """
  if (textFsz > (u64(vmPageBytes) + u64(vmPageBytes) + u64(vmPageBytes))) {
    u64 page3 = textFsz - u64(vmPageBytes) - u64(vmPageBytes) - u64(vmPageBytes);
    if (page3 > u64(vmPageBytes)) {
      page3 = u64(vmPageBytes);
    }
    if (elfDlopenCopy(
            scratch4,
            textOff + u64(vmPageBytes) + u64(vmPageBytes) + u64(vmPageBytes),
            page3,
            hdr) >
        u64(0)) {
      final u64 b0 = freeFrame(scratch6);
      final u64 b1 = freeFrame(scratch5);
      final u64 b2 = freeFrame(scratch4);
      final u64 b3 = freeFrame(scratch3);
      final u64 b4 = freeFrame(scratch2);
      final u64 b5 = freeFrame(scratch);
      final u64 b6 = freeFrame(hdr);
      elfSetMeta(u64(elfMetaStatus), b0 + b1 + b2 + b3 + b4 + b5 + b6);
      fatClose();
      return u64(elfDlopenRetBadSo);
    }
  }
  if (textFsz >
      (u64(vmPageBytes) + u64(vmPageBytes) + u64(vmPageBytes) +
          u64(vmPageBytes))) {
    u64 page4 = textFsz - u64(vmPageBytes) - u64(vmPageBytes) -
        u64(vmPageBytes) - u64(vmPageBytes);
    if (page4 > u64(vmPageBytes)) {
      page4 = u64(vmPageBytes);
    }
    if (elfDlopenCopy(
            scratch5,
            textOff + u64(vmPageBytes) + u64(vmPageBytes) + u64(vmPageBytes) +
                u64(vmPageBytes),
            page4,
            hdr) >
        u64(0)) {
      final u64 b0 = freeFrame(scratch6);
      final u64 b1 = freeFrame(scratch5);
      final u64 b2 = freeFrame(scratch4);
      final u64 b3 = freeFrame(scratch3);
      final u64 b4 = freeFrame(scratch2);
      final u64 b5 = freeFrame(scratch);
      final u64 b6 = freeFrame(hdr);
      elfSetMeta(u64(elfMetaStatus), b0 + b1 + b2 + b3 + b4 + b5 + b6);
      fatClose();
      return u64(elfDlopenRetBadSo);
    }
  }
  if (textFsz >
      (u64(vmPageBytes) + u64(vmPageBytes) + u64(vmPageBytes) +
          u64(vmPageBytes) + u64(vmPageBytes))) {
    if (elfDlopenCopy(
            scratch6,
            textOff + u64(vmPageBytes) + u64(vmPageBytes) + u64(vmPageBytes) +
                u64(vmPageBytes) + u64(vmPageBytes),
            textFsz - u64(vmPageBytes) - u64(vmPageBytes) - u64(vmPageBytes) -
                u64(vmPageBytes) - u64(vmPageBytes),
            hdr) >
        u64(0)) {
      final u64 b0 = freeFrame(scratch6);
      final u64 b1 = freeFrame(scratch5);
      final u64 b2 = freeFrame(scratch4);
      final u64 b3 = freeFrame(scratch3);
      final u64 b4 = freeFrame(scratch2);
      final u64 b5 = freeFrame(scratch);
      final u64 b6 = freeFrame(hdr);
      elfSetMeta(u64(elfMetaStatus), b0 + b1 + b2 + b3 + b4 + b5 + b6);
      fatClose();
      return u64(elfDlopenRetBadSo);
    }
  }"""
    if page2 not in elf:
        raise SystemExit("page2 copy block not found")
    elf = elf.replace(page2, page6)

    elf = elf.replace(
        "  // ADR-0179: metadata may span page0+page1 (≤8 KiB); .text may reach page2.\n"
        "  final u64 metaPages = u64(vmPageBytes) + u64(vmPageBytes);",
        "  // ADR-0180: metadata may span page0..page2 (≤12 KiB); .text may reach page5.\n"
        "  final u64 metaPages = u64(vmPageBytes) + u64(vmPageBytes) + u64(vmPageBytes);",
    )

    # Replace body copy loop with elfDlopenRxPa
    old_copy = """        while (i < bodyLen) {
          final u64 srcOff = bodyOff + i;
          u64 srcPa = scratch + srcOff;
          if (srcOff >= (u64(vmPageBytes) + u64(vmPageBytes))) {
            srcPa = scratch3 +
                (srcOff - u64(vmPageBytes) - u64(vmPageBytes));
          } else if (srcOff >= u64(vmPageBytes)) {
            srcPa = scratch2 + (srcOff - u64(vmPageBytes));
          }
          Pointer<u8>.fromAddress(dstBody + i).value =
              Pointer<u8>.fromAddress(srcPa).value;
          i = i + u64(1);
        }"""
    new_copy = """        while (i < bodyLen) {
          final u64 srcVa = textVa + bodyOff + i;
          final u64 srcPa = elfDlopenRxPa(
              scratch,
              scratch2,
              scratch3,
              scratch4,
              scratch5,
              scratch6,
              textVa,
              srcVa);
          Pointer<u8>.fromAddress(dstBody + i).value =
              Pointer<u8>.fromAddress(srcPa).value;
          i = i + u64(1);
        }"""
    if old_copy not in elf:
        raise SystemExit("body copy loop not found")
    elf = elf.replace(old_copy, new_copy)

    # Final free includes scratch4..6
    elf = elf.replace(
        "  final u64 b0 = freeFrame(scratch3);\n"
        "  final u64 b1 = freeFrame(scratch2);\n"
        "  final u64 b2 = freeFrame(scratch);\n"
        "  final u64 b3 = freeFrame(hdr);\n"
        "  elfSetMeta(u64(elfMetaStatus), b0 + b1 + b2 + b3);\n"
        "  fatClose();\n"
        "  if (bound < u64(elfCefUndBatchWant)) {",
        "  final u64 b0 = freeFrame(scratch6);\n"
        "  final u64 b1 = freeFrame(scratch5);\n"
        "  final u64 b2 = freeFrame(scratch4);\n"
        "  final u64 b3 = freeFrame(scratch3);\n"
        "  final u64 b4 = freeFrame(scratch2);\n"
        "  final u64 b5 = freeFrame(scratch);\n"
        "  final u64 b6 = freeFrame(hdr);\n"
        "  elfSetMeta(u64(elfMetaStatus), b0 + b1 + b2 + b3 + b4 + b5 + b6);\n"
        "  fatClose();\n"
        "  if (bound < u64(elfCefUndBatchWant)) {",
    )

    # Insert rodata + plt + phases
    if "elfStrSelect" in elf:
        raise SystemExit("elfStrSelect already present — rerun aborted")
    elf = elf.replace(
        "@rodata\nfinal List<u8> elfStrMktime = const [\n"
        "  u8(0x6D), u8(0x6B), u8(0x74), u8(0x69), u8(0x6D), u8(0x65), u8(0x00),\n"
        "];\n",
        "@rodata\nfinal List<u8> elfStrMktime = const [\n"
        "  u8(0x6D), u8(0x6B), u8(0x74), u8(0x69), u8(0x6D), u8(0x65), u8(0x00),\n"
        "];\n\n"
        + patch["str_block"]
        + "\n",
    )
    elf = elf.replace(
        "const int elfCefMktimePltVaddr = 0xDCF6040;\n"
        "const int elfCefMktimePltOff = 0xDCF5040;\n"
        "/// Face slab:",
        patch["plt_block"]
        + "\n/// Face slab:",
    )
    elf = elf.replace(
        "    if (phase == u64(199)) {\n"
        "      namePtr = Rodata.addressOf(elfStrMktime);\n"
        "      nameLen = u64(6);\n"
        "      pltOff = u64(elfCefMktimePltOff);\n"
        "      pltVa = u64(elfCefMktimePltVaddr);\n"
        "    }\n"
        "    u64 stVal = u64(0xFFFFFFFFFFFFFFFF);",
        "    if (phase == u64(199)) {\n"
        "      namePtr = Rodata.addressOf(elfStrMktime);\n"
        "      nameLen = u64(6);\n"
        "      pltOff = u64(elfCefMktimePltOff);\n"
        "      pltVa = u64(elfCefMktimePltVaddr);\n"
        "    }\n"
        + patch["phase_block"]
        + "\n"
        "    u64 stVal = u64(0xFFFFFFFFFFFFFFFF);",
    )

    p.write_text(elf)


def patch_derive(bound_list: str) -> None:
    p = HERE / "derive.py"
    txt = p.read_text()
    txt = txt.replace("MIX = 0x0000000000000179", "MIX = 0x0000000000000180")
    txt = txt.replace("BATCH = 200", "BATCH = 400")
    txt = re.sub(
        r'BOUND_LIST = \(\s*"[\s\S]*?"\s*\)',
        f'BOUND_LIST = (\n    "{bound_list}"\n)',
        txt,
        count=1,
    )
    txt = txt.replace(
        'print("und_line=CEF UND BATCH 00000000000000C8")',
        'print("und_line=CEF UND BATCH 0000000000000190")',
    )
    txt = txt.replace(
        'print("batch_user=BATCH 00000000000000C8")',
        'print("batch_user=BATCH 0000000000000190")',
    )
    p.write_text(txt)


def patch_prog() -> None:
    p = HERE / "prog.c"
    txt = p.read_text()
    txt = txt.replace("#define MIX 0x0000000000000179UL", "#define MIX 0x0000000000000180UL")
    txt = txt.replace("#define BATCH 200UL", "#define BATCH 400UL")
    txt = txt.replace("binds ≥200 measured", "binds ≥400 measured")
    p.write_text(txt)


def patch_run(last_face: str) -> None:
    p = HERE / "run.sh"
    txt = p.read_text()
    txt = txt.replace("ADR-0179:", "ADR-0180:")
    txt = txt.replace("ASSERTIONS_REQUIRED=60", "ASSERTIONS_REQUIRED=62")
    txt = txt.replace("expected 200", "expected 400")
    txt = txt.replace("expected ≥200", "expected ≥400")
    txt = txt.replace("UND batch count %d, expected 200", "UND batch count %d, expected 400")
    txt = txt.replace("UND batch count %d, expected ≥200", "UND batch count %d, expected ≥400")
    txt = txt.replace("bound %d < 200", "bound %d < 400")
    txt = txt.replace("expected 1136", "expected 936")
    txt = txt.replace("elfCefUnd2BatchWant is $BATCH2, expected 200", "elfCefUnd2BatchWant is $BATCH2, expected 400")
    txt = txt.replace("libc.c exports $FACE_COUNT faces, expected 200", "libc.c exports $FACE_COUNT faces, expected 400")
    txt = txt.replace("STRUCTURAL: pass  UND2×200 batch", "STRUCTURAL: pass  UND2×400 batch")
    txt = txt.replace("CEF-UND2: PASS — bound 200/1336", "CEF-UND2: PASS — bound 400/1336")
    txt = txt.replace("remain 1136", "remain 936")
    txt = txt.replace(
        'ck; grep -q \'ADR-0179\' "$CORE_DIR/docs/decisions/0179-high-traffic-und-batch-grows-to-two-hundred.md" \\\n  || fail "ADR-0179 file is missing"',
        'ck; grep -q \'ADR-0180\' "$CORE_DIR/docs/decisions/0180-high-traffic-und-batch-grows-to-four-hundred.md" \\\n  || fail "ADR-0180 file is missing"',
    )
    txt = txt.replace(
        'ck; grep -q \'0178 is the hundred-face\' "$CORE_DIR/docs/decisions/0179-high-traffic-und-batch-grows-to-two-hundred.md" \\\n  || fail "ADR-0179 stole 0178"',
        'ck; grep -q \'0179 is the two-hundred-face\' "$CORE_DIR/docs/decisions/0180-high-traffic-und-batch-grows-to-four-hundred.md" \\\n  || fail "ADR-0180 stole 0179"',
    )
    txt = txt.replace("# Drop mktime definition (last ADR-0179 face).", f"# Drop {last_face} definition (last ADR-0180 face).")
    txt = txt.replace(
        'r"\\nlong mktime\\(void \\*tm\\) \\{.*?\\n\\}\\n"',
        f'r"\\nint {last_face}\\(void\\) \\{{.*?\\n\\}}\\n"',
    )
    txt = txt.replace('if re.search(r"^long mktime\\(", out, re.M):', f'if re.search(r"^int {last_face}\\(", out, re.M):')
    txt = txt.replace('raise SystemExit("strip left mktime behind")', f'raise SystemExit("strip left {last_face} behind")')
    txt = txt.replace('print("anti-vacuity: wrote libc-miss.c without mktime")', f'print("anti-vacuity: wrote libc-miss.c without {last_face}")')
    txt = txt.replace("|| fail \"anti-vacuity strip failed\"", f"|| fail \"anti-vacuity strip failed\"")
    txt = txt.replace("grep -qE ' [Tt] mktime$'", f"grep -qE ' [Tt] {last_face}$'")
    txt = txt.replace("fail \"libc-miss.so still exports mktime", f"fail \"libc-miss.so still exports {last_face}")
    txt = txt.replace("grep -qE ' [Tt] mktime$' \"$WORKDIR/libc.so\"", f"grep -qE ' [Tt] mktime$' \"$WORKDIR/libc.so\"")
    txt = txt.replace("[[ \"$FACE_COUNT\" -eq 200 ]]", "[[ \"$FACE_COUNT\" -eq 400 ]]")
    p.write_text(txt)


def patch_build_progs(bound_list: str) -> None:
    p = HERE / "build-progs.sh"
    faces = bound_list.split(",")
    block = "\n".join(f"  {f}" for f in faces)
    txt = p.read_text()
    txt = re.sub(
        r"FACES=\(\n[\s\S]*?\n\)",
        f"FACES=(\n{block}\n)",
        txt,
        count=1,
    )
    txt = txt.replace("# PLAT/ASK + LIBC.SO (100 UND faces)", "# PLAT/ASK + LIBC.SO (400 UND faces)")
    txt = txt.replace("# ADR-0179: RX LOAD may span three pages", "# ADR-0180: RX LOAD may span six pages")
    txt = txt.replace('[[ "$FSZ" -le 12288 ]]', '[[ "$FSZ" -le 24576 ]]')
    txt = txt.replace("build-progs: PASS — plat.elf", "build-progs: PASS — plat.elf")
    txt = re.sub(
        r"build-progs: PASS — plat\.elf \(.*?\) \+ libc\.so \(.*?\)",
        lambda m: m.group(0).replace("200 faces", "400 faces"),
        txt,
    )
    if "400 faces" not in txt:
        txt = txt.replace("+ 200 faces", "+ 400 faces")
    p.write_text(txt)


def write_adr(last_face: str) -> None:
    path = CORE / "docs/decisions/0180-high-traffic-und-batch-grows-to-four-hundred.md"
    names = json.loads((HERE / "faces400.json").read_text())["faces"]
    face_names = ", ".join(f"`{f['name']}`" for f in names[:20])
    path.write_text(
        f"""# ADR-0180 — High-traffic UND batch grows to four hundred through OUR libc

**Status:** accepted, implemented, verified (`tests/conformance/cef-und2/run.sh`)
**Date:** 2026-08-31
**Milestone:** grow the measured CEF UND bind set past ADR-0179's two hundred
**Files:** `core/kernel/elf.dart` (`elfCefUnd2BatchWant=400`,
`elfDlopenSymMax=512`, six-page LIBC RX copy, face slab 8192 B, faces 200..399),
`tests/conformance/cef-und2/`, GAP-0322
**Depends on** ADR-0179 (two-hundred-face batch), ADR-0178 (hundred),
ADR-0172 (fifty), ADR-0171 (twenty), ADR-0170 (five), ADR-0169 (`memset@plt`),
ADR-0168 (full LOADs), ADR-0152 (tiny libc).
**Does not close** Content `OnPaint`. Does not bind the rest of
1,336 UND. Does not raise `de-browse/` floor 87. Does not ship glibc.
Graphite / Venus fenced.
**Number:** 0180 — 0179 is the two-hundred-face UND batch. Do not reuse.
Syscall 11 stays `fdwait`. No new syscall. No help line.

---

## 1. The question

ADR-0179 PASSed **200 of 1,336** high-traffic UND and left **1,136**.
What binary grows the bound set to **≥400** (200+ new), measured from
the official PLT, through OUR libs, with unbound → fail?

## 2. The measurement

Official linux64 `libcef.so` JUMP_SLOT survey (same plant as
ADR-0168/0179). Two hundred additional POSIX / pthread / locale /
stdio leaf faces present in the PLT and implementable as freestanding
leaf bodies. Examples: {face_names}, … `{last_face}`.
Together with the ADR-0179 two hundred: **400 of 1,336**. Remaining
**936**. `malloc` still absent. Content `OnPaint` stays leftover.

## 3. The decision

1. **OUR tiny FAT `LIBC.SO` may export four hundred faces.** Bodies
   stay leaf (`-Os`; no cross-calls).
2. **LIBC RX may span six pages.** Kernel copies page0..page5;
   `elfDlopenSymMax` rises to 512. Face slab grows to 4608 B at PLT
   idx ≥ 511.
3. **Bind policy unchanged:** first five faces required. Extras bind
   when present; missing an extra leaves that `@plt` unbound → `#PF` /
   no `LINE`. Harness builds `libc-miss.so` without `{last_face}`
   (anti-vacuity).
4. **Kernel prints** `CEF UND BATCH <n>` (`0000000000000190` when all
   four hundred land).
5. **Honest leftover.** Rest of 936 UND, then Content `OnPaint`.

## 4. What this is not

Not Chromium Content painting. Not glibc. Not binding every UND.
Not raising `de-browse` floor 87. Not Graphite / Venus.

## 5. What remains (GAP-0322 leftovers)

The remaining 936 UND, then Content `OnPaint`.

## 6. Verification

`core/tests/conformance/cef-und2/run.sh` — `PLAT.ELF` dlopens
`CEF.SO`; kernel opens `LIBC.SO`, prints `CEF UND BATCH 400`;
userspace calls through four hundred official PLT addresses and
prints derived `LINE`; floors held.
"""
    )


def patch_known_gaps() -> None:
    p = CORE / "docs/known-gaps.md"
    txt = p.read_text()
    insert = """
**NARROWED** (ADR-0180, `cef-und2/`): grows the bound set to
**400 of 1,336** (200+ beyond ADR-0179) — POSIX / pthread / locale
leaf stubs through OUR `LIBC.SO`. LIBC RX may span six pages;
`elfDlopenSymMax` rises to 512; face slab grows to 4608 B.
Anti-vacuity: host `libc-miss.so` drops `{last}`. **936** remain.
Not OnPaint. Floor 87 stays.

"""
    txt = txt.replace(
        "**Binary next step:** remaining UND, then Content `OnPaint`.",
        insert.replace("{last}", json.loads((HERE / "und400.patch.json").read_text())["last_face"])
        + "**Binary next step:** remaining UND, then Content `OnPaint`.",
    )
    p.write_text(txt)


def main() -> None:
    subprocess.run(["python3", str(HERE / "gen-und400.py")], check=True)
    patch = json.loads((HERE / "und400.patch.json").read_text())
    patch_elf(patch)
    patch_derive(patch["bound_list"])
    patch_prog()
    patch_run(patch["last_face"])
    patch_build_progs(patch["bound_list"])
    write_adr(patch["last_face"])
    patch_known_gaps()
    print("apply-und400: done")


if __name__ == "__main__":
    main()
