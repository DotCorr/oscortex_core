# Time and power — a design, not yet a decision

**Status:** DESIGN. Nothing here is built. This document proposes what an RTC, a monotonic clock, a
timer service, an ACPI table parser and a shutdown path would cost this kernel, what each one would
change in the twenty conformance harnesses, and in what order they are worth doing.

**Everything in this document that describes QEMU's behaviour was MEASURED on the QEMU this repo's
harnesses actually run** — `qemu-system-x86_64` 11.0.0, machine `pc` (`pc-i440fx-11.0`, the default),
on this host — and every measurement is reproducible from Appendix A, which gives the exact command.
Nothing about QEMU below is quoted from memory or from a wiki. Where a fact is from a specification
rather than from a measurement it is labelled **[spec]**, because the difference matters: this kernel
has been wrong about hardware before (GAP-0063, GAP-0071) and it was always the unmeasured half.

### The seven things decided here, for a reader in a hurry

| # | Decision | Where |
|---|---|---|
| 1 | **Shutdown is the highest-value item in this document and it is the cheapest.** One `outb` to QEMU's `isa-debug-exit` device turns "the host gave up after N seconds" into "the guest finished and reported a status" across all twenty harnesses. Measured: a byte write of `0x10` to port `0xF4` exits QEMU with status **33**. | §5 |
| 2 | **The RTC is small, self-contained, needs no new assembly, and is assertable byte-for-byte** — because `-rtc base=<datetime>,clock=vm` pins the guest's date. It unblocks GAP-0127 item 4 (FAT timestamps). Measured: QEMU's RTC is **BCD, 24-hour**, and the FADT names CMOS register **0x32** as the century. | §1 |
| 3 | **A monotonic clock costs one mask byte and two goldens.** The counter already exists. Free-running IRQ0 moves exactly the `TICKS <start> +0010 LIVE` line in `m3-shell` and `m4-fault`; **`M1 TICKS 0000000000000064` does not move**, and neither does anything else. | §2 |
| 4 | **Build sub-tick time BEFORE building fast time.** Latching PIT channel 0 gives 838 ns resolution with IRQ0 still masked, needs no calibration and no new hardware — but only after channel 0 is switched from mode 3 to mode 2, which is a one-nibble change that moves no golden. | §2.4 |
| 5 | **The ACPI PM timer is the best cheap monotonic source in the machine and nobody has noticed it.** Measured at `PM_TMR_BLK = 0x608`, 3.579545 MHz, 24-bit, readable with the `port_inl` that already exists. No MMIO, no mapping, no calibration. It is also the reference a TSC calibration needs. | §3.2 |
| 6 | **ACPI parsing pays for itself twice** — shutdown needs the FADT, SMP needs the MADT — and it needs **zero new assembly**. It has one measured hazard: on a 256 MiB boot the tables sit **outside** `boot.S`'s 128 MiB identity map, and `m7-frames` boots a 256 MiB machine. | §6 |
| 7 | **HPET is already mapped and needs no calibration; TSC needs both a new instruction and a calibration loop.** HPET at `0xFED00000` falls inside `boot.S`'s 3–4 GiB PCI-hole directory. Measured period: 10 ns. Neither is worth building until something measurably needs better than 838 ns. | §3 |

---

## 0. Ground truth — what this kernel has today, measured rather than recalled

### 0.1 The one clock that exists

`core/kernel/interrupts.dart:296` programs 8253/8254 channel 0 with command byte `0x36` and divisor
`0x2E9C` (11932), giving 1193182 / 11932 = **99.9985 Hz**. `core/boot/isr.S` owns a 64-bit counter in
`.bss`; the IRQ0 arm of `isrDispatch` (`interrupts.dart:478`) increments it through a
`Pointer<u64>`, and `tick_count()` reads it back **through an `@extern` call on purpose** — DC-IR's
`Load` has no volatile semantics (DCDart GAP-0006), so a wait loop reading the same address through a
plain load is one LLVM may hoist. That constraint reappears in §3.1 the moment anyone tries to read an
MMIO counter.

At 100 Hz a 64-bit tick counter wraps in 5.8 billion years. Wrap is not a design problem here and is
not discussed again.

### 0.2 The PIT is masked at rest, and three places say so

`picRemap` leaves master mask `0xFE` (IRQ0 only). `picUnmaskKeyboardOnly` (`keyboard.dart:172`) writes
`0xFD` — IRQ1 only, **timer masked** — and that is the shell's steady state. Two sites turn IRQ0 back
on, both temporarily:

* `shellTicks` (`shell.dart:1083`) unmasks, spins until the counter advances by `0x10`, re-masks.
* `procSchedule` (`proc.dart:2434`) unmasks for the duration of a **preemptive** session only, and
  `procSessionTimerOff` (`proc.dart:2005`) re-masks at every exit — ordinary, faulting, and refusing.
  A cooperative session never unmasks at all.

GAP-0058 states the trade and both of its costs. The reason is reproducibility: with the timer masked
the counter holds still between commands, so `TICKS 0000000000000064 +0010 LIVE` is a constant, and a
constant is the only thing a byte-exact golden can hold.

### 0.3 There is no RTC, no ACPI, no HPET, no TSC, and no shutdown

Grepped for, and absent: `0x70`/`0x71` never appear; no `RSD PTR` scan; no `rdtsc`; no `0xFED00000`;
no `isa-debug-exit`; no `0xCF9`; no keyboard-controller reset. `core/boot/portio.S` provides
`port_inl`, `port_outl`, `port_inw`, `port_outw`; DCDart's own `Port.inb`/`Port.outb` cover byte
width. **Every port access this document needs already exists.** The only instruction anything here
would newly require is `rdtsc` (§3.3), and only if TSC is built at all.

### 0.4 Termination today, harness by harness — measured, not assumed

**Twenty** `run.sh` files exist under `core/tests/conformance/` — counted, not recalled. (This
document is sometimes briefed as "eighteen harnesses". The full set is `m0`–`m16`, `m18`, `m19` —
nineteen milestone harnesses, since M17 was a storage refactor with no harness of its own — plus
`mb-info`, which is not a milestone. Every statement below is against all twenty.) They fall into two
groups:

* **Three have no driver at all** — `m0-boot` (`timeout 5`), `m1-interrupts` (`timeout 10`),
  `mb-info` (`timeout 5`). The kernel ends in `halt_forever()`; the harness accepts exit status
  **0 or 124** and comments that 124 is "the EXPECTED termination path, not a failure". These three
  burn their entire timeout on every successful run.
* **Seventeen drive QEMU over QMP** with `core/tests/conformance/m2-console/qmp-drive.py`, whose last
  act is `qmp.cmd("quit")` (line 297). They also accept 0 or 124.

Every one of the twenty passes `-no-reboot`. None passes `-no-shutdown`, `-rtc`, or any `-device`
relevant here.

**The precise gap is not "there is no shutdown". It is that the guest never terminates itself and
never reports a status.** `timeout` means *the host gave up*. `quit` means *the host decided we were
done*. Neither of them can ever mean *the OS finished, and here is what it concluded*. GAP-0001's
last paragraph has said so since M0.

---

## 1. The RTC — CMOS ports 0x70 and 0x71

### 1.1 Why this is first among the small things

Every filesystem and every build tool wants a file timestamp. `fatDirCreate` writes `DIR_CrtTime`,
`DIR_WrtTime` and `DIR_LstAccDate` as **zero** today and GAP-0127 item 4 gives the reason — "this
kernel has no wall clock … a made-up date would be worse than no date". That is correct and it is
also a hundred and twenty lines from being false.

The RTC is the only wall-clock source on a PC that survives a power cycle. It is not a good clock —
it has one-second granularity, it can be read while it is updating itself, and its encoding is a
runtime property rather than a constant — but it is the only one, and reading it *once* at boot is
all a kernel ever needs to do (§4.4).

### 1.2 The interface

Two ports. `0x70` is the index register, `0x71` the data register. Writing an index then reading
`0x71` returns that CMOS byte. Both are byte-wide, which is exactly the width DCDart's `Port` class
provides — **no new assembly, unlike PCI (GAP-0066)**.

| CMOS register | Contents |
|---|---|
| `0x00` | Seconds |
| `0x02` | Minutes |
| `0x04` | Hours |
| `0x06` | Day of week (unreliable on most hardware — do not use) **[spec]** |
| `0x07` | Day of month |
| `0x08` | Month |
| `0x09` | Year within century |
| `0x0A` | Status A — bit 7 = **UIP** (update in progress); bits 6:4 divider; bits 3:0 rate select |
| `0x0B` | Status B — bit 6 PIE, bit 4 UIE, **bit 2 = DM (1 = binary, 0 = BCD)**, **bit 1 = 24-hour** |
| `0x0C` | Status C — interrupt flags; **reading it is what re-arms an RTC interrupt** **[spec]** |
| `0x32` | Century — *by convention only*; the authoritative index is the FADT's `CENTURY` byte (§6.4) |

**Measured on QEMU 11.0.0, machine `pc`, with `-rtc base=2026-08-23T12:34:56,clock=vm`:**

```
reg 0x00 (sec)      = 0x58      reg 0x07 (day)      = 0x23
reg 0x02 (min)      = 0x34      reg 0x08 (month)    = 0x08
reg 0x04 (hour)     = 0x12      reg 0x09 (year)     = 0x26
reg 0x0B (status B) = 0x02      reg 0x32 (century)  = 0x20
reg 0x0A (status A) = 0x26
```

Status B `0x02` = bit 1 set, bit 2 clear: **24-hour, BCD**. Every field above reads back as BCD of the
pinned base time. Status A `0x26` = UIP clear, divider `010` (normal 32.768 kHz operation), rate
select `0110` (1024 Hz, the power-on default — relevant only if periodic interrupts are ever wanted,
§4.5).

### 1.3 The UIP flag, and the only correct way to read the thing

The RTC updates its own registers roughly once a second, and during that window the values are
undefined **[spec]**. Reading naively gets you `12:59:60`, or `13:00:00` on a date that has not
rolled over yet. Both are rare and both are the kind of bug that shows up once a month in a log and
never reproduces.

The read is two rules, not one:

1. **Wait for UIP to clear before starting**, and start the read immediately after — the update takes
   under 2 ms and the next one is ~999 ms away, so a read begun just after UIP falls is safe **[spec]**.
2. **Read the whole set twice and require the two to agree.** This is the rule that actually holds,
   because it needs no assumption about how long you have. If they disagree, an update landed in the
   middle; go round again.

Both rules together, plus register B read once (its encoding cannot change under you), is the whole
algorithm:

```
rtcNow():
  attempts = 0
  loop:
    if ++attempts > rtcMaxAttempts:      // see below
      return refusal
    while (cmosRead(0x0A) & 0x80) != 0: {}   // UIP clear
    a = readAllSeven()
    while (cmosRead(0x0A) & 0x80) != 0: {}
    b = readAllSeven()
    if a == b: break
  statusB = cmosRead(0x0B)
  if (statusB & 0x04) == 0: a = bcdToBinaryAll(a)
  if (statusB & 0x02) == 0: a.hour = fixTwelveHour(a.hour)
  return unixSecondsFrom(a)
```

**The two spins must be bounded, and this is not optional here.** GAP-0058 cost 2 and GAP-0072 both
name unbounded waits as this kernel's recurring hazard: `uartPutc`'s THRE poll and `shellTicks`'
tick wait can each wedge the machine with no diagnostic. A dead or absent RTC would add a third. The
bound is the same shape `ataWait` already uses — a counted iteration limit, checked structurally by
`m6-disk` — and the refusal is a diagnostic naming the register that never settled, not a silent
zero. It is worth saying plainly that the bound is *not* a timeout (GAP-0072's argument applies
unchanged: a faster CPU spins out sooner in wall-clock terms), and that this is one of the places
where §2.4's `pitElapsed()` would upgrade a counted bound into a real one.

### 1.4 BCD versus binary, and the trap in the hour byte

BCD stores each decimal digit in a nibble: `0x26` is twenty-six, not thirty-eight. The conversion is
`(v & 0x0F) + ((v >> 4) * 10)`.

**Detect it, never assume it.** Status B bit 2 is the authority. QEMU measured BCD; some firmware
sets binary mode; the same physical machine can report either depending on what the last OS left
behind. Assuming BCD and meeting a binary RTC gives you a year of "38" for 2026 — plausible-looking
garbage, which is the worst failure mode available.

**The hour byte has an extra rule that catches people.** If Status B bit 1 is clear the clock is in
12-hour mode, and bit 7 of the hour register is the PM flag. In 12-hour BCD mode that flag sits
inside the byte you are about to BCD-convert, so **it must be masked off before conversion, not
after**: `hour = bcd(raw & 0x7F); if (raw & 0x80) hour = (hour % 12) + 12; else hour = hour % 12;`.
Doing it in the other order converts `0x92` (9 PM) into 92. QEMU is 24-hour so this path would never
execute here — which is exactly why it should be written correctly once and commented, rather than
written hopefully and discovered on hardware.

### 1.5 The century

CMOS register `0x32` is not architectural. The authoritative source is the FADT's one-byte `CENTURY`
field at offset 108, which names the CMOS register index to use, or is **zero** meaning "there is no
century register" **[spec]**.

**Measured: QEMU's FADT gives `CENTURY = 0x32`**, and register `0x32` reads `0x20` under a 2026 base.
So on QEMU the convention and the table agree — which is the good case and not the general one.

This produces a clean two-tier design and a genuinely good conformance criterion:

* If the FADT is available and `CENTURY != 0`, read that register. Full year = `century*100 + year`.
* If not, apply the standard window: `year < 70 → 2000 + year`, else `1900 + year` **[spec]**.

**Measured with `-rtc base=1999-12-31T23:58:00`: register `0x09` reads `0x99` and register `0x32`
reads `0x19`.** So a harness can boot the *same kernel binary* twice with two different `-rtc base`
values and require it to print 2026 once and 1999 once — which proves the century register is being
*read* rather than 20 being assumed. That is T3's exit criterion 3 and it is worth having, because
"assume 20xx" is the shortcut everybody takes and nothing else would catch it.

### 1.6 Turning it into a number, once

DCDart functions return one scalar, so the RTC's seven fields cannot come back as a struct. Do not
invent a packed encoding for them. **Return Unix seconds** — one `u64`, printable, comparable,
subtractable, and the input every other representation is derived from. `days_from_civil` is about
ten lines of integer arithmetic with no division by a variable (so it does not meet GAP-0063's
`ud2`-on-zero-divisor path) and no table:

```
  y -= (m <= 2) ? 1 : 0
  era = y / 400
  yoe = y - era*400
  doy = (153*(m + (m > 2 ? -3 : 9)) + 2)/5 + d - 1
  doe = yoe*365 + yoe/4 - yoe/100 + doy
  days = era*146097 + doe - 719468
  return days*86400 + h*3600 + mi*60 + s
```

A second function, `rtcFatDateTime()`, packs FAT's two 16-bit fields into one `u64` for `fat.dart` to
consume: `date = ((y-1980) << 9) | (m << 5) | d`, `time = (h << 11) | (mi << 5) | (s >> 1)`
**[spec]**. FAT's granularity is two seconds and its epoch is 1980, so dates before 1980 or after
2107 are not representable — a real limit worth a refusal rather than a wraparound.

### 1.7 What the RTC unblocks, and what it costs the harnesses

Writing real timestamps into `fatDirCreate`/`fatDirWrite` closes GAP-0127 item 4. The bill is
`m16-filewrite`, which compares the **entire disk image** byte-for-byte after the boot and derives
every expected byte in `derive.py`. A nonzero timestamp is a new set of image bytes that
`derive.py` must predict.

**It can predict them, and only because of `-rtc base=`.** With `-rtc base=2026-08-23T12:00:00,clock=vm`
the harness knows the date the guest will read, so it can compute the exact `DIR_WrtDate`/`DIR_WrtTime`
words the kernel must write. That turns a timestamp from "an unassertable duration" into "a derived
constant", which is the same move `m7-frames` makes with the memory map and `m18-preempt` makes with
quanta. Without a pinned base it is not assertable at all and the honest thing would be to keep
writing zero.

Two residual honesty points that belong in a gap, not in a comment:

* **Seconds still drift.** `clock=vm` advances the guest clock with virtual time, so a boot that
  takes eleven seconds reads eleven seconds past the base. A golden must therefore assert **date,
  hour and minute** and treat seconds as bounded — or pin a base at `HH:00:00` and require the boot
  to finish inside the minute, which every harness except `m16` (600 s ceiling, far less in practice)
  comfortably does. Predicting the *seconds* field exactly is not achievable and should not be
  attempted.
* **FAT timestamps are local time by specification; the RTC here is UTC** (QEMU's default is
  `base=utc`). There is no timezone anywhere in this OS and there should not be one yet. Writing UTC
  into a local-time field is a known, recorded inaccuracy — it is what a machine with no timezone
  database can do, and it is strictly better than zero.

### 1.8 Cost

~120 lines of DCDart in a new `core/kernel/rtc.dart`, no new assembly, no `@bss` (everything is
computed and returned), one shell command. The shell command is the part that is not free: see §5.5.

---

## 2. Monotonic time

### 2.1 What is already built

Everything except the decision. The counter exists, the handler increments it, the read path is
already hoist-proof, and the frequency is already correct. Making it a clock is **one byte**:
`picUnmaskKeyboardOnly` writes `0xFD`; writing `0xFC` instead leaves IRQ0 permanently unmasked.

The question was never "what does it cost to build" — it is "what does it cost to *turn on*", and
that is a question about goldens.

### 2.2 What a free-running timer moves, exactly

This was worked out against the goldens, not estimated.

| Golden text | Where | Free-running effect |
|---|---|---|
| `M1 TICKS 0000000000000064` | 20 files (19 `expected.txt` plus `m2-console/expected-screen.txt`) | **UNCHANGED.** The M1 wait already runs with IRQ0 unmasked; it exits the first time the counter reaches 100 and prints that value. It is a trigger count, not a duration — `kmain.dart:255` says so — and it stays 100 whether or not the timer keeps running afterwards. |
| `TICKS 0000000000000064 +0010 LIVE` | `m3-shell`, `m4-fault` | **BREAKS.** `start` is currently the constant 100 only because the counter has been frozen since `picMaskAll`. Free-running, it becomes a function of how long the boot took to reach the command. |
| `PROC SCHED … KTICKS <n>` | `m18-preempt` | **Changes, softly.** `KTICKS` counts ticks that interrupted ring 0. `run.sh:579` extracts it by regex and appends a *note* when it is nonzero rather than requiring a value, so a free-running timer raises the number without failing the harness. Worth re-reading that note when it lands, because a much larger `KTICKS` is real information about §2.5. |
| everything else | all 20 | **UNCHANGED.** A timer interrupt emits no output. It changes when instructions execute, never which bytes are printed. |

**So the entire cost is two lines in two goldens.** That is a much smaller number than GAP-0058's
framing suggests, and it is worth writing down because the gap has been read for several milestones
as "the clock is expensive".

### 2.3 What `ticks` should become

`shellTicks` prints `TICKS <start> +0010 LIVE` and its own docstring explains that `start` is
assertable only because the counter is frozen. Once it is not frozen, there are two options and one
of them is wrong.

* **Keep the mask, add `uptime` alongside.** Wrong. Two mechanisms for time is how you get two
  answers for what time it is, and the shell would then have a command whose value depends on
  whether another command has run.
* **Print the delta only: `TICKS +0010 LIVE`.** Right. The delta is the evidence — the line is
  printed only after a loop whose sole exit is the counter advancing by `0x10`, so a dead timer still
  hangs the harness rather than printing a wrong number, which is the property the docstring says it
  is protecting. The starting value never carried information; it carried reproducibility, and
  deleting it is how reproducibility survives the timer being real.

Both goldens then move by **deleting a fixed field**, which is the smallest possible edit and is
mechanically checkable: the new line must be the old line with bytes 6–23 removed.

`uptime` (§4.4) then becomes the command that reports a duration, and it is deliberately *not*
assertable as a value — its harness criterion is that two boots differ while every other byte of the
capture is identical, which is a stronger statement than any constant could make.

### 2.4 Sub-tick time, with the timer still masked — build this first

The PIT's counter can be read directly. Write `0x00` to the mode register (counter-latch command for
channel 0) and read `0x40` twice — low byte then high byte — to get the count at the instant of the
latch **[spec]**. This works **with IRQ0 masked**, needs no calibration, needs no new hardware, and
needs no interrupt. Resolution: one PIT input clock, 1/1193182 s = **838 ns**.

This is what GAP-0072 asked for when it said the ATA driver's counted spin "is not a timeout" and
named "the PIT read back through its latch command rather than through its IRQ" as one of the two
things that would close it. It is also what `blocking-and-threads.md` §2.4 names as its own falsifier
for the preemptible-kernel question ("one new function, no new hardware"). Two independent designs
have now asked for the same twenty lines.

**There is a snag, and it has a one-nibble fix.** `pitInit` writes command byte `0x36`, which selects
**mode 3, square wave**. In mode 3 the counter decrements by *two* per input clock and reloads at the
half-period, so a latched count does not tell you where you are in the tick — the same count occurs
twice per period and nothing in the latched value distinguishes the halves **[spec]**. Interpolation
is ambiguous by a factor of two.

Command byte `0x34` selects **mode 2, rate generator**: decrement by one, a clean monotonic ramp from
11932 down to 1, one output pulse per period. The 8259 latches that pulse as an edge exactly as it
latches mode 3's transition, so IRQ0 arrives at the same 100 Hz **[spec]**. Nothing observable
changes; the golden `M1 TICKS 0000000000000064` is a count of interrupts and is unaffected.

With mode 2:

```
elapsedNanos = ticks * 10_000_000 + (11932 - latched) * 838
```

and the read has one race worth handling: latch and counter must be sampled without a tick landing
between them. Read the tick counter, latch, read the tick counter again; if it changed, redo. With
IF clear it is a bounded two-iteration loop.

**Recommendation: this is the first piece of time infrastructure worth building**, ahead of the RTC
and ahead of unmasking anything. It costs ~25 lines, changes no golden, and it is the thing that
turns three existing counted spins (`ataWait`, `uartPutc`'s THRE poll, `shellTicks`) into bounded
waits measured in microseconds rather than in iterations.

### 2.5 What a free-running timer does that is not about goldens

Ticks are currently *destroyed*, not deferred. Every syscall runs behind an interrupt gate with IF
clear, and the 8259 cannot queue two pending IRQ0s, so a long disk read loses roughly one tick per
10 ms of its duration. `blocking-and-threads.md` §2.1–2.2 measures this and calls it unbounded.

A free-running timer does **not** fix that — it makes it *measurable*, which is the necessary first
step. Once `tick_count()` runs continuously, comparing it against `pitElapsed()`'s sub-tick reading
across a syscall gives the number of lost ticks directly. That is precisely the measurement
`blocking-and-threads.md` §2.4 says it cannot produce today, and §2.4 of this document is what
produces it.

---

## 3. HPET and TSC — which is worth it, and what each needs

### 3.1 The constraint both of them run into first

A free-running counter read through a `Pointer<u64>` is exactly the pattern DCDart GAP-0006 makes
unsafe: DC-IR's `Load` has no volatile semantics, so a loop that reads one address with nothing
opaque in between is one LLVM may hoist into a register. `interrupts.dart:120` already documents this
for the tick counter and works around it with an `@extern` call.

**So any MMIO counter needs the same treatment**: a tiny assembly reader (`hpet_read(addr) -> u64`),
in the same category as `cpu_probe` in `isr.S` — an instruction sequence reached over the C ABI
because the language cannot express it. This is not a reason to avoid HPET; it is a line item that
should be budgeted rather than discovered.

Port I/O does not have this problem: `Port.inb` and `port_inl` are already opaque calls.

### 3.2 The ACPI PM timer — the cheap answer nobody looked for

**Measured**: the FADT reports `PM_TMR_BLK = 0x608`, `PM_TMR_LEN = 4`, and FADT flags bit 8
(`TMR_VAL_EXT`) **clear**, meaning the counter is 24-bit. Reading port `0x608` on a live machine
returned `0x00D906E3` — a running count.

It is a free-running counter at exactly **3.579545 MHz** (fixed by the ACPI specification, not by the
platform) **[spec]**, giving **279 ns** resolution. It is read with one `port_inl`, which
`portio.S` already provides. It needs no MMIO mapping, no volatile workaround, no calibration and no
enabling.

Its one limitation is the 24-bit width: it wraps every 2²⁴ / 3579545 = **4.687 seconds**. Any user
must sample it more often than that, or extend it to 64 bits by accumulating in the timer tick — at
100 Hz that is 468 ticks of margin, which is enormous.

**This is the best value-per-line time source in the machine.** Its only prerequisite is finding the
FADT, which §6 has to do anyway for shutdown. It is also the canonical thing you calibrate a TSC
against.

### 3.3 TSC

`rdtsc` returns a 64-bit counter in EDX:EAX. There is no DCDart primitive; it needs a four-line
`@extern` in the same file and the same shape as `cpu_probe` — trivial to write, and it moves the
declared-extern count, which several harnesses assert structurally.

The work is not the instruction, it is everything around it:

* **Calibration.** The TSC has no self-describing frequency. You measure it against something else —
  the PM timer (§3.2) or a PIT-timed interval — over a window long enough to beat the noise, twice,
  and require the two to agree. That is a real loop with a real convergence criterion.
* **Invariance.** A TSC that changes rate with the CPU's power state is useless as a clock. The check
  is CPUID leaf `0x80000007`, EDX bit 8 **[spec]**; `boot.S` already executes CPUID for other reasons
  so the pattern exists. `-cpu qemu64`, which most harnesses use, does not advertise invariant TSC.
* **It is not a real cycle counter under this emulator.** QEMU on macOS runs TCG, where `rdtsc` is
  derived from a virtual clock rather than counting host cycles. A calibration measured on this host
  is not transferable, and TSC-derived timings under TCG measure the emulator as much as the guest.
* **Per-CPU offsets** become a problem the moment SMP exists — which is the other agent's design, and
  a reason not to bake a single global TSC frequency in before that lands.

**Verdict: last.** It is the fastest read available and the only one requiring calibration, an
invariance check and an SMP story. Nothing in this OS is currently limited by the cost of reading a
clock.

### 3.4 HPET

**Measured**: the ACPI `HPET` table is present on the default `pc` machine (no `-machine hpet=on`
needed; the machine property exists and defaults on). Base address `0xFED00000`, event timer block id
`0x8086A201`. Reading the capability register at that base gave `GCAP_ID = 0x009896808086A201`:

* period = `0x00989680` = **10,000,000 femtoseconds = 10 ns → 100 MHz**;
* `NUM_TIM_CAP` = 3 comparators;
* `COUNT_SIZE_CAP` = 1 → **64-bit main counter**, no wrap handling needed.

Three things make it cheaper here than it usually is:

1. **It is already mapped.** `boot.S` identity-maps 0xC0000000–0xFFFFFFFF with 512 2 MiB pages
   (ADR-0009, the PCI-hole directory added at M5 for the framebuffer BAR). `0xFED00000` falls inside
   it. No page-table work, no `vm.dart` involvement.
2. **It self-describes its frequency.** No calibration, ever. The period is in the capability
   register.
3. Main counter at offset `0xF0`, enable is bit 0 of `GEN_CONF` at `0x10`, comparators at
   `0x100 + 0x20*N` **[spec]**. Reading the counter is the whole job for a monotonic clock; the
   comparators only matter if HPET is to *generate* interrupts, which nothing here needs while the
   PIT works.

Two costs:

* The volatile-read problem of §3.1 — one `@extern`.
* **The mapping is cacheable**, which GAP-0071 already records as wrong-in-principle for MMIO. Under
  QEMU the emulator's MMIO dispatch makes it work anyway; on real hardware a cacheable HPET main
  counter is a genuine bug. Fixing it needs PAT/MTRR setup that this kernel does not have. The honest
  position is that HPET should not be *relied on* until that is fixed, even though it will work in
  every test this repo runs.

### 3.5 Recommendation

| Source | Resolution | Needs | Verdict |
|---|---|---|---|
| PIT tick counter | 10 ms | nothing — it exists | **Have it. Turn it on (§2).** |
| PIT latch (mode 2) | 838 ns | ~25 lines, one nibble in `pitInit` | **Build first.** No golden moves. |
| ACPI PM timer | 279 ns | the FADT (§6), one `port_inl` | **Build with §6.** Wraps at 4.7 s. |
| HPET | 10 ns | ACPI HPET table, one MMIO `@extern`; already mapped | **Only when something needs it.** |
| TSC | ~1 ns | new instruction, calibration, invariance check, SMP story | **Last, if ever.** |

The falsifier for building either of the bottom two: if a *measured* failure is ever traced to 838 ns
being too coarse, build HPET. Until then the resolution this kernel has is three orders of magnitude
finer than anything it does.

---

## 4. Timers as a service

### 4.1 This section deliberately does not design blocking

`core/docs/design/blocking-and-threads.md` already specifies the waiting half, and duplicating it
here would produce two specifications that drift. In brief, so that this document is readable on its
own — **read that document for the actual design**:

* One blocking primitive, `fdwait(mask, timeoutTicks) -> readyMask`, syscall 11 (§3 there). `sleep(n)`
  is `fdwait(0, n)`; a non-blocking poll is `fdwait(mask, 0)`.
* A sixth process state, BLOCKED, with two new slot words: `procSlotWaitMask` and
  `procSlotWaitUntil` (§1.2 there).
* **Deadlines are absolute and counted in ticks**, not relative and not in milliseconds — because a
  relative deadline must be decremented for every waiter on every tick, and because "a duration is a
  different test on every host; a tick count is the same test everywhere" (§1.2 there, quoting
  ADR-0022's argument for the quantum).
* `procWakeDue(now)` is called from `procTick` and wakes every slot whose deadline has arrived; §1.6
  there gives the ordering constraint and the trap in it.

### 4.2 The dependency that document has on this one, and it is hard

`blocking-and-threads.md` §1.8 ("THE HARD PART: nothing to run") reaches the conclusion that **the
timer must stay unmasked while a session is idle** — otherwise a session whose only process is asleep
has no tick to wake it, and it sleeps forever. It notes in passing that this "moves `m3-shell`'s
byte-exact `ticks` golden".

**Stated plainly, because it is a scheduling constraint between two designs: B1 in that ladder cannot
land until §2.3 of this document lands.** The free-running timer and the `ticks` golden change are a
*prerequisite* of the blocking work, not an independent option. §2.2 above is the full accounting of
what that costs — two lines in two goldens — so the prerequisite is cheap, but it has to be
sequenced.

### 4.3 What this document owes the timer service, and what DCDart forbids

Three things are in scope here and not there:

**A periodic kernel callback cannot be a registry.** DCDart has no function pointers and no dynamic
dispatch (GAP-0002); `isrDispatch` classifies interrupts with a branch chain for exactly this reason.
So "register a periodic callback" is not expressible, and the honest shape is a **fixed sequence of
named calls in `procTick`** — the wake scan, then whatever else earns a slot — each one a compile-time
decision. This is fine at the current scale (`procTick` has one caller and four process slots) and it
is the wrong shape at thirty subsystems, which is the same sentence GAP-0002 already writes about
interrupt vectors. Do not build a general timer-callback API; build the two or three calls that are
needed and let the shape stay legible.

**A timer list is not needed yet.** With four process slots, `procWakeDue` is a linear scan of four
words on each tick. A sorted list or a timer wheel would be strictly more code and strictly slower at
n=4. The threshold to revisit is when waiters stop being process slots — a network stack's
retransmission timers are the first thing that would cross it, because those are per-connection, not
per-process.

**Tick granularity is 10 ms and that is coarse for a network retransmit.** If it becomes the limiting
factor, the fix is to reprogram the PIT to 1000 Hz — divisor 1193 instead of 11932. And here is a
result worth having: **that change moves no golden.** `M1 TICKS 0000000000000064` prints a *count* of
100 interrupts, so it reads `0x64` at 1000 Hz exactly as it does at 100 Hz; the boot simply reaches it
in 100 ms instead of 1 s. What it costs is ten times as many VM exits under TCG, which is a real
performance cost in a 600-second harness and the reason not to do it speculatively.

### 4.4 Wall clock and monotonic clock, composed once

Read the RTC **once**, at boot, into `bootUnixSeconds`. Everything after that is arithmetic on the
tick counter:

```
uptimeMillis()   = ticks * 10                       (+ pitElapsed() for sub-tick, §2.4)
timeOfDay()      = bootUnixSeconds + ticks / 100
```

Do not re-read the RTC. It costs four port accesses and a UIP wait, it has one-second granularity,
and — read carelessly — it can go *backwards* relative to the monotonic clock across an update. One
sample at boot plus a monotonic counter is both cheaper and more correct, and it is what every real
kernel does.

The one thing this composition does not survive is a machine that sleeps, which this OS cannot do.
When suspend exists, so does clock resynchronisation; not before.

### 4.5 RTC periodic interrupts — possible, and not recommended

The RTC can generate IRQ8 at rates from 2 Hz to 8192 Hz: set the rate in Status A bits 3:0, set
Status B bit 6 (PIE), and **read Status C after every interrupt or it never fires again** **[spec]**.

Two reasons not to:

* IRQ8 is on the **slave** PIC, which `picRemap` masks entirely (`0xFF`) and which
  `ata.dart:182` already notes is masked at rest. Using it means unmasking IRQ8 on the slave *and*
  IRQ2 (the cascade) on the master, and issuing EOI to **both** PICs. That is a second interrupt path
  with a second correctness rule, added for a capability the PIT already provides.
* It buys nothing. The PIT is a periodic interrupt source that already works, is already wired, and
  already has a handler.

The RTC's *alarm* (Status B bit 5) has the same objection. Build neither.

---

## 5. Shutdown and reboot — the highest-value item in this document

### 5.1 What is actually wrong today

Not "the machine cannot be turned off". The problem is evidential:

* **`timeout 5` firing means the host gave up.** It is indistinguishable from a kernel that hung on
  its first instruction, and `m0-boot`/`m1-interrupts`/`mb-info` each treat exit 124 as *the expected
  outcome*. A hang is therefore caught only by the serial byte comparison — and only if the hang
  happens after enough bytes were printed to make the comparison fail in an interesting way.
* **`qmp.cmd("quit")` means the host decided we were done.** The seventeen QMP harnesses are better
  off — they end promptly and deliberately — but the decision is still the driver's. The guest is
  never asked and never answers.
* **The guest cannot report anything except bytes on a wire.** Every verdict this suite reaches is
  reached by the host parsing serial text. There is no channel by which the OS itself can say "I
  checked, and the answer is no".

An exit status closes all three. It is a second, independent channel, it is one instruction wide, and
it is the difference between "the output looked right" and "the output looked right *and the machine
completed and said so*".

### 5.2 Mechanism 1 — `isa-debug-exit` (the one to build first)

QEMU has a device whose entire purpose is letting a guest exit the emulator with a status code.

**Measured on QEMU 11.0.0:**

```
$ qemu-system-x86_64 -device isa-debug-exit,iobase=0xf4,iosize=0x04 ...   # then, from the monitor:
(qemu) o/b 0xf4 0x10
$ echo $?
33
```

* The status is **`(value << 1) | 1`**. `0x10` → 33. Confirmed by direct measurement, not recalled.
* **A one-byte `outb` works even with `iosize=0x04`** — the device accepts accesses of 1–4 bytes.
  This matters: it means **`Port.outb` is sufficient and no new assembly is needed at all.**
* Device defaults, from `-device isa-debug-exit,help`: `iobase=1281` (0x501), `iosize=2`. The harness
  should pass `iobase=0xf4,iosize=0x04` explicitly rather than depend on defaults.
* **It also emits a QMP `SHUTDOWN` event** before exiting — measured:
  `{"event": "SHUTDOWN", "data": {"guest": true, "reason": "guest-shutdown"}}`. So this mechanism
  gives *both* channels: an event for a QMP-attached harness and a status code for a plain one.

**The constraint that shapes the convention: the status is always odd and never zero.** `(v<<1)|1`
cannot produce 0, cannot produce an even number, and `v=0` produces 1 — which collides with the
generic shell/harness "failure" status. So:

| guest writes | QEMU exits | meaning |
|---|---|---|
| `0x10` | **33** | the milestone's own checks passed |
| `0x11` | **35** | the guest reached its end and *failed* its own check |
| (not reached) | 124 | `timeout` fired — **always a failure now** |
| anything else | other | a QEMU-level problem |

Guest-side cost: one function, one `Port.outb`, no ACPI, no tables, no new externs.

### 5.3 Mechanism 2 — ACPI S5 soft-off

The architectural shutdown: write `SLP_TYPa << 10 | SLP_EN` (bit 13) to the FADT's `PM1a_CNT_BLK`
**[spec]**.

**Measured:**

```
(qemu) o/h 0x604 0x2000      # 16-bit write, PM1a_CNT_BLK, SLP_TYP=0 SLP_EN=1
```
→ QEMU exits **0**, and QMP records
`{"event": "SHUTDOWN", "data": {"guest": true, "reason": "guest-shutdown"}}`.

Three measured details that are easy to get wrong:

1. **The access must be 16 bits.** The FADT reports `PM1_CNT_LEN = 2`, and QEMU's register only
   accepts 2-byte accesses — a 32-bit write to `0x604` is rejected and silently does nothing. This was
   observed directly: the first attempts used a 4-byte access and the machine kept running. Use
   `port_outw`, which `portio.S` already provides.
2. **No SMI handshake is needed on QEMU.** The FADT reports `SMI_CMD = 0xB2` and `ACPI_ENABLE = 0xF1`,
   and reading `PM1a_CNT` shows `SCI_EN` clear — yet the S5 write works anyway. Writing `0xF1` to
   `0xB2` was measured to *not* set `SCI_EN`. So the spec-blessed enable sequence (write `ACPI_ENABLE`
   to `SMI_CMD`, poll `SCI_EN`) should be written, bounded, and **not treated as a precondition** — do
   it, don't wait forever for it, then write S5 regardless.
3. **`SLP_TYPa` properly comes from the DSDT's `\_S5_` AML object, and this OS will never interpret
   AML.** The options, honestly ranked:
   * *Hardcode 0.* Works on QEMU (measured). Silently wrong elsewhere.
   * *Byte-scan the DSDT for `_S5_` and decode the small package that follows.* The well-known
     twenty-line shortcut; not a real AML parser, and it fails on any DSDT where `_S5_` appears inside
     a construct it does not understand. It is bounded work and it is the only option that has a
     chance on a machine that is not QEMU.
   * *Refuse unless the value is 0.* Safe, useless off QEMU.

   **Recommend the scan, with the refusal as the fallback**, and a gap filed saying plainly that this
   is not AML interpretation and never will be.

### 5.4 Mechanism 3 — reboot

**Measured, with `-no-reboot` (which every harness already passes):**

| guest action | QEMU exit | QMP event |
|---|---|---|
| `outb(0xCF9, 0x06)` — PCI reset control | **0** | `SHUTDOWN {guest: true, reason: "guest-reset"}` |
| `outb(0x64, 0xFE)` — 8042 pulse CPU reset line | **0** | `SHUTDOWN {guest: true, reason: "guest-reset"}` |

Both work; both are distinguishable from a shutdown by the `reason` field, which is a genuinely
useful assertion for a harness ("the guest *rebooted*, it did not power off").

**ACPI reset is not available here, and this is measured rather than assumed.** QEMU's FADT is
**revision 1 and 116 bytes long**. `RESET_REG` is a GAS at offset 116 and `RESET_VALUE` at 128 —
i.e. *past the end of the table*. There is no reset register to read. Any code that reaches for
`FADT.RESET_REG` must first check `FADT.Length > 128` and fall back, or it will read whatever follows
the table in memory and write it to a port.

Triple-faulting also reboots the machine, and should not be used: it is indistinguishable at the QMP
level from the bug it looks like, and this kernel has spent M1 and M4 making faults *diagnosable*.

### 5.5 What changes in each harness

The migration is mechanical and it splits cleanly.

**The three with no driver** — `m0-boot`, `m1-interrupts`, `mb-info`:

| | now | after |
|---|---|---|
| kernel ends at | `halt_forever()` | `powerDebugExit(0x10)` |
| QEMU invocation | `timeout 5 qemu … -no-reboot` | `+ -device isa-debug-exit,iobase=0xf4,iosize=0x04` |
| accepted status | `0 or 124` | **`33`, exactly** |
| what 124 means | expected | **failure: the guest never got to its exit** |
| serial golden | 15 / 544 / 433 bytes | **byte-identical — the exit adds no output** |
| wall time | always the full 5 / 10 / 5 s | as long as the boot takes |

The byte-neutrality is the important part and it is why these three should go first. `m1-interrupts`
ends with `M1 END\n` printed from the fault handler, followed by `halt_forever()`. Replacing that
call with an exit does not change one byte of the 544-byte golden that **seventeen other harnesses
assert as a prefix** — so the highest-risk artefact in the repo is untouched.

**The seventeen QMP harnesses.** Three coordinated edits:

1. **`qmp-drive.py`** gains `--expect-guest-exit`. With it, the driver does everything it does today
   (keys, monitor commands, screendump, text-buffer read) and then, instead of `qmp.cmd("quit")`,
   waits for the `SHUTDOWN` event and lets QEMU exit on its own. Without it, behaviour is unchanged —
   so the flag can be adopted harness by harness rather than in one commit.
2. **Each `run.sh`** adds the `-device` and tightens its status check from `!= 0 && != 124` to `== 33`.
3. **The guest needs a way to be told.** Either the driver's key sequence ends with a new `shutdown`
   command, or the existing final command implies it. **The `shutdown` command is the real bill in
   this whole section**, because `shellStrHelp` is currently 2224 bytes, is asserted by
   `check_table shellStrHelp 2224` in `m10-elf` and `m11-proc`, and its text appears inside five
   goldens: `m3-shell`, `m4-fault`, `m5-pci`, `m6-disk`, `m14-fat`. Adding a command line moves all
   seven artefacts. The ROADMAP records that exact cost being paid at M19 ("`help` gained one line …
   taking `shellStrHelp` from 2147 to 2224 and moving five harnesses' goldens"), so the procedure is
   known: substitute the line, then require the kernel to reproduce the result byte for byte.

   **Add `shutdown`, `reboot`, `date` and `uptime` in one milestone rather than four**, and pay the
   help-string cost once.

**One ordering rule for the guest.** Flush the UART before exiting. `uartPutc` polls LSR bit 5 (THRE)
*before* each write, so when the last call returns the final byte may still be in the shift register.
QEMU's `file:` serial backend writes through immediately so nothing is lost there, but on real
hardware the last character would be dropped. Poll LSR bit 6 (TEMT, transmitter empty) once before the
exit write **[spec]** — two lines, and it removes an entire class of "the last line is sometimes
missing" from the future.

**One flag rule for the harness.** Never add `-no-shutdown`: it makes QEMU stay alive after a guest
shutdown, which is precisely the behaviour being removed.

### 5.6 What this buys, stated as testing outcomes

1. **A hang becomes a distinct, named failure.** Today a kernel that wedges before printing anything
   exits 124 and three harnesses call that expected. After, 124 is always a failure and the message
   can say "the guest never reached its exit point" — different from "the bytes did not match".
2. **The guest gets a verdict channel.** A self-check that today must be rendered as text and parsed
   by the host can instead be an exit status. That does not replace the byte goldens (see the warning
   below) — it adds a second, independent assertion about the same boot.
3. **Negative controls get cleaner.** Several harnesses already build a deliberately-wrong kernel and
   require it to fail. Today "fail" means "the byte comparison fails". After, a mutant can be made to
   exit **35** and the harness can assert *that*, which is a much sharper statement.
4. **Wall time.** `m0`, `m1` and `mb-info` currently burn 5 + 10 + 5 = 20 seconds of pure `timeout` on
   every successful sweep. That goes to roughly the boot time. The seventeen QMP harnesses already
   exit promptly, so the saving is honestly small — it is listed fourth, not first, because it is the
   least of the four benefits and it would be easy to oversell.

**The warning that must survive into the implementation: an exit status is ADDED, never SUBSTITUTED.**
The byte-exact goldens are what actually verify this OS. A harness that checked only the exit status
would be a much weaker harness wearing a cleaner shirt. Every migrated `run.sh` keeps every byte
comparison it has, and gains one status assertion.

---

## 6. ACPI table parsing

### 6.1 Why it pays for itself twice

Shutdown (§5.3) needs `PM1a_CNT_BLK` from the FADT. The SMP design being written by another agent
needs the MADT — the local APIC address, one entry per CPU, the I/O APIC address, and the interrupt
source overrides. Both come out of the same walk, and the walk needs **no new assembly**: every table
is ordinary memory read through `Pointer<u8>`/`Pointer<u32>`/`Pointer<u64>`.

Even without SMP, the FADT alone yields the PM timer (§3.2), the century register (§1.5) and the
shutdown port — three separate answers from one parse.

### 6.2 The walk

**RSDP.** Scan two regions on 16-byte boundaries for the 8-byte signature `"RSD PTR "` **[spec]**:
the first KiB of the EBDA (segment at physical `0x40E`, shifted left 4), then `0xE0000`–`0xFFFFF`.
Validate by checksum.

**Measured: the RSDP is at `0xF52E0`, OEM ID `"BOCHS "`, revision 0.**

Revision 0 is ACPI 1.0 and it has three consequences, all measured:

* The structure is **20 bytes**, not 36. There is no length field and no XSDT pointer.
* **The checksum covers the first 20 bytes only** — measured: sum of the first 20 bytes is 0, sum of
  36 bytes is **94**. A parser that checksums 36 bytes unconditionally *rejects QEMU's valid RSDP*.
  Check the extended checksum only when `revision >= 2`.
* **There is no XSDT.** `rsdt_address = 0x07FE2328`, `xsdt_address` field absent. Code must handle
  RSDT-only, not merely prefer XSDT — which is the opposite of what most tutorials emphasise.

**Root table.** Header is 36 bytes: 4-byte signature, `u32` length, revision, checksum, OEM fields.
Entries follow: `(length - 36) / 4` × `u32` for an RSDT, `/8` × `u64` for an XSDT. Every table's whole
length must sum to zero mod 256.

**Measured on `-m 128M` (what 28 of the 30 QEMU invocations in this repo use):**

```
RSDT at 0x07FE2328, length 52, 4 entries — every checksum verified zero:
  0x07FE21DC  FACP  116 bytes     0x07FE2250  APIC  120 bytes
  0x07FE22C8  HPET   56 bytes     0x07FE2300  WAET   40 bytes
```

### 6.3 The addressing hazard — measured, and it bites an existing harness

`boot.S` identity-maps **128 MiB** (`MAP_2MIB_PAGES = 64`, raised from 16 MiB at M7 by ADR-0011) plus
3–4 GiB for the PCI hole. QEMU places the ACPI tables just below the top of RAM.

| `-m` | RSDT address | inside the 128 MiB map? |
|---|---|---|
| `128M` | `0x07FE2328` | **yes** (0x07FE2328 < 0x08000000, by 120 KiB) |
| `256M` | `0x0FFE2328` | **NO** |

Both rows are measured. `m7-frames` boots a 256 MiB machine, and `m5-pci` boots four machines with
varying devices. So an ACPI parser that assumes its tables are reachable will page-fault on a harness
that already exists — with a clean M8 diagnostic, which is at least the good failure, but a failure.

Three ways out, in order of when they are worth doing:

1. **Bound-check and refuse**, printing the address that was out of range. Ten lines. Correct
   behaviour, no capability. Right answer for the first milestone.
2. **Map the pages through `vm.dart`.** M8 has the machinery (`vmSetEntry`, `vmWalk`). Right answer
   once ACPI is load-bearing.
3. **Raise `MAP_2MIB_PAGES`.** Tempting and wrong: it is a boot-time constant that would have to
   exceed the largest machine anyone ever boots, and M7's own accounting (`m7-frames` asserts
   `boot.S`'s identity map bound *equals* the allocator's bound) would need rework.

This hazard belongs to the SMP design too, since the MADT is in the same block.

### 6.4 FADT — measured field by field

Revision 1, 116 bytes. Every value below was read out of the running machine:

| field | offset | measured | used for |
|---|---|---|---|
| `FIRMWARE_CTRL` | 36 | `0x07FE0000` | — |
| `DSDT` | 40 | `0x07FE0040` | the `\_S5_` scan (§5.3) |
| `SCI_INT` | 46 | `0x09` | — (no SCI handling proposed) |
| `SMI_CMD` | 48 | `0xB2` | ACPI enable handshake |
| `ACPI_ENABLE` / `ACPI_DISABLE` | 52 / 53 | `0xF1` / `0xF0` | ” |
| `PM1a_EVT_BLK` | 56 | `0x600` | — |
| **`PM1a_CNT_BLK`** | 64 | **`0x604`** | **shutdown (§5.3)** |
| `PM1b_CNT_BLK` | 68 | `0x0` | absent — do not write it |
| **`PM_TMR_BLK`** | 76 | **`0x608`** | **monotonic time (§3.2)** |
| `GPE0_BLK` | 80 | `0xAFE0` | — |
| `PM1_CNT_LEN` | 89 | **`2`** | proves the 16-bit access width |
| `PM_TMR_LEN` | 91 | `4` | |
| **`CENTURY`** | 108 | **`0x32`** | **RTC century (§1.5)** |
| `FLAGS` | 112 | `0x80A5` | bit 8 `TMR_VAL_EXT` = **0** → 24-bit PM timer |
| `RESET_REG` | 116 | **does not exist** — table is 116 bytes | §5.4 |

### 6.5 MADT — measured, and what SMP gets from it

`Local APIC address = 0xFEE00000`, `flags = 0x1` (`PCAT_COMPAT`: the dual 8259 is present, which is
why everything in `interrupts.dart` works). With `-smp 4`:

```
type 0  Processor Local APIC   ×4   proc id 0..3, APIC id 0..3, flags=1 (enabled)
type 1  I/O APIC                    id 0, address 0xFEC00000, GSI base 0
type 2  Interrupt Source Override   bus 0: IRQ0→GSI2 (flags 0), IRQ5→5, IRQ9→9, IRQ10→10, IRQ11→11
                                    (the last four flags 0x0D = active low, level triggered)
type 4  Local APIC NMI              all processors (0xFF), LINT1
```

With no `-smp`, exactly one type-0 entry. So the MADT is a complete and accurate CPU inventory here,
and **the `IRQ0 → GSI 2` override is exactly the fact an I/O APIC-based timer route needs and the one
that is silently wrong if you assume identity mapping of ISA IRQs to GSIs.** That is the SMP agent's
business; it is recorded here because this walk is what produces it.

### 6.6 Storage and shape

One `@bss` block, `acpiStore`, ~128 bytes, holding: a validity word, the RSDP/RSDT/FADT/MADT/HPET/DSDT
addresses, `PM1a_CNT_BLK`, `PM_TMR_BLK`, the century index, the resolved `SLP_TYPa`, and the table
count. Same seam pattern as `fatStore`, `procStore` and `pmmStore` (M17, ADR-0021) — one symbol, a
small accessor pair, and the structural check that several harnesses already apply to donated `.bss`
sizes will need its number updated.

Roughly 250 lines of DCDart in a new `core/kernel/acpi.dart`, zero new assembly, zero new externs.

### 6.7 What this is not

No AML interpreter — and the `_S5_` byte-scan of §5.3 is emphatically not one. No SCI handling, no
GPE dispatch, no `_PTS`/`_GTS` evaluation before sleep, no power-button event, no thermal zones, no
device enumeration from the namespace (PCI enumeration stays with `pci.dart`'s `0xCF8`/`0xCFC` walk,
ADR-0008). No DSDT/SSDT parsing beyond the byte scan. No XSDT path exercised, because QEMU's revision-0
RSDP never reaches it — which means that code path would be **written and never executed**, and it
should be labelled as such rather than counted as tested.

---

## 7. The milestone ladder

Each rung has binary exit criteria. Host-side verification uses three things, all demonstrated in
Appendix A: the **QEMU process exit status**, the **QMP `SHUTDOWN` event** (`guest` and `reason`
fields), and **QMP `query-status`** for the live state before termination. Where a criterion says
"derived", it means the harness computes the expectation from the machine rather than having it
typed — the discipline `m7-frames` and `m18-preempt` already follow.

### T1 — The machine can turn itself off, and one harness proves it

*Smallest possible first step. No ACPI, no tables, no new assembly.*

1. `core/kernel/power.dart` exists and `powerDebugExit(u64 status)` is exactly one `Port.outb` to
   `0xF4` followed by an unreachable halt; a structural check asserts it is the only write to that
   port in the linked kernel.
2. `m0-boot/run.sh` passes `-device isa-debug-exit,iobase=0xf4,iosize=0x04` and requires
   `QEMU_STATUS == 33`. Status 124 is a FAILURE with its own message, distinct from a byte mismatch.
3. `m0`'s serial golden is **byte-identical** to today's, verified by the harness's existing
   comparison, unchanged.
4. A negative control: a kernel built with the status changed to `0x11` makes the harness fail, and
   the reported status is **35**.
5. The harness prints its own QEMU wall time and it is under 2 s, where the current floor is a hard
   5 s.

### T2 — Every driverless harness stops depending on `timeout`

1. `m1-interrupts` and `mb-info` both assert `QEMU_STATUS == 33`.
2. **`m1`'s 544-byte golden is byte-identical**, and the seventeen harnesses that assert it as a
   prefix are re-run unchanged and unchanged in result. This is the criterion that matters; the exit
   call is placed after the last `uartWrite` in the fault path precisely so it can be met.
3. The UART TEMT flush (§5.5) is present and a structural check finds it on the path to every exit.
4. Mutation: a kernel that halts one line before its exit is killed by the status check with the
   message "the guest never reached its exit point", *before* any byte comparison runs.

### T3 — A wall clock, and a date a golden can assert

1. `core/kernel/rtc.dart` exists; `rtcNow()` returns Unix seconds; a `date` command prints
   `DATE YYYY-MM-DD HH:MM:SS UTC`.
2. The UIP protocol is the two-agreeing-reads form, both spins are **bounded**, and exhaustion prints
   a diagnostic naming the register. Structural check: no unbounded loop in `rtc.dart`.
3. **Two boots of the same kernel binary**: `-rtc base=2026-08-23T12:00:00,clock=vm` must print
   `DATE 2026-08-23 12:00:` and `-rtc base=1999-12-31T23:58:00,clock=vm` must print
   `DATE 1999-12-31 23:58:`. The second boot is what proves the **century register is read** rather
   than 20 assumed — measured to read `0x19`/`0x99` under that base.
4. BCD detection reads Status B; a structural check asserts the binary branch exists, and the
   documentation states plainly that on QEMU it is **never executed** (Status B measured `0x02`).
5. Everything else in both captures is byte-identical to the pre-T3 golden, so the only new bytes are
   the `date` line — and the seconds field is excluded from the comparison with a stated reason.

### T4 — Monotonic time, and three unbounded waits become bounded

1. `pitInit` writes `0x34` (mode 2). `M1 TICKS 0000000000000064` is unchanged in all 20 goldens; a
   harness check reads the mode byte back out of the compiled code.
2. `pitElapsed()` returns sub-tick PIT counts and is proven monotonic across a tick boundary: 1000
   consecutive samples, no decrease, asserted by the guest and reported as a count.
3. IRQ0 is unmasked from boot (`0xFC`). `ticks` prints `TICKS +0010 LIVE`. The `m3-shell` and
   `m4-fault` goldens change by **exactly the deletion of bytes 6–23 of that line** and by nothing
   else — checked mechanically, not by eye.
4. `uptime` prints milliseconds; two boots print **different** values while every other byte of both
   captures is identical.
5. `ataWait`'s bound becomes a real time bound expressed in microseconds; `m6-disk`'s existing
   disassembly check for the bound is updated and still passes.
6. A measured number this suite cannot currently produce: **ticks lost during one disk read**, printed
   by the guest as the difference between `tick_count()`'s delta and `pitElapsed()`'s. This is the
   measurement `blocking-and-threads.md` §2.4 asks for.

### T5 — The ACPI tables, and the harness re-derives them independently

1. An `acpi` command prints: the RSDP address and revision, the RSDT address, and one line per table
   giving signature, address, length and a checksum verdict.
2. **The harness derives the same set itself** — via QMP `pmemsave` of the low BIOS area and of the
   table region, re-parsed in Python — and requires an exact match, address for address and length for
   length. Nothing is typed. (Demonstrated working: Appendix A.4.)
3. The FADT fields of §6.4 are printed and matched against the harness's own parse, including
   `PM1a_CNT_BLK`, `PM_TMR_BLK`, `PM1_CNT_LEN` and `CENTURY`.
4. The revision-0 path is exercised and the extended checksum is **not** applied — proven by the fact
   that QEMU's RSDP (36-byte sum = 94) is accepted.
5. A **256 MiB boot** either maps the tables or refuses with a diagnostic naming the unreachable
   address. Whichever it does, the harness asserts it. This is the measured hazard of §6.3 and it must
   be closed on the rung that creates it.
6. The MADT is printed in full — CPU count, APIC ids, I/O APIC address, every override — and matched
   against the harness's parse on a `-smp 1` boot **and** a `-smp 4` boot from the same binary.

### T6 — ACPI shutdown and reboot, and seventeen harnesses migrate

1. `shutdown` writes `SLP_TYPa << 10 | SLP_EN` to the **FADT-supplied** `PM1a_CNT_BLK` with a 16-bit
   write. Host-side proof: QMP records `SHUTDOWN {guest: true, reason: "guest-shutdown"}` and QEMU
   exits **0**.
2. `reboot` writes `0xCF9`. Host-side proof: `SHUTDOWN {guest: true, reason: **"guest-reset"**}`. The
   harness asserts the **reason string**, which is what distinguishes the two paths.
3. Mutation: a build whose FADT parse yields `PM1a_CNT_BLK = 0` must **refuse** with a diagnostic, not
   write to port 0. Killed by the refusal's own sentence.
4. The FADT length check guards `RESET_REG` — a build that reads offset 116 of a 116-byte table is
   caught by a source-level check, since the machine cannot demonstrate it.
5. `qmp-drive.py` gains `--expect-guest-exit`; all seventeen QMP harnesses use it, stop sending `quit`,
   and assert `QEMU_STATUS == 33`.
6. `shellStrHelp` moves **once** for all four new commands (`date`, `uptime`, `shutdown`, `reboot`);
   the five goldens containing help text and the two `check_table shellStrHelp` sites are updated in
   the same change, and the M1 544-byte prefix is unchanged in every one of them.
7. Across the whole suite, **exit status 124 is a failure everywhere**, and no `run.sh` contains the
   phrase "expected termination path" any more.

### T7 — HPET and TSC (optional; the criteria include when not to bother)

1. `hpet` prints the capability register, the derived period and the counter, read through an
   `@extern` (not a `Pointer` load) — with a structural check that no `Pointer` load of the HPET base
   exists, since that is the GAP-0006 trap.
2. The harness derives `10 ns` from the ACPI HPET table it dumped itself and requires the guest's
   number to match.
3. `tsc` prints a frequency calibrated against the PM timer; two calibrations 100 ms apart agree
   within 1 %, and CPUID leaf `0x80000007` bit 8 is reported rather than assumed.
4. **The falsifier for building this rung at all**: a *measured* failure attributable to 838 ns being
   too coarse. Absent that, T7 stays unbuilt and this section is the record of why.

---

## 8. What I did not decide, and would rather be told

* **Whether the PIT should move to 1000 Hz.** It moves no golden (§4.3) and it costs ten times the VM
  exits under TCG. It is a scheduler-latency question, and the scheduler's designer should answer it.
* **Timezones.** FAT timestamps are local time by specification; this OS has UTC and no timezone
  database. I propose recording UTC in the local-time field and filing the inaccuracy. The alternative
  — a fixed offset constant — is worse, because it is a lie that looks like a configuration.
* **Whether `shutdown` should be reachable from ring 3.** A syscall that ends the machine with a
  status derived from a *program's* exit code would let a real test runner live in userland, which is
  attractive and is a policy decision (which programs may? what happens to open write descriptors?)
  rather than a mechanism decision. `fileReleaseOwner` already flushes on teardown, so the mechanism
  is closer than the policy.
* **Whether the RTC should ever be written.** Setting the clock is four port writes. Nothing needs it,
  and a `date --set` that does not persist across a QEMU restart is a toy.
* **Whether `M1 TICKS` should keep its leading count at all** once time is real. It costs nothing to
  keep and it is one of the oldest bytes in the repo.

---

## 9. Notes for the coordinator to fold in elsewhere

**Cross-document dependencies:**

* `blocking-and-threads.md` **B1 depends on T4.** Its §1.8 requires the timer to run while a session
  is idle; that is §2.3 here, including the two-golden change. Sequence T4 before B1 or B1 stalls.
* `blocking-and-threads.md` §2.4's falsifier ("PIT latch for sub-tick elapsed time — one new function,
  no new hardware") **is T4 criterion 2**, and it needs the mode-3-to-mode-2 change to be exact.
  Neither document had that detail before.
* The SMP design **depends on T5** for the MADT, and **inherits T5's 256 MiB addressing hazard**
  (§6.3). Both designs should reference the same measurement.
* `fat.dart`'s zero timestamps (GAP-0127 item 4) **are closed by T3**, and `m16-filewrite`'s
  `derive.py` must gain the FAT date/time prediction at the same time — it cannot be deferred, because
  the image comparison is byte-exact.

**Gaps these milestones would close:**

* **GAP-0001**, final paragraph ("there is no `timeout`-free shutdown path … every harness still ends
  by letting `timeout` kill QEMU") — closed by T1/T2/T6.
* **GAP-0058** ("the PIT is masked at rest … it waits without a timeout") — cost 1 closed by T4,
  cost 2 (the unbounded wait) closed by T4 criterion 5.
* **GAP-0072** ("a wall-clock bound needs a clock, and the only one this kernel has is the PIT, which
  is masked at rest … `rdtsc` needs a DCDart primitive it does not have") — closed by T4, and note
  that the gap's own suggestion of `rdtsc` turns out to be the *expensive* answer: the PIT latch it
  also names is the cheap one.
* **GAP-0127 item 4** (no timestamps) — closed by T3.

**Gaps these milestones would open, and that should be filed rather than discovered:**

1. **No AML interpreter, and never will be.** `SLP_TYPa` comes from a byte scan of the DSDT for
   `_S5_`, which is not parsing. Name the failure mode: a DSDT that expresses `_S5_` in a form the
   scan does not recognise gets the fallback, and the fallback is a refusal.
2. **The RSDP is found only by scanning.** Multiboot1 carries no ACPI tag (Multiboot2 does), so if a
   real bootloader ever replaces the `-kernel` path (GAP-0001's remaining open item), the RSDP should
   come from the boot protocol instead.
3. **The XSDT path is written and never executed** on QEMU, whose RSDP is revision 0. Untested code
   that looks tested is worse than absent code.
4. **ACPI tables can sit outside the identity map** (§6.3) — a measured fact with an existing harness
   that triggers it.
5. **MMIO is mapped cacheable.** Already GAP-0071; HPET makes it matter for a *counter* rather than a
   framebuffer, which is a stronger case.
6. **FAT timestamps are UTC in a local-time field** (§1.7).
7. **The RTC seconds field is not assertable**, so goldens assert date/hour/minute only (§1.7).

---

## Appendix A — every measurement, and how to reproduce it

Host: macOS, `qemu-system-x86_64` **11.0.0**, default machine `pc-i440fx-11.0`. QEMU's HMP `o`/`i`
commands write and read guest I/O ports, so every port-level fact below was produced **without
building a kernel**. Note the HMP size suffixes: `b` = 1 byte, **`h` = 2 bytes**, `w` = **4** bytes.
Using `w` where `h` was meant is why the first ACPI attempts appeared to do nothing.

**A.1 — `isa-debug-exit` status formula and access width**

```
printf 'o/b 0xf4 0x10\n' | qemu-system-x86_64 -machine pc -m 64 -display none \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 -monitor stdio -no-reboot
echo $?          # -> 33  ==  (0x10 << 1) | 1
```
A **one-byte** write to a device configured with `iosize=0x04` is accepted. With a QMP socket also
attached, the same run emits `SHUTDOWN {guest: true, reason: "guest-shutdown"}` before exiting.
`-device isa-debug-exit,help` reports defaults `iobase=1281` (0x501), `iosize=2`.

**A.2 — ACPI S5, and the access-width trap**

```
(sleep 3; printf 'i/h 0x604\n'; printf 'o/h 0x604 0x2000\n'; sleep 4) | \
  qemu-system-x86_64 -machine pc -m 64 -display none -monitor stdio -no-reboot
echo $?          # -> 0
```
`PM1a_CNT` reads `0x0000` (SCI_EN clear) and the S5 write still works. QMP records
`SHUTDOWN {guest: true, reason: "guest-shutdown"}`. The same write issued as a **4-byte** access
(`o/w`) does nothing at all — the register accepts 2-byte accesses only, consistent with
`PM1_CNT_LEN = 2`. Writing `ACPI_ENABLE` (`0xF1`) to `SMI_CMD` (`0xB2`) was measured **not** to set
`SCI_EN`, and is not required.

**A.3 — Reset paths, with `-no-reboot`**

```
o/b 0xcf9 0x06   ->  QEMU exit 0, SHUTDOWN {guest: true, reason: "guest-reset"}
o/b 0x64 0xfe    ->  QEMU exit 0, SHUTDOWN {guest: true, reason: "guest-reset"}
```

**A.4 — ACPI tables, dumped and decoded over QMP**

`pmemsave` writes guest physical memory to a host file, so the whole table walk can be done from the
host with no guest code — which is also exactly how T5's harness should verify the guest's own parse:

```
{"execute":"pmemsave","arguments":{"val":917504,"size":131072,"filename":"/tmp/low.bin"}}
```
Search that for `"RSD PTR "`, then `pmemsave` each table address it leads to. Results are in §6.2,
§6.4 and §6.5. `-m 128M` puts the RSDT at `0x07FE2328`; `-m 256M` puts it at `0x0FFE2328`. The RSDP is
at `0xF52E0` in both.

**A.5 — RTC registers under a pinned base**

```
-rtc base=2026-08-23T12:34:56,clock=vm
  0x00=0x58  0x02=0x34  0x04=0x12  0x07=0x23  0x08=0x08  0x09=0x26  0x0B=0x02  0x32=0x20

-rtc base=1999-12-31T23:58:00,clock=vm
  0x09=0x99  0x32=0x19  0x0B=0x02  0x0A=0x26
```
Read with `o/b 0x70 <reg>` followed by `i/b 0x71`. Status B `0x02` = BCD, 24-hour. The century
register tracks the pinned base, which is what makes T3's two-boot criterion possible.

**A.6 — QMP `query-status`**

```
{"execute":"query-status"} -> {"return":{"status":"running","running":true}}
```
Useful *before* termination. After a guest-initiated exit the process is gone and the socket closes,
so the post-mortem evidence is the `SHUTDOWN` event and the exit status — not a status query.

---

## Appendix B — repo facts this design depends on

| Fact | Where |
|---|---|
| PIT at 99.9985 Hz, command `0x36`, divisor `0x2E9C` | `core/kernel/interrupts.dart:296-313` |
| Tick counter in `isr.S` `.bss`, read via `@extern` because DC-IR loads are not volatile (DCDart GAP-0006) | `core/kernel/interrupts.dart:115-129` |
| Shell steady state masks IRQ0 (`0xFD`); `0xFC` unmasks it | `core/kernel/keyboard.dart:166-190` |
| `ticks` unmasks, waits `0x10`, re-masks | `core/kernel/shell.dart:1070-1095` |
| M18 unmasks IRQ0 per preemptive session; `procSessionTimerOff` re-masks at every exit | `core/kernel/proc.dart:2417-2436`, `1994-2007` |
| Identity map is 128 MiB, plus 3–4 GiB for the PCI hole | `core/boot/boot.S:96`, `:368-398` |
| `port_inw`/`port_outw`/`port_inl`/`port_outl` already exist; `Port.inb`/`outb` are DCDart's | `core/boot/portio.S` |
| `cpu_probe` is the precedent for reaching an instruction DCDart lacks | `core/boot/isr.S:82` |
| `qmp-drive.py` ends with `quit`; reused by 17 harnesses | `core/tests/conformance/m2-console/qmp-drive.py:297` |
| `shellStrHelp` is 2224 bytes, asserted by `check_table` in two harnesses, quoted in five goldens | `core/kernel/shell.dart:957`, `m10-elf/run.sh:503`, `m11-proc/run.sh:426` |
| `M1 TICKS 0000000000000064` appears in 20 golden files; `TICKS … +0010 LIVE` in 2 | `core/tests/conformance/*/expected*.txt` |
| Every harness passes `-no-reboot`; none passes `-no-shutdown` or `-rtc` | all 20 `run.sh` |
| The `@bss` storage-seam pattern for a new `acpiStore` | `core/kernel/fat.dart:866-885`, ADR-0021 |
