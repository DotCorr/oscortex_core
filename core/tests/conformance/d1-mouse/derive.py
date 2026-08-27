#!/usr/bin/env python3
"""core/tests/conformance/d1-mouse/derive.py

Computes, ON THE HOST AND BEFORE THE MACHINE BOOTS, every line D1's kernel must
print -- from the protocol, not from a previous run.

TWO INDEPENDENT MODELS, AND THAT IS THE POINT
---------------------------------------------------------------------------
`encode()` is what QEMU's emulated PS/2 mouse puts on the wire for a given
pointer event. `Pointer` is what a correct PS/2 mouse driver makes of a stream
of such bytes -- framing rule, resynchronisation, overflow discard, 9-bit sign
extension and all. Neither is a copy of `core/kernel/mouse.dart`; both are
written from the protocol, and the harness then requires the kernel to agree
with the pair.

If they were one model the check would be circular. If either were copied from
the kernel it would be a transcription check. They are separate because the
milestone's claim -- "the kernel decoded the movement it was given, exactly" --
is a claim about two things agreeing that were derived apart.

EVERY BYTE GOES THROUGH THE SAME STATE MACHINE
---------------------------------------------------------------------------
A `rel`/`btn` element is encoded into four bytes and then pushed through
`Pointer.byte()` one at a time, exactly as IRQ12 would; a `feed` element pushes
its bytes through the SAME function. So a script can interleave real device
motion with deliberately misaligned bytes and this file still knows, line for
line, what the transcript must contain -- including which packet is the WRONG
one a one-byte offset produces before the framing rule catches up.

THE AXIS AND CLAMP CONVENTIONS, WRITTEN DOWN RATHER THAN DISCOVERED
---------------------------------------------------------------------------
  * QEMU's `input-send-event` REL y is SCREEN-DOWN positive and reaches the
    emulated device as `mouse_dy -= value`, because a PS/2 mouse reports Y
    positive when it is pushed AWAY from the user. A downward motion therefore
    puts a NEGATIVE ninth-bit delta on the wire, and the driver must turn it
    back into an INCREASING row.
  * QEMU clamps each axis to +/-127 per packet and keeps sending packets until
    the accumulated motion drains. `encode()` REFUSES a bigger delta rather
    than letting a harness silently assert the first of two packets.
  * A wheel click is two QMP edges and therefore two packets: the down edge
    carries the Z delta, the up edge carries zero. `wheel-up` is Z = 0xFF
    (minus one) and `wheel-down` is Z = 0x01, and neither touches the button
    bits, because QEMU's button bitmap has no entry for the wheel.

Usage:
    derive.py <script-file> [--packet-size N]

`<script-file>` is one element per line:

    rel <dx> <dy>              a pointer motion, in screen units
    btn <name> <down|up>       a button edge; left, right, middle, wheel-up,
                               wheel-down
    feed <hex> [<hex> ...]     bytes pushed straight into the decoder, which is
                               what `mouse feed` does in the kernel
    state <label>              emit the regular expression the `mouse` command's
                               report must match at this point in the script

Blank lines and `#` comments are ignored. Output is `key=value` lines.
"""

import sys

WIDTH = 800
HEIGHT = 600

# QEMU's ps2.c button bitmap. The wheel "buttons" are NOT in it -- they carry a
# Z delta and leave the button bits alone -- and that asymmetry is why they are
# handled separately below rather than as another entry here.
BUTTON_BIT = {"left": 0x01, "right": 0x02, "middle": 0x04}
WHEEL_DZ = {"wheel-up": -1, "wheel-down": 1}


def encode(dx, dy, dz, buttons):
    """The four bytes QEMU's PS/2 mouse puts on the wire. Refuses a split."""
    if not (-127 <= dx <= 127 and -127 <= dy <= 127):
        raise SystemExit("derive: |delta| > 127 would be split into two packets "
                         "by QEMU's clamp; this harness asserts whole motions")
    mdx = dx
    mdy = -dy  # QEMU: mouse_dy -= value
    b0 = 0x08 | (buttons & 0x07)
    if mdx < 0:
        b0 |= 0x10
    if mdy < 0:
        b0 |= 0x20
    return [b0, mdx & 0xFF, mdy & 0xFF, dz & 0xFF]


class Pointer(object):
    """The driver, modelled from the protocol rather than from the kernel."""

    def __init__(self, packet_size):
        self.size = packet_size
        self.idx = 0
        self.b = [0, 0, 0, 0]
        self.x = 0
        self.y = 0
        self.btn = 0
        self.packets = 0
        self.syncs = 0
        self.overflows = 0
        self.wu = 0
        self.wd = 0

    def byte(self, v):
        """One byte of the stream. Returns the line it must produce, or None."""
        if self.idx == 0:
            # THE FRAMING RULE. Bit 3 of byte 0 is always one; a byte without it
            # cannot be a first byte, so it is discarded and the stream STAYS
            # WHERE IT IS -- consuming it as a first byte would keep the offset
            # forever.
            if not (v & 0x08):
                self.syncs += 1
                return "MOUSE SYNC %02X N %08X" % (v, self.syncs)
            self.b[0] = v
            self.idx = 1
            return None
        if self.idx == 1:
            self.b[1] = v
            self.idx = 2
            return None
        if self.idx == 2:
            self.b[2] = v
            if self.size > 3:
                self.idx = 3
                return None
            self.b[3] = 0
            self.idx = 0
            return self.complete()
        self.b[3] = v
        self.idx = 0
        return self.complete()

    def complete(self):
        b0, b1, b2, b3 = self.b
        # An overflowed packet is DISCARDED, not clamped: the byte that arrived
        # is the low eight bits of something larger and there is no way back.
        if b0 & 0xC0:
            self.overflows += 1
            return "MOUSE OVF %02X N %08X" % (b0, self.overflows)
        dxraw = b1 | (((b0 >> 4) & 1) << 8)
        dyraw = b2 | (((b0 >> 5) & 1) << 8)
        # 9-bit two's complement: THE NINTH BIT IS IN BYTE 0.
        if b0 & 0x10:
            self.x = max(0, self.x - (256 - b1))
        else:
            self.x = min(WIDTH - 1, self.x + b1)
        # A positive Y delta is AWAY from the user, which is UP the screen.
        if b0 & 0x20:
            self.y = min(HEIGHT - 1, self.y + (256 - b2))
        else:
            self.y = max(0, self.y - b2)
        self.btn = b0 & 0x07
        if b3:
            if b3 & 0x80:
                self.wu += 256 - b3
            else:
                self.wd += b3
        self.packets += 1
        return ("MOUSE PKT %X %02X %02X %02X %02X DX %03X DY %03X X %04X Y %04X B %X"
                % (self.size, b0, b1, b2, b3, dxraw, dyraw, self.x, self.y, self.btn))

    def state_regex(self):
        """The `mouse` report, with the two fields this file cannot know left
        open.

        IRQ and STRAY are counted by the HANDLER, not by the protocol: a
        spurious interrupt with an empty output buffer is a real event on real
        and emulated hardware alike, and asserting an exact IRQ count would make
        this harness fail for something that is not a defect. They are asserted
        as "present and hexadecimal" here and STRAY is asserted to be zero
        separately, because a non-zero stray count IS a defect worth naming.
        """
        return ("MOUSE STATE X %04X Y %04X B %X PKT %08X SYNC %08X OVF %08X "
                "IRQ [0-9A-F]{8} STRAY 00000000 SIZE %X ID [0-9A-F]{3} "
                "WU %04X WD %04X INIT [0-9A-F]{4}"
                % (self.x, self.y, self.btn, self.packets, self.syncs,
                   self.overflows, self.size, self.wu, self.wd))


def parse(path):
    out = []
    for raw in open(path):
        line = raw.split("#", 1)[0].strip()
        if line:
            out.append(line.split())
    return out


def main():
    argv = sys.argv[1:]
    size = 4
    if "--packet-size" in argv:
        i = argv.index("--packet-size")
        size = int(argv[i + 1])
        del argv[i:i + 2]
    if len(argv) != 1:
        raise SystemExit("usage: derive.py <script-file> [--packet-size N]")

    p = Pointer(size)
    buttons = 0
    lines = []
    states = []
    for parts in parse(argv[0]):
        kind = parts[0]
        if kind == "state":
            states.append((parts[1], p.state_regex()))
            continue
        if kind == "feed":
            stream = [int(h, 16) for h in parts[1:]]
        elif kind == "rel":
            stream = encode(int(parts[1]), int(parts[2]), 0, buttons)
        elif kind == "btn":
            name, edge = parts[1], parts[2]
            if name in BUTTON_BIT:
                if edge == "down":
                    buttons |= BUTTON_BIT[name]
                else:
                    buttons &= ~BUTTON_BIT[name]
                stream = encode(0, 0, 0, buttons)
            elif name in WHEEL_DZ:
                stream = encode(0, 0, WHEEL_DZ[name] if edge == "down" else 0,
                                buttons)
            else:
                raise SystemExit("derive: unknown button %r" % name)
        else:
            raise SystemExit("derive: unknown element %r" % kind)
        for v in stream:
            got = p.byte(v)
            if got is not None:
                lines.append(got)

    for i, l in enumerate(lines):
        print("line%d=%s" % (i, l))
    print("lines=%d" % len(lines))
    for label, rx in states:
        print("state_%s=%s" % (label, rx))
    print("packets=%d" % p.packets)
    print("syncs=%d" % p.syncs)
    print("overflows=%d" % p.overflows)
    print("final_x=%04X" % p.x)
    print("final_y=%04X" % p.y)
    print("final_b=%X" % p.btn)
    print("wu=%04X" % p.wu)
    print("wd=%04X" % p.wd)
    print("mid_stream=%d" % (1 if p.idx else 0))
    # What ring 3 must read back, packed as core/kernel/mouse.dart's
    # [mousePacked] documents: x | y<<16 | buttons<<32 | packets<<40.
    packed = ((p.x & 0xFFFF) | ((p.y & 0xFFFF) << 16) | ((p.btn & 0xFF) << 32)
              | ((p.packets & 0xFFFFFF) << 40))
    print("packed=%016X" % packed)
    print("exit_code=%016X" % (packed & 0xFFFFFFFFFF))
    print("count_field=%06X" % (p.packets & 0xFFFFFF))
    # The cursor's row-8 address, RELATIVE to the framebuffer base. run.sh adds
    # the base THE KERNEL REPORTED, because the base is SeaBIOS's business and
    # never this harness's assumption (m5-pci's rule).
    print("row8_offset=%X" % ((p.y + 8) * WIDTH * 4 + p.x * 4))
    # THE NEGATIVE CONTROL FOR THE SIGN EXTENSION. What the accumulated X would
    # be if the driver had sign-extended from BYTE 1's own high bit instead of
    # from byte 0's ninth bit -- the single easiest thing to get wrong in this
    # protocol. run.sh requires this value to be ABSENT from the transcript, and
    # the value above to be present, so the pair is not satisfiable by both.
    naive = 0
    q = Pointer(size)
    buttons = 0
    for parts in parse(argv[0]):
        if parts[0] == "state":
            continue
        if parts[0] == "feed":
            stream = [int(h, 16) for h in parts[1:]]
        elif parts[0] == "rel":
            stream = encode(int(parts[1]), int(parts[2]), 0, buttons)
        else:
            name, edge = parts[1], parts[2]
            if name in BUTTON_BIT:
                if edge == "down":
                    buttons |= BUTTON_BIT[name]
                else:
                    buttons &= ~BUTTON_BIT[name]
                stream = encode(0, 0, 0, buttons)
            else:
                stream = encode(0, 0, WHEEL_DZ[name] if edge == "down" else 0,
                                buttons)
        for v in stream:
            if q.idx == 0 and not (v & 0x08):
                q.syncs += 1
                continue
            q.b[q.idx] = v
            q.idx += 1
            if q.idx == size:
                q.idx = 0
                if q.b[0] & 0xC0:
                    continue
                b1 = q.b[1]
                naive = max(0, min(WIDTH - 1,
                                   naive + (b1 - 256 if b1 & 0x80 else b1)))
    print("naive_x=%04X" % naive)
    return 0


if __name__ == "__main__":
    sys.exit(main())
