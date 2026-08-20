interface Shape {}
class Base {}
class WrongBase extends Shape {}
class WrongInterface implements Base {}
interface WrongExtends extends Base {}
class BuiltinBase extends Bytes {
    fn init() {
        super.init(8)
    }
}

class CycleA extends CycleB {
    a: int
    fn init() {
        self.a = 1
        super.init()
    }
}
class CycleB extends CycleA {
    b: int
    fn init() {
        self.b = 1
        super.init()
    }
}
