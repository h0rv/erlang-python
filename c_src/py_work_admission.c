#include "py_work_admission.h"

/* Native invocation ownership only. Lock order: loop task_queue_mutex, then
 * gate mutex. The owner DOWN callback never acquires a GIL or loop mutex. */
struct work_admission {
    pthread_mutex_t mutex;
    bool mutex_initialized;
    ErlNifPid owner;
    ErlNifMonitor monitor;
    uint64_t capacity;
    uint64_t max_bytes;
    uint64_t count;
    uint64_t bytes;
    /* Work transferred to an external dispatch queue, whose completion may
     * outlive its owner process. Protected by the same admission mutex. */
    uint64_t unsettled;
    bool closed;
};

static ErlNifResourceType *WORK_ADMISSION_RESOURCE_TYPE;

static void work_admission_dtor(ErlNifEnv *env, void *obj) {
    (void)env;
    work_admission_t *gate = obj;
    if (gate->mutex_initialized) pthread_mutex_destroy(&gate->mutex);
}

void work_admission_close(work_admission_t *gate) {
    if (gate == NULL) return;
    pthread_mutex_lock(&gate->mutex);
    gate->closed = true;
    pthread_mutex_unlock(&gate->mutex);
}

static void work_admission_down(ErlNifEnv *env, void *obj, ErlNifPid *pid,
                                 ErlNifMonitor *monitor) {
    (void)env;
    (void)pid;
    (void)monitor;
    /* Death closes admission. It is NOT evidence that execution stopped. */
    work_admission_close(obj);
}

int work_admission_init(ErlNifEnv *env) {
    ErlNifResourceTypeInit init = {
        .dtor = work_admission_dtor,
        .down = work_admission_down,
        .members = 3
    };
    WORK_ADMISSION_RESOURCE_TYPE = enif_init_resource_type(
        env, "py_work_admission", &init, ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER, NULL);
    return WORK_ADMISSION_RESOURCE_TYPE == NULL ? -1 : 0;
}

work_admission_t *work_admission_new(ErlNifEnv *env, ErlNifPid *owner,
                                    uint64_t capacity, uint64_t max_bytes) {
    work_admission_t *gate = enif_alloc_resource(WORK_ADMISSION_RESOURCE_TYPE, sizeof(*gate));
    if (gate == NULL) return NULL;
    memset(gate, 0, sizeof(*gate));
    if (pthread_mutex_init(&gate->mutex, NULL) != 0) {
        enif_release_resource(gate);
        return NULL;
    }
    gate->mutex_initialized = true;
    gate->owner = *owner;
    gate->capacity = capacity;
    gate->max_bytes = max_bytes;
    if (enif_monitor_process(env, gate, owner, &gate->monitor) != 0)
        gate->closed = true;
    return gate;
}

ERL_NIF_TERM work_admission_info(ErlNifEnv *env, work_admission_t *gate) {
    const char *names[] = {"capacity", "max_bytes", "count", "bytes", "closed"};
    ERL_NIF_TERM keys[5], values[5], result;
    for (int i = 0; i < 5; i++) keys[i] = enif_make_atom(env, names[i]);
    pthread_mutex_lock(&gate->mutex);
    values[0] = enif_make_uint64(env, gate->capacity);
    values[1] = enif_make_uint64(env, gate->max_bytes);
    values[2] = enif_make_uint64(env, gate->count);
    values[3] = enif_make_uint64(env, gate->bytes);
    values[4] = enif_make_atom(env, gate->closed ? "true" : "false");
    pthread_mutex_unlock(&gate->mutex);
    enif_make_map_from_arrays(env, keys, values, 5, &result);
    return result;
}

const char *work_admission_reserve(ErlNifEnv *env, work_admission_t *gate, uint64_t id,
                                  uint64_t bytes, work_ticket_t **out) {
    work_ticket_t *ticket = enif_alloc(sizeof(*ticket));
    if (ticket == NULL) return "alloc_failed";
    pthread_mutex_lock(&gate->mutex);
    const char *error = NULL;
    if (!enif_is_process_alive(env, &gate->owner)) gate->closed = true;
    if (gate->closed) error = "admission_closed";
    else if (gate->count >= gate->capacity || bytes > gate->max_bytes - gate->bytes)
        error = "overloaded";
    if (error == NULL) {
        gate->count++;
        gate->bytes += bytes;
        enif_keep_resource(gate);
        *ticket = (work_ticket_t){.gate = gate, .id = id, .bytes = bytes};
        *out = ticket;
    }
    pthread_mutex_unlock(&gate->mutex);
    if (error != NULL) enif_free(ticket);
    return error;
}

static void work_ticket_release(work_ticket_t *ticket) {
    if (ticket == NULL || ticket->released) return;
    work_admission_t *gate = ticket->gate;
    pthread_mutex_lock(&gate->mutex);
    gate->count--;
    gate->bytes -= ticket->bytes;
    ticket->released = true;
    pthread_mutex_unlock(&gate->mutex);
    enif_release_resource(gate);
}

void work_ticket_dispose(work_ticket_t *ticket) {
    if (ticket == NULL) return;
    work_ticket_release(ticket);
    enif_free(ticket);
}

/* The capsule owns the ticket once native processing hands it to a Python
 * Task. Its destructor is NOT proof of task completion: if the callback is
 * discarded, close admission and leave the unresolved work charged. */
typedef struct {
    work_ticket_t *ticket;
    PyObject *coro;
} work_completion_t;

static void work_completion_dtor(PyObject *capsule) {
    work_completion_t *completion = PyCapsule_GetPointer(capsule, "py.work_completion");
    if (completion == NULL) { PyErr_Clear(); return; }
    if (!completion->ticket->released) {
        work_admission_close(completion->ticket->gate);
        enif_release_resource(completion->ticket->gate);
    }
    Py_XDECREF(completion->coro);
    enif_free(completion->ticket);
    enif_free(completion);
}

static PyObject *work_completion_call(PyObject *capsule, PyObject *task) {
    work_completion_t *completion = PyCapsule_GetPointer(capsule, "py.work_completion");
    if (completion == NULL) return NULL;
    if (completion->ticket->released) Py_RETURN_NONE;
    PyObject *done = PyObject_CallMethod(task, "done", NULL);
    if (done == NULL) return NULL;
    int ended = PyObject_IsTrue(done);
    Py_DECREF(done);
    if (ended < 0) return NULL;
    if (ended) {
        /* Also close an inner coroutine if its wrapper was cancelled before
         * its first step. A finished coroutine's close() is a no-op. */
        PyObject *closed = PyObject_CallMethod(completion->coro, "close", NULL);
        if (closed == NULL) {
            work_admission_close(completion->ticket->gate);
            return NULL;
        }
        Py_DECREF(closed);
        work_ticket_release(completion->ticket);
    }
    Py_RETURN_NONE;
}

static PyMethodDef work_completion_method = {
    "_complete_admitted_work", work_completion_call, METH_O, NULL
};

/* Transfers ownership to a callback, or releases it if callback construction
 * fails after capsule creation. Earlier failure leaves it with the batch.
 * Construct this BEFORE scheduling any Python work. */
static PyObject *work_completion_new(work_ticket_t **ticket, PyObject *coro) {
    work_completion_t *completion = enif_alloc(sizeof(*completion));
    if (completion == NULL) return PyErr_NoMemory();
    completion->ticket = *ticket;
    completion->coro = Py_NewRef(coro);
    PyObject *capsule = PyCapsule_New(completion, "py.work_completion", work_completion_dtor);
    if (capsule == NULL) {
        Py_DECREF(completion->coro);
        enif_free(completion);
        return NULL;
    }
    PyObject *callback = PyCFunction_New(&work_completion_method, capsule);
    if (callback == NULL) {
        /* Work has not started: release, then allow capsule destruction. */
        work_ticket_release(completion->ticket);
    }
    *ticket = NULL;
    Py_DECREF(capsule);
    return callback;
}

/* A custom factory may return a proxy whose done()/callbacks do not describe
 * actual work. Fail closed instead of trusting it. Construct the native Task
 * directly so the admission callback observes the real coroutine lifecycle. */
static PyObject *work_admission_create_task(PyObject *loop, PyObject *coro,
                                           bool *construction_attempted) {
    *construction_attempted = false;
    PyObject *factory = PyObject_CallMethod(loop, "get_task_factory", NULL);
    if (factory == NULL) return NULL;
    bool unsupported = factory != Py_None;
    Py_DECREF(factory);
    if (unsupported) {
        PyErr_SetString(PyExc_RuntimeError, "bounded submission does not support a custom task factory");
        return NULL;
    }
    PyObject *module = PyImport_ImportModule("_asyncio");
    if (module == NULL) return NULL;
    PyObject *task_type = PyObject_GetAttrString(module, "Task");
    Py_DECREF(module);
    if (task_type == NULL) return NULL;
    PyObject *args = PyTuple_Pack(1, coro);
    PyObject *kwargs = Py_BuildValue("{s:O,s:O}", "loop", loop, "eager_start", Py_False);
    PyObject *task = NULL;
    if (args != NULL && kwargs != NULL) {
        /* If construction raises after scheduling any work, NULL alone is
         * not a stop acknowledgment. The caller must conservatively close
         * admission rather than return this reservation. */
        *construction_attempted = true;
        task = PyObject_Call(task_type, args, kwargs);
    }
    Py_XDECREF(args);
    Py_XDECREF(kwargs);
    Py_DECREF(task_type);
    return task;
}

static void work_completion_not_started(PyObject *callback) {
    PyObject *capsule = PyCFunction_GetSelf(callback);
    work_completion_t *completion = PyCapsule_GetPointer(capsule, "py.work_completion");
    work_ticket_release(completion->ticket);
}
