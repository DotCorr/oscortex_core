# DCDart — language identity

**Status: DESIGN / identity. Not an ADR, not numbered.** Owner-ratified.
This file is the public line and the cuts around it. It does not grow
the language and it does not schedule a Flutter port.

**Packaging readiness (2026-09-02):** **not ready** for Homebrew / winget /
distro packages. Scored dimensions, what the OS has proven, and binary
gates live in the repo-root [`LANGUAGE.md`](../../../LANGUAGE.md). Draft
(unpublished) release outline: [`docs/release-draft-language.md`](../../../docs/release-draft-language.md).

**It cites rather than re-derives.** The first in-built app / SDK and
the host-side compile path are `app-framework.md`'s. FRAME1's two
siblings are `core/user/frame/osframe.h` and
`core/user/frame/osframe.dart` (harness `frame1/`). The `@bare` cut is
already the language table in `display-protocol.md` §6. **No syscall is
invented here.**

---

## The public line

**DCDart is its own language that uses Dart’s spelling. It is not Dart.
A Dart app will not run on it.**

That is the sentence. Do not sell it as Dart. “Dart dialect” is a
compiler-people phrase; it is not the public line.

---

## 1. Spelling is not identity

DCDart source looks like Dart because that is the spelling `dcc` reads.
The kernel, and every `@bare` guest this OS can run, is compiled by
`dcc` on the host (`app-framework.md` §1, §3.2). A program written for
the Dart VM, `dart run`, or `dart compile` is a different language
talking to a different runtime. It will not load, will not link, and
will not execute here.

---

## 2. `@bare` is a cut, not Flutter-native

`display-protocol.md` §6 already lists what `@bare` cannot say: no
`String`, no growable collection, no function pointers, no `switch`,
no `&&` / `||`, one return value, every `Pointer<T>` volatile. Those
are not style notes. They are the language this OS is written in.

Installing DCDart does not hijack `flutter run`. `@bare` is the subset
`dcc` will compile for this machine. It is not a Flutter embedding
and it is not a Dart SDK on PATH that steals Flutter’s commands.

---

## 3. Flutter-on-oscortex is not “compile Flutter with `dcc`”

Flutter is a widget tree plus a C++ engine — Skia or Impeller, a Dart
runtime, isolates, a message loop. Pointing `dcc` at Flutter sources
does not produce that. You would rewrite the substrate.

Until a DCDart UI kit exists, Flutter apps do not run here. The
FRAME ladder (`app-framework.md`) is a header and a pixel surface,
not that kit.

---

## 4. Two siblings, two compilers. DCDart does not `#include`

FRAME1 shipped the ABI twice on purpose:

* `core/user/frame/osframe.h` — a C header for clang guests
  (`clang -target x86_64-unknown-none-elf`). A freestanding `.c`
  `#include`s it. An 8.3 copy (`FRAME.H`) boots on the volume.
* `core/user/frame/osframe.dart` — the sibling for `dcc`. The same
  numbers, as integer literals a `@bare` program can name.

DCDart has no preprocessor and no `#include`. The `.h` is not an
input to `dcc`. The `.dart` is not an input to clang. They agree
because an author keeps them in agreement, the way
`verify-syscall-registry.sh` already keeps the kernel and `oslibc.h`
in agreement — not because one file includes the other.

---

## 5. What this file does not do

It does not amend a language ADR. There is none in this repo to
amend; DCDart’s own ADRs live in that repo. It does not add a FRAME
rung, a syscall, or a guest Dart runtime. `app-framework.md` §0.4
already names a hosted Dart SDK on the guest as fantasy. This file
is why that sentence is not a temporary gap.
