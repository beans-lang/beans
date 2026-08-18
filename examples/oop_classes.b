// Class-side OOP features: strict private fields, static state,
// abstract contracts, interface requirements, and one eager singleton.
import std.io

interface Named {
    fn name() -> string
}

abstract class Job {
    abstract fn run() -> int

    fn doubled() -> int {
        return self.run() * 2
    }
}

class BuildJob extends Job implements Named {
    static created: int = 0
    priv id: int

    priv static fn record_created() {
        BuildJob.created += 1
    }

    priv fn job_id() -> int {
        return self.id
    }

    fn init(id: int) {
        self.id = id
        BuildJob.record_created()
    }

    // Replacing an abstract class method needs override.
    override fn run() -> int {
        return self.job_id() + BuildJob.created
    }

    // A first implementation of a bodyless interface method does not.
    fn name() -> string {
        return "build-{self.id}"
    }
}

singleton class Registry {
    priv completed: int = 0

    fn record() -> int {
        self.completed += 1
        return self.completed
    }
}

fn main() {
    let first: BuildJob = new BuildJob(10)
    let second: BuildJob = new BuildJob(20)
    let job: Job = first

    io.println("{first.name()} {job.doubled()}")
    io.println("{second.name()} {BuildJob.created}")
    io.println("{Registry.instance.record()}")
    io.println("{Registry.instance.record()}")
}
