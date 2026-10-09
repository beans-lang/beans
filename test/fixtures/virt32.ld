/* QEMU virt loads the ELF at 0x80000000; shared startup's .data copy is a no-op. */






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
