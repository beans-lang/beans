/* RISC-V `virt` under QEMU, booted with -bios none.
 *
 * One region: QEMU loads the ELF into DRAM at 0x80000000 and jumps to the entry point, so
 * nothing has to be copied out of flash. The __data_* symbols still exist because the
 * startup code is shared with the Cortex-M board — here the copy is a no-op, which costs
 * one comparison and keeps the two boards on one code path.
 */
MEMORY {
    DRAM (rwx) : ORIGIN = 0x80000000, LENGTH = 64M
}

ENTRY(_start)

SECTIONS {
    .text : {
        KEEP(*(.text.start))
        *(.text .text.*)
        *(.rodata .rodata.*)
    } > DRAM

    .data : {
        . = ALIGN(8);
        __data_start__ = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        . = ALIGN(8);
        __data_end__ = .;
    } > DRAM
    __data_load__ = LOADADDR(.data);

    .bss (NOLOAD) : {
        . = ALIGN(8);
        __bss_start__ = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end__ = .;
    } > DRAM

    /* The RISC-V calling convention requires a 16-byte-aligned stack pointer. */
    . = ALIGN(16);
    __stack_top__ = ORIGIN(DRAM) + LENGTH(DRAM);

    /DISCARD/ : {
        *(.comment)
        *(.riscv.attributes)
    }
}
