import std.io
import std.encoding.xml

@xml.name(value: "user")
@xml.naming(value: xml.Naming.camel_case)
struct XmlUser {
    @xml.attribute
    pub user_id: u64
    pub display_name: string
    pub active: bool
    pub delta: i8
    pub ratio: f32
    pub note: Option<string>
    pub age: Option<u16>
}

@xml.name(value: "message")
struct XmlMessage {
    @xml.attribute
    pub code: u16
    @xml.text
    pub body: string
}

fn from_text(text: string) -> Result<XmlUser> {
    return xml.decode(text)
}

fn from_bytes(data: Bytes) -> Result<XmlUser> {
    return xml.decode_bytes(data)
}

fn from_owned_bytes(move data: Bytes) -> Result<XmlUser> {
    return xml.decode_bytes_in_place(move data)
}

fn from_owned_text(text: string) -> Result<XmlUser> {
    let data: Bytes = Bytes.from(text)
    return from_owned_bytes(move data)
}

fn list_from_text(text: string) -> Result<List<XmlUser>> {
    return xml.decode(text)
}

fn from_text_with_options(text: string) -> Result<XmlUser> {
    var options: xml.Options = new xml.Options()
    options.allow_doctype = true
    return xml.decode_with_options(text, options)
}

fn message_with_space(text: string) -> Result<XmlMessage> {
    var options: xml.Options = new xml.Options()
    options.preserve_space_text = true
    return xml.decode_with_options(text, options)
}

fn show(label: string, result: Result<XmlUser>) {
    match result {
        ok(user) => {
            var note: string = "none"
            match user.note {
                some(value) => { note = value }
                none => {}
            }
            var age: int = -1
            match user.age {
                some(value) => { age = value as int }
                none => {}
            }
            io.println("{label}: {user.user_id} {user.display_name} {user.active} {user.delta} {user.ratio} {note} {age}")
        }
        err(error) => io.println("{label}: {error.kind}"),
    }
}

fn main() {
    show("text", from_text("<user userId=\"7\"><displayName>Ada</displayName><active>true</active><delta>-8</delta><ratio>1.5</ratio><note>ok</note><age>42</age></user>"))
    show("shuffled", from_text("<user userId=\"8\"><ratio>2</ratio><delta>0</delta><active>false</active><displayName>Lin</displayName></user>"))
    show("bytes", from_bytes(Bytes.from("<user userId=\"9\"><displayName>Jo</displayName><active>1</active><delta>127</delta><ratio>0.25</ratio></user>")))
    show("in place", from_owned_text("<user userId=\"13\"><displayName>Mia</displayName><active>true</active><delta>3</delta><ratio>0.5</ratio></user>"))
    show("unknown", from_text("<user userId=\"1\" extra=\"x\"><displayName>x</displayName><active>true</active><delta>0</delta><ratio>1</ratio></user>"))
    show("duplicate", from_text("<user userId=\"1\"><displayName>x</displayName><displayName>y</displayName><active>true</active><delta>0</delta><ratio>1</ratio></user>"))
    show("missing", from_text("<user userId=\"1\"><displayName>x</displayName><active>true</active><delta>0</delta></user>"))
    show("range", from_text("<user userId=\"1\"><displayName>x</displayName><active>true</active><delta>128</delta><ratio>1</ratio></user>"))
    show("exponent", from_text("<user userId=\"2\"><displayName>x</displayName><active>true</active><delta>1</delta><ratio>1e2</ratio></user>"))
    show("float range", from_text("<user userId=\"2\"><displayName>x</displayName><active>true</active><delta>1</delta><ratio>1e9999</ratio></user>"))
    show("root", from_text("<other userId=\"1\"><displayName>x</displayName><active>true</active><delta>0</delta><ratio>1</ratio></other>"))
    show("doctype default", from_text("<!DOCTYPE user><user userId=\"11\"><displayName>D</displayName><active>true</active><delta>1</delta><ratio>1</ratio></user>"))
    show("doctype option", from_text_with_options("<!DOCTYPE user><user userId=\"12\"><displayName>D</displayName><active>true</active><delta>1</delta><ratio>1</ratio></user>"))
    match list_from_text("<users><user userId=\"10\"><displayName>A</displayName><active>true</active><delta>1</delta><ratio>1</ratio></user><user userId=\"20\"><displayName>B</displayName><active>false</active><delta>2</delta><ratio>2</ratio><age>5</age></user></users>") {
        ok(users) => {
            var total: u64 = 0
            for user: XmlUser in users { total += user.user_id }
            io.println("list: {users.len()} {total}")
        }
        err(error) => io.println("list: {error.kind}"),
    }
    let message: Result<XmlMessage> = xml.decode("<message code=\"200\">hello &amp; bye</message>")
    match message {
        ok(value) => io.println("text field: {value.code} {value.body}"),
        err(error) => io.println("text field: {error.kind}"),
    }
    match message_with_space("<message code=\"201\">   </message>") {
        ok(value) => io.println("space text: {value.code} {value.body.len()}"),
        err(error) => io.println("space text: {error.kind}"),
    }
    let bad_list: Result<List<XmlUser>> = xml.decode("<users><other/></users>")
    match bad_list {
        ok(_) => io.println("bad list: accepted"),
        err(error) => io.println("bad list: {error.kind}"),
    }
    let bad_wrapper: Result<List<XmlUser>> = xml.decode("<users extra=\"x\"></users>")
    match bad_wrapper {
        ok(_) => io.println("bad wrapper: accepted"),
        err(error) => io.println("bad wrapper: {error.kind}"),
    }
}
