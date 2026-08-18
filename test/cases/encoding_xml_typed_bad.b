import std.encoding.xml

struct DuplicateElements {
    @xml.name(value: "same")
    pub first: int
    @xml.name(value: "same")
    pub second: int
}

struct DuplicateAttributes {
    @xml.attribute
    @xml.name(value: "same")
    pub first: int
    @xml.attribute
    @xml.name(value: "same")
    pub second: int
}

struct AttributeText {
    @xml.attribute
    @xml.text
    pub value: string
}

struct DuplicateText {
    @xml.text
    pub first: string
    @xml.text
    pub second: string
}

struct IgnoredRequired {
    @xml.ignore
    pub value: int
}

struct IgnoredDefault {
    @xml.ignore
    pub value: int = 0
}

struct DefaultedField {
    pub value: int = 0
}

@xml.name(value: "")
struct EmptyRoot {
    pub value: int
}

struct NestedList {
    pub values: List<List<int>>
}

class ClassTarget {
    pub value: int = 0
}

fn duplicate_elements(text: string) -> Result<DuplicateElements> {
    return xml.decode(text)
}

fn duplicate_attributes(text: string) -> Result<DuplicateAttributes> {
    return xml.decode(text)
}

fn attribute_text(text: string) -> Result<AttributeText> {
    return xml.decode(text)
}

fn duplicate_text(text: string) -> Result<DuplicateText> {
    return xml.decode(text)
}

fn ignored_required(text: string) -> Result<IgnoredRequired> {
    return xml.decode(text)
}

fn ignored_default(text: string) -> Result<IgnoredDefault> {
    return xml.decode(text)
}

fn defaulted(text: string) -> Result<DefaultedField> {
    return xml.decode(text)
}

fn empty_root(text: string) -> Result<EmptyRoot> {
    return xml.decode(text)
}

fn nested_list(text: string) -> Result<NestedList> {
    return xml.decode(text)
}

fn class_target(text: string) -> Result<ClassTarget> {
    return xml.decode(text)
}

fn scalar_target(text: string) -> Result<int> {
    return xml.decode(text)
}

fn scalar_list(text: string) -> Result<List<int>> {
    return xml.decode(text)
}

fn main() {}
