# ADR-0043 — One root for the toolchain: the prelude import goes through `core/build/dcdart`

**Status:** ACCEPTED
**Date:** 2026-08-27
**Supersedes:** the sibling-checkout convention recorded in ADR-0001 and `core/README.md`
**Closes:** the oscortex_core half of GAP-0003. The DCDart half stays open — see "What this does not fix".

---

## Context

`core/kernel/kmain.dart:20` read:

```dart
import '../../../DCDart/core/runtime/dc-core-bare/prelude.dart';
```

and `core/scripts/build-kernel.sh` separately located the compiler through `DCDART_HOME`. Those are
**two independent answers to the question "which DCDart is this build using"**, and nothing checked
that they agreed. When they disagreed the build failed with

```
dcc build: DccLowerError: no @bare top-level function found in kmain.dart
```

which reads as a broken compiler. It was read as one: four clean DCDart checkouts were tested, all
four failed, and the conclusion drawn was that `dcc` was unbuildable. A sibling session disproved it
by building a clean clone successfully. One cause, four data points, one line of Dart.

### The mechanism, measured

`dcc` decides whether an annotation is `@bare`/`@extern`/`@rodata` in
`DCDart/core/dcc-lower/lib/lower.dart:622`:

```dart
if (constant.classNode.enclosingLibrary.importUri != preludeUri) continue;
```

`preludeUri` comes from `DCDart/core/dcc/lib/pipeline.dart:165`:

```dart
Uri _resolvePreludeUri() =>
    Platform.script.resolve('../../runtime/dc-core-bare/prelude.dart');
```

Six experiments, run against this machine's toolchain, establish exactly what that comparison is:

| # | dcc invoked via | `kmain.dart` imports | Result |
|---|---|---|---|
| 1 | real path `/private/tmp/gap0003/DCDart` | that same real path, absolute | **PASS** |
| 2 | real path | a **symlink** to the same real file | **FAIL** |
| 3 | a **symlink** to that tree | the real path | **FAIL** |
| 4 | that symlink | that same symlink | **PASS** |
| 5 | probe of `Platform.script` through a symlink | — | reports the **symlink** path, unresolved |
| 6 | real path | real path spelled with a `..` segment | **PASS** |

So the rule is **exact `Uri` equality on a lexically normalised absolute path**: `..` segments are
folded (6), symlinks are resolved on **neither** side (2, 3, 5), and two spellings of one file are two
libraries (2, 3) while one spelling of two different-looking paths is one library (4).

This corrects the folklore. GAP-0110 records the cause as "Dart resolves a library's identity through
real paths" — experiment 5 shows it does not resolve them at all. The observable failures are the
same, but the wrong model made a symlink look impossible in principle, and it is not: a symlinked
`DCDART_HOME` works fine *provided both sides go through it*. That is the property this ADR uses.

---

## Decision

**Both sides are derived from one path prefix that this repo owns.**

`build-kernel.sh` creates `core/build/dcdart` as a symlink to `$DCDART_HOME` on every build, invokes
the compiler as `dart core/build/dcdart/core/dcc/bin/dcc.dart`, and `kmain.dart` imports
`../build/dcdart/core/runtime/dc-core-bare/prelude.dart`. dcc's `Platform.script.resolve(...)` and
Dart's resolution of that import land on the same characters **by construction**, for any
`$DCDART_HOME`, at any real path, symlinked or not.

Three supporting parts, all in `build-kernel.sh`:

- **A `dcc` on PATH is no longer used, even if one exists.** It would be a third, invisible answer to
  "which DCDart", outside `$DCDART_HOME`'s control — the same defect in a new place.
- **The import line is asserted literally** (`grep -qxF`) before the build. dcc's check is a string
  comparison, so the guard is one too: any re-spelling of that path is named in one line here instead
  of surfacing later as a missing `@bare`.
- **The prelude path is printed on every build**, alongside the toolchain banner: the path dcc will
  compute, and the tree it resolves into. That is the fact `@bare` resolution actually turns on, and
  it was previously invisible.

`build-kernel.sh` also now derives the kernel directory with `pwd -P`. Dart takes the importing
library's URI from `getcwd()`, which is symlink-free; a shell's `pwd` is not. Reaching this checkout
through a symlinked parent would otherwise hand dcc a logical prefix and the front end a physical one
— two spellings of one file, which is the failure being closed.

---

## Evidence

Built in a copy of this repo at `/private/tmp/gap0003/wt/oscortex_core`, which has **no DCDart three
directories up at all**, against `DCDART_HOME=/private/tmp/gap0003/DCDart`:

```
BEFORE (sources at 40ea339):  Bad state: Generating kernel failed!
                              build-kernel: FAIL — 'dcc build ...' exited 1
AFTER:                        build-kernel: prelude  /private/tmp/gap0003/wt/oscortex_core/core/build/dcdart/...
                              build-kernel: PASS — .../core/build/kernel.elf
                              nm kmain.o -> 0000000000017da0 T kmain
```

Four configurations now build: the canonical sibling layout, a `DCDART_HOME` at an unrelated real
path, a `DCDART_HOME` reached through a symlink (previously fatal), and a full worktree with no
sibling DCDart. `kmain.o` is **byte-identical (md5 `4e7efe27345b84cc8de56cc159c406ed`) in every one**,
including against the pre-change canonical build — the prelude path does not reach the object file, so
no golden in the suite can move because of this change.

With no `DCDART_HOME` and no sibling, the failure is now a setup error naming the missing directory,
not a compiler error.

---

## What this does not fix

**The real gap is DCDart's, and it stays open.** DCDart has no library resolution:

- there is no `--prelude` flag, and no `DCDART_HOME` support, in `core/dcc/lib/cli_args.dart`;
- `dc:core.bare` as a scheme (DCDART_SPEC §2/§8) needs the front_end fork ADR-0008 deferred;
- a `package:` URI cannot work at all today, because `kernel_frontend.dart` writes its synthetic
  driver into a fresh temp directory and runs `dart compile kernel` with no `--packages`, so no
  package config is ever in scope.

DCDart's own source says as much (`pipeline.dart:157-164`): *"dcc currently only works run from inside
this checkout at this exact relative layout."*

Per CLAUDE.md rule 3, that fix belongs in DCDart's repo, with DCDart's own ADR and its own conformance
suite — **not here**. The narrowest honest version is a `--prelude <path>` option on `dcc build`,
defaulting to today's `Platform.script.resolve(...)`, which would let this repo name the prelude once
instead of encoding it in a source import. That is the recommendation to escalate. It is not
implemented here, and DCDart's tree currently carries ~2,300 lines of another session's uncommitted
work, so nothing in it was touched.

**What this ADR changes is not a language workaround.** It does not simulate a missing DCDart feature;
it stops this repo from asserting a second, uncontrolled answer to a question its own build script
already answers. That is a build-system defect, and it was ours.

---

## Alternatives rejected

- **`package:` URI with a path dependency.** Cannot work: dcc passes no package config to the front
  end (above). Would require a DCDart change — and a larger one than `--prelude`.
- **Stage the kernel sources into `build/` with the import rewritten.** Measured working, but it makes
  every compiler diagnostic point at a generated copy rather than the file a human edits, and adds a
  staleness failure mode. Rejected as strictly worse than a symlink that costs nothing.
- **Symlink DCDart into the sibling location the old import named.** Writes outside the repo, and
  fails for the reason experiment 3 shows: only the import would go through it, not dcc.
- **Leave the import and only add a mismatch check.** Turns a four-hour misdiagnosis into a one-line
  error — worth having, and kept — but the build stays locked to one checkout layout. Not a fix.

## Consequences

- `core/build/dcdart` is owned by `build-kernel.sh`. `build/` is already gitignored. The script
  refuses to proceed if that name exists as anything other than a symlink.
- `kmain.dart` does not resolve in an editor or under `dart analyze` until `build-kernel.sh` has run
  once in that checkout. Previously it resolved only in one checkout layout and nowhere else; this is
  a better trade, but it is a trade.
- Two concurrent `build-kernel.sh` runs in **one** checkout with **different** `DCDART_HOME` values
  will race on the symlink. They already raced on `core/build/*.o`; the hazard is not new, and
  per-worktree builds (how this repo is actually used) are unaffected.
- The edited region of `build-kernel.sh` overlaps the M21 toolchain-identity banner currently sitting
  unmerged in a sibling worktree. Expect one merge conflict there; the two blocks are complementary
  — that one says which commit, this one says which prelude.
