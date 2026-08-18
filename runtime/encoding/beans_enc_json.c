// std.encoding.json native bridge over yyjson (vendored, see vendor/VENDOR.md).
//
// One translation unit: the vendored implementation is included below so the
// whole feature is a single cached object, compiled only into programs that
// import std.encoding.json. Everything yyjson is internal; only the
// beans_enc_json_* entry points are visible.
//
// ABI shape (shared by every encoding bridge): payload buffers cross as
// direct RawPtr parameters and everything else — lengths, flags, handles,
// outputs — rides in a RawPtr<u64> request buffer. Interpreter compatibility
// forces the split: both interpreters hand extern "C" calls a real host copy
// of each RawPtr *argument*, but a pointer smuggled through an integer word
// would be a synthetic interpreter address no C code can dereference.
// Handles this bridge itself returned (documents, values, write buffers) are
// opaque words and safe to embed.
//
// Handle lifetimes:
//   - a document handle is a heap BeansEncJsonDoc* (imm or mut)
//   - a value handle is a yyjson_val* / yyjson_mut_val*, valid only while
//     its document is alive; the Beans package keeps every Value holding an
//     ARC reference to its Doc owner, and Doc.deinit frees the handle
//   - a write-buffer handle stays alive until take_buf copies and frees it

#include "beans_enc_common.h"

// The vendored sources stay byte-identical to the upstream release; all
// Beans-specific configuration happens here, before inclusion.
//
// yyjson marks its whole API `visibility("default")`, which overrides the
// -fvisibility=hidden the build passes and would export ~50 yyjson_* symbols
// from any Beans shared library or executable that imports std.encoding.json.
// The header only defines the macro `#ifndef`, so defining it first is the
// supported way to keep the vendored implementation internal. On Windows the
// upstream default is already empty unless YYJSON_EXPORTS is set, so the
// override is a no-op there.
#if !defined(_WIN32)
  #define yyjson_api __attribute__((visibility("hidden")))
#else
  #define yyjson_api
#endif
#include "vendor/yyjson/yyjson.c"

typedef struct {
    int mutable_doc;
    yyjson_doc* imm;
    yyjson_mut_doc* mut;
} BeansEncJsonDoc;

// Value kinds shared with json.b.
enum {
    BEANS_JSON_NULL = 0,
    BEANS_JSON_BOOL = 1,
    BEANS_JSON_SINT = 2,
    BEANS_JSON_UINT = 3,
    BEANS_JSON_REAL = 4,
    BEANS_JSON_STR = 5,
    BEANS_JSON_ARR = 6,
    BEANS_JSON_OBJ = 7,
};

// Parse error codes shared with json.b (rendered into messages there, so
// both backends print identical text).
enum {
    BEANS_JSON_ERR_CHARACTER = 1,
    BEANS_JSON_ERR_EOF = 2,
    BEANS_JSON_ERR_MEMORY = 3,
    BEANS_JSON_ERR_TRAILING = 4,
    BEANS_JSON_ERR_NUMBER = 5,
    BEANS_JSON_ERR_STRING = 6,
    BEANS_JSON_ERR_LITERAL = 7,
    BEANS_JSON_ERR_COMMENT = 8,
    BEANS_JSON_ERR_STRUCTURE = 9,
    BEANS_JSON_ERR_EMPTY = 10,
};

// Write error codes shared with json.b.
enum {
    BEANS_JSON_WERR_INVALID = 1,
    BEANS_JSON_WERR_NAN_INF = 2,
    BEANS_JSON_WERR_MEMORY = 3,
};

// Read option bits shared with json.b (strict RFC 8259 is flags == 0).
enum {
    BEANS_JSON_READ_ALLOW_COMMENTS = 1,
    BEANS_JSON_READ_ALLOW_TRAILING_COMMAS = 2,
    BEANS_JSON_READ_ALLOW_INF_AND_NAN = 4,
    BEANS_JSON_READ_INSITU = 8,
};

// Private compiler-generated typed-decoding ABI. The generated schema is a
// set of read-only LLVM globals, so decoding does not build reflection data or
// allocate JSON key strings at runtime.
typedef struct {
    const unsigned char* name;
    uint64_t len;
    // Zero marks an empty hash-table bucket. A live bucket stores index + 1.
    uint64_t field;
} BeansJsonTypedKey;

typedef struct {
    uint64_t kind;
    uint64_t flags;
    uint64_t value_offset;
    // UINT64_MAX for plain fields and nullable-pointer options.
    uint64_t presence_offset;
    const unsigned char* primary_name;
    uint64_t primary_name_len;
} BeansJsonTypedField;

typedef struct {
    const struct BeansJsonTypedSchema* child_schema;
    uint64_t element_kind;
    const struct BeansJsonTypedSchema* element_schema;
    uint64_t element_size;
    uint64_t element_pointer_mask;
    uint64_t box_size;
    uint64_t box_meta;
    uint64_t box_value_offset;
    uint64_t missing_value;
} BeansJsonTypedComplex;

typedef struct BeansJsonTypedSchema {
    uint64_t field_count;
    uint64_t key_mask;
    uint64_t flags;
    const BeansJsonTypedKey* keys;
    const BeansJsonTypedField* fields;
    uint64_t record_size;
    uint64_t pointer_mask;
    const BeansJsonTypedComplex* complex;
} BeansJsonTypedSchema;

typedef struct {
    yyjson_doc* doc;
    uint64_t* slots;
} BeansJsonTypedHandle;

enum {
    BEANS_JSON_TYPED_BOOL = 1,
    BEANS_JSON_TYPED_SINT = 2,
    BEANS_JSON_TYPED_UINT = 3,
    BEANS_JSON_TYPED_F32 = 4,
    BEANS_JSON_TYPED_F64 = 5,
    BEANS_JSON_TYPED_STRING = 6,
    BEANS_JSON_TYPED_STRUCT = 7,
    BEANS_JSON_TYPED_LIST = 8,
};

enum {
    BEANS_JSON_TYPED_OPTIONAL = 1,
    BEANS_JSON_TYPED_DEFAULT = 2,
    BEANS_JSON_TYPED_IGNORED = 4,
    BEANS_JSON_TYPED_BOXED_OPTION = 8,
};

enum {
    BEANS_JSON_TYPED_ALLOW_UNKNOWN = 1,
    BEANS_JSON_TYPED_ROOT_ARRAY = 2,
    BEANS_JSON_TYPED_HAS_MISSING = 4,
};

enum {
    BEANS_JSON_TYPED_ERR_ROOT = 101,
    BEANS_JSON_TYPED_ERR_UNKNOWN = 102,
    BEANS_JSON_TYPED_ERR_DUPLICATE = 103,
    BEANS_JSON_TYPED_ERR_TYPE = 104,
    BEANS_JSON_TYPED_ERR_RANGE = 105,
    BEANS_JSON_TYPED_ERR_MISSING = 106,
    BEANS_JSON_TYPED_ERR_NULL = 107,
    BEANS_JSON_TYPED_ERR_DEPTH = 108,
};

// Write mode values shared with json.b.
enum {
    BEANS_JSON_WRITE_COMPACT = 0,
    BEANS_JSON_WRITE_PRETTY_FOUR = 1,
    BEANS_JSON_WRITE_PRETTY_TWO = 2,
};

static uint64_t beans_enc_json_map_read_code(yyjson_read_code code) {
    if (code == YYJSON_READ_ERROR_MEMORY_ALLOCATION) return BEANS_JSON_ERR_MEMORY;
    if (code == YYJSON_READ_ERROR_EMPTY_CONTENT) return BEANS_JSON_ERR_EMPTY;
    if (code == YYJSON_READ_ERROR_UNEXPECTED_END) return BEANS_JSON_ERR_EOF;
    if (code == YYJSON_READ_ERROR_UNEXPECTED_CONTENT) return BEANS_JSON_ERR_TRAILING;
    if (code == YYJSON_READ_ERROR_INVALID_NUMBER) return BEANS_JSON_ERR_NUMBER;
    if (code == YYJSON_READ_ERROR_INVALID_STRING) return BEANS_JSON_ERR_STRING;
    if (code == YYJSON_READ_ERROR_LITERAL) return BEANS_JSON_ERR_LITERAL;
    if (code == YYJSON_READ_ERROR_INVALID_COMMENT) return BEANS_JSON_ERR_COMMENT;
    if (code == YYJSON_READ_ERROR_JSON_STRUCTURE) return BEANS_JSON_ERR_STRUCTURE;
    return BEANS_JSON_ERR_CHARACTER;
}

// req[0]=text len, req[1]=option bits
// out: req[2]=doc handle, req[3]=root value,
//      req[4]=error code, req[5]=error byte offset
BEANS_ENC_API long long beans_enc_json_parse(unsigned char* src, uint64_t* req) {
    size_t len = (size_t)req[0];
    uint64_t options = req[1];
    yyjson_read_flag flags = YYJSON_READ_NOFLAG;
    if (options & BEANS_JSON_READ_ALLOW_COMMENTS) flags |= YYJSON_READ_ALLOW_COMMENTS;
    if (options & BEANS_JSON_READ_ALLOW_TRAILING_COMMAS) flags |= YYJSON_READ_ALLOW_TRAILING_COMMAS;
    if (options & BEANS_JSON_READ_ALLOW_INF_AND_NAN) flags |= YYJSON_READ_ALLOW_INF_AND_NAN;
    req[2] = 0;
    req[3] = 0;
    req[4] = 0;
    req[5] = 0;
    // yyjson reports a zero-length input as an invalid parameter; "empty
    // input" is the message a caller can act on.
    if (len == 0) {
        req[4] = BEANS_JSON_ERR_EMPTY;
        return BEANS_ENC_ERR_INVALID;
    }
    yyjson_read_err err;
    // yyjson never reads past `len`: the non-in-situ reader copies the input
    // into its own padded buffer first, so a Beans string or Bytes payload
    // needs no NUL terminator.
    yyjson_doc* doc = yyjson_read_opts((char*)src, len, flags, NULL, &err);
    if (!doc) {
        req[4] = beans_enc_json_map_read_code(err.code);
        req[5] = (uint64_t)err.pos;
        return BEANS_ENC_ERR_INVALID;
    }
    BeansEncJsonDoc* handle = (BeansEncJsonDoc*)malloc(sizeof(BeansEncJsonDoc));
    if (!handle) {
        yyjson_doc_free(doc);
        req[4] = BEANS_JSON_ERR_MEMORY;
        return BEANS_ENC_ERR_MEMORY;
    }
    handle->mutable_doc = 0;
    handle->imm = doc;
    handle->mut = NULL;
    req[2] = (uint64_t)(uintptr_t)handle;
    req[3] = (uint64_t)(uintptr_t)yyjson_doc_get_root(doc);
    return BEANS_ENC_OK;
}

BEANS_ENC_API long long beans_enc_json_free_doc(long long doc_word) {
    BeansEncJsonDoc* doc = (BeansEncJsonDoc*)(uintptr_t)doc_word;
    if (!doc) return BEANS_ENC_OK;
    if (doc->imm) yyjson_doc_free(doc->imm);
    if (doc->mut) yyjson_mut_doc_free(doc->mut);
    free(doc);
    return BEANS_ENC_OK;
}

static uint64_t beans_json_typed_key_hash(const unsigned char* text,
                                          size_t len,
                                          uint64_t mask) {
    uint64_t hash = 0;
    for (size_t index = 0; index < len; index++) {
        hash = ((hash << 5) + hash + text[index]) & mask;
    }
    return hash;
}

static const BeansJsonTypedKey* beans_json_typed_find_key(
        const BeansJsonTypedSchema* schema,
        const unsigned char* text,
        size_t len) {
    uint64_t slot = beans_json_typed_key_hash(text, len, schema->key_mask);
    for (uint64_t scanned = 0; scanned <= schema->key_mask; scanned++) {
        const BeansJsonTypedKey* key = &schema->keys[slot];
        if (key->field == 0) return NULL;
        if (key->len == len && memcmp(key->name, text, len) == 0) return key;
        slot = (slot + 1) & schema->key_mask;
    }
    return NULL;
}

static int beans_json_typed_within_depth(yyjson_val* value,
                                         uint64_t depth,
                                         uint64_t maximum) {
    if (depth > maximum) return 0;
    if (yyjson_is_arr(value)) {
        yyjson_arr_iter iterator;
        yyjson_arr_iter_init(value, &iterator);
        yyjson_val* item;
        while ((item = yyjson_arr_iter_next(&iterator)) != NULL) {
            if (!beans_json_typed_within_depth(item, depth + 1, maximum))
                return 0;
        }
    } else if (yyjson_is_obj(value)) {
        yyjson_obj_iter iterator;
        yyjson_obj_iter_init(value, &iterator);
        yyjson_val* key;
        while ((key = yyjson_obj_iter_next(&iterator)) != NULL) {
            if (!beans_json_typed_within_depth(
                    yyjson_obj_iter_get_val(key), depth + 1, maximum))
                return 0;
        }
    }
    return 1;
}

static int beans_json_typed_check_depth(yyjson_val* root, uint64_t options,
                                        uint64_t* req) {
    uint64_t maximum = options >> 8;
    if (maximum == 0 ||
        !beans_json_typed_within_depth(root, 1, maximum)) {
        req[5] = BEANS_JSON_TYPED_ERR_DEPTH;
        return 0;
    }
    return 1;
}

static int beans_json_typed_integer(yyjson_val* value,
                                    int want_unsigned,
                                    unsigned bits,
                                    uint64_t* output) {
    if (!yyjson_is_num(value) || yyjson_is_real(value)) return 0;
    if (want_unsigned) {
        uint64_t number;
        if (yyjson_is_uint(value)) {
            number = yyjson_get_uint(value);
        } else {
            int64_t signed_number = yyjson_get_sint(value);
            if (signed_number < 0) return -1;
            number = (uint64_t)signed_number;
        }
        if (bits < 64 && number > ((UINT64_C(1) << bits) - 1)) return -1;
        *output = number;
        return 1;
    }

    int64_t number;
    if (yyjson_is_sint(value)) {
        number = yyjson_get_sint(value);
    } else {
        uint64_t unsigned_number = yyjson_get_uint(value);
        if (unsigned_number > INT64_MAX) return -1;
        number = (int64_t)unsigned_number;
    }
    if (bits < 64) {
        int64_t minimum = -(INT64_C(1) << (bits - 1));
        int64_t maximum = (INT64_C(1) << (bits - 1)) - 1;
        if (number < minimum || number > maximum) return -1;
    }
    *output = (uint64_t)number;
    return 1;
}

static int beans_json_typed_store(const BeansJsonTypedField* field,
                                  yyjson_val* value,
                                  uint64_t* slot) {
    if (yyjson_is_null(value)) {
        if (!(field->flags & BEANS_JSON_TYPED_OPTIONAL)) return BEANS_JSON_TYPED_ERR_NULL;
        slot[0] = 2;
        return 0;
    }

    slot[0] = 1;
    if (field->kind == BEANS_JSON_TYPED_BOOL) {
        if (!yyjson_is_bool(value)) return BEANS_JSON_TYPED_ERR_TYPE;
        slot[1] = yyjson_get_bool(value) ? 1 : 0;
        return 0;
    }
    if (field->kind == BEANS_JSON_TYPED_SINT ||
        field->kind == BEANS_JSON_TYPED_UINT) {
        unsigned bits = (unsigned)(field->flags >> 8);
        int result = beans_json_typed_integer(
            value, field->kind == BEANS_JSON_TYPED_UINT, bits, &slot[1]);
        if (result == 0) return BEANS_JSON_TYPED_ERR_TYPE;
        if (result < 0) return BEANS_JSON_TYPED_ERR_RANGE;
        return 0;
    }
    if (field->kind == BEANS_JSON_TYPED_F32 ||
        field->kind == BEANS_JSON_TYPED_F64) {
        if (!yyjson_is_num(value)) return BEANS_JSON_TYPED_ERR_TYPE;
        double number = yyjson_get_num(value);
        if (field->kind == BEANS_JSON_TYPED_F32) {
            float narrowed = (float)number;
            if (!isfinite(narrowed)) return BEANS_JSON_TYPED_ERR_RANGE;
            uint32_t bits;
            memcpy(&bits, &narrowed, sizeof(bits));
            slot[1] = bits;
        } else {
            memcpy(&slot[1], &number, sizeof(number));
        }
        return 0;
    }
    if (field->kind == BEANS_JSON_TYPED_STRING) {
        if (!yyjson_is_str(value)) return BEANS_JSON_TYPED_ERR_TYPE;
        slot[1] = (uint64_t)(uintptr_t)yyjson_get_str(value);
        slot[2] = (uint64_t)yyjson_get_len(value);
        return 0;
    }
    return BEANS_JSON_TYPED_ERR_TYPE;
}

static int beans_json_typed_object(const BeansJsonTypedSchema* schema,
                                   yyjson_val* object,
                                   uint64_t* slots,
                                   uint64_t* req) {
    if (!yyjson_is_obj(object)) {
        req[5] = BEANS_JSON_TYPED_ERR_ROOT;
        return BEANS_ENC_ERR_TYPE;
    }
    yyjson_obj_iter iterator;
    yyjson_obj_iter_init(object, &iterator);
    yyjson_val* json_key;
    while ((json_key = yyjson_obj_iter_next(&iterator)) != NULL) {
        const unsigned char* name =
            (const unsigned char*)yyjson_get_str(json_key);
        size_t name_len = yyjson_get_len(json_key);
        const BeansJsonTypedKey* key =
            beans_json_typed_find_key(schema, name, name_len);
        if (!key) {
            if (schema->flags & BEANS_JSON_TYPED_ALLOW_UNKNOWN) continue;
            req[5] = BEANS_JSON_TYPED_ERR_UNKNOWN;
            return BEANS_ENC_ERR_INVALID;
        }
        uint64_t field_index = key->field - 1;
        req[7] = field_index;
        uint64_t* slot = &slots[field_index * 4];
        if (slot[0] != 0) {
            req[5] = BEANS_JSON_TYPED_ERR_DUPLICATE;
            return BEANS_ENC_ERR_INVALID;
        }
        int code = beans_json_typed_store(
            &schema->fields[field_index], yyjson_obj_iter_get_val(json_key), slot);
        if (code != 0) {
            req[5] = (uint64_t)code;
            return code == BEANS_JSON_TYPED_ERR_RANGE ?
                BEANS_ENC_ERR_RANGE : BEANS_ENC_ERR_TYPE;
        }
    }
    for (uint64_t index = 0; index < schema->field_count; index++) {
        const BeansJsonTypedField* field = &schema->fields[index];
        if (field->flags & BEANS_JSON_TYPED_IGNORED) continue;
        if (slots[index * 4] != 0) continue;
        if (field->flags &
            (BEANS_JSON_TYPED_OPTIONAL | BEANS_JSON_TYPED_DEFAULT))
            continue;
        req[5] = BEANS_JSON_TYPED_ERR_MISSING;
        req[7] = index;
        return BEANS_ENC_ERR_INVALID;
    }
    return BEANS_ENC_OK;
}

typedef void* (*BeansJsonNewListFn)(long long, long long, long long);
typedef void* (*BeansJsonAllocFn)(long long, long long);
typedef void (*BeansJsonReleaseFn)(void*);

typedef struct {
    void* data;
    uint64_t len __attribute__((aligned(8)));
    uint64_t cap;
    int64_t stride;
    int64_t pointer_mask;
} BeansJsonListPrefix;

static int64_t beans_json_typed_storage_stride(uint64_t value_size,
                                                uint64_t kind) {
    return kind == BEANS_JSON_TYPED_STRUCT ? (int64_t)value_size : -8;
}

static size_t beans_json_typed_list_stride(
        const BeansJsonListPrefix* list) {
    return list->stride < 0
        ? (size_t)-list->stride
        : (size_t)(list->stride ? list->stride : 8);
}

typedef struct {
    BeansJsonNewListFn new_list;
    BeansJsonAllocFn allocate;
    BeansJsonReleaseFn release;
    uint64_t* req;
} BeansJsonDecodeContext;

static void beans_json_typed_write_integer(unsigned char* target,
                                           uint64_t value,
                                           unsigned bits) {
    if (bits == 8) {
        uint8_t narrowed = (uint8_t)value;
        memcpy(target, &narrowed, sizeof(narrowed));
    } else if (bits == 16) {
        uint16_t narrowed = (uint16_t)value;
        memcpy(target, &narrowed, sizeof(narrowed));
    } else if (bits == 32) {
        uint32_t narrowed = (uint32_t)value;
        memcpy(target, &narrowed, sizeof(narrowed));
    } else {
        memcpy(target, &value, sizeof(value));
    }
}

static void beans_json_typed_init_record(
        const BeansJsonTypedSchema* schema,
        unsigned char* record) {
    memset(record, 0, (size_t)schema->record_size);
    if (!(schema->flags & BEANS_JSON_TYPED_HAS_MISSING)) return;
    for (uint64_t index = 0; index < schema->field_count; index++) {
        const BeansJsonTypedField* field = &schema->fields[index];
        const BeansJsonTypedComplex* complex = schema->complex
            ? &schema->complex[index] : NULL;
        if (complex && complex->missing_value)
            memcpy(record + field->value_offset,
                   &complex->missing_value,
                   sizeof(complex->missing_value));
    }
}

static int beans_json_typed_object_direct(
        const BeansJsonTypedSchema* schema,
        yyjson_val* object,
        unsigned char* record,
        BeansJsonDecodeContext* context);

static int beans_json_typed_value_direct(
        uint64_t kind,
        uint64_t flags,
        const BeansJsonTypedSchema* child_schema,
        uint64_t element_kind,
        const BeansJsonTypedSchema* element_schema,
        uint64_t element_size,
        uint64_t element_pointer_mask,
        yyjson_val* value,
        unsigned char* target,
        BeansJsonDecodeContext* context);

static int beans_json_typed_store_direct(
        const BeansJsonTypedSchema* schema,
        uint64_t field_index,
        yyjson_val* value,
        unsigned char* record,
        BeansJsonDecodeContext* context) {
    const BeansJsonTypedField* field = &schema->fields[field_index];
    const BeansJsonTypedComplex* complex = schema->complex
        ? &schema->complex[field_index] : NULL;
    if (yyjson_is_null(value)) {
        return (field->flags & BEANS_JSON_TYPED_OPTIONAL) ?
            0 : BEANS_JSON_TYPED_ERR_NULL;
    }

    unsigned char* target = record + field->value_offset;
    if (field->flags & BEANS_JSON_TYPED_BOXED_OPTION) {
        if (!complex) return BEANS_JSON_TYPED_ERR_TYPE;
        void* box = context->allocate(
            (long long)complex->box_size, (long long)complex->box_meta);
        memset(box, 0, (size_t)complex->box_size);
        memcpy(record + field->value_offset, &box, sizeof(box));
        target = (unsigned char*)box + complex->box_value_offset;
    }
    int status = beans_json_typed_value_direct(
        field->kind, field->flags,
        complex ? complex->child_schema : NULL,
        complex ? complex->element_kind : 0,
        complex ? complex->element_schema : NULL,
        complex ? complex->element_size : 0,
        complex ? complex->element_pointer_mask : 0,
        value, target, context);
    if (status) return status;
    if (field->presence_offset != UINT64_MAX)
        record[field->presence_offset] = 1;
    return 0;
}

static int beans_json_typed_list_direct(
        uint64_t element_kind,
        const BeansJsonTypedSchema* element_schema,
        uint64_t element_size,
        uint64_t element_pointer_mask,
        yyjson_val* value,
        unsigned char* target,
        BeansJsonDecodeContext* context) {
    if (!yyjson_is_arr(value) || !context->new_list || element_size == 0)
        return BEANS_JSON_TYPED_ERR_TYPE;
    size_t count = yyjson_arr_size(value);
    if (count > INT64_MAX) return BEANS_JSON_TYPED_ERR_RANGE;
    void* list = context->new_list(
        beans_json_typed_storage_stride(element_size, element_kind),
        (long long)element_pointer_mask,
        (long long)count);
    memcpy(target, &list, sizeof(list));
    BeansJsonListPrefix* output = (BeansJsonListPrefix*)list;
    yyjson_arr_iter iterator;
    yyjson_arr_iter_init(value, &iterator);
    yyjson_val* item;
    size_t index = 0;
    size_t stride = beans_json_typed_list_stride(output);
    while ((item = yyjson_arr_iter_next(&iterator)) != NULL) {
        unsigned char* destination =
            (unsigned char*)output->data + index * stride;
        memset(destination, 0, (size_t)element_size);
        output->len = (uint64_t)++index;
        uint64_t element_flags =
            (element_kind == BEANS_JSON_TYPED_SINT ||
             element_kind == BEANS_JSON_TYPED_UINT)
                ? element_size * 8 << 8 : 0;
        int status = beans_json_typed_value_direct(
            element_kind, element_flags, element_schema, 0, NULL, 0, 0,
            item, destination, context);
        if (status) return status;
    }
    return 0;
}

static int beans_json_typed_value_direct(
        uint64_t kind,
        uint64_t flags,
        const BeansJsonTypedSchema* child_schema,
        uint64_t element_kind,
        const BeansJsonTypedSchema* element_schema,
        uint64_t element_size,
        uint64_t element_pointer_mask,
        yyjson_val* value,
        unsigned char* target,
        BeansJsonDecodeContext* context) {
    switch (kind) {
        case BEANS_JSON_TYPED_BOOL:
            if (!yyjson_is_bool(value)) return BEANS_JSON_TYPED_ERR_TYPE;
            *target = yyjson_get_bool(value) ? 1 : 0;
            break;
        case BEANS_JSON_TYPED_SINT:
        case BEANS_JSON_TYPED_UINT: {
            unsigned bits = (unsigned)(flags >> 8);
            uint64_t integer = 0;
            int result = beans_json_typed_integer(
                value, kind == BEANS_JSON_TYPED_UINT, bits, &integer);
            if (result == 0) return BEANS_JSON_TYPED_ERR_TYPE;
            if (result < 0) return BEANS_JSON_TYPED_ERR_RANGE;
            beans_json_typed_write_integer(target, integer, bits);
            break;
        }
        case BEANS_JSON_TYPED_F32: {
            if (!yyjson_is_num(value)) return BEANS_JSON_TYPED_ERR_TYPE;
            double number = yyjson_get_num(value);
            float narrowed = (float)number;
            if (!isfinite(narrowed)) return BEANS_JSON_TYPED_ERR_RANGE;
            memcpy(target, &narrowed, sizeof(narrowed));
            break;
        }
        case BEANS_JSON_TYPED_F64: {
            if (!yyjson_is_num(value)) return BEANS_JSON_TYPED_ERR_TYPE;
            double number = yyjson_get_num(value);
            memcpy(target, &number, sizeof(number));
            break;
        }
        case BEANS_JSON_TYPED_STRING: {
            if (!yyjson_is_str(value)) return BEANS_JSON_TYPED_ERR_TYPE;
            size_t length = yyjson_get_len(value);
            char* string = (char*)context->allocate(
                (long long)length + 1, (long long)length << 3);
            memcpy(string, yyjson_get_str(value), length);
            memcpy(target, &string, sizeof(string));
            break;
        }
        case BEANS_JSON_TYPED_STRUCT:
            if (!child_schema) return BEANS_JSON_TYPED_ERR_TYPE;
            beans_json_typed_init_record(child_schema, target);
            {
                int status = beans_json_typed_object_direct(
                    child_schema, value, target, context);
                return status == BEANS_ENC_OK ? 0 : -status;
            }
        case BEANS_JSON_TYPED_LIST:
            return beans_json_typed_list_direct(
                element_kind, element_schema, element_size,
                element_pointer_mask, value, target, context);
        default:
            return BEANS_JSON_TYPED_ERR_TYPE;
    }
    return 0;
}

static int beans_json_typed_object_direct(
        const BeansJsonTypedSchema* schema,
        yyjson_val* object,
        unsigned char* record,
        BeansJsonDecodeContext* context) {
    uint64_t* req = context->req;
    if (!yyjson_is_obj(object)) {
        req[5] = BEANS_JSON_TYPED_ERR_ROOT;
        return BEANS_ENC_ERR_TYPE;
    }
    size_t seen_words = ((size_t)schema->field_count + 63) / 64;
    uint64_t local_seen[2];
    uint64_t* seen = seen_words <= 2 ? local_seen :
        (uint64_t*)malloc(seen_words * sizeof(uint64_t));
    if (!seen) {
        req[5] = BEANS_JSON_ERR_MEMORY;
        return BEANS_ENC_ERR_MEMORY;
    }
    yyjson_obj_iter iterator;
    yyjson_obj_iter_init(object, &iterator);
    yyjson_val* json_key;
    uint64_t expected = 0;
    int ordered = 1;
    while ((json_key = yyjson_obj_iter_next(&iterator)) != NULL) {
        const unsigned char* name =
            (const unsigned char*)yyjson_get_str(json_key);
        size_t name_len = yyjson_get_len(json_key);
        uint64_t index;
        const BeansJsonTypedField* expected_field =
            expected < schema->field_count ? &schema->fields[expected] : NULL;
        if (ordered && expected_field &&
            expected_field->primary_name_len == name_len &&
            memcmp(expected_field->primary_name, name, name_len) == 0) {
            index = expected++;
        } else {
            if (ordered) {
                memset(seen, 0, seen_words * sizeof(uint64_t));
                for (uint64_t prior = 0; prior < expected; prior++)
                    seen[prior >> 6] |= UINT64_C(1) << (prior & 63);
                ordered = 0;
            }
            const BeansJsonTypedKey* key = beans_json_typed_find_key(
                schema, name, name_len);
            if (!key) {
                if (schema->flags & BEANS_JSON_TYPED_ALLOW_UNKNOWN) continue;
                req[5] = BEANS_JSON_TYPED_ERR_UNKNOWN;
                if (seen != local_seen) free(seen);
                return BEANS_ENC_ERR_INVALID;
            }
            index = key->field - 1;
            uint64_t bit = UINT64_C(1) << (index & 63);
            if (seen[index >> 6] & bit) {
                req[5] = BEANS_JSON_TYPED_ERR_DUPLICATE;
                if (seen != local_seen) free(seen);
                return BEANS_ENC_ERR_INVALID;
            }
            seen[index >> 6] |= bit;
        }
        req[7] = index;
        int code = beans_json_typed_store_direct(
            schema, index, yyjson_obj_iter_get_val(json_key),
            record, context);
        if (code != 0) {
            if (code < 0) {
                if (seen != local_seen) free(seen);
                return -code;
            }
            req[5] = (uint64_t)code;
            if (seen != local_seen) free(seen);
            return code == BEANS_JSON_TYPED_ERR_RANGE ?
                BEANS_ENC_ERR_RANGE : BEANS_ENC_ERR_TYPE;
        }
    }
    uint64_t first_missing_check = ordered ? expected : 0;
    for (uint64_t index = first_missing_check;
         index < schema->field_count; index++) {
        if (!ordered &&
            (seen[index >> 6] & (UINT64_C(1) << (index & 63))))
            continue;
        const BeansJsonTypedField* field = &schema->fields[index];
        if (field->flags &
            (BEANS_JSON_TYPED_OPTIONAL | BEANS_JSON_TYPED_DEFAULT |
             BEANS_JSON_TYPED_IGNORED))
            continue;
        req[5] = BEANS_JSON_TYPED_ERR_MISSING;
        req[7] = index;
        if (seen != local_seen) free(seen);
        return BEANS_ENC_ERR_INVALID;
    }
    if (seen != local_seen) free(seen);
    return BEANS_ENC_OK;
}

static void beans_json_typed_release_record(
        const BeansJsonTypedSchema* schema,
        unsigned char* record,
    BeansJsonReleaseFn release) {
    for (uint64_t index = 0; index < schema->field_count; index++) {
        const BeansJsonTypedField* field = &schema->fields[index];
        const BeansJsonTypedComplex* complex = schema->complex
            ? &schema->complex[index] : NULL;
        if (field->flags & BEANS_JSON_TYPED_BOXED_OPTION) {
            void* box = NULL;
            memcpy(&box, record + field->value_offset, sizeof(box));
            if (box) release(box);
            continue;
        }
        if (field->kind == BEANS_JSON_TYPED_STRING ||
            field->kind == BEANS_JSON_TYPED_LIST) {
            void* owned = NULL;
            memcpy(&owned, record + field->value_offset, sizeof(owned));
            if (owned) release(owned);
        } else if (field->kind == BEANS_JSON_TYPED_STRUCT &&
                   complex && complex->child_schema) {
            beans_json_typed_release_record(
                complex->child_schema,
                record + field->value_offset, release);
        }
    }
}

// Direct native path. It maps into the final Beans struct/list storage while
// the yyjson tree is hot, avoiding the large field-slot table used by the
// portable fallback.
// req[0]=length, [1]=read flags, [2]=schema, [3]=scalar output/list output,
// [5]=error, [6]=record count/error byte, [7]=field index,
// [8]=new-list callback, [10]=Beans allocator callback,
// [11]=release callback.
BEANS_ENC_API long long beans_enc_json_typed_decode_direct(
        unsigned char* src, uint64_t* req) {
    const BeansJsonTypedSchema* schema =
        (const BeansJsonTypedSchema*)(uintptr_t)req[2];
    BeansJsonNewListFn new_list =
        (BeansJsonNewListFn)(uintptr_t)req[8];
    BeansJsonAllocFn allocate =
        (BeansJsonAllocFn)(uintptr_t)req[10];
    BeansJsonReleaseFn release =
        (BeansJsonReleaseFn)(uintptr_t)req[11];
    req[5] = 0;
    req[6] = 0;
    req[7] = UINT64_MAX;
    if (!schema || !schema->keys || !schema->fields || !allocate ||
        !release || schema->record_size == 0) {
        req[5] = BEANS_JSON_TYPED_ERR_TYPE;
        return BEANS_ENC_ERR_INVALID;
    }
    size_t len = (size_t)req[0];
    if (len == 0) {
        req[5] = BEANS_JSON_ERR_EMPTY;
        return BEANS_ENC_ERR_INVALID;
    }
    yyjson_read_flag flags = YYJSON_READ_NOFLAG;
    if (req[1] & BEANS_JSON_READ_ALLOW_COMMENTS)
        flags |= YYJSON_READ_ALLOW_COMMENTS;
    if (req[1] & BEANS_JSON_READ_ALLOW_TRAILING_COMMAS)
        flags |= YYJSON_READ_ALLOW_TRAILING_COMMAS;
    if (req[1] & BEANS_JSON_READ_ALLOW_INF_AND_NAN)
        flags |= YYJSON_READ_ALLOW_INF_AND_NAN;
    if (req[1] & BEANS_JSON_READ_INSITU)
        flags |= YYJSON_READ_INSITU;
    yyjson_read_err error;
    yyjson_doc* doc = yyjson_read_opts((char*)src, len, flags, NULL, &error);
    if (!doc) {
        req[5] = beans_enc_json_map_read_code(error.code);
        req[6] = (uint64_t)error.pos;
        return BEANS_ENC_ERR_INVALID;
    }

    yyjson_val* root = yyjson_doc_get_root(doc);
    if (!beans_json_typed_check_depth(root, req[1], req)) {
        yyjson_doc_free(doc);
        return BEANS_ENC_ERR_INVALID;
    }
    int root_array = (schema->flags & BEANS_JSON_TYPED_ROOT_ARRAY) != 0;
    if ((!root_array && !yyjson_is_obj(root)) ||
        (root_array && !yyjson_is_arr(root))) {
        req[5] = BEANS_JSON_TYPED_ERR_ROOT;
        yyjson_doc_free(doc);
        return BEANS_ENC_ERR_TYPE;
    }
    size_t count = root_array ? yyjson_arr_size(root) : 1;
    req[6] = (uint64_t)count;
    BeansJsonDecodeContext context = {new_list, allocate, release, req};

    long long status = BEANS_ENC_OK;
    void* list = NULL;
    if (root_array) {
        if (!new_list || count > INT64_MAX) {
            status = BEANS_ENC_ERR_MEMORY;
            req[5] = BEANS_JSON_ERR_MEMORY;
        } else {
            list = new_list(
                            beans_json_typed_storage_stride(
                                schema->record_size,
                                BEANS_JSON_TYPED_STRUCT),
                            (long long)schema->pointer_mask,
                            (long long)count);
            req[3] = (uint64_t)(uintptr_t)list;
            BeansJsonListPrefix* output = (BeansJsonListPrefix*)list;
            yyjson_arr_iter iterator;
            yyjson_arr_iter_init(root, &iterator);
            yyjson_val* item;
            size_t index = 0;
            size_t stride = beans_json_typed_list_stride(output);
            while ((item = yyjson_arr_iter_next(&iterator)) != NULL) {
                unsigned char* record =
                    (unsigned char*)output->data +
                    index * stride;
                beans_json_typed_init_record(schema, record);
                output->len = (uint64_t)++index;
                status = beans_json_typed_object_direct(
                    schema, item, record, &context);
                if (status != BEANS_ENC_OK) break;
            }
        }
        if (status != BEANS_ENC_OK && list) {
            release(list);
            req[3] = 0;
        }
    } else {
        unsigned char* record = (unsigned char*)(uintptr_t)req[3];
        beans_json_typed_init_record(schema, record);
        status = beans_json_typed_object_direct(
            schema, root, record, &context);
        if (status != BEANS_ENC_OK)
            beans_json_typed_release_record(schema, record, release);
    }
    yyjson_doc_free(doc);
    if (status == BEANS_ENC_OK) req[7] = UINT64_MAX;
    return status;
}

// req[0]=text length, req[1]=yyjson read flags, req[2]=schema pointer
// out: req[3]=typed handle, req[4]=field slots, req[5]=error code,
//      req[6]=record count on success/error byte offset on parse failure,
//      req[7]=field index (UINT64_MAX if unknown)
// Each field owns four u64 words: state, payload word 0, payload word 1,
// and one reserved word for wider scalar support.
BEANS_ENC_API long long beans_enc_json_typed_bind(unsigned char* src,
                                                  uint64_t* req) {
    size_t len = (size_t)req[0];
    const BeansJsonTypedSchema* schema =
        (const BeansJsonTypedSchema*)(uintptr_t)req[2];
    req[3] = 0;
    req[4] = 0;
    req[5] = 0;
    req[6] = 0;
    req[7] = UINT64_MAX;
    if (!schema || !schema->keys || !schema->fields) {
        req[5] = BEANS_JSON_TYPED_ERR_TYPE;
        return BEANS_ENC_ERR_INVALID;
    }
    if (len == 0) {
        req[5] = BEANS_JSON_ERR_EMPTY;
        return BEANS_ENC_ERR_INVALID;
    }

    yyjson_read_flag flags = YYJSON_READ_NOFLAG;
    if (req[1] & BEANS_JSON_READ_ALLOW_COMMENTS) flags |= YYJSON_READ_ALLOW_COMMENTS;
    if (req[1] & BEANS_JSON_READ_ALLOW_TRAILING_COMMAS) flags |= YYJSON_READ_ALLOW_TRAILING_COMMAS;
    if (req[1] & BEANS_JSON_READ_ALLOW_INF_AND_NAN) flags |= YYJSON_READ_ALLOW_INF_AND_NAN;
    if (req[1] & BEANS_JSON_READ_INSITU) flags |= YYJSON_READ_INSITU;
    yyjson_read_err error;
    yyjson_doc* doc = yyjson_read_opts((char*)src, len, flags, NULL, &error);
    if (!doc) {
        req[5] = beans_enc_json_map_read_code(error.code);
        req[6] = (uint64_t)error.pos;
        return BEANS_ENC_ERR_INVALID;
    }
    yyjson_val* root = yyjson_doc_get_root(doc);
    if (!beans_json_typed_check_depth(root, req[1], req)) {
        yyjson_doc_free(doc);
        return BEANS_ENC_ERR_INVALID;
    }
    const int root_array =
        (schema->flags & BEANS_JSON_TYPED_ROOT_ARRAY) != 0;
    if ((!root_array && !yyjson_is_obj(root)) ||
        (root_array && !yyjson_is_arr(root))) {
        req[5] = BEANS_JSON_TYPED_ERR_ROOT;
        yyjson_doc_free(doc);
        return BEANS_ENC_ERR_TYPE;
    }
    size_t record_count = root_array ? yyjson_arr_size(root) : 1;
    if (schema->field_count != 0 &&
        record_count > SIZE_MAX / (size_t)schema->field_count) {
        req[5] = BEANS_JSON_ERR_MEMORY;
        yyjson_doc_free(doc);
        return BEANS_ENC_ERR_MEMORY;
    }
    size_t slot_count = record_count * (size_t)schema->field_count;
    if (slot_count > SIZE_MAX / (4 * sizeof(uint64_t))) {
        req[5] = BEANS_JSON_ERR_MEMORY;
        yyjson_doc_free(doc);
        return BEANS_ENC_ERR_MEMORY;
    }
    uint64_t* slots = (uint64_t*)calloc(
        slot_count ? slot_count * 4 : 1, sizeof(uint64_t));
    BeansJsonTypedHandle* handle =
        (BeansJsonTypedHandle*)malloc(sizeof(BeansJsonTypedHandle));
    if (!slots || !handle) {
        free(slots);
        free(handle);
        yyjson_doc_free(doc);
        req[5] = BEANS_JSON_ERR_MEMORY;
        return BEANS_ENC_ERR_MEMORY;
    }
    handle->doc = doc;
    handle->slots = slots;
    req[3] = (uint64_t)(uintptr_t)handle;
    req[4] = (uint64_t)(uintptr_t)slots;
    req[6] = (uint64_t)record_count;

    if (root_array) {
        yyjson_arr_iter iterator;
        yyjson_arr_iter_init(root, &iterator);
        yyjson_val* item;
        size_t record = 0;
        while ((item = yyjson_arr_iter_next(&iterator)) != NULL) {
            int result = beans_json_typed_object(
                schema, item,
                slots + record * (size_t)schema->field_count * 4, req);
            if (result != BEANS_ENC_OK) return result;
            record += 1;
        }
    } else {
        int result = beans_json_typed_object(schema, root, slots, req);
        if (result != BEANS_ENC_OK) return result;
    }
    req[7] = UINT64_MAX;
    return BEANS_ENC_OK;
}

BEANS_ENC_API long long beans_enc_json_typed_free(long long handle_word) {
    BeansJsonTypedHandle* handle =
        (BeansJsonTypedHandle*)(uintptr_t)handle_word;
    if (!handle) return BEANS_ENC_OK;
    yyjson_doc_free(handle->doc);
    free(handle->slots);
    free(handle);
    return BEANS_ENC_OK;
}

typedef long long (*BeansJsonStringLenFn)(char*);

typedef struct {
    yyjson_mut_doc* doc;
    BeansJsonStringLenFn string_len;
    uint64_t* req;
} BeansJsonEncodeContext;

static yyjson_mut_val* beans_json_typed_encode_value(
        uint64_t kind, uint64_t flags,
        const BeansJsonTypedSchema* child_schema,
        uint64_t element_kind,
        const BeansJsonTypedSchema* element_schema,
        uint64_t element_size,
        const unsigned char* value,
        BeansJsonEncodeContext* context);

static uint64_t beans_json_typed_read_integer(const unsigned char* value,
                                              unsigned bits,
                                              int want_unsigned) {
    uint64_t raw = 0;
    if (bits == 8) {
        if (want_unsigned) {
            uint8_t number;
            memcpy(&number, value, sizeof(number));
            raw = number;
        } else {
            int8_t number;
            memcpy(&number, value, sizeof(number));
            raw = (uint64_t)(int64_t)number;
        }
    } else if (bits == 16) {
        if (want_unsigned) {
            uint16_t number;
            memcpy(&number, value, sizeof(number));
            raw = number;
        } else {
            int16_t number;
            memcpy(&number, value, sizeof(number));
            raw = (uint64_t)(int64_t)number;
        }
    } else if (bits == 32) {
        if (want_unsigned) {
            uint32_t number;
            memcpy(&number, value, sizeof(number));
            raw = number;
        } else {
            int32_t number;
            memcpy(&number, value, sizeof(number));
            raw = (uint64_t)(int64_t)number;
        }
    } else {
        memcpy(&raw, value, sizeof(raw));
    }
    return raw;
}

static yyjson_mut_val* beans_json_typed_encode_object(
        const BeansJsonTypedSchema* schema,
        const unsigned char* record,
        BeansJsonEncodeContext* context) {
    yyjson_mut_val* object = yyjson_mut_obj(context->doc);
    if (!object) return NULL;
    for (uint64_t index = 0; index < schema->field_count; index++) {
        const BeansJsonTypedField* field = &schema->fields[index];
        const BeansJsonTypedComplex* complex = schema->complex
            ? &schema->complex[index] : NULL;
        if (field->flags & BEANS_JSON_TYPED_IGNORED) continue;
        context->req[7] = index;

        const unsigned char* value = record + field->value_offset;
        int present = 1;
        if (field->flags & BEANS_JSON_TYPED_OPTIONAL) {
            if (field->presence_offset != UINT64_MAX) {
                present = record[field->presence_offset] != 0;
            } else if (field->flags & BEANS_JSON_TYPED_BOXED_OPTION) {
                uint64_t box_word = 0;
                memcpy(&box_word, record + field->value_offset,
                       sizeof(box_word));
                present = complex && box_word != complex->missing_value;
                if (present)
                    value = (const unsigned char*)(uintptr_t)box_word +
                            complex->box_value_offset;
            } else {
                void* pointer = NULL;
                memcpy(&pointer, record + field->value_offset,
                       sizeof(pointer));
                present = pointer != NULL;
            }
        }

        yyjson_mut_val* encoded = present
            ? beans_json_typed_encode_value(
                  field->kind, field->flags,
                  complex ? complex->child_schema : NULL,
                  complex ? complex->element_kind : 0,
                  complex ? complex->element_schema : NULL,
                  complex ? complex->element_size : 0,
                  value, context)
            : yyjson_mut_null(context->doc);
        yyjson_mut_val* key = yyjson_mut_strn(
            context->doc, (const char*)field->primary_name,
            (size_t)field->primary_name_len);
        if (!encoded || !key || !yyjson_mut_obj_add(object, key, encoded))
            return NULL;
    }
    return object;
}

static yyjson_mut_val* beans_json_typed_encode_list(
        uint64_t element_kind,
        const BeansJsonTypedSchema* element_schema,
        uint64_t element_size,
        const unsigned char* value,
        BeansJsonEncodeContext* context) {
    void* list_pointer = NULL;
    memcpy(&list_pointer, value, sizeof(list_pointer));
    if (!list_pointer || element_size == 0) return NULL;
    const BeansJsonListPrefix* list =
        (const BeansJsonListPrefix*)list_pointer;
    yyjson_mut_val* array = yyjson_mut_arr(context->doc);
    if (!array) return NULL;
    size_t stride = beans_json_typed_list_stride(list);
    for (uint64_t index = 0; index < list->len; index++) {
        const unsigned char* item =
            (const unsigned char*)list->data + index * stride;
        uint64_t element_flags =
            (element_kind == BEANS_JSON_TYPED_SINT ||
             element_kind == BEANS_JSON_TYPED_UINT)
                ? element_size * 8 << 8 : 0;
        yyjson_mut_val* encoded = beans_json_typed_encode_value(
            element_kind, element_flags, element_schema, 0, NULL, 0,
            item, context);
        if (!encoded || !yyjson_mut_arr_append(array, encoded)) return NULL;
    }
    return array;
}

static yyjson_mut_val* beans_json_typed_encode_value(
        uint64_t kind, uint64_t flags,
        const BeansJsonTypedSchema* child_schema,
        uint64_t element_kind,
        const BeansJsonTypedSchema* element_schema,
        uint64_t element_size,
        const unsigned char* value,
        BeansJsonEncodeContext* context) {
    if (kind == BEANS_JSON_TYPED_BOOL)
        return yyjson_mut_bool(context->doc, *value != 0);
    if (kind == BEANS_JSON_TYPED_SINT || kind == BEANS_JSON_TYPED_UINT) {
        unsigned bits = (unsigned)(flags >> 8);
        uint64_t integer = beans_json_typed_read_integer(
            value, bits, kind == BEANS_JSON_TYPED_UINT);
        return kind == BEANS_JSON_TYPED_UINT
            ? yyjson_mut_uint(context->doc, integer)
            : yyjson_mut_sint(context->doc, (int64_t)integer);
    }
    if (kind == BEANS_JSON_TYPED_F32) {
        float number;
        memcpy(&number, value, sizeof(number));
        return yyjson_mut_real(context->doc, (double)number);
    }
    if (kind == BEANS_JSON_TYPED_F64) {
        double number;
        memcpy(&number, value, sizeof(number));
        return yyjson_mut_real(context->doc, number);
    }
    if (kind == BEANS_JSON_TYPED_STRING) {
        void* string = NULL;
        memcpy(&string, value, sizeof(string));
        if (!string || !context->string_len) return NULL;
        long long length = context->string_len(string);
        if (length < 0) return NULL;
        return yyjson_mut_strn(
            context->doc, (const char*)string, (size_t)length);
    }
    if (kind == BEANS_JSON_TYPED_STRUCT && child_schema)
        return beans_json_typed_encode_object(child_schema, value, context);
    if (kind == BEANS_JSON_TYPED_LIST)
        return beans_json_typed_encode_list(
            element_kind, element_schema, element_size, value, context);
    return NULL;
}

// Compiler-generated typed encoding.
// root is a record address, or a List object when schema has ROOT_ARRAY.
// req[0]=schema, [1]=write mode, [2]=beans_str_len callback
// out: req[3]=buffer handle, [4]=byte length, [5]=write error,
//      [7]=field index on an invalid value.
BEANS_ENC_API long long beans_enc_json_typed_encode(
        unsigned char* root, uint64_t* req) {
    const BeansJsonTypedSchema* schema =
        (const BeansJsonTypedSchema*)(uintptr_t)req[0];
    BeansJsonStringLenFn string_len =
        (BeansJsonStringLenFn)(uintptr_t)req[2];
    req[3] = 0;
    req[4] = 0;
    req[5] = 0;
    req[7] = UINT64_MAX;
    if (!root || !schema || !schema->fields || !schema->complex ||
        !string_len) {
        req[5] = BEANS_JSON_WERR_INVALID;
        return BEANS_ENC_ERR_INVALID;
    }

    yyjson_mut_doc* doc = yyjson_mut_doc_new(NULL);
    if (!doc) {
        req[5] = BEANS_JSON_WERR_MEMORY;
        return BEANS_ENC_ERR_MEMORY;
    }
    BeansJsonEncodeContext context = {doc, string_len, req};
    yyjson_mut_val* value;
    if (schema->flags & BEANS_JSON_TYPED_ROOT_ARRAY) {
        void* list = root;
        value = beans_json_typed_encode_list(
            BEANS_JSON_TYPED_STRUCT, schema, schema->record_size,
            (const unsigned char*)&list, &context);
    } else {
        value = beans_json_typed_encode_object(schema, root, &context);
    }
    if (!value) {
        yyjson_mut_doc_free(doc);
        req[5] = BEANS_JSON_WERR_MEMORY;
        return BEANS_ENC_ERR_MEMORY;
    }

    yyjson_write_flag flags = YYJSON_WRITE_NOFLAG;
    if (req[1] == BEANS_JSON_WRITE_PRETTY_FOUR)
        flags |= YYJSON_WRITE_PRETTY;
    if (req[1] == BEANS_JSON_WRITE_PRETTY_TWO)
        flags |= YYJSON_WRITE_PRETTY_TWO_SPACES;
    size_t length = 0;
    yyjson_write_err error;
    char* text = yyjson_mut_val_write_opts(
        value, flags, NULL, &length, &error);
    yyjson_mut_doc_free(doc);
    if (!text) {
        if (error.code == YYJSON_WRITE_ERROR_NAN_OR_INF)
            req[5] = BEANS_JSON_WERR_NAN_INF;
        else if (error.code == YYJSON_WRITE_ERROR_MEMORY_ALLOCATION)
            req[5] = BEANS_JSON_WERR_MEMORY;
        else
            req[5] = BEANS_JSON_WERR_INVALID;
        return BEANS_ENC_ERR_INVALID;
    }
    req[3] = (uint64_t)(uintptr_t)text;
    req[4] = (uint64_t)length;
    req[7] = UINT64_MAX;
    return BEANS_ENC_OK;
}

BEANS_ENC_API long long beans_enc_json_kind(long long doc_word, long long val_word) {
    BeansEncJsonDoc* doc = (BeansEncJsonDoc*)(uintptr_t)doc_word;
    void* val = (void*)(uintptr_t)val_word;
    if (!doc || !val) return -1;
    yyjson_type type;
    yyjson_subtype subtype;
    if (doc->mutable_doc) {
        type = yyjson_mut_get_type((yyjson_mut_val*)val);
        subtype = yyjson_mut_get_subtype((yyjson_mut_val*)val);
    } else {
        type = yyjson_get_type((yyjson_val*)val);
        subtype = yyjson_get_subtype((yyjson_val*)val);
    }
    if (type == YYJSON_TYPE_NULL) return BEANS_JSON_NULL;
    if (type == YYJSON_TYPE_BOOL) return BEANS_JSON_BOOL;
    if (type == YYJSON_TYPE_NUM) {
        if (subtype == YYJSON_SUBTYPE_UINT) return BEANS_JSON_UINT;
        if (subtype == YYJSON_SUBTYPE_SINT) return BEANS_JSON_SINT;
        return BEANS_JSON_REAL;
    }
    if (type == YYJSON_TYPE_STR) return BEANS_JSON_STR;
    if (type == YYJSON_TYPE_ARR) return BEANS_JSON_ARR;
    if (type == YYJSON_TYPE_OBJ) return BEANS_JSON_OBJ;
    return -1;
}

BEANS_ENC_API long long beans_enc_json_get_bool(long long doc_word, long long val_word) {
    BeansEncJsonDoc* doc = (BeansEncJsonDoc*)(uintptr_t)doc_word;
    void* val = (void*)(uintptr_t)val_word;
    if (doc->mutable_doc) return yyjson_mut_get_bool((yyjson_mut_val*)val) ? 1 : 0;
    return yyjson_get_bool((yyjson_val*)val) ? 1 : 0;
}

BEANS_ENC_API long long beans_enc_json_get_sint(long long doc_word, long long val_word) {
    BeansEncJsonDoc* doc = (BeansEncJsonDoc*)(uintptr_t)doc_word;
    void* val = (void*)(uintptr_t)val_word;
    if (doc->mutable_doc) return (long long)yyjson_mut_get_sint((yyjson_mut_val*)val);
    return (long long)yyjson_get_sint((yyjson_val*)val);
}

// The u64 payload crosses as its raw bit pattern in the i64 return.
BEANS_ENC_API long long beans_enc_json_get_uint(long long doc_word, long long val_word) {
    BeansEncJsonDoc* doc = (BeansEncJsonDoc*)(uintptr_t)doc_word;
    void* val = (void*)(uintptr_t)val_word;
    if (doc->mutable_doc) return (long long)yyjson_mut_get_uint((yyjson_mut_val*)val);
    return (long long)yyjson_get_uint((yyjson_val*)val);
}

// The f64 payload crosses as its IEEE-754 bit pattern; json.b bit-casts it.
BEANS_ENC_API long long beans_enc_json_get_real_bits(long long doc_word, long long val_word) {
    BeansEncJsonDoc* doc = (BeansEncJsonDoc*)(uintptr_t)doc_word;
    void* val = (void*)(uintptr_t)val_word;
    double real;
    if (doc->mutable_doc) {
        real = yyjson_mut_get_real((yyjson_mut_val*)val);
    } else {
        real = yyjson_get_real((yyjson_val*)val);
    }
    uint64_t bits;
    memcpy(&bits, &real, sizeof bits);
    return (long long)bits;
}

// Byte length of a string value, or -1 when the value is not a string.
BEANS_ENC_API long long beans_enc_json_str_len(long long doc_word, long long val_word) {
    BeansEncJsonDoc* doc = (BeansEncJsonDoc*)(uintptr_t)doc_word;
    void* val = (void*)(uintptr_t)val_word;
    if (doc->mutable_doc) {
        if (!yyjson_mut_is_str((yyjson_mut_val*)val)) return -1;
        return (long long)yyjson_mut_get_len((yyjson_mut_val*)val);
    }
    if (!yyjson_is_str((yyjson_val*)val)) return -1;
    return (long long)yyjson_get_len((yyjson_val*)val);
}

// Copies the string payload into dst, which the caller sized from str_len.
// Embedded NULs are preserved; nothing is terminated.
BEANS_ENC_API long long beans_enc_json_str_copy(long long doc_word, long long val_word,
                                                unsigned char* dst) {
    BeansEncJsonDoc* doc = (BeansEncJsonDoc*)(uintptr_t)doc_word;
    void* val = (void*)(uintptr_t)val_word;
    const char* data;
    size_t len;
    if (doc->mutable_doc) {
        data = yyjson_mut_get_str((yyjson_mut_val*)val);
        len = yyjson_mut_get_len((yyjson_mut_val*)val);
    } else {
        data = yyjson_get_str((yyjson_val*)val);
        len = yyjson_get_len((yyjson_val*)val);
    }
    if (!data) return BEANS_ENC_ERR_TYPE;
    memcpy(dst, data, len);
    return BEANS_ENC_OK;
}

BEANS_ENC_API long long beans_enc_json_container_len(long long doc_word, long long val_word) {
    BeansEncJsonDoc* doc = (BeansEncJsonDoc*)(uintptr_t)doc_word;
    void* val = (void*)(uintptr_t)val_word;
    if (doc->mutable_doc) {
        yyjson_mut_val* value = (yyjson_mut_val*)val;
        if (yyjson_mut_is_arr(value)) return (long long)yyjson_mut_arr_size(value);
        if (yyjson_mut_is_obj(value)) return (long long)yyjson_mut_obj_size(value);
        return -1;
    }
    yyjson_val* value = (yyjson_val*)val;
    if (yyjson_is_arr(value)) return (long long)yyjson_arr_size(value);
    if (yyjson_is_obj(value)) return (long long)yyjson_obj_size(value);
    return -1;
}

// Element handle at `index`, or 0 when out of range or not an array.
// yyjson walks to the index, so random access is O(index); items() is the
// bulk path for whole-array iteration.
BEANS_ENC_API long long beans_enc_json_arr_get(long long doc_word, long long val_word,
                                               long long index) {
    BeansEncJsonDoc* doc = (BeansEncJsonDoc*)(uintptr_t)doc_word;
    void* val = (void*)(uintptr_t)val_word;
    if (index < 0) return 0;
    if (doc->mutable_doc) {
        return (long long)(uintptr_t)yyjson_mut_arr_get((yyjson_mut_val*)val,
                                                        (size_t)index);
    }
    return (long long)(uintptr_t)yyjson_arr_get((yyjson_val*)val, (size_t)index);
}

// Writes every element handle into out[0..n); the caller sized `out` from
// container_len. One crossing per array instead of one per element.
BEANS_ENC_API long long beans_enc_json_arr_items(long long doc_word, long long val_word,
                                                 uint64_t* out) {
    BeansEncJsonDoc* doc = (BeansEncJsonDoc*)(uintptr_t)doc_word;
    void* val = (void*)(uintptr_t)val_word;
    size_t index = 0;
    if (doc->mutable_doc) {
        yyjson_mut_val* arr = (yyjson_mut_val*)val;
        if (!yyjson_mut_is_arr(arr)) return BEANS_ENC_ERR_TYPE;
        yyjson_mut_arr_iter iter;
        yyjson_mut_arr_iter_init(arr, &iter);
        yyjson_mut_val* item;
        while ((item = yyjson_mut_arr_iter_next(&iter)) != NULL) {
            out[index++] = (uint64_t)(uintptr_t)item;
        }
        return BEANS_ENC_OK;
    }
    yyjson_val* arr = (yyjson_val*)val;
    if (!yyjson_is_arr(arr)) return BEANS_ENC_ERR_TYPE;
    yyjson_arr_iter iter;
    yyjson_arr_iter_init(arr, &iter);
    yyjson_val* item;
    while ((item = yyjson_arr_iter_next(&iter)) != NULL) {
        out[index++] = (uint64_t)(uintptr_t)item;
    }
    return BEANS_ENC_OK;
}

static size_t beans_enc_json_key_words(size_t key_len) {
    return (key_len + 7) / 8;
}

// Portable word count: [key length], [value handle], then copied key bytes.
// Native code uses the smaller borrowed-reference stream below instead.
BEANS_ENC_API long long beans_enc_json_obj_entries_words(long long doc_word,
                                                         long long val_word) {
    BeansEncJsonDoc* doc = (BeansEncJsonDoc*)(uintptr_t)doc_word;
    void* val = (void*)(uintptr_t)val_word;
    long long words = 0;
    if (doc->mutable_doc) {
        yyjson_mut_val* obj = (yyjson_mut_val*)val;
        if (!yyjson_mut_is_obj(obj)) return -1;
        yyjson_mut_obj_iter iter;
        yyjson_mut_obj_iter_init(obj, &iter);
        yyjson_mut_val* key;
        while ((key = yyjson_mut_obj_iter_next(&iter)) != NULL) {
            words += 2 + (long long)beans_enc_json_key_words(yyjson_mut_get_len(key));
        }
        return words;
    }
    yyjson_val* obj = (yyjson_val*)val;
    if (!yyjson_is_obj(obj)) return -1;
    yyjson_obj_iter iter;
    yyjson_obj_iter_init(obj, &iter);
    yyjson_val* key;
    while ((key = yyjson_obj_iter_next(&iter)) != NULL) {
        words += 2 + (long long)beans_enc_json_key_words(yyjson_get_len(key));
    }
    return words;
}

static size_t beans_enc_json_pack_entry(uint64_t* out, size_t index,
                                        const char* key, size_t key_len,
                                        void* value) {
    out[index++] = (uint64_t)key_len;
    out[index++] = (uint64_t)(uintptr_t)value;
    size_t words = beans_enc_json_key_words(key_len);
    if (words) {
        out[index + words - 1] = 0;
        memcpy(&out[index], key, key_len);
        index += words;
    }
    return index;
}

// Packs every (key, value) entry into `out` in document order, duplicates
// included; the caller sized `out` from obj_entries_words.
BEANS_ENC_API long long beans_enc_json_obj_entries_pack(long long doc_word,
                                                        long long val_word,
                                                        uint64_t* out) {
    BeansEncJsonDoc* doc = (BeansEncJsonDoc*)(uintptr_t)doc_word;
    void* val = (void*)(uintptr_t)val_word;
    size_t index = 0;
    if (doc->mutable_doc) {
        yyjson_mut_val* obj = (yyjson_mut_val*)val;
        if (!yyjson_mut_is_obj(obj)) return BEANS_ENC_ERR_TYPE;
        yyjson_mut_obj_iter iter;
        yyjson_mut_obj_iter_init(obj, &iter);
        yyjson_mut_val* key;
        while ((key = yyjson_mut_obj_iter_next(&iter)) != NULL) {
            index = beans_enc_json_pack_entry(
                out, index, yyjson_mut_get_str(key), yyjson_mut_get_len(key),
                yyjson_mut_obj_iter_get_val(key));
        }
        return BEANS_ENC_OK;
    }
    yyjson_val* obj = (yyjson_val*)val;
    if (!yyjson_is_obj(obj)) return BEANS_ENC_ERR_TYPE;
    yyjson_obj_iter iter;
    yyjson_obj_iter_init(obj, &iter);
    yyjson_val* key;
    while ((key = yyjson_obj_iter_next(&iter)) != NULL) {
        index = beans_enc_json_pack_entry(
            out, index, yyjson_get_str(key), yyjson_get_len(key),
            yyjson_obj_iter_get_val(key));
    }
    return BEANS_ENC_OK;
}

static size_t beans_enc_json_ref_entry(uint64_t* out, size_t index,
                                       const char* key, size_t key_len,
                                       void* value) {
    out[index++] = (uint64_t)key_len;
    out[index++] = (uint64_t)(uintptr_t)key;
    out[index++] = (uint64_t)(uintptr_t)value;
    return index;
}

// Native-only compact stream: [key length], [borrowed key pointer],
// [value handle]. The document keeps both references alive while entries()
// copies each key once into its final Beans string.
BEANS_ENC_API long long beans_enc_json_obj_entries_refs(long long doc_word,
                                                        long long val_word,
                                                        uint64_t* out) {
    BeansEncJsonDoc* doc = (BeansEncJsonDoc*)(uintptr_t)doc_word;
    void* val = (void*)(uintptr_t)val_word;
    size_t index = 0;
    if (doc->mutable_doc) {
        yyjson_mut_val* obj = (yyjson_mut_val*)val;
        if (!yyjson_mut_is_obj(obj)) return BEANS_ENC_ERR_TYPE;
        yyjson_mut_obj_iter iter;
        yyjson_mut_obj_iter_init(obj, &iter);
        yyjson_mut_val* key;
        while ((key = yyjson_mut_obj_iter_next(&iter)) != NULL) {
            index = beans_enc_json_ref_entry(
                out, index, yyjson_mut_get_str(key), yyjson_mut_get_len(key),
                yyjson_mut_obj_iter_get_val(key));
        }
        return BEANS_ENC_OK;
    }
    yyjson_val* obj = (yyjson_val*)val;
    if (!yyjson_is_obj(obj)) return BEANS_ENC_ERR_TYPE;
    yyjson_obj_iter iter;
    yyjson_obj_iter_init(obj, &iter);
    yyjson_val* key;
    while ((key = yyjson_obj_iter_next(&iter)) != NULL) {
        index = beans_enc_json_ref_entry(
            out, index, yyjson_get_str(key), yyjson_get_len(key),
            yyjson_obj_iter_get_val(key));
    }
    return BEANS_ENC_OK;
}

// req[0]=doc, req[1]=object, req[2]=key byte length
// out: req[3]=value handle (0 when absent). Duplicate keys: first match,
// matching yyjson_obj_getn; entries() exposes every duplicate.
BEANS_ENC_API long long beans_enc_json_obj_get(unsigned char* key, uint64_t* req) {
    BeansEncJsonDoc* doc = (BeansEncJsonDoc*)beans_enc_ptr(req, 0);
    void* val = beans_enc_ptr(req, 1);
    size_t key_len = (size_t)req[2];
    req[3] = 0;
    if (doc->mutable_doc) {
        yyjson_mut_val* obj = (yyjson_mut_val*)val;
        if (!yyjson_mut_is_obj(obj)) return BEANS_ENC_ERR_TYPE;
        req[3] = (uint64_t)(uintptr_t)yyjson_mut_obj_getn(obj, (const char*)key,
                                                          key_len);
        return BEANS_ENC_OK;
    }
    yyjson_val* obj = (yyjson_val*)val;
    if (!yyjson_is_obj(obj)) return BEANS_ENC_ERR_TYPE;
    req[3] = (uint64_t)(uintptr_t)yyjson_obj_getn(obj, (const char*)key, key_len);
    return BEANS_ENC_OK;
}

// ---- building ----

BEANS_ENC_API long long beans_enc_json_mut_new(void) {
    yyjson_mut_doc* doc = yyjson_mut_doc_new(NULL);
    if (!doc) return 0;
    BeansEncJsonDoc* handle = (BeansEncJsonDoc*)malloc(sizeof(BeansEncJsonDoc));
    if (!handle) {
        yyjson_mut_doc_free(doc);
        return 0;
    }
    handle->mutable_doc = 1;
    handle->imm = NULL;
    handle->mut = doc;
    return (long long)(uintptr_t)handle;
}

static yyjson_mut_doc* beans_enc_json_mut_of(long long doc_word) {
    BeansEncJsonDoc* doc = (BeansEncJsonDoc*)(uintptr_t)doc_word;
    if (!doc || !doc->mutable_doc) return NULL;
    return doc->mut;
}

BEANS_ENC_API long long beans_enc_json_mut_null(long long doc_word) {
    yyjson_mut_doc* doc = beans_enc_json_mut_of(doc_word);
    if (!doc) return 0;
    return (long long)(uintptr_t)yyjson_mut_null(doc);
}

BEANS_ENC_API long long beans_enc_json_mut_bool(long long doc_word, long long value) {
    yyjson_mut_doc* doc = beans_enc_json_mut_of(doc_word);
    if (!doc) return 0;
    return (long long)(uintptr_t)yyjson_mut_bool(doc, value != 0);
}

BEANS_ENC_API long long beans_enc_json_mut_sint(long long doc_word, long long value) {
    yyjson_mut_doc* doc = beans_enc_json_mut_of(doc_word);
    if (!doc) return 0;
    return (long long)(uintptr_t)yyjson_mut_sint(doc, value);
}

BEANS_ENC_API long long beans_enc_json_mut_uint(long long doc_word, long long bits) {
    yyjson_mut_doc* doc = beans_enc_json_mut_of(doc_word);
    if (!doc) return 0;
    return (long long)(uintptr_t)yyjson_mut_uint(doc, (uint64_t)bits);
}

BEANS_ENC_API long long beans_enc_json_mut_real(long long doc_word, long long bits) {
    yyjson_mut_doc* doc = beans_enc_json_mut_of(doc_word);
    if (!doc) return 0;
    double real;
    uint64_t raw = (uint64_t)bits;
    memcpy(&real, &raw, sizeof real);
    return (long long)(uintptr_t)yyjson_mut_real(doc, real);
}

BEANS_ENC_API long long beans_enc_json_mut_str(long long doc_word, unsigned char* src,
                                               long long len) {
    yyjson_mut_doc* doc = beans_enc_json_mut_of(doc_word);
    if (!doc) return 0;
    // strncpy stores an explicit length: embedded NULs survive.
    return (long long)(uintptr_t)yyjson_mut_strncpy(doc, (const char*)src,
                                                    (size_t)len);
}

BEANS_ENC_API long long beans_enc_json_mut_arr(long long doc_word) {
    yyjson_mut_doc* doc = beans_enc_json_mut_of(doc_word);
    if (!doc) return 0;
    return (long long)(uintptr_t)yyjson_mut_arr(doc);
}

BEANS_ENC_API long long beans_enc_json_mut_obj(long long doc_word) {
    yyjson_mut_doc* doc = beans_enc_json_mut_of(doc_word);
    if (!doc) return 0;
    return (long long)(uintptr_t)yyjson_mut_obj(doc);
}

// Deep-copies a value from any document into `dst`. Copy-always is the rule:
// a yyjson mutable value may sit in only one container, so aliasing a pushed
// Value would corrupt the tree. The Beans side pays one copy per insert and
// stays safe with no ownership bookkeeping across documents.
static yyjson_mut_val* beans_enc_json_copy_into(yyjson_mut_doc* dst,
                                                BeansEncJsonDoc* src_doc,
                                                void* src_val) {
    if (src_doc->mutable_doc) {
        return yyjson_mut_val_mut_copy(dst, (yyjson_mut_val*)src_val);
    }
    return yyjson_val_mut_copy(dst, (yyjson_val*)src_val);
}

// req[0]=dst doc, req[1]=array, req[2]=src doc, req[3]=src value
BEANS_ENC_API long long beans_enc_json_arr_push(uint64_t* req) {
    BeansEncJsonDoc* dst = (BeansEncJsonDoc*)beans_enc_ptr(req, 0);
    BeansEncJsonDoc* src = (BeansEncJsonDoc*)beans_enc_ptr(req, 2);
    if (!dst || !dst->mutable_doc) return BEANS_ENC_ERR_IMMUTABLE;
    yyjson_mut_val* arr = (yyjson_mut_val*)beans_enc_ptr(req, 1);
    if (!yyjson_mut_is_arr(arr)) return BEANS_ENC_ERR_TYPE;
    yyjson_mut_val* copy =
        beans_enc_json_copy_into(dst->mut, src, beans_enc_ptr(req, 3));
    if (!copy) return BEANS_ENC_ERR_MEMORY;
    if (!yyjson_mut_arr_append(arr, copy)) return BEANS_ENC_ERR_TYPE;
    return BEANS_ENC_OK;
}

// req[0]=dst doc, req[1]=object, req[2]=key byte length,
// req[3]=src doc, req[4]=src value.
// Appends without replacing: duplicate keys are preserved in entry order,
// the same behaviour a parsed document reports through entries().
BEANS_ENC_API long long beans_enc_json_obj_add(unsigned char* key, uint64_t* req) {
    BeansEncJsonDoc* dst = (BeansEncJsonDoc*)beans_enc_ptr(req, 0);
    BeansEncJsonDoc* src = (BeansEncJsonDoc*)beans_enc_ptr(req, 3);
    if (!dst || !dst->mutable_doc) return BEANS_ENC_ERR_IMMUTABLE;
    yyjson_mut_val* obj = (yyjson_mut_val*)beans_enc_ptr(req, 1);
    if (!yyjson_mut_is_obj(obj)) return BEANS_ENC_ERR_TYPE;
    yyjson_mut_val* key_val =
        yyjson_mut_strncpy(dst->mut, (const char*)key, (size_t)req[2]);
    if (!key_val) return BEANS_ENC_ERR_MEMORY;
    yyjson_mut_val* copy =
        beans_enc_json_copy_into(dst->mut, src, beans_enc_ptr(req, 4));
    if (!copy) return BEANS_ENC_ERR_MEMORY;
    if (!yyjson_mut_obj_add(obj, key_val, copy)) return BEANS_ENC_ERR_TYPE;
    return BEANS_ENC_OK;
}

// Marks a mutable document's root; write() with val=0 uses it.
BEANS_ENC_API long long beans_enc_json_mut_set_root(long long doc_word, long long val_word) {
    yyjson_mut_doc* doc = beans_enc_json_mut_of(doc_word);
    if (!doc) return BEANS_ENC_ERR_IMMUTABLE;
    yyjson_mut_doc_set_root(doc, (yyjson_mut_val*)(uintptr_t)val_word);
    return BEANS_ENC_OK;
}

// req[0]=doc, req[1]=value (0 = document root), req[2]=write mode
// out: req[3]=buffer handle (claim with take_buf), req[4]=byte len,
//      req[5]=write error code
BEANS_ENC_API long long beans_enc_json_write(uint64_t* req) {
    BeansEncJsonDoc* doc = (BeansEncJsonDoc*)beans_enc_ptr(req, 0);
    void* val = beans_enc_ptr(req, 1);
    uint64_t mode = req[2];
    yyjson_write_flag flags = YYJSON_WRITE_NOFLAG;
    if (mode == BEANS_JSON_WRITE_PRETTY_FOUR) flags |= YYJSON_WRITE_PRETTY;
    if (mode == BEANS_JSON_WRITE_PRETTY_TWO) flags |= YYJSON_WRITE_PRETTY_TWO_SPACES;
    req[3] = 0;
    req[4] = 0;
    req[5] = 0;
    size_t len = 0;
    yyjson_write_err err;
    err.code = YYJSON_WRITE_SUCCESS;
    char* text;
    if (doc->mutable_doc) {
        yyjson_mut_val* value = val ? (yyjson_mut_val*)val
                                    : yyjson_mut_doc_get_root(doc->mut);
        text = yyjson_mut_val_write_opts(value, flags, NULL, &len, &err);
    } else {
        yyjson_val* value = val ? (yyjson_val*)val
                                : yyjson_doc_get_root(doc->imm);
        text = yyjson_val_write_opts(value, flags, NULL, &len, &err);
    }
    if (!text) {
        if (err.code == YYJSON_WRITE_ERROR_NAN_OR_INF) {
            req[5] = BEANS_JSON_WERR_NAN_INF;
        } else if (err.code == YYJSON_WRITE_ERROR_MEMORY_ALLOCATION) {
            req[5] = BEANS_JSON_WERR_MEMORY;
        } else {
            req[5] = BEANS_JSON_WERR_INVALID;
        }
        return BEANS_ENC_ERR_INVALID;
    }
    req[3] = (uint64_t)(uintptr_t)text;
    req[4] = (uint64_t)len;
    return BEANS_ENC_OK;
}

// Copies a write buffer into dst (sized from the write's length) and frees
// the buffer. The handle is dead after this call, success or not.
BEANS_ENC_API long long beans_enc_json_take_buf(long long buf_word, long long len,
                                                unsigned char* dst) {
    char* text = (char*)(uintptr_t)buf_word;
    if (!text) return BEANS_ENC_ERR_INVALID;
    memcpy(dst, text, (size_t)len);
    free(text);
    return BEANS_ENC_OK;
}
