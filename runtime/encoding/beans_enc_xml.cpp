// std.encoding.xml native bridge over pugixml (vendored, see
// vendor/VENDOR.md). Compiled as C++17 with no exceptions, no RTTI, no STL
// and no XPath; beans_enc_cxx_shim.h supplies the two C++ runtime symbols the
// object still references, so programs link through the plain C driver.
//
// ABI shape (shared by every encoding bridge): payload buffers cross as
// direct RawPtr parameters and everything else — lengths, flags, handles,
// outputs — rides in a RawPtr<u64> request buffer. Interpreter compatibility
// forces the split: both interpreters hand extern "C" calls a real host copy
// of each RawPtr *argument*, but a pointer smuggled through an integer word
// would be a synthetic interpreter address no C code can dereference.
// Handles this bridge itself returned (documents, nodes, write buffers) are
// opaque words and safe to embed.
//
// Handles crossing the ABI:
//   - a document handle is a heap pugi::xml_document*
//   - a node handle is pugi's internal xml_node_struct*, reconstructed with
//     the public explicit constructor; valid while the document is alive
//   - attributes never cross as handles: they are packed out in bulk
//
// Security: pugixml expands only the five built-in XML entities and numeric
// character references. It has no external-entity mechanism, never touches
// the filesystem or network during parsing, and this bridge rejects DOCTYPE
// by default; opting in only stores the doctype text as an inert node.

#include "beans_enc_common.h"
#include "beans_enc_cxx_shim.h"

#define PUGIXML_NO_XPATH
#define PUGIXML_NO_STL
#define PUGIXML_NO_EXCEPTIONS
#include "vendor/pugixml/pugixml.cpp"

// Node kinds shared with xml.b.
enum {
    BEANS_XML_ELEMENT = 1,
    BEANS_XML_TEXT = 2,
    BEANS_XML_CDATA = 3,
    BEANS_XML_COMMENT = 4,
    BEANS_XML_PI = 5,
    BEANS_XML_DECLARATION = 6,
    BEANS_XML_DOCTYPE = 7,
};

// Parse option bits shared with xml.b.
enum {
    BEANS_XML_ALLOW_DOCTYPE = 1,
    BEANS_XML_PRESERVE_SPACE_TEXT = 2,
};

static int beans_enc_xml_kind_of(pugi::xml_node_type type) {
    switch (type) {
    case pugi::node_element: return BEANS_XML_ELEMENT;
    case pugi::node_pcdata: return BEANS_XML_TEXT;
    case pugi::node_cdata: return BEANS_XML_CDATA;
    case pugi::node_comment: return BEANS_XML_COMMENT;
    case pugi::node_pi: return BEANS_XML_PI;
    case pugi::node_declaration: return BEANS_XML_DECLARATION;
    case pugi::node_doctype: return BEANS_XML_DOCTYPE;
    default: return 0;
    }
}

static pugi::xml_node beans_enc_xml_node_of(uint64_t word) {
    return pugi::xml_node((pugi::xml_node_struct*)(uintptr_t)word);
}

// Byte offset of the first "<!DOCTYPE" in the input, for the rejection
// message; XML requires the keyword in upper case.
static uint64_t beans_enc_xml_doctype_offset(const char* text, size_t len) {
    static const char needle[] = "<!DOCTYPE";
    const size_t needle_len = sizeof(needle) - 1;
    if (len < needle_len) return 0;
    const char* cursor = text;
    size_t remaining = len;
    while (remaining >= needle_len) {
        const char* hit = (const char*)memchr(cursor, '<', remaining - needle_len + 1);
        if (!hit) return 0;
        if (memcmp(hit, needle, needle_len) == 0) return (uint64_t)(hit - text);
        remaining = (size_t)(len - (size_t)(hit - text) - 1);
        cursor = hit + 1;
    }
    return 0;
}

static size_t beans_enc_xml_pack_words(size_t len) { return (len + 7) / 8; }

static size_t beans_enc_xml_pack_string(uint64_t* out, size_t index,
                                        const char* text, size_t len) {
    out[index++] = (uint64_t)len;
    size_t words = beans_enc_xml_pack_words(len);
    if (words) {
        out[index + words - 1] = 0;
        memcpy(&out[index], text, len);
        index += words;
    }
    return index;
}

extern "C" {

// req[0]=text len, req[1]=option bits
// out: req[2]=doc handle, req[3]=document root node handle,
//      req[4]=pugixml parse status (vendored 1.16's enum values, rendered
//      into messages by xml.b so both backends print identical text),
//      req[5]=error byte offset
// Returns BEANS_ENC_OK, BEANS_ENC_ERR_DOCTYPE, or BEANS_ENC_ERR_INVALID.
BEANS_ENC_API long long beans_enc_xml_parse(unsigned char* src, uint64_t* req) {
    size_t len = (size_t)req[0];
    uint64_t options = req[1];
    req[2] = 0;
    req[3] = 0;
    req[4] = 0;
    req[5] = 0;
    unsigned int flags = pugi::parse_default | pugi::parse_comments |
                         pugi::parse_pi | pugi::parse_declaration |
                         pugi::parse_doctype;
    if (options & BEANS_XML_PRESERVE_SPACE_TEXT) flags |= pugi::parse_ws_pcdata;
    pugi::xml_document* doc = (pugi::xml_document*)malloc(sizeof(pugi::xml_document));
    if (!doc) return BEANS_ENC_ERR_MEMORY;
    new (doc) pugi::xml_document();
    // load_buffer copies the input into the document's own buffer: it reads
    // exactly `len` bytes and never assumes a NUL terminator.
    pugi::xml_parse_result outcome =
        doc->load_buffer(src, len, flags, pugi::encoding_auto);
    if (!outcome) {
        req[4] = (uint64_t)outcome.status;
        req[5] = (uint64_t)outcome.offset;
        doc->~xml_document();
        free(doc);
        return BEANS_ENC_ERR_INVALID;
    }
    if (!(options & BEANS_XML_ALLOW_DOCTYPE)) {
        for (pugi::xml_node child = doc->first_child(); child;
             child = child.next_sibling()) {
            if (child.type() == pugi::node_doctype) {
                req[5] = beans_enc_xml_doctype_offset((const char*)src, len);
                doc->~xml_document();
                free(doc);
                return BEANS_ENC_ERR_DOCTYPE;
            }
        }
    }
    // pugixml happily parses fragments with several top-level elements; a
    // well-formed XML document has exactly one. 17 extends the vendored
    // status enum, rendered by xml.b.
    {
        int elements = 0;
        for (pugi::xml_node child = doc->first_child(); child;
             child = child.next_sibling()) {
            if (child.type() == pugi::node_element) elements++;
        }
        if (elements > 1) {
            req[4] = 17;
            doc->~xml_document();
            free(doc);
            return BEANS_ENC_ERR_INVALID;
        }
    }
    req[2] = (uint64_t)(uintptr_t)doc;
    req[3] = (uint64_t)(uintptr_t)doc->internal_object();
    return BEANS_ENC_OK;
}

BEANS_ENC_API long long beans_enc_xml_new_doc(void) {
    pugi::xml_document* doc = (pugi::xml_document*)malloc(sizeof(pugi::xml_document));
    if (!doc) return 0;
    new (doc) pugi::xml_document();
    return (long long)(uintptr_t)doc;
}

BEANS_ENC_API long long beans_enc_xml_doc_root(long long doc_word) {
    pugi::xml_document* doc = (pugi::xml_document*)(uintptr_t)doc_word;
    if (!doc) return 0;
    return (long long)(uintptr_t)doc->internal_object();
}

BEANS_ENC_API long long beans_enc_xml_free_doc(long long doc_word) {
    pugi::xml_document* doc = (pugi::xml_document*)(uintptr_t)doc_word;
    if (!doc) return BEANS_ENC_OK;
    doc->~xml_document();
    free(doc);
    return BEANS_ENC_OK;
}

BEANS_ENC_API long long beans_enc_xml_node_kind(long long node_word) {
    return beans_enc_xml_kind_of(beans_enc_xml_node_of((uint64_t)node_word).type());
}

// Byte length of the node's name (empty for kinds with no name).
BEANS_ENC_API long long beans_enc_xml_name_len(long long node_word) {
    return (long long)strlen(beans_enc_xml_node_of((uint64_t)node_word).name());
}

// Copies the name into dst, sized from name_len.
BEANS_ENC_API long long beans_enc_xml_name_copy(long long node_word,
                                                unsigned char* dst) {
    const char* name = beans_enc_xml_node_of((uint64_t)node_word).name();
    memcpy(dst, name, strlen(name));
    return BEANS_ENC_OK;
}

// Byte length of the node's value. Element nodes report 0; their text lives
// in child text/CDATA nodes, order preserved.
BEANS_ENC_API long long beans_enc_xml_value_len(long long node_word) {
    return (long long)strlen(beans_enc_xml_node_of((uint64_t)node_word).value());
}

BEANS_ENC_API long long beans_enc_xml_value_copy(long long node_word,
                                                 unsigned char* dst) {
    const char* value = beans_enc_xml_node_of((uint64_t)node_word).value();
    memcpy(dst, value, strlen(value));
    return BEANS_ENC_OK;
}

BEANS_ENC_API long long beans_enc_xml_child_count(long long node_word) {
    pugi::xml_node node = beans_enc_xml_node_of((uint64_t)node_word);
    long long count = 0;
    for (pugi::xml_node child = node.first_child(); child;
         child = child.next_sibling()) {
        count++;
    }
    return count;
}

// Writes every child node handle into out[0..n) in document order; the
// caller sized `out` from child_count. Mixed content keeps its order.
BEANS_ENC_API long long beans_enc_xml_children(long long node_word, uint64_t* out) {
    pugi::xml_node node = beans_enc_xml_node_of((uint64_t)node_word);
    size_t index = 0;
    for (pugi::xml_node child = node.first_child(); child;
         child = child.next_sibling()) {
        out[index++] = (uint64_t)(uintptr_t)child.internal_object();
    }
    return BEANS_ENC_OK;
}

BEANS_ENC_API long long beans_enc_xml_attr_count(long long node_word) {
    pugi::xml_node node = beans_enc_xml_node_of((uint64_t)node_word);
    long long count = 0;
    for (pugi::xml_attribute attr = node.first_attribute(); attr;
         attr = attr.next_attribute()) {
        count++;
    }
    return count;
}

// Word count of the packed attribute stream: per attribute,
// [name byte length][name words...][value byte length][value words...].
BEANS_ENC_API long long beans_enc_xml_attrs_words(long long node_word) {
    pugi::xml_node node = beans_enc_xml_node_of((uint64_t)node_word);
    long long words = 0;
    for (pugi::xml_attribute attr = node.first_attribute(); attr;
         attr = attr.next_attribute()) {
        words += 2;
        words += (long long)beans_enc_xml_pack_words(strlen(attr.name()));
        words += (long long)beans_enc_xml_pack_words(strlen(attr.value()));
    }
    return words;
}

// Packs every attribute into `out` in declaration order; the caller sized
// `out` from attrs_words.
BEANS_ENC_API long long beans_enc_xml_attrs_pack(long long node_word, uint64_t* out) {
    pugi::xml_node node = beans_enc_xml_node_of((uint64_t)node_word);
    size_t index = 0;
    for (pugi::xml_attribute attr = node.first_attribute(); attr;
         attr = attr.next_attribute()) {
        index = beans_enc_xml_pack_string(out, index, attr.name(),
                                          strlen(attr.name()));
        index = beans_enc_xml_pack_string(out, index, attr.value(),
                                          strlen(attr.value()));
    }
    return BEANS_ENC_OK;
}

// ---- building ----

// req[0]=doc, req[1]=parent node (0 = document root), req[2]=kind,
// req[3]=name byte length, req[4]=value byte length
// out: req[5]=new node handle.
// Elements use name; text/CDATA/comment use value; processing instructions
// use both; declarations ignore both (version/encoding ride as attributes).
BEANS_ENC_API long long beans_enc_xml_append_node(unsigned char* name,
                                                  unsigned char* value,
                                                  uint64_t* req) {
    pugi::xml_document* doc = (pugi::xml_document*)beans_enc_ptr(req, 0);
    if (!doc) return BEANS_ENC_ERR_INVALID;
    pugi::xml_node parent = req[1] ? beans_enc_xml_node_of(req[1])
                                   : pugi::xml_node(doc->internal_object());
    uint64_t kind = req[2];
    size_t name_len = (size_t)req[3];
    size_t value_len = (size_t)req[4];
    req[5] = 0;

    // pugixml stores names and values as NUL-terminated strings, so an
    // embedded NUL cannot survive the round trip; refuse it rather than
    // silently truncating. XML forbids the NUL character anyway.
    if (name_len && memchr(name, 0, name_len)) return BEANS_ENC_ERR_INVALID;
    if (value_len && memchr(value, 0, value_len)) return BEANS_ENC_ERR_INVALID;

    pugi::xml_node_type type;
    switch (kind) {
    case BEANS_XML_ELEMENT: type = pugi::node_element; break;
    case BEANS_XML_TEXT: type = pugi::node_pcdata; break;
    case BEANS_XML_CDATA: type = pugi::node_cdata; break;
    case BEANS_XML_COMMENT: type = pugi::node_comment; break;
    case BEANS_XML_PI: type = pugi::node_pi; break;
    case BEANS_XML_DECLARATION: type = pugi::node_declaration; break;
    default: return BEANS_ENC_ERR_TYPE;
    }
    pugi::xml_node node = parent.append_child(type);
    if (!node) return BEANS_ENC_ERR_TYPE;
    if (kind == BEANS_XML_ELEMENT || kind == BEANS_XML_PI) {
        char* copy = (char*)malloc(name_len + 1);
        if (!copy) return BEANS_ENC_ERR_MEMORY;
        memcpy(copy, name, name_len);
        copy[name_len] = 0;
        bool named = node.set_name(copy);
        free(copy);
        if (!named) return BEANS_ENC_ERR_INVALID;
    }
    if (kind == BEANS_XML_TEXT || kind == BEANS_XML_CDATA ||
        kind == BEANS_XML_COMMENT || kind == BEANS_XML_PI) {
        char* copy = (char*)malloc(value_len + 1);
        if (!copy) return BEANS_ENC_ERR_MEMORY;
        memcpy(copy, value, value_len);
        copy[value_len] = 0;
        bool set = node.set_value(copy);
        free(copy);
        if (!set) return BEANS_ENC_ERR_INVALID;
    }
    req[5] = (uint64_t)(uintptr_t)node.internal_object();
    return BEANS_ENC_OK;
}

// req[0]=node, req[1]=name byte length, req[2]=value byte length.
// Appends in declaration order; the Beans layer decides duplicate policy.
BEANS_ENC_API long long beans_enc_xml_set_attr(unsigned char* name,
                                               unsigned char* value,
                                               uint64_t* req) {
    pugi::xml_node node = beans_enc_xml_node_of(req[0]);
    size_t name_len = (size_t)req[1];
    size_t value_len = (size_t)req[2];
    if (name_len && memchr(name, 0, name_len)) return BEANS_ENC_ERR_INVALID;
    if (value_len && memchr(value, 0, value_len)) return BEANS_ENC_ERR_INVALID;
    char* name_copy = (char*)malloc(name_len + 1);
    char* value_copy = (char*)malloc(value_len + 1);
    if (!name_copy || !value_copy) {
        free(name_copy);
        free(value_copy);
        return BEANS_ENC_ERR_MEMORY;
    }
    memcpy(name_copy, name, name_len);
    name_copy[name_len] = 0;
    memcpy(value_copy, value, value_len);
    value_copy[value_len] = 0;
    pugi::xml_attribute attr = node.append_attribute(name_copy);
    long long status = BEANS_ENC_OK;
    if (!attr || !attr.set_value(value_copy)) status = BEANS_ENC_ERR_INVALID;
    free(name_copy);
    free(value_copy);
    return status;
}

// A malloc-backed growing sink for pugixml's writer interface.
struct BeansEncXmlBuffer : pugi::xml_writer {
    char* data = NULL;
    size_t len = 0;
    size_t cap = 0;
    bool failed = false;

    void write(const void* chunk, size_t size) override {
        if (failed) return;
        if (len + size > cap) {
            size_t next = cap ? cap * 2 : 1024;
            while (next < len + size) next *= 2;
            char* grown = (char*)realloc(data, next);
            if (!grown) {
                failed = true;
                return;
            }
            data = grown;
            cap = next;
        }
        memcpy(data + len, chunk, size);
        len += size;
    }
};

// req[0]=doc, req[1]=mode (0 raw/compact, 1 indented), req[2]=indent len
// out: req[3]=buffer handle (claim with take_buf), req[4]=byte len
BEANS_ENC_API long long beans_enc_xml_write(unsigned char* indent, uint64_t* req) {
    pugi::xml_document* doc = (pugi::xml_document*)beans_enc_ptr(req, 0);
    uint64_t mode = req[1];
    size_t indent_len = (size_t)req[2];
    req[3] = 0;
    req[4] = 0;
    if (!doc) return BEANS_ENC_ERR_INVALID;
    char indent_copy[17];
    unsigned int flags;
    if (mode == 0) {
        flags = pugi::format_raw;
        indent_copy[0] = 0;
    } else {
        flags = pugi::format_indent;
        if (indent_len > 16) return BEANS_ENC_ERR_RANGE;
        memcpy(indent_copy, indent, indent_len);
        indent_copy[indent_len] = 0;
    }
    BeansEncXmlBuffer buffer;
    doc->save(buffer, indent_copy, flags, pugi::encoding_utf8);
    if (buffer.failed) {
        free(buffer.data);
        return BEANS_ENC_ERR_MEMORY;
    }
    req[3] = (uint64_t)(uintptr_t)buffer.data;
    req[4] = (uint64_t)buffer.len;
    return BEANS_ENC_OK;
}

// Copies a write buffer into dst (sized from the write's length) and frees
// the buffer. The handle is dead after this call, success or not.
BEANS_ENC_API long long beans_enc_xml_take_buf(long long buf_word, long long len,
                                               unsigned char* dst) {
    char* text = (char*)(uintptr_t)buf_word;
    if (!text) return BEANS_ENC_ERR_INVALID;
    memcpy(dst, text, (size_t)len);
    free(text);
    return BEANS_ENC_OK;
}

} // extern "C"
