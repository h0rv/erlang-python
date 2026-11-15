#ifndef PY_WORK_ADMISSION_H
#define PY_WORK_ADMISSION_H

#include <erl_nif.h>
#include <stdint.h>
#include <stdbool.h>

typedef struct work_admission work_admission_t;
typedef struct work_ticket work_ticket_t;

struct work_ticket {
    work_admission_t *gate;
    uint64_t id;
    uint64_t bytes;
    bool released;
    work_ticket_t *next;
};

int work_admission_init(ErlNifEnv *env);
work_admission_t *work_admission_new(ErlNifEnv *env, ErlNifPid *owner,
                                    uint64_t capacity, uint64_t max_bytes);
void work_admission_close(work_admission_t *gate);
ERL_NIF_TERM work_admission_info(ErlNifEnv *env, work_admission_t *gate);
const char *work_admission_reserve(ErlNifEnv *env, work_admission_t *gate, uint64_t id,
                                  uint64_t bytes, work_ticket_t **ticket);
void work_ticket_dispose(work_ticket_t *ticket);

#endif
