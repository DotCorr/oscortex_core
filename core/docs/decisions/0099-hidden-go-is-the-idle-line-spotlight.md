# ADR-0099 — Hidden `go NAME` is the idle-line Spotlight

**Status:** accepted, implemented (`core/kernel/proc.dart` `shellGoArgs`,
`core/kernel/shell.dart` dispatch, `core/tests/conformance/de-studio`).
**Depends on** ADR-0078 (syscall 26 `spawn`) and ADR-0053 (shell is the
idle context).
**Implements** the run-by-name sibling in `docs/design/osxstudio.md`.
Not a new syscall. Not WM chrome. Not a builder.
**Number:** 0099 — 0098 is VirtIO-GPU 3D. 11, 21 and 22 stay reserved.

---

## 1. The question

STUDIO1 lists planted `APPS.TXT`. STUDIO2 (ADR-0078) starts a catalog
name from `STUDIO.ELF` via syscall 26. The compositor start-menu is a
sibling surface (wm chrome). A driver sitting at the idle prompt still
needs a name-to-process door that does not wait on that widget and
does not grow `help`.

## 2. The decision

1. **Hidden `go <name>`.** Prefix `go ` (3 bytes) plus the bare `go`
   (2 bytes) so a missing name lands on existing proc usage. Not in
   `help`. `shellStrHelp` stays 2511.
2. **Reuse the named residency door.** `shellGoArgs` prints `GO` and
   calls `shellProcSpawnArgs`. Same `fatLookup` + `procCreate(named)`
   as `proc spawn <name>`. No new `.bss`. `wmeventStore` stays last.
3. **Not syscall 27.** Ring 3 already has 26. The idle line is ring 0
   and already had the named spawn. This is a second spelling, not a
   second mechanism.
4. **Not WM chrome.** The start-menu widget is the sibling. This
   command does not touch `wm*.dart` or virtgpu.

`run <name>` still exists and still takes the idle context. `go` is
the resident form: the prompt returns (ADR-0053).

## 3. The printed lines

```
GO
PROC SPAWN <slot>
ELF FILE
USER WRITE APPS1 APP1
USER WRITE APPS1 APP1 HEAP 1
```

From Studio, the exhibit is still `STUDIO1 NAME` / `STUDIO2 HAVE` /
`STUDIO2 LAUNCH` / the child's HEAP line.

## 4. Binary

`de-studio/run.sh` plants `APPS.TXT` listing `APP1.ELF`, `proc spawn`s
`STUDIO.ELF`, sees the planted name and `STUDIO2 HAVE`, then the
derived key starts APP1 (HEAP 1). A second boot types hidden `go`
plus the planted name and sees `GO` and the same HEAP line. Negative:
no key and no `go` → APP1 does not start.

## 5. What this is not

Not live-edit of `@bare`. Not a guest Dart SDK. Not a compiler. Not
`opendir`. Not `rename`. Not argv-from-spawn (APP7 remainder). Not
persist of `SEL.DAT`. Not a builder. Reflection / emit stays
GAP-0166.
