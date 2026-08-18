// std.encoding.xml native bridge over pugixml (vendored, see
// vendor/VENDOR.md). Compiled as C++17 with no exceptions, no RTTI, no STL
// and no XPath. beans_enc_pugixml_shim.h supplies the two C++ runtime
// symbols pugixml's writer vtable still references, so programs link
// through the plain C driver with no C++ standard library.
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
#include "beans_enc_pugixml_shim.h"

#define PUGIXML_NO_XPATH
#define PUGIXML_NO_STL
#define PUGIXML_NO_EXCEPTIONS
#include "vendor/pugixml/pugixml.cpp"

#include <errno.h>
#include <limits.h>
#include <math.h>

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

// Private compiler-generated typed XML ABI. All names and field offsets are
// read-only globals emitted for a concrete decode<T> use. No reflection data
// or field-name strings are allocated at runtime.
struct BeansXmlTypedKey {
    const char* name;
    uint64_t len;
    uint64_t field; // zero is an empty hash bucket; live values are index + 1
};

struct BeansXmlTypedSchema;

struct BeansXmlTypedField {
    uint64_t kind;
    uint64_t flags;
    uint64_t source;
    uint64_t value_offset;
    uint64_t presence_offset;
    const char* name;
    uint64_t name_len;
    uint64_t missing_value;
};

struct BeansXmlTypedComplex {
    const BeansXmlTypedSchema* child_schema;
    uint64_t element_kind;
    const BeansXmlTypedSchema* element_schema;
    uint64_t element_size;
    uint64_t element_pointer_mask;
    uint64_t box_size;
    uint64_t box_meta;
    uint64_t box_value_offset;
    const char* namespace_uri;
    uint64_t namespace_uri_len;
};

struct BeansXmlTypedSchema {
    uint64_t field_count;
    uint64_t flags;
    uint64_t record_size;
    uint64_t pointer_mask;
    const char* root_name;
    uint64_t root_name_len;
    uint64_t attribute_mask;
    uint64_t element_mask;
    const BeansXmlTypedKey* attribute_keys;
    const BeansXmlTypedKey* element_keys;
    const BeansXmlTypedField* fields;
    const char* root_namespace_uri;
    uint64_t root_namespace_uri_len;
    const BeansXmlTypedComplex* complex;
};

enum {
    BEANS_XML_TYPED_BOOL = 1,
    BEANS_XML_TYPED_SINT = 2,
    BEANS_XML_TYPED_UINT = 3,
    BEANS_XML_TYPED_F32 = 4,
    BEANS_XML_TYPED_F64 = 5,
    BEANS_XML_TYPED_STRING = 6,
    BEANS_XML_TYPED_STRUCT = 7,
    BEANS_XML_TYPED_LIST = 8,
};

enum {
    BEANS_XML_TYPED_OPTIONAL = 1,
    BEANS_XML_TYPED_DEFAULT = 2,
    BEANS_XML_TYPED_IGNORED = 4,
    BEANS_XML_TYPED_BOXED_OPTION = 8,
};

enum {
    BEANS_XML_TYPED_ELEMENT = 0,
    BEANS_XML_TYPED_ATTRIBUTE = 1,
    BEANS_XML_TYPED_TEXT = 2,
};

enum {
    BEANS_XML_TYPED_ALLOW_UNKNOWN = 1,
    BEANS_XML_TYPED_ROOT_LIST = 2,
    BEANS_XML_TYPED_HAS_LIST = 4,
    BEANS_XML_TYPED_HAS_NAMESPACES = 8,
};

enum {
    BEANS_XML_TYPED_ERR_ROOT = 101,
    BEANS_XML_TYPED_ERR_UNKNOWN = 102,
    BEANS_XML_TYPED_ERR_DUPLICATE = 103,
    BEANS_XML_TYPED_ERR_TYPE = 104,
    BEANS_XML_TYPED_ERR_RANGE = 105,
    BEANS_XML_TYPED_ERR_MISSING = 106,
};

typedef void* (*BeansXmlNewListFn)(long long, long long, long long);
typedef void* (*BeansXmlAllocFn)(long long, long long);
typedef void (*BeansXmlReleaseFn)(void*);

struct BeansXmlListPrefix {
    void* data;
    uint64_t len __attribute__((aligned(8)));
    uint64_t cap;
    int64_t stride;
    int64_t pointer_mask;
};

struct BeansXmlDecodeContext {
    BeansXmlNewListFn new_list;
    BeansXmlAllocFn allocate;
    BeansXmlReleaseFn release;
    uint64_t* req;
};

// Parse option bits shared with xml.b.
enum {
    BEANS_XML_ALLOW_DOCTYPE = 1,
    BEANS_XML_PRESERVE_SPACE_TEXT = 2,
    BEANS_XML_INPLACE = 4,
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

// True when pugixml will consume the buffer as UTF-8 (with or without a
// UTF-8 BOM), which is exactly when a reported offset is an offset into the
// caller's own bytes. UTF-16 and UTF-32 inputs are transcoded into an
// internal UTF-8 buffer first, so pugixml's offsets index that buffer and
// mean nothing to the caller; the bridge reports them as unavailable rather
// than as a wrong number. The detection mirrors pugixml's own
// guess_buffer_encoding: BOM first, then the byte pattern of a leading '<'.
static int beans_enc_xml_offsets_are_input_bytes(const unsigned char* src,
                                                 size_t len) {
    if (len >= 4) {
        if (src[0] == 0 && src[1] == 0 && src[2] == 0xfe && src[3] == 0xff) return 0;
        if (src[0] == 0xff && src[1] == 0xfe && src[2] == 0 && src[3] == 0) return 0;
    }
    if (len >= 2) {
        if (src[0] == 0xfe && src[1] == 0xff) return 0;
        if (src[0] == 0xff && src[1] == 0xfe) return 0;
    }
    if (len >= 4) {
        // UTF-32 without a BOM: '<' surrounded by three zero bytes.
        if (src[0] == 0 && src[1] == 0 && src[2] == 0 && src[3] == 0x3c) return 0;
        if (src[0] == 0x3c && src[1] == 0 && src[2] == 0 && src[3] == 0) return 0;
    }
    if (len >= 2) {
        // UTF-16 without a BOM: '<' beside one zero byte.
        if (src[0] == 0 && src[1] == 0x3c) return 0;
        if (src[0] == 0x3c && src[1] == 0) return 0;
    }
    return 1;
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

static uint64_t beans_xml_typed_hash(const char* text, size_t len,
                                     uint64_t mask) {
    uint64_t hash = 0;
    for (size_t index = 0; index < len; ++index)
        hash = ((hash << 5) + hash + (unsigned char)text[index]) & mask;
    return hash;
}

static const BeansXmlTypedKey* beans_xml_typed_find(
        const BeansXmlTypedKey* keys, uint64_t mask,
        const char* text, size_t len) {
    uint64_t slot = beans_xml_typed_hash(text, len, mask);
    for (uint64_t scanned = 0; scanned <= mask; ++scanned) {
        const BeansXmlTypedKey* key = &keys[slot];
        if (key->field == 0) return NULL;
        if (key->len == len && memcmp(key->name, text, len) == 0) return key;
        slot = (slot + 1) & mask;
    }
    return NULL;
}

static const char* beans_xml_local_name(const char* name, size_t* len) {
    const char* colon = (const char*)memchr(name, ':', *len);
    if (!colon) return name;
    size_t prefix = (size_t)(colon - name) + 1;
    *len -= prefix;
    return colon + 1;
}

static void beans_xml_namespace_uri(
        pugi::xml_node owner, const char* name, int attribute,
        const char** uri, size_t* uri_len) {
    size_t name_len = strlen(name);
    const char* colon = (const char*)memchr(name, ':', name_len);
    if (!colon && attribute) {
        *uri = "";
        *uri_len = 0;
        return;
    }
    const char* declaration = "xmlns";
    size_t declaration_len = 5;
    char local_declaration[256];
    if (colon) {
        size_t prefix_len = (size_t)(colon - name);
        if (prefix_len + 7 > sizeof(local_declaration)) {
            *uri = "";
            *uri_len = 0;
            return;
        }
        memcpy(local_declaration, "xmlns:", 6);
        memcpy(local_declaration + 6, name, prefix_len);
        local_declaration[6 + prefix_len] = 0;
        declaration = local_declaration;
        declaration_len = 6 + prefix_len;
    }
    for (pugi::xml_node scope = owner; scope; scope = scope.parent()) {
        for (pugi::xml_attribute candidate = scope.first_attribute(); candidate;
             candidate = candidate.next_attribute()) {
            const char* candidate_name = candidate.name();
            if (strlen(candidate_name) == declaration_len &&
                memcmp(candidate_name, declaration, declaration_len) == 0) {
                *uri = candidate.value();
                *uri_len = strlen(*uri);
                return;
            }
        }
    }
    *uri = "";
    *uri_len = 0;
}

static int beans_xml_namespace_matches(
        const BeansXmlTypedComplex* complex, pugi::xml_node owner,
        const char* qualified_name, int attribute) {
    if (!complex || complex->namespace_uri_len == 0) return 1;
    const char* uri;
    size_t uri_len;
    beans_xml_namespace_uri(
        owner, qualified_name, attribute, &uri, &uri_len);
    return uri_len == complex->namespace_uri_len &&
           memcmp(uri, complex->namespace_uri, uri_len) == 0;
}

static const BeansXmlTypedKey* beans_xml_typed_find_node(
        const BeansXmlTypedSchema* schema, pugi::xml_node owner,
        const char* qualified_name, int attribute) {
    const BeansXmlTypedKey* keys = attribute
        ? schema->attribute_keys : schema->element_keys;
    uint64_t mask = attribute
        ? schema->attribute_mask : schema->element_mask;
    size_t qualified_len = strlen(qualified_name);
    if (!(schema->flags & BEANS_XML_TYPED_HAS_NAMESPACES))
        return beans_xml_typed_find(
            keys, mask, qualified_name, qualified_len);
    const BeansXmlTypedKey* key = beans_xml_typed_find(
        keys, mask, qualified_name, qualified_len);
    if (key && beans_xml_namespace_matches(
            schema->complex ? &schema->complex[key->field - 1] : NULL, owner,
            qualified_name, attribute))
        return key;
    size_t local_len = qualified_len;
    const char* local = beans_xml_local_name(qualified_name, &local_len);
    if (local != qualified_name) {
        key = beans_xml_typed_find(keys, mask, local, local_len);
        if (key && beans_xml_namespace_matches(
                schema->complex ? &schema->complex[key->field - 1] : NULL,
                owner,
                qualified_name, attribute))
            return key;
    }
    // Two namespaces may legally use the same local name. The hash table
    // returns the first one; scan only this collision case for the URI match.
    for (uint64_t index = 0; index < schema->field_count; ++index) {
        const BeansXmlTypedField* field = &schema->fields[index];
        if ((attribute && field->source != BEANS_XML_TYPED_ATTRIBUTE) ||
            (!attribute && field->source != BEANS_XML_TYPED_ELEMENT) ||
            field->name_len != local_len ||
            memcmp(field->name, local, local_len) != 0)
            continue;
        if (beans_xml_namespace_matches(
                schema->complex ? &schema->complex[index] : NULL,
                owner, qualified_name, attribute)) {
            for (uint64_t slot = 0; slot <= mask; ++slot)
                if (keys[slot].field == index + 1) return &keys[slot];
        }
    }
    return NULL;
}

static int beans_xml_root_matches(
        const BeansXmlTypedSchema* schema, pugi::xml_node element) {
    const char* name = element.name();
    size_t len = strlen(name);
    const char* expected = name;
    if (schema->root_namespace_uri_len)
        expected = beans_xml_local_name(name, &len);
    if (len != schema->root_name_len ||
        memcmp(expected, schema->root_name, len) != 0)
        return 0;
    if (!schema->root_namespace_uri_len) return 1;
    const char* uri;
    size_t uri_len;
    beans_xml_namespace_uri(element, name, 0, &uri, &uri_len);
    return uri_len == schema->root_namespace_uri_len &&
           memcmp(uri, schema->root_namespace_uri, uri_len) == 0;
}

static void beans_xml_trim(const char** text, size_t* len) {
    while (*len && ((*text)[0] == ' ' || (*text)[0] == '\t' ||
                    (*text)[0] == '\r' || (*text)[0] == '\n')) {
        ++*text;
        --*len;
    }
    while (*len && ((*text)[*len - 1] == ' ' || (*text)[*len - 1] == '\t' ||
                    (*text)[*len - 1] == '\r' || (*text)[*len - 1] == '\n'))
        --*len;
}

static int beans_xml_integer(const char* text, size_t len,
                             int want_unsigned, unsigned bits,
                             uint64_t* output) {
    beans_xml_trim(&text, &len);
    if (!len) return 0;
    errno = 0;
    char* end = NULL;
    if (want_unsigned) {
        if (*text == '-') return -1;
        unsigned long long value = strtoull(text, &end, 10);
        if (errno == ERANGE || end != text + len) return -1;
        if (bits < 64 && value > ((UINT64_C(1) << bits) - 1)) return -1;
        *output = (uint64_t)value;
        return 1;
    }
    long long value = strtoll(text, &end, 10);
    if (errno == ERANGE || end != text + len) return -1;
    if (bits < 64) {
        int64_t minimum = -(INT64_C(1) << (bits - 1));
        int64_t maximum = (INT64_C(1) << (bits - 1)) - 1;
        if (value < minimum || value > maximum) return -1;
    }
    *output = (uint64_t)value;
    return 1;
}

static void beans_xml_write_integer(unsigned char* target,
                                    uint64_t value, unsigned bits) {
    if (bits == 8) {
        uint8_t narrowed = (uint8_t)value;
        memcpy(target, &narrowed, sizeof(narrowed));
    } else if (bits == 16) {
        uint16_t narrowed = (uint16_t)value;
        memcpy(target, &narrowed, sizeof(narrowed));
    } else if (bits == 32) {
        uint32_t narrowed = (uint32_t)value;
        memcpy(target, &narrowed, sizeof(narrowed));
    } else memcpy(target, &value, sizeof(value));
}

static int beans_xml_double(const char* text, size_t len, double* output) {
    beans_xml_trim(&text, &len);
    if (!len) return 0;
    const char* cursor = text;
    const char* end = text + len;
    int negative = 0;
    if (*cursor == '+' || *cursor == '-') {
        negative = *cursor == '-';
        if (++cursor == end) return 0;
    }
    uint64_t significand = 0;
    unsigned digits = 0;
    unsigned fractional = 0;
    while (cursor != end && *cursor >= '0' && *cursor <= '9') {
        if (digits == 18) goto fallback;
        significand = significand * 10 + (unsigned)(*cursor - '0');
        ++digits;
        ++cursor;
    }
    if (cursor != end && *cursor == '.') {
        ++cursor;
        while (cursor != end && *cursor >= '0' && *cursor <= '9') {
            if (digits == 18) goto fallback;
            significand = significand * 10 + (unsigned)(*cursor - '0');
            ++digits;
            ++fractional;
            ++cursor;
        }
    }
    if (digits && cursor == end) {
        static const double powers[] = {
            1.0, 10.0, 100.0, 1000.0, 10000.0, 100000.0,
            1000000.0, 10000000.0, 100000000.0, 1000000000.0,
            10000000000.0, 100000000000.0, 1000000000000.0,
            10000000000000.0, 100000000000000.0,
            1000000000000000.0, 10000000000000000.0,
            100000000000000000.0, 1000000000000000000.0,
        };
        double value = (double)significand / powers[fractional];
        *output = negative ? -value : value;
        return 1;
    }
fallback:
    errno = 0;
    char* parsed_end = NULL;
    double value = strtod(text, &parsed_end);
    if (errno == ERANGE || parsed_end != text + len || !isfinite(value))
        return 0;
    *output = value;
    return 1;
}

static int beans_xml_typed_scalar(
        uint64_t kind, uint64_t flags,
        const char* text, size_t len,
        unsigned char* target,
        BeansXmlDecodeContext* context) {
    switch (kind) {
    case BEANS_XML_TYPED_BOOL: {
        beans_xml_trim(&text, &len);
        uint8_t value;
        if ((len == 4 && memcmp(text, "true", 4) == 0) ||
            (len == 1 && text[0] == '1')) value = 1;
        else if ((len == 5 && memcmp(text, "false", 5) == 0) ||
                 (len == 1 && text[0] == '0')) value = 0;
        else return BEANS_XML_TYPED_ERR_TYPE;
        memcpy(target, &value, sizeof(value));
        break;
    }
    case BEANS_XML_TYPED_SINT:
    case BEANS_XML_TYPED_UINT: {
        unsigned bits = (unsigned)(flags >> 8);
        uint64_t value = 0;
        int status = beans_xml_integer(
            text, len, kind == BEANS_XML_TYPED_UINT, bits, &value);
        if (status == 0) return BEANS_XML_TYPED_ERR_TYPE;
        if (status < 0) return BEANS_XML_TYPED_ERR_RANGE;
        beans_xml_write_integer(target, value, bits);
        break;
    }
    case BEANS_XML_TYPED_F32:
    case BEANS_XML_TYPED_F64: {
        double value;
        if (!beans_xml_double(text, len, &value))
            return BEANS_XML_TYPED_ERR_RANGE;
        if (kind == BEANS_XML_TYPED_F32) {
            float narrowed = (float)value;
            if (!isfinite(narrowed)) return BEANS_XML_TYPED_ERR_RANGE;
            memcpy(target, &narrowed, sizeof(narrowed));
        } else memcpy(target, &value, sizeof(value));
        break;
    }
    case BEANS_XML_TYPED_STRING: {
        char* string = (char*)context->allocate(
            (long long)len + 1, (long long)len << 3);
        memcpy(string, text, len);
        memcpy(target, &string, sizeof(string));
        break;
    }
    default:
        return BEANS_XML_TYPED_ERR_TYPE;
    }
    return 0;
}

static void beans_xml_typed_init_record(
        const BeansXmlTypedSchema* schema,
        unsigned char* record) {
    memset(record, 0, (size_t)schema->record_size);
    for (uint64_t index = 0; index < schema->field_count; ++index) {
        const BeansXmlTypedField* field = &schema->fields[index];
        if (field->missing_value)
            memcpy(record + field->value_offset,
                   &field->missing_value, sizeof(field->missing_value));
    }
}

static int beans_xml_typed_record(
        const BeansXmlTypedSchema* schema,
        pugi::xml_node element,
        unsigned char* record,
        BeansXmlDecodeContext* context);

static unsigned char* beans_xml_typed_field_target(
        const BeansXmlTypedField* field,
        const BeansXmlTypedComplex* complex,
        unsigned char* record,
        BeansXmlDecodeContext* context) {
    unsigned char* target = record + field->value_offset;
    if (field->flags & BEANS_XML_TYPED_BOXED_OPTION) {
        if (!complex) return NULL;
        void* box = context->allocate(
            (long long)complex->box_size, (long long)complex->box_meta);
        memset(box, 0, (size_t)complex->box_size);
        memcpy(record + field->value_offset, &box, sizeof(box));
        target = (unsigned char*)box + complex->box_value_offset;
    }
    return target;
}

static int beans_xml_typed_apply_scalar(
        const BeansXmlTypedSchema* schema,
        uint64_t field_index,
        const char* text, size_t len,
        unsigned char* record,
        uint64_t* seen,
        BeansXmlDecodeContext* context) {
    uint64_t* req = context->req;
    uint64_t bit = UINT64_C(1) << (field_index & 63);
    if (seen[field_index >> 6] & bit) {
        req[5] = BEANS_XML_TYPED_ERR_DUPLICATE;
        req[7] = field_index;
        return BEANS_ENC_ERR_INVALID;
    }
    seen[field_index >> 6] |= bit;
    const BeansXmlTypedField* field = &schema->fields[field_index];
    if (field->kind == BEANS_XML_TYPED_STRUCT ||
        field->kind == BEANS_XML_TYPED_LIST) {
        req[5] = BEANS_XML_TYPED_ERR_TYPE;
        req[7] = field_index;
        return BEANS_ENC_ERR_TYPE;
    }
    const BeansXmlTypedComplex* complex =
        (field->flags & BEANS_XML_TYPED_BOXED_OPTION) && schema->complex
            ? &schema->complex[field_index] : NULL;
    unsigned char* target = beans_xml_typed_field_target(
        field, complex, record, context);
    if (!target) return BEANS_ENC_ERR_TYPE;
    int code = beans_xml_typed_scalar(
        field->kind, field->flags, text, len, target, context);
    if (code) {
        req[5] = (uint64_t)code;
        req[7] = field_index;
        return code == BEANS_XML_TYPED_ERR_RANGE ?
            BEANS_ENC_ERR_RANGE : BEANS_ENC_ERR_TYPE;
    }
    if (field->presence_offset != UINT64_MAX)
        record[field->presence_offset] = 1;
    return BEANS_ENC_OK;
}

static int beans_xml_namespace_attribute(const char* name) {
    return strcmp(name, "xmlns") == 0 || strncmp(name, "xmlns:", 6) == 0;
}

static int beans_xml_typed_list_item(
        const BeansXmlTypedSchema* schema,
        uint64_t field_index,
        pugi::xml_node child,
        unsigned char* target,
        BeansXmlDecodeContext* context) {
    const BeansXmlTypedComplex* complex = schema->complex
        ? &schema->complex[field_index] : NULL;
    if (!complex) return BEANS_ENC_ERR_TYPE;
    if (complex->element_kind == BEANS_XML_TYPED_STRUCT) {
        if (!complex->element_schema) return BEANS_ENC_ERR_TYPE;
        beans_xml_typed_init_record(complex->element_schema, target);
        return beans_xml_typed_record(
            complex->element_schema, child, target, context);
    }
    for (pugi::xml_node nested = child.first_child(); nested;
         nested = nested.next_sibling())
        if (nested.type() == pugi::node_element) {
            context->req[5] = BEANS_XML_TYPED_ERR_TYPE;
            return BEANS_ENC_ERR_TYPE;
        }
    int code = beans_xml_typed_scalar(
        complex->element_kind, 0, child.child_value(),
        strlen(child.child_value()), target, context);
    if (!code) return BEANS_ENC_OK;
    context->req[5] = (uint64_t)code;
    return code == BEANS_XML_TYPED_ERR_RANGE
        ? BEANS_ENC_ERR_RANGE : BEANS_ENC_ERR_TYPE;
}

static int beans_xml_typed_apply_element(
        const BeansXmlTypedSchema* schema,
        const BeansXmlTypedField* field, uint64_t field_index,
        pugi::xml_node child, unsigned char* record,
    BeansXmlDecodeContext* context) {
    uint64_t* req = context->req;
    req[7] = field_index;
    if (field->kind == BEANS_XML_TYPED_STRUCT) {
        const BeansXmlTypedComplex* complex = schema->complex
            ? &schema->complex[field_index] : NULL;
        if (!complex || !complex->child_schema) {
            req[5] = BEANS_XML_TYPED_ERR_TYPE;
            return BEANS_ENC_ERR_TYPE;
        }
        unsigned char* target = beans_xml_typed_field_target(
            field, complex, record, context);
        if (!target) return BEANS_ENC_ERR_TYPE;
        beans_xml_typed_init_record(complex->child_schema, target);
        int status = beans_xml_typed_record(
            complex->child_schema, child, target, context);
        if (status) return status;
        if (field->presence_offset != UINT64_MAX)
            record[field->presence_offset] = 1;
        return BEANS_ENC_OK;
    }
    const BeansXmlTypedComplex* complex =
        (field->flags & BEANS_XML_TYPED_BOXED_OPTION) && schema->complex
            ? &schema->complex[field_index] : NULL;
    for (pugi::xml_node nested = child.first_child(); nested;
         nested = nested.next_sibling())
        if (nested.type() == pugi::node_element) {
            req[5] = BEANS_XML_TYPED_ERR_TYPE;
            return BEANS_ENC_ERR_TYPE;
        }
    unsigned char* target = beans_xml_typed_field_target(
        field, complex, record, context);
    if (!target) return BEANS_ENC_ERR_TYPE;
    int code = beans_xml_typed_scalar(
        field->kind, field->flags, child.child_value(),
        strlen(child.child_value()), target, context);
    if (code) {
        req[5] = (uint64_t)code;
        return code == BEANS_XML_TYPED_ERR_RANGE
            ? BEANS_ENC_ERR_RANGE : BEANS_ENC_ERR_TYPE;
    }
    if (field->presence_offset != UINT64_MAX)
        record[field->presence_offset] = 1;
    return BEANS_ENC_OK;
}

static int beans_xml_typed_record(
        const BeansXmlTypedSchema* schema,
        pugi::xml_node element,
        unsigned char* record,
        BeansXmlDecodeContext* context) {
    uint64_t* req = context->req;
    size_t seen_words = ((size_t)schema->field_count + 63) / 64;
    uint64_t local_seen[2] = {};
    uint64_t* seen = seen_words <= 2 ? local_seen :
        (uint64_t*)calloc(seen_words, sizeof(uint64_t));
    int has_lists = (schema->flags & BEANS_XML_TYPED_HAS_LIST) != 0;
    uint64_t local_lists[32];
    uint64_t* list_counts = NULL;
    uint64_t* list_indexes = NULL;
    if (has_lists) {
        list_counts = schema->field_count <= 16 ? local_lists :
            (uint64_t*)calloc(
                (size_t)schema->field_count * 2, sizeof(uint64_t));
        list_indexes = list_counts + schema->field_count;
        if (schema->field_count <= 16)
            memset(local_lists, 0,
                   (size_t)schema->field_count * 2 * sizeof(uint64_t));
    }
    if (!seen || (has_lists && !list_counts)) {
        if (seen != local_seen) free(seen);
        if (list_counts && list_counts != local_lists) free(list_counts);
        req[5] = BEANS_XML_TYPED_ERR_TYPE;
        return BEANS_ENC_ERR_MEMORY;
    }
#define BEANS_XML_TYPED_RETURN(status) do { \
    if (seen != local_seen) free(seen); \
    if (list_counts && list_counts != local_lists) free(list_counts); \
    return (status); \
} while (0)
    for (pugi::xml_attribute attribute = element.first_attribute(); attribute;
         attribute = attribute.next_attribute()) {
        const char* name = attribute.name();
        if (beans_xml_namespace_attribute(name)) continue;
        const BeansXmlTypedKey* key = beans_xml_typed_find_node(
            schema, element, name, 1);
        if (!key) {
            if (schema->flags & BEANS_XML_TYPED_ALLOW_UNKNOWN) continue;
            req[5] = BEANS_XML_TYPED_ERR_UNKNOWN;
            BEANS_XML_TYPED_RETURN(BEANS_ENC_ERR_INVALID);
        }
        int status = beans_xml_typed_apply_scalar(
            schema, key->field - 1, attribute.value(),
            strlen(attribute.value()), record, seen, context);
        if (status) BEANS_XML_TYPED_RETURN(status);
    }

    // Schemas with repeated elements count them first, so every list gets one
    // exact-size allocation. Scalar-only schemas stay on a single pass.
    for (pugi::xml_node child = element.first_child(); child;
         child = child.next_sibling()) {
        if (child.type() == pugi::node_element) {
            const char* name = child.name();
            const BeansXmlTypedKey* key = beans_xml_typed_find_node(
                schema, child, name, 0);
            if (!key) {
                if (schema->flags & BEANS_XML_TYPED_ALLOW_UNKNOWN) continue;
                req[5] = BEANS_XML_TYPED_ERR_UNKNOWN;
                BEANS_XML_TYPED_RETURN(BEANS_ENC_ERR_INVALID);
            }
            uint64_t field_index = key->field - 1;
            const BeansXmlTypedField* field = &schema->fields[field_index];
            uint64_t bit = UINT64_C(1) << (field_index & 63);
            if (!has_lists) {
                if (seen[field_index >> 6] & bit) {
                    req[5] = BEANS_XML_TYPED_ERR_DUPLICATE;
                    req[7] = field_index;
                    BEANS_XML_TYPED_RETURN(BEANS_ENC_ERR_INVALID);
                }
                seen[field_index >> 6] |= bit;
                int status = beans_xml_typed_apply_element(
                    schema, field, field_index, child, record, context);
                if (status) BEANS_XML_TYPED_RETURN(status);
                continue;
            }
            if (field->kind == BEANS_XML_TYPED_LIST) {
                if (list_counts[field_index] == UINT64_MAX)
                    BEANS_XML_TYPED_RETURN(BEANS_ENC_ERR_RANGE);
                ++list_counts[field_index];
                seen[field_index >> 6] |= bit;
            } else {
                if (seen[field_index >> 6] & bit) {
                    req[5] = BEANS_XML_TYPED_ERR_DUPLICATE;
                    req[7] = field_index;
                    BEANS_XML_TYPED_RETURN(BEANS_ENC_ERR_INVALID);
                }
                seen[field_index >> 6] |= bit;
            }
        } else if (child.type() == pugi::node_pcdata ||
                   child.type() == pugi::node_cdata) {
            uint64_t text_index = UINT64_MAX;
            for (uint64_t index = 0; index < schema->field_count; ++index) {
                if (schema->fields[index].source == BEANS_XML_TYPED_TEXT) {
                    text_index = index;
                    break;
                }
            }
            const char* value = child.value();
            size_t length = strlen(value);
            const char* trimmed = value;
            size_t trimmed_len = length;
            beans_xml_trim(&trimmed, &trimmed_len);
            if (text_index == UINT64_MAX) {
                if (trimmed_len == 0 ||
                    (schema->flags & BEANS_XML_TYPED_ALLOW_UNKNOWN))
                    continue;
                req[5] = BEANS_XML_TYPED_ERR_UNKNOWN;
                BEANS_XML_TYPED_RETURN(BEANS_ENC_ERR_INVALID);
            }
            int status = beans_xml_typed_apply_scalar(
                schema, text_index, value, length,
                record, seen, context);
            if (status) BEANS_XML_TYPED_RETURN(status);
        }
    }

    for (uint64_t index = 0; has_lists && index < schema->field_count; ++index) {
        const BeansXmlTypedField* field = &schema->fields[index];
        const BeansXmlTypedComplex* complex = schema->complex
            ? &schema->complex[index] : NULL;
        if (field->kind != BEANS_XML_TYPED_LIST) continue;
        if (!list_counts[index] &&
            (field->flags & BEANS_XML_TYPED_OPTIONAL))
            continue;
        if (!complex || !context->new_list || !complex->element_size ||
            list_counts[index] > INT64_MAX) {
            req[5] = BEANS_XML_TYPED_ERR_TYPE;
            req[7] = index;
            BEANS_XML_TYPED_RETURN(BEANS_ENC_ERR_TYPE);
        }
        void* list = context->new_list(
            (long long)complex->element_size,
            (long long)complex->element_pointer_mask,
            (long long)list_counts[index]);
        memcpy(record + field->value_offset, &list, sizeof(list));
        seen[index >> 6] |= UINT64_C(1) << (index & 63);
        if (field->presence_offset != UINT64_MAX)
            record[field->presence_offset] = 1;
    }

    for (pugi::xml_node child = has_lists ? element.first_child() : pugi::xml_node(); child;
         child = child.next_sibling()) {
        if (child.type() == pugi::node_element) {
            const BeansXmlTypedKey* key = beans_xml_typed_find_node(
                schema, child, child.name(), 0);
            if (!key) continue;
            uint64_t field_index = key->field - 1;
            const BeansXmlTypedField* field = &schema->fields[field_index];
            const BeansXmlTypedComplex* complex = schema->complex
                ? &schema->complex[field_index] : NULL;
            req[7] = field_index;
            if (field->kind == BEANS_XML_TYPED_LIST) {
                BeansXmlListPrefix* list = NULL;
                memcpy(&list, record + field->value_offset, sizeof(list));
                uint64_t item_index = list_indexes[field_index]++;
                unsigned char* target = (unsigned char*)list->data +
                    item_index * (size_t)complex->element_size;
                memset(target, 0, (size_t)complex->element_size);
                list->len = item_index + 1;
                int status = beans_xml_typed_list_item(
                    schema, field_index, child, target, context);
                if (status) BEANS_XML_TYPED_RETURN(status);
            } else {
                int status = beans_xml_typed_apply_element(
                    schema, field, field_index, child, record, context);
                if (status) BEANS_XML_TYPED_RETURN(status);
            }
        }
    }

    for (uint64_t index = 0; index < schema->field_count; ++index) {
        if (seen[index >> 6] & (UINT64_C(1) << (index & 63))) continue;
        const BeansXmlTypedField* field = &schema->fields[index];
        if (field->flags & (BEANS_XML_TYPED_OPTIONAL |
                            BEANS_XML_TYPED_DEFAULT |
                            BEANS_XML_TYPED_IGNORED))
            continue;
        req[5] = BEANS_XML_TYPED_ERR_MISSING;
        req[7] = index;
        BEANS_XML_TYPED_RETURN(BEANS_ENC_ERR_INVALID);
    }
    BEANS_XML_TYPED_RETURN(BEANS_ENC_OK);
#undef BEANS_XML_TYPED_RETURN
}

static void beans_xml_typed_release_record(
        const BeansXmlTypedSchema* schema,
        unsigned char* record,
        BeansXmlReleaseFn release) {
    for (uint64_t index = 0; index < schema->field_count; ++index) {
        const BeansXmlTypedField* field = &schema->fields[index];
        const BeansXmlTypedComplex* complex = schema->complex
            ? &schema->complex[index] : NULL;
        if (field->flags & BEANS_XML_TYPED_BOXED_OPTION) {
            void* owned = NULL;
            memcpy(&owned, record + field->value_offset, sizeof(owned));
            if (owned) release(owned);
        } else if (field->kind == BEANS_XML_TYPED_STRING ||
                   field->kind == BEANS_XML_TYPED_LIST) {
            void* owned = NULL;
            memcpy(&owned, record + field->value_offset, sizeof(owned));
            if (owned) release(owned);
        } else if (field->kind == BEANS_XML_TYPED_STRUCT &&
                   complex && complex->child_schema) {
            beans_xml_typed_release_record(
                complex->child_schema,
                record + field->value_offset, release);
        }
    }
}

extern "C" {

// req[0]=text len, req[1]=option bits
// out: req[2]=doc handle, req[3]=document root node handle,
//      req[4]=pugixml parse status (vendored 1.16's enum values, plus 17 for
//      the multi-root check below; rendered into messages by xml.b so both
//      backends print identical text),
//      req[5]=error byte offset, req[6]=1 when that offset indexes the
//      caller's own bytes and 0 when the input was transcoded and no input
//      offset exists
// Returns BEANS_ENC_OK, BEANS_ENC_ERR_DOCTYPE, or BEANS_ENC_ERR_INVALID.
BEANS_ENC_API long long beans_enc_xml_parse(unsigned char* src, uint64_t* req) {
    size_t len = (size_t)req[0];
    uint64_t options = req[1];
    req[2] = 0;
    req[3] = 0;
    req[4] = 0;
    req[5] = 0;
    req[6] = (uint64_t)beans_enc_xml_offsets_are_input_bytes(src, len);
    unsigned int flags = pugi::parse_default | pugi::parse_comments |
                         pugi::parse_pi | pugi::parse_declaration |
                         pugi::parse_doctype;
    if (options & BEANS_XML_PRESERVE_SPACE_TEXT) flags |= pugi::parse_ws_pcdata;
    pugi::xml_document* doc = (pugi::xml_document*)malloc(sizeof(pugi::xml_document));
    if (!doc) return BEANS_ENC_ERR_MEMORY;
    new (doc) pugi::xml_document();
    // The consumed form lets pugixml split UTF-8 tokens in the caller's
    // buffer. Its owner keeps that buffer alive through document teardown.
    // Borrowed input keeps load_buffer's private copy and is never mutated.
    pugi::xml_parse_result outcome = options & BEANS_XML_INPLACE
        ? doc->load_buffer_inplace(src, len, flags, pugi::encoding_auto)
        : doc->load_buffer(src, len, flags, pugi::encoding_auto);
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
                // The scan is over the caller's bytes, so it only applies to
                // a UTF-8 input; a transcoded one already reported that no
                // input offset exists.
                req[5] = req[6]
                             ? beans_enc_xml_doctype_offset((const char*)src, len)
                             : 0;
                doc->~xml_document();
                free(doc);
                return BEANS_ENC_ERR_DOCTYPE;
            }
        }
    }
    // A well-formed XML document has exactly one root element. pugixml
    // already refuses zero with status_no_document_element (16) — that
    // covers empty, whitespace-only, declaration-only, comment-only,
    // processing-instruction-only and DOCTYPE-only inputs — but it accepts
    // fragments with several top-level elements, so the upper bound is
    // enforced here. 17 extends the vendored status enum and is rendered by
    // xml.b. The count is asserted in both directions rather than assumed.
    {
        int elements = 0;
        for (pugi::xml_node child = doc->first_child(); child;
             child = child.next_sibling()) {
            if (child.type() == pugi::node_element) elements++;
        }
        if (elements != 1) {
            req[4] = elements > 1 ? 17 : 16;
            doc->~xml_document();
            free(doc);
            return BEANS_ENC_ERR_INVALID;
        }
    }
    req[2] = (uint64_t)(uintptr_t)doc;
    req[3] = (uint64_t)(uintptr_t)doc->internal_object();
    return BEANS_ENC_OK;
}

// Direct typed path.
// req[0]=length, [1]=parse flags, [2]=schema, [3]=record pointer/list result,
// [5]=error code, [6]=record count/error byte, [7]=field index,
// [8]=new-list callback, [10]=Beans allocator, [11]=Beans release.
BEANS_ENC_API long long beans_enc_xml_typed_decode_direct(
        unsigned char* src, uint64_t* req) {
    const BeansXmlTypedSchema* schema =
        (const BeansXmlTypedSchema*)(uintptr_t)req[2];
    BeansXmlNewListFn new_list =
        (BeansXmlNewListFn)(uintptr_t)req[8];
    BeansXmlAllocFn allocate =
        (BeansXmlAllocFn)(uintptr_t)req[10];
    BeansXmlReleaseFn release =
        (BeansXmlReleaseFn)(uintptr_t)req[11];
    req[5] = 0;
    req[6] = 0;
    req[7] = UINT64_MAX;
    if (!schema || !schema->fields || !schema->attribute_keys ||
        !schema->element_keys || !schema->root_name || !allocate ||
        !release || schema->record_size == 0) {
        req[5] = BEANS_XML_TYPED_ERR_TYPE;
        return BEANS_ENC_ERR_INVALID;
    }

    uint64_t parse_req[7] = {};
    parse_req[0] = req[0];
    parse_req[1] = req[1];
    long long parsed = beans_enc_xml_parse(src, parse_req);
    if (parsed != BEANS_ENC_OK) {
        req[5] = parse_req[4];
        req[6] = parse_req[5];
        return parsed;
    }
    pugi::xml_document* doc =
        (pugi::xml_document*)(uintptr_t)parse_req[2];
    pugi::xml_node root = doc->document_element();
    int root_list = (schema->flags & BEANS_XML_TYPED_ROOT_LIST) != 0;
    if (!root_list && !beans_xml_root_matches(schema, root)) {
        req[5] = BEANS_XML_TYPED_ERR_ROOT;
        doc->~xml_document();
        free(doc);
        return BEANS_ENC_ERR_TYPE;
    }
    if (root_list && !(schema->flags & BEANS_XML_TYPED_ALLOW_UNKNOWN)) {
        for (pugi::xml_attribute attribute = root.first_attribute(); attribute;
             attribute = attribute.next_attribute()) {
            if (beans_xml_namespace_attribute(attribute.name())) continue;
            req[5] = BEANS_XML_TYPED_ERR_UNKNOWN;
            doc->~xml_document();
            free(doc);
            return BEANS_ENC_ERR_INVALID;
        }
        for (pugi::xml_node child = root.first_child(); child;
             child = child.next_sibling()) {
            if (child.type() != pugi::node_pcdata &&
                child.type() != pugi::node_cdata)
                continue;
            const char* value = child.value();
            size_t length = strlen(value);
            beans_xml_trim(&value, &length);
            if (!length) continue;
            req[5] = BEANS_XML_TYPED_ERR_UNKNOWN;
            doc->~xml_document();
            free(doc);
            return BEANS_ENC_ERR_INVALID;
        }
    }

    BeansXmlDecodeContext context = {new_list, allocate, release, req};

    long long status = BEANS_ENC_OK;
    if (root_list) {
        size_t count = 0;
        for (pugi::xml_node child = root.first_child(); child;
             child = child.next_sibling()) {
            if (child.type() != pugi::node_element) continue;
            if (!beans_xml_root_matches(schema, child)) {
                if (schema->flags & BEANS_XML_TYPED_ALLOW_UNKNOWN) continue;
                req[5] = BEANS_XML_TYPED_ERR_UNKNOWN;
                status = BEANS_ENC_ERR_INVALID;
                break;
            }
            ++count;
        }
        if (status == BEANS_ENC_OK && (!new_list || count > INT64_MAX)) {
            status = BEANS_ENC_ERR_MEMORY;
        }
        void* list = NULL;
        if (status == BEANS_ENC_OK) {
            list = new_list((long long)schema->record_size,
                            (long long)schema->pointer_mask,
                            (long long)count);
            req[3] = (uint64_t)(uintptr_t)list;
            req[6] = (uint64_t)count;
            BeansXmlListPrefix* output = (BeansXmlListPrefix*)list;
            size_t index = 0;
            for (pugi::xml_node child = root.first_child(); child;
                 child = child.next_sibling()) {
                if (child.type() != pugi::node_element) continue;
                if (!beans_xml_root_matches(schema, child))
                    continue;
                unsigned char* record =
                    (unsigned char*)output->data +
                    index * (size_t)schema->record_size;
                beans_xml_typed_init_record(schema, record);
                output->len = (uint64_t)++index;
                status = beans_xml_typed_record(
                    schema, child, record, &context);
                if (status != BEANS_ENC_OK) break;
            }
        }
        if (status != BEANS_ENC_OK && list) {
            release(list);
            req[3] = 0;
        }
    } else {
        unsigned char* record = (unsigned char*)(uintptr_t)req[3];
        beans_xml_typed_init_record(schema, record);
        status = beans_xml_typed_record(
            schema, root, record, &context);
        if (status != BEANS_ENC_OK)
            beans_xml_typed_release_record(schema, record, release);
        else req[6] = 1;
    }
    doc->~xml_document();
    free(doc);
    if (status == BEANS_ENC_OK) req[7] = UINT64_MAX;
    return status;
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

// Native compact stream: [name length], [borrowed name pointer],
// [value length], [borrowed value pointer]. The document owns every pointer
// while the Beans side copies once into its final strings.
BEANS_ENC_API long long beans_enc_xml_attrs_refs(long long node_word,
                                                 uint64_t* out) {
    pugi::xml_node node = beans_enc_xml_node_of((uint64_t)node_word);
    size_t index = 0;
    for (pugi::xml_attribute attr = node.first_attribute(); attr;
         attr = attr.next_attribute()) {
        const char* name = attr.name();
        const char* value = attr.value();
        out[index++] = (uint64_t)strlen(name);
        out[index++] = (uint64_t)(uintptr_t)name;
        out[index++] = (uint64_t)strlen(value);
        out[index++] = (uint64_t)(uintptr_t)value;
    }
    return BEANS_ENC_OK;
}

// req[0]=node, req[1]=qualified-name length; out req[2]=attribute handle.
BEANS_ENC_API long long beans_enc_xml_attr_get(unsigned char* name,
                                               uint64_t* req) {
    pugi::xml_node node = beans_enc_xml_node_of(req[0]);
    size_t length = (size_t)req[1];
    req[2] = 0;
    for (pugi::xml_attribute attr = node.first_attribute(); attr;
         attr = attr.next_attribute()) {
        const char* candidate = attr.name();
        if (strlen(candidate) == length &&
            memcmp(candidate, name, length) == 0) {
            req[2] = (uint64_t)(uintptr_t)attr.internal_object();
            break;
        }
    }
    return BEANS_ENC_OK;
}

BEANS_ENC_API long long beans_enc_xml_attr_value_len(long long attr_word) {
    pugi::xml_attribute attr(
        (pugi::xml_attribute_struct*)(uintptr_t)attr_word);
    return (long long)strlen(attr.value());
}

BEANS_ENC_API long long beans_enc_xml_attr_value_copy(long long attr_word,
                                                      unsigned char* dst) {
    pugi::xml_attribute attr(
        (pugi::xml_attribute_struct*)(uintptr_t)attr_word);
    const char* value = attr.value();
    memcpy(dst, value, strlen(value));
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
        bool named = node.set_name((const char*)name, name_len);
        if (!named) return BEANS_ENC_ERR_INVALID;
    }
    if (kind == BEANS_XML_TEXT || kind == BEANS_XML_CDATA ||
        kind == BEANS_XML_COMMENT || kind == BEANS_XML_PI) {
        bool set = node.set_value((const char*)value, value_len);
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
    pugi::xml_attribute attr = node.append_attribute("");
    long long status = BEANS_ENC_OK;
    if (!attr || !attr.set_name((const char*)name, name_len) ||
        !attr.set_value((const char*)value, value_len))
        status = BEANS_ENC_ERR_INVALID;
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
