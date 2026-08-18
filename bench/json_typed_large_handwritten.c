// Handwritten yyjson baselines for bench/json_typed_large.sh.

#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "runtime/encoding/vendor/yyjson/yyjson.c"

typedef struct {
    uint64_t id;
    uint64_t user_id;
    int active;
    double score;
    char* name;
    size_t name_len;
    char* note;
    size_t note_len;
} Row;

// Match the generated Beans value layouts used by List<JsonBenchRow>.
typedef struct {
    long long* data;
    long long len;
    long long cap;
    long long stride;
    long long ptr_mask;
} BeansList;

typedef struct {
    uint64_t id;
    uint64_t user_id;
    _Bool active;
    double score;
    char* name;
    char* note;
} BeansRow;

extern void* beans_list_new_typed_capacity(long long stride,
                                            long long ptr_mask,
                                            long long capacity);
extern void beans_list_push_typed(BeansList* list, const void* value);
extern char* beans_str_from_raw(const char* data, long long length);
extern long long beans_str_len(char* value);
extern void beans_release(void* value);

// Standalone runtime metadata normally emitted by the Beans compiler.
long long beans_deinit_sel = 0;
long long beans_class_parents[1] = {0};

static uint64_t nanos(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (uint64_t)value.tv_sec * UINT64_C(1000000000) +
           (uint64_t)value.tv_nsec;
}

static char* copy_string(yyjson_val* value, size_t* len) {
    if (!value || yyjson_is_null(value)) {
        *len = 0;
        return NULL;
    }
    if (!yyjson_is_str(value)) return NULL;
    *len = yyjson_get_len(value);
    char* copy = (char*)malloc(*len + 1);
    if (!copy) return NULL;
    memcpy(copy, yyjson_get_str(value), *len);
    copy[*len] = 0;
    return copy;
}

static int key_is(yyjson_val* key, const char* text, size_t len) {
    return yyjson_get_len(key) == len &&
           memcmp(yyjson_get_str(key), text, len) == 0;
}

int main(int argc, char** argv) {
    if (argc != 2) return 2;
    FILE* file = fopen(argv[1], "rb");
    if (!file) return 2;
    fseek(file, 0, SEEK_END);
    long length_long = ftell(file);
    fseek(file, 0, SEEK_SET);
    size_t length = (size_t)length_long;
    char* input = (char*)malloc(length ? length : 1);
    if (!input || fread(input, 1, length, file) != length) return 2;
    fclose(file);

    uint64_t started = nanos();
    yyjson_doc* parse_doc = yyjson_read(input, length, 0);
    uint64_t parse_nanos = nanos() - started;
    if (!parse_doc) return 3;
    size_t records = yyjson_arr_size(yyjson_doc_get_root(parse_doc));
    yyjson_doc_free(parse_doc);
    printf("parse size=%zu records=%zu nanos=%llu mib_s=%llu\n", length,
           records, (unsigned long long)parse_nanos,
           (unsigned long long)((uint64_t)length * UINT64_C(1000000000) /
                                (parse_nanos ? parse_nanos : 1) / 1048576));

    started = nanos();
    yyjson_doc* doc = yyjson_read(input, length, 0);
    if (!doc) return 3;
    yyjson_val* root = yyjson_doc_get_root(doc);
    records = yyjson_arr_size(root);
    Row* rows = (Row*)calloc(records ? records : 1, sizeof(Row));
    if (!rows) return 4;
    yyjson_arr_iter array;
    yyjson_arr_iter_init(root, &array);
    yyjson_val* object;
    size_t row_index = 0;
    while ((object = yyjson_arr_iter_next(&array)) != NULL) {
        Row* row = &rows[row_index++];
        yyjson_obj_iter fields;
        yyjson_obj_iter_init(object, &fields);
        yyjson_val* key;
        while ((key = yyjson_obj_iter_next(&fields)) != NULL) {
            yyjson_val* value = yyjson_obj_iter_get_val(key);
            if (key_is(key, "id", 2)) row->id = yyjson_get_uint(value);
            else if (key_is(key, "userId", 6)) row->user_id = yyjson_get_uint(value);
            else if (key_is(key, "active", 6)) row->active = yyjson_get_bool(value);
            else if (key_is(key, "score", 5)) row->score = yyjson_get_num(value);
            else if (key_is(key, "name", 4)) row->name = copy_string(value, &row->name_len);
            else if (key_is(key, "note", 4)) row->note = copy_string(value, &row->note_len);
        }
    }
    uint64_t map_nanos = nanos() - started;
    uint64_t checksum = 0;
    for (size_t index = 0; index < records; ++index) {
        checksum += rows[index].id + rows[index].user_id + rows[index].active +
                    rows[index].name_len + rows[index].note_len;
        free(rows[index].name);
        free(rows[index].note);
    }
    free(rows);
    yyjson_doc_free(doc);
    printf("handwritten_c size=%zu records=%zu nanos=%llu mib_s=%llu records_s=%llu checksum=%llu\n",
           length, records, (unsigned long long)map_nanos,
           (unsigned long long)((uint64_t)length * UINT64_C(1000000000) /
                                (map_nanos ? map_nanos : 1) / 1048576),
           (unsigned long long)((uint64_t)records * UINT64_C(1000000000) /
                                (map_nanos ? map_nanos : 1)),
           (unsigned long long)checksum);

    started = nanos();
    doc = yyjson_read(input, length, 0);
    if (!doc) return 3;
    root = yyjson_doc_get_root(doc);
    records = yyjson_arr_size(root);
    const long long pointer_mask =
        (1LL << (offsetof(BeansRow, name) / sizeof(void*))) |
        (1LL << (offsetof(BeansRow, note) / sizeof(void*)));
    BeansList* beans_rows = beans_list_new_typed_capacity(
        (long long)sizeof(BeansRow), pointer_mask, (long long)records);
    yyjson_arr_iter_init(root, &array);
    int strict_valid = 1;
    while ((object = yyjson_arr_iter_next(&array)) != NULL) {
        if (!yyjson_is_obj(object)) { strict_valid = 0; break; }
        BeansRow row = {0};
        uint64_t seen = 0;
        yyjson_obj_iter fields;
        yyjson_obj_iter_init(object, &fields);
        yyjson_val* key;
        while ((key = yyjson_obj_iter_next(&fields)) != NULL) {
            yyjson_val* value = yyjson_obj_iter_get_val(key);
            int field = key_is(key, "id", 2) ? 0 :
                key_is(key, "userId", 6) ? 1 :
                key_is(key, "active", 6) ? 2 :
                key_is(key, "score", 5) ? 3 :
                key_is(key, "name", 4) ? 4 :
                key_is(key, "note", 4) ? 5 : -1;
            if (field < 0 || (seen & (UINT64_C(1) << field))) {
                strict_valid = 0;
                break;
            }
            seen |= UINT64_C(1) << field;
            if (field == 0 && yyjson_is_uint(value)) {
                row.id = yyjson_get_uint(value);
            } else if (field == 1 && yyjson_is_uint(value)) {
                row.user_id = yyjson_get_uint(value);
            } else if (field == 2 && yyjson_is_bool(value)) {
                row.active = yyjson_get_bool(value);
            } else if (field == 3 && yyjson_is_num(value)) {
                row.score = yyjson_get_num(value);
            } else if (field == 4 && yyjson_is_str(value)) {
                row.name = beans_str_from_raw(yyjson_get_str(value),
                                              (long long)yyjson_get_len(value));
            } else if (field == 5 && yyjson_is_str(value)) {
                row.note = beans_str_from_raw(yyjson_get_str(value),
                                              (long long)yyjson_get_len(value));
            } else if (field != 5 || !yyjson_is_null(value)) {
                strict_valid = 0;
                break;
            }
        }
        if ((seen & UINT64_C(0x1f)) != UINT64_C(0x1f)) strict_valid = 0;
        if (!strict_valid) {
            beans_release(row.name);
            beans_release(row.note);
            break;
        }
        beans_list_push_typed(beans_rows, &row);
    }
    uint64_t beans_nanos = nanos() - started;
    if (!strict_valid) {
        beans_release(beans_rows);
        yyjson_doc_free(doc);
        free(input);
        return 5;
    }
    checksum = 0;
    for (long long index = 0; index < beans_rows->len; ++index) {
        BeansRow* row = (BeansRow*)((char*)beans_rows->data +
                                   index * beans_rows->stride);
        checksum += row->id + row->user_id + row->active;
        checksum += (uint64_t)beans_str_len(row->name);
        if (row->note) checksum += (uint64_t)beans_str_len(row->note);
    }
    printf("handwritten_beans_strict size=%zu records=%zu nanos=%llu mib_s=%llu records_s=%llu checksum=%llu\n",
           length, records, (unsigned long long)beans_nanos,
           (unsigned long long)((uint64_t)length * UINT64_C(1000000000) /
                                (beans_nanos ? beans_nanos : 1) / 1048576),
           (unsigned long long)((uint64_t)records * UINT64_C(1000000000) /
                                (beans_nanos ? beans_nanos : 1)),
           (unsigned long long)checksum);
    beans_release(beans_rows);
    yyjson_doc_free(doc);
    free(input);
    return 0;
}
