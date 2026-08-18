import std.encoding.xml

@xml.name(value: "user")
@xml.naming(value: xml.Naming.camel_case)
@xml.allow_unknown
struct ContractUser {
    @xml.attribute
    pub user_id: u64

    @xml.name(value: "label")
    pub display_name: string

    pub active: bool
    pub score: Option<f32>
}

@xml.name(value: "message")
struct ContractMessage {
    @xml.attribute
    pub code: u16

    @xml.text
    pub body: string
}

fn from_text(text: string) -> Result<ContractUser> {
    return xml.decode(text)
}

fn from_bytes(data: Bytes) -> Result<ContractUser> {
    return xml.decode_bytes(data)
}

fn rows(text: string) -> Result<List<ContractUser>> {
    return xml.decode(text)
}

fn message(text: string) -> Result<ContractMessage> {
    return xml.decode(text)
}

fn with_options(text: string) -> Result<ContractUser> {
    return xml.decode_with_options(text, new xml.Options())
}

fn main() {}
