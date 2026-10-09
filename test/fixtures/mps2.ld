/* MPS2 boots from CODE at 0; startup copies initialized data from CODE to SRAM. */







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
