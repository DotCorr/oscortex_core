/* core/boot/portio.S
 *
 * oscortex_core M5: 16- AND 32-BIT PORT I/O -- the four instructions DCDart's
 * `Port` class does not have.
 *
 * WHY THIS FILE EXISTS (and why it is not a design choice)
 * ------------------------------------------------------------------
 * DCDart's port-I/O primitive (its ADR-0029) is `Port.outb(u16, u8)` /
 * `Port.inb(u16) -> u8` and nothing else. It is BYTE-WIDE ONLY. The legacy PCI
 * configuration mechanism is defined in terms of a 32-BIT write to the address
 * register at 0xCF8 followed by a 32-bit access at 0xCFC -- PCI Local Bus
 * Specification 3.0 §3.2.2.3.2 is explicit that CONFIG_ADDRESS is only
 * decoded for a full doubleword access, so four byte writes are not a legal
 * substitute for one `outl`, on real hardware or in principle.
 *
 * That makes `outl`/`inl` exactly the same KIND of thing as `cpuid`, `lidt`,
 * `int3` and `div`: an instruction with no DCDart primitive, reached across
 * the ordinary C ABI. It goes in assembly for the reason OSCORTEX_SPEC.md §5's
 * table gives for all of those, not because a workaround was convenient.
 *
 * IT IS ALSO A NARROW DCDart LANGUAGE GAP, AND IS FILED AS ONE.
 * docs/known-gaps.md GAP-0066 records the real ask: `Port.outl`/`Port.inl`
 * (and `outw`/`inw`) in DCDart, which is precisely ADR-0029's shape one width
 * wider -- a handful of lines in the same lowering path, not a new subsystem.
 * When that lands, this file is deleted and the `@extern` declarations in
 * core/kernel/pci.dart become `Port.outl`/`Port.inl` calls. CLAUDE.md rule 3
 * says language needs are RECORDED here and BUILT there; this file is what
 * standing still would have cost, and it is deliberately two instructions
 * wide so that the deletion is mechanical.
 *
 * WHY A SEPARATE OBJECT rather than more of isr.S: isr.S is interrupt entry
 * and the privileged instructions the interrupt path needs; kdata.S is donated
 * mutable storage. This is neither -- it is a missing language primitive,
 * standing in for one, and naming the file after that keeps the workaround
 * legible and its size countable, the same argument kdata.S's own header
 * makes. It has NO undefined symbols and no data of its own, so it passes
 * `verify-freestanding.sh` standalone, exactly as kdata.o does
 * (docs/known-gaps.md GAP-0056).
 *
 * THE PROTOCOL IS NOT HERE. Composing an address out of bus/device/function
 * /offset, writing 0xCF8 and reading 0xCFC is all in core/kernel/pci.dart, in
 * DCDart, where it can be read. This file provides the INSTRUCTION and nothing
 * else -- the same division CLAUDE.md rule 3 asks for ("one port-I/O
 * primitive, not general inline asm").
 */
.section .text
.code64

/* uint64_t port_inl(uint64_t port)
 *
 * `in` takes its port in DX (the immediate form only reaches ports 0..255, and
 * 0xCF8/0xCFC are well past that), so the argument is moved to EDX first. The
 * 32-bit `inl` writes EAX, which zero-extends into RAX by the x86-64 rule that
 * any 32-bit destination write clears the upper half -- so the u64 this
 * returns has a defined, zero, high half without an explicit widening. */
.align 16
.global port_inl
.type port_inl, @function
port_inl:
    movl %edi, %edx               /* port (arg 0) -> DX */
    inl (%dx), %eax               /* 32-bit read; high half of RAX cleared */
    ret

/* void port_outl(uint64_t port, uint64_t value)
 *
 * Same addressing constraint as above. Only the low 32 bits of `value` are
 * written, which is the whole point -- a caller that wants a byte still uses
 * DCDart's own Port.outb. */
.align 16
.global port_outl
.type port_outl, @function
port_outl:
    movl %edi, %edx               /* port  (arg 0) -> DX */
    movl %esi, %eax               /* value (arg 1) -> EAX */
    outl %eax, (%dx)
    ret

/* uint64_t port_inw(uint64_t port)
 *
 * 16-bit port read. Added for the Bochs VBE (dispi) interface at 0x1CE/0x1CF,
 * whose index and data registers QEMU registers as 2-byte-only ports -- a byte
 * access there is not narrowed, it is simply not decoded, so a mode set built
 * on `Port.outb` would write nothing and report no error.
 *
 * The 16-bit `in` writes AX, which leaves the upper 48 bits of RAX ALONE (only
 * a 32-bit destination write zero-extends), so RAX is zeroed first. Without
 * that this would return the requested halfword ORed with whatever the caller
 * happened to leave in RAX -- a bug that would be invisible for any value
 * whose high bits are already zero, which is most of them. */
.align 16
.global port_inw
.type port_inw, @function
port_inw:
    movl %edi, %edx               /* port (arg 0) -> DX */
    xorl %eax, %eax               /* clear RAX: `inw` writes only AX */
    inw (%dx), %ax
    ret

/* void port_outw(uint64_t port, uint64_t value)
 *
 * 16-bit port write; only the low 16 bits of `value` are written. */
.align 16
.global port_outw
.type port_outw, @function
port_outw:
    movl %edi, %edx               /* port  (arg 0) -> DX */
    movl %esi, %eax               /* value (arg 1) -> EAX; only AX is used */
    outw %ax, (%dx)
    ret

/* Mark the stack non-executable (see kdata.S for the full note). */
.section .note.GNU-stack,"",@progbits
