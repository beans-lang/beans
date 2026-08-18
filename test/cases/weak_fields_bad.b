class Solo {
    weak count: Option<int> = none
    weak plain: Solo = new Solo()
    static weak shared: Option<Solo> = none
}

unique class Pipe {}

class Holder {
    weak line: Option<Pipe> = none
}

struct Point {
    weak buddy: Option<Solo>
}
