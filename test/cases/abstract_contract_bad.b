abstract class Base {
    abstract fn value() -> int
}

class Missing extends Base {}

class NoOverride extends Base {
    fn value() -> int { return 1 }
}

interface Named {
    fn label() -> string
}

class MissingInterface implements Named {}

fn main() {
    let bad: Base = new Base()
}
