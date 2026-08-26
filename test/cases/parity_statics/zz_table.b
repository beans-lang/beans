package main

struct Step {
    pub size: int = 0
}

fn step(size: int) -> Step {
    Built.count += 1
    return Step { size: size }
}

class Built {
    static count: int = 0
}

// the table shape: entries built once, before main
class Gap {
    static s1: Step = step(4)
    static s2: Step = step(8)
    static s3: Step = step(12)
}
