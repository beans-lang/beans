package main

class BindgenJson {
    kind: string
    text: string
    flag: bool
    items: List<BindgenJson>
    fields: Map<string, BindgenJson>

    fn init(kind: string) {
        self.kind = kind
        self.text = ""
        self.flag = false
        self.items = []
        self.fields = {}
    }

    fn get(name: string) -> Option<BindgenJson> {
        return self.fields.get(name)
    }

    fn string(name: string) -> string {
        match self.fields.get(name) {
            some(value) => {
                if value.kind == "string" {
                    return value.text
                }
            }
            none => {}
        }
        return ""
    }

    fn boolean(name: string) -> bool {
        match self.fields.get(name) {
            some(value) => {
                return value.kind == "bool" &&
                       value.flag
            }
            none => { return false }
        }
    }
}

class BindgenJsonParser {
    source: string
    index: int
    ok: bool

    fn init(source: string) {
        self.source = source
        self.index = 0
        self.ok = true
    }

    fn whitespace() {
        for self.index < self.source.len() {
            let byte: int =
                self.source.byte_at(self.index)
            if byte != 32 && byte != 9 &&
               byte != 10 && byte != 13 {
                break
            }
            self.index += 1
        }
    }

    fn peek() -> int {
        if self.index >= self.source.len() {
            return 0
        }
        return self.source.byte_at(self.index)
    }

    fn string_value() -> string {
        var result: string = ""
        self.index += 1
        for self.index < self.source.len() {
            let start: int = self.index
            let byte: int =
                self.source.byte_at(self.index)
            self.index += 1
            if byte == 34 { return result }
            if byte != 92 {
                result =
                    "{result}{self.source.slice(start, self.index)}"
                continue
            }
            if self.index >= self.source.len() {
                break
            }
            let escaped: int =
                self.source.byte_at(self.index)
            self.index += 1
            if escaped == 34 {
                result = "{result}\""
            } else if escaped == 92 {
                result = "{result}\\"
            } else if escaped == 47 {
                result = "{result}/"
            } else if escaped == 110 {
                result = "{result}\n"
            } else if escaped == 114 {
                result = "{result}\r"
            } else if escaped == 116 {
                result = "{result}\t"
            } else if escaped == 117 {
                if self.index + 4 <=
                   self.source.len() {
                    self.index += 4
                }
                result = "{result}?"
            } else {
                result =
                    "{result}{self.source.slice(self.index - 1, self.index)}"
            }
        }
        self.ok = false
        return result
    }

    fn value() -> BindgenJson {
        self.whitespace()
        if self.index >= self.source.len() {
            self.ok = false
            return new BindgenJson("null")
        }
        let byte: int = self.peek()
        if byte == 123 { return self.object() }
        if byte == 91 { return self.array() }
        if byte == 34 {
            let result: BindgenJson =
                new BindgenJson("string")
            result.text = self.string_value()
            return result
        }
        if self.source.slice(
               self.index,
               if self.index + 4 <=
                      self.source.len() {
                   self.index + 4
               } else {
                   self.source.len()
               }) == "true" {
            self.index += 4
            let result: BindgenJson =
                new BindgenJson("bool")
            result.flag = true
            return result
        }
        if self.source.slice(
               self.index,
               if self.index + 5 <=
                      self.source.len() {
                   self.index + 5
               } else {
                   self.source.len()
               }) == "false" {
            self.index += 5
            return new BindgenJson("bool")
        }
        if self.source.slice(
               self.index,
               if self.index + 4 <=
                      self.source.len() {
                   self.index + 4
               } else {
                   self.source.len()
               }) == "null" {
            self.index += 4
            return new BindgenJson("null")
        }
        let start: int = self.index
        for self.index < self.source.len() {
            let current: int =
                self.source.byte_at(self.index)
            if !((current >= 48 && current <= 57) ||
                 current == 45 || current == 43 ||
                 current == 46 || current == 101 ||
                 current == 69) {
                break
            }
            self.index += 1
        }
        if self.index == start {
            self.ok = false
            return new BindgenJson("null")
        }
        let result: BindgenJson =
            new BindgenJson("number")
        result.text =
            self.source.slice(start, self.index)
        return result
    }

    fn array() -> BindgenJson {
        let result: BindgenJson =
            new BindgenJson("array")
        self.index += 1
        self.whitespace()
        if self.peek() == 93 {
            self.index += 1
            return result
        }
        for self.ok {
            result.items.push(self.value())
            self.whitespace()
            if self.peek() == 44 {
                self.index += 1
                continue
            }
            if self.peek() == 93 {
                self.index += 1
                break
            }
            self.ok = false
        }
        return result
    }

    fn object() -> BindgenJson {
        let result: BindgenJson =
            new BindgenJson("object")
        self.index += 1
        self.whitespace()
        if self.peek() == 125 {
            self.index += 1
            return result
        }
        for self.ok {
            self.whitespace()
            if self.peek() != 34 {
                self.ok = false
                break
            }
            let key: string = self.string_value()
            self.whitespace()
            if self.peek() != 58 {
                self.ok = false
                break
            }
            self.index += 1
            result.fields[key] = self.value()
            self.whitespace()
            if self.peek() == 44 {
                self.index += 1
                continue
            }
            if self.peek() == 125 {
                self.index += 1
                break
            }
            self.ok = false
        }
        return result
    }
}

fn bindgen_find(text: string,
                wanted: string) -> int {
    match text.find(wanted) {
        some(index) => { return index }
        none => { return -1 }
    }
}

fn bindgen_rfind(text: string,
                 wanted: string) -> int {
    match text.rfind(wanted) {
        some(index) => { return index }
        none => { return -1 }
    }
}

fn bindgen_has_kind(node: BindgenJson,
                    wanted: string) -> bool {
    if node.string("kind") == wanted { return true }
    match node.get("inner") {
        some(inner) => {
            for child: BindgenJson in inner.items {
                if bindgen_has_kind(child, wanted) {
                    return true
                }
            }
        }
        none => {}
    }
    return false
}
