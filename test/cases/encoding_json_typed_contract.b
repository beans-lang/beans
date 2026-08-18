// Public typed-JSON declarations and imported tool annotations.

import std.encoding.json

@json.naming(value: json.Naming.camel_case)
@json.allow_unknown
struct ContractUser {
    @json.name(value: "user_id")
    pub id: u64

    @json.alias(value: ["display_name_legacy", "full_name"])
    pub display_name: string

    @json.ignore
    pub cached_name: string = ""

    pub signature: string
}

fn from_text(text: string) -> Result<ContractUser> {
    return json.decode(text)
}

fn from_bytes(data: Bytes) -> Result<ContractUser> {
    return json.decode_bytes(data)
}

fn from_owned_bytes(move data: Bytes) -> Result<ContractUser> {
    return json.decode_bytes_in_place(move data)
}

fn with_options(text: string) -> Result<ContractUser> {
    let options: json.DecodeOptions = new json.DecodeOptions()
    return json.decode_with_options(text, options)
}

fn unwrap_at_call(text: string) -> Result<u64> {
    let user: ContractUser = json.decode(text)?
    return ok(user.id)
}

fn main() {}
