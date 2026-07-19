/*
 * API19 static-bionic TLS alignment anchor.
 *
 * Android NDK clang lowers C __thread to emulated TLS for this target, which
 * cannot affect the ELF PT_TLS segment. This genuine TLS section is aligned to
 * 64 bytes so lld emits PT_TLS p_align >= 32, as required by the static bionic
 * startup code linked into the daemon.
 */
    .section .tdata,"awT",%progbits
    .balign 64
    .global lmw_tls_alignment_anchor
    .type lmw_tls_alignment_anchor,%object
lmw_tls_alignment_anchor:
    .word 0
    .size lmw_tls_alignment_anchor, .-lmw_tls_alignment_anchor
