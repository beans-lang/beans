import std.encoding.json

struct DuplicateNames {
    @json.name(value: "same")
    pub first: int
    @json.alias(value: ["same"])
    pub second: int
}

struct IgnoredRequired {
    @json.ignore
    pub value: int
}

struct WrongBytesAnnotation {
    @json.bytes(value: json.BytesFormat.array)
    pub value: int
}

@json.naming(value: json.Naming.snake_case)
struct SnakeCollision {
    pub userName: string
    pub user_name: string
}

struct RecursiveNode {
    pub children: List<RecursiveNode>
}

enum PayloadEvent {
    value(number: int)
}

struct PayloadHolder {
    pub event: PayloadEvent
}

struct DefaultedField {
    pub value: int = 1
}

struct BytesField {
    pub value: Bytes
}

struct NestedListField {
    pub values: List<List<int>>
}

struct ChildField {
    pub value: int
}

struct IgnoredWithNested {
    pub child: ChildField

    @json.ignore
    pub cache: string = ""
}

class ClassTarget {
    pub value: int = 0
}

fn duplicate(text: string) -> Result<DuplicateNames> {
    return json.decode(text)
}

fn ignored(text: string) -> Result<IgnoredRequired> {
    return json.decode(text)
}

fn bytes_annotation(text: string) -> Result<WrongBytesAnnotation> {
    return json.decode(text)
}

fn snake_collision(text: string) -> Result<SnakeCollision> {
    return json.decode(text)
}

fn recursive(text: string) -> Result<RecursiveNode> {
    return json.decode(text)
}

fn payload(text: string) -> Result<PayloadHolder> {
    return json.decode(text)
}

fn class_value(text: string) -> Result<ClassTarget> {
    return json.decode(text)
}

fn map_keys(text: string) -> Result<Map<int, string>> {
    return json.decode(text)
}

fn unsupported_result(text: string) -> Result<Result<int>> {
    return json.decode(text)
}

fn defaulted(text: string) -> Result<DefaultedField> {
    return json.decode(text)
}

fn bytes_field(text: string) -> Result<BytesField> {
    return json.decode(text)
}

fn nested_list(text: string) -> Result<NestedListField> {
    return json.decode(text)
}

fn ignored_with_nested(text: string) -> Result<IgnoredWithNested> {
    return json.decode(text)
}

fn encode_scalar() -> Result<string> {
    return json.encode(1)
}

fn main() {}
