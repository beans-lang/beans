class Base {
    value: int = 0
    pub fn tune(n: int) -> Self {
        self.value = self.value + n
        return self
    }
    pub fn broken() -> Self {
        return new Base()
    }
}

class Concrete extends Base {
    pub override fn tune(n: int) -> Base {
        return self
    }
}

fn free_self() -> Self {
    return free_self()
}
