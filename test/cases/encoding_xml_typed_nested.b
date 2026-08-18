import std.encoding.xml
import std.io

@xml.namespace(value: "urn:geo")
struct Coordinates {
    pub lat: float
    @xml.name(value: "long")
    pub longitude: float
}

@xml.namespace(value: "urn:store")
struct Storage {
    @xml.attribute
    pub kind: string
    @xml.text
    pub capacity: float
}

@xml.namespace(value: "urn:store")
struct Stock {
    @xml.attribute
    pub location: string
    @xml.text
    pub quantity: u64
}

@xml.namespace(value: "urn:store")
struct Product {
    @xml.attribute
    pub sku: string
    @xml.name(value: "tag")
    pub tags: List<string>
    pub storage: Option<Storage>
    @xml.name(value: "connectivity")
    pub connectivity: Option<List<string>>
    pub note: Option<string>
    @xml.name(value: "stock")
    pub stock: List<Stock>
    @xml.namespace(value: "urn:geo")
    pub coordinates: Coordinates
}

@xml.name(value: "payload")
@xml.namespace(value: "urn:store")
struct Payload {
    @xml.attribute
    pub id: string
    @xml.name(value: "product")
    pub products: List<Product>
    @xml.name(value: "label")
    pub store_label: string
    @xml.name(value: "label")
    @xml.namespace(value: "urn:geo")
    pub geo_label: string
}

fn show(text: string) {
    let decoded: Result<Payload> = xml.decode(text)
    match decoded {
        ok(payload) => {
            io.println("{payload.id}: {payload.products.len()}")
            io.println("labels={payload.store_label},{payload.geo_label}")
            for product: Product in payload.products {
                io.println("{product.sku}: tags={product.tags.len()} stock={product.stock.len()} geo={product.coordinates.lat},{product.coordinates.longitude}")
                match product.storage {
                    some(value) => io.println("storage={value.kind}:{value.capacity}"),
                    none => io.println("storage=none"),
                }
                match product.connectivity {
                    some(value) => io.println("connectivity={value.len()}"),
                    none => io.println("connectivity=none"),
                }
                match product.note {
                    some(value) => io.println("note={value}"),
                    none => io.println("note=none"),
                }
            }
        }
        err(error) => io.println("error: {error.kind}"),
    }
}

fn main() {
    show("<a:payload xmlns:a=\"urn:store\" xmlns:s=\"urn:store\" xmlns:g=\"urn:geo\" id=\"fleet\"><s:product sku=\"LAP\"><s:tag>fast</s:tag><s:tag>portable</s:tag><s:storage kind=\"SSD\">1</s:storage><s:note>ready</s:note><s:stock location=\"east\">4</s:stock><s:stock location=\"west\">2</s:stock><g:coordinates><g:lat>2.7</g:lat><g:long>101.7</g:long></g:coordinates></s:product><a:product sku=\"MOUSE\"><a:tag>wireless</a:tag><a:connectivity>Bluetooth</a:connectivity><a:connectivity>2.4GHz</a:connectivity><g:coordinates><g:lat>3</g:lat><g:long>102</g:long></g:coordinates></a:product><s:label>store</s:label><g:label>geo</g:label></a:payload>")
    show("<x:payload xmlns:x=\"urn:wrong\" id=\"bad\"/>")
}
