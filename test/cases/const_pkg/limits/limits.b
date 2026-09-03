package limits

// pub const is the point of the feature: a library exports compile-time
// values, and a consumer folds them exactly as if it had typed the literal.
pub const MAX_FRAME: int = 1 << 20
pub const NAME: string = "beans"
pub const FLAGS: int = (1 << 0) | (1 << 3)
