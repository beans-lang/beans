interface Secret {
    priv fn hidden() -> int
}

abstract class AbstractSecret {
    priv abstract fn hidden() -> int
}

class BadOverride extends AbstractSecret {
    priv override fn hidden() -> int {
        return 1
    }
}

class MixedVisibility {
    pub priv fn hidden() -> int {
        return 2
    }
}

fn main() {}
