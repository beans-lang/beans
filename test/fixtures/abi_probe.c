// ABI probe — evidence for why the fallible-builtin boundary must not take a
// BRes/BOpt struct back from C.
//
// `probe_bres`/`probe_bopt` return the 16-byte aggregate by value, exactly as the
// runtime's BRes/BOpt-returning functions used to. How that return is lowered is a
// per-target C-ABI decision Clang makes — a register pair on SysV and AAPCS64, a
// hidden sret pointer on Win64/i686/ARMv7/s390x, and so on. That is precisely the
// fact the compiler must not hard-code, and hard-coding it (object_format==coff)
// produced broken IR on ARM64 Windows.
//
// `probe_bres_out`/`probe_bopt_out` are the portable form the generated code now
// calls: the raw value returned normally, the second word written through an
// output pointer. Their signature is `i64 (..., ptr)` on every target.
//
// test/abi_probe.sh compiles this for each supported triple and shows the first
// group's return ABI diverging while the `_out` group stays scalar everywhere.

typedef struct {
    long long val;
    void* err;
} BRes; // a Result: err null = ok

typedef struct {
    long long val;
    long long has;
} BOpt; // an Option: has 0 = none

// ---- the old boundary: aggregate return, ABI varies by target ----

BRes probe_bres(long long x) {
    BRes r;
    r.val = x + 1;
    r.err = 0;
    return r;
}

BOpt probe_bopt(long long x) {
    BOpt o;
    o.val = x + 1;
    o.has = 1;
    return o;
}

// ---- the new boundary: scalar value + output pointer, identical everywhere ----

long long probe_bres_out(long long x, void** err_out) {
    BRes r = probe_bres(x);
    *err_out = r.err;
    return r.val;
}

long long probe_bopt_out(long long x, long long* has_out) {
    BOpt o = probe_bopt(x);
    *has_out = o.has;
    return o.val;
}
