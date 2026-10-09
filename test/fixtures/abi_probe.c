// Compare target-specific aggregate returns with the portable i64-plus-output-pointer ABI.
















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
