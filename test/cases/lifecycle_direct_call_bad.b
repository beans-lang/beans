class Conn {
    host: string
    hits: int = 0

    fn init(host: string) {
        self.host = host
    }

    fn deinit() {
        self.host = ""
    }
}

fn main() {
    let con: Conn = new Conn("llll")
    con.init("...")
    con.deinit()
}
