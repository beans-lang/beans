package main

import std.io

// 60 captured strings ride shared cells across the annex chain;
// the trailing ints are by-value candidates whose indexes cross
// bit 63, where the per-instruction value mask ends and the
// capture falls back to a cell. The program's exit is half the
// test: releasing the chained environment must tear down clean.
fn main() {
    let s0: string = "v0"
    let s1: string = "v1"
    let s2: string = "v2"
    let s3: string = "v3"
    let s4: string = "v4"
    let s5: string = "v5"
    let s6: string = "v6"
    let s7: string = "v7"
    let s8: string = "v8"
    let s9: string = "v9"
    let s10: string = "v10"
    let s11: string = "v11"
    let s12: string = "v12"
    let s13: string = "v13"
    let s14: string = "v14"
    let s15: string = "v15"
    let s16: string = "v16"
    let s17: string = "v17"
    let s18: string = "v18"
    let s19: string = "v19"
    let s20: string = "v20"
    let s21: string = "v21"
    let s22: string = "v22"
    let s23: string = "v23"
    let s24: string = "v24"
    let s25: string = "v25"
    let s26: string = "v26"
    let s27: string = "v27"
    let s28: string = "v28"
    let s29: string = "v29"
    let s30: string = "v30"
    let s31: string = "v31"
    let s32: string = "v32"
    let s33: string = "v33"
    let s34: string = "v34"
    let s35: string = "v35"
    let s36: string = "v36"
    let s37: string = "v37"
    let s38: string = "v38"
    let s39: string = "v39"
    let s40: string = "v40"
    let s41: string = "v41"
    let s42: string = "v42"
    let s43: string = "v43"
    let s44: string = "v44"
    let s45: string = "v45"
    let s46: string = "v46"
    let s47: string = "v47"
    let s48: string = "v48"
    let s49: string = "v49"
    let s50: string = "v50"
    let s51: string = "v51"
    let s52: string = "v52"
    let s53: string = "v53"
    let s54: string = "v54"
    let s55: string = "v55"
    let s56: string = "v56"
    let s57: string = "v57"
    let s58: string = "v58"
    let s59: string = "v59"
    let n0: int = 1
    let n1: int = 2
    let n2: int = 3
    let n3: int = 4
    let n4: int = 5
    let n5: int = 6
    let n6: int = 7
    let n7: int = 8
    let n8: int = 9
    let n9: int = 10
    let n10: int = 11
    let n11: int = 12
    let n12: int = 13
    let n13: int = 14
    let n14: int = 15
    let f: fn() -> int = fn() -> int {
        return s0.len() +
            s1.len() +
            s2.len() +
            s3.len() +
            s4.len() +
            s5.len() +
            s6.len() +
            s7.len() +
            s8.len() +
            s9.len() +
            s10.len() +
            s11.len() +
            s12.len() +
            s13.len() +
            s14.len() +
            s15.len() +
            s16.len() +
            s17.len() +
            s18.len() +
            s19.len() +
            s20.len() +
            s21.len() +
            s22.len() +
            s23.len() +
            s24.len() +
            s25.len() +
            s26.len() +
            s27.len() +
            s28.len() +
            s29.len() +
            s30.len() +
            s31.len() +
            s32.len() +
            s33.len() +
            s34.len() +
            s35.len() +
            s36.len() +
            s37.len() +
            s38.len() +
            s39.len() +
            s40.len() +
            s41.len() +
            s42.len() +
            s43.len() +
            s44.len() +
            s45.len() +
            s46.len() +
            s47.len() +
            s48.len() +
            s49.len() +
            s50.len() +
            s51.len() +
            s52.len() +
            s53.len() +
            s54.len() +
            s55.len() +
            s56.len() +
            s57.len() +
            s58.len() +
            s59.len() +
            n0 +
            n1 +
            n2 +
            n3 +
            n4 +
            n5 +
            n6 +
            n7 +
            n8 +
            n9 +
            n10 +
            n11 +
            n12 +
            n13 +
            n14
    }
    io.println("first {f()}")
    io.println("second {f()}")
}
