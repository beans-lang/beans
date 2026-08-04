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

// Word count of the packed entries stream: per entry, [key byte length]
// [value handle] then the key bytes padded to whole words. -1 for non-objects.
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
// included; the caller sized `out` from obj_entries_words. Keys are byte
// copies, value handles stay opaque words.
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
