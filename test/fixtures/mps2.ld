/* ARM MPS2-AN386 (Cortex-M4) under QEMU.
 *
 * Two regions, as on the real board: code and read-only data are placed in the ZBT SRAM
 * at address 0, which is where the CPU fetches its vector table out of reset, and writable
 * data lives in the SRAM at 0x20000000. .data is *loaded* into the first and *runs* from
 * the second, which is why the startup code copies it — the three __data_* symbols below
 * are what it copies between.
 */
MEMORY {
    CODE (rx)  : ORIGIN = 0x00000000, LENGTH = 4M
    SRAM (rwx) : ORIGIN = 0x20000000, LENGTH = 4M
}

ENTRY(vectors)

SECTIONS {
    /* The vector table has to be the first thing at address 0: the CPU loads word 0 into
     * the stack pointer and jumps to word 1 without executing anything first. */
    .vectors : {
        KEEP(*(.vectors))
    } > CODE

    .text : {
        *(.text .text.*)
        *(.rodata .rodata.*)
    } > CODE

    .data : {
        . = ALIGN(8);
        __data_start__ = .;
        *(.data .data.*)
        . = ALIGN(8);
        __data_end__ = .;
    } > SRAM AT > CODE
    __data_load__ = LOADADDR(.data);

    .bss (NOLOAD) : {
        . = ALIGN(8);
        __bss_start__ = .;
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end__ = .;
    } > SRAM

    /* The stack grows down from the top of SRAM. AAPCS wants 8 at a public interface;
     * giving it 16 costs nothing and matches what the C entry expects. */
    . = ALIGN(16);
    __stack_top__ = ORIGIN(SRAM) + LENGTH(SRAM);

    /DISCARD/ : {
        *(.ARM.exidx*)
        *(.ARM.attributes)
        *(.comment)
    }
}
