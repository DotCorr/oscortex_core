/* core/boot-arm/boot.S
 *
 * aarch64 virt entry for A1. QEMU `-M virt -kernel` jumps here at EL1
 * already (arm64-port.md STEP 2 / STEP 3): no Multiboot header, no
 * 32→64 transition, no GDT, no page tables. The x86 `core/boot/boot.S`
 * is not rewritten; this file is the parallel path.
 *
 * Shape: set a stack, `bl kmain`, PSCI SYSTEM_OFF. `kmain` is @bare
 * DCDart (core/arch/aarch64/kmain_virt.dart). `hvc` cannot come from
 * DCDart today (arm64-port.md STEP 5, mrs/msr/hvc gap).
 */

    .section .text
    .global _start
    .global psci_system_off
    .extern kmain

_start:
    ldr     x1, =boot_stack_top
    mov     sp, x1
    bl      kmain
    /* fall through if kmain returns without calling psci_system_off */

psci_system_off:
    /* PSCI 0.2 SYSTEM_OFF, 32-bit SMC/HVC calling convention.
       virt's /psci node is method = "hvc"; QEMU implements it at EL1. */
    ldr     w0, =0x84000008
    hvc     #0
1:
    wfi
    b       1b

    .section .bss
    .align  16
boot_stack:
    .skip   4096
boot_stack_top:
