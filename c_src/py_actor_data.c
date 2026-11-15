/* Included by py_nif.c. Shares the LoopRef admission counter implementation.
 * Ticket lock precedes gate lock. No Python execution occurs under either. */
typedef enum { ACTOR_RESERVED, ACTOR_ENQUEUED, ACTOR_COMMITTED, ACTOR_ABORTED, ACTOR_COMPLETE } actor_ticket_state;
typedef struct {
    pthread_mutex_t mutex;
    bool mutex_initialized;
    work_ticket_t *work;
    work_admission_t *gate;
    actor_ticket_state state;
    uint64_t bytes;
} actor_ticket_t;
static ErlNifResourceType *ACTOR_TICKET_RESOURCE_TYPE;
#define ACTOR_GATE_CAPSULE "erlang.actor_gate"
#define ACTOR_TICKET_CAPSULE "erlang.actor_ticket"

static void actor_resource_capsule_destroy(PyObject *capsule) {
    void *ptr = PyCapsule_GetPointer(capsule, PyCapsule_GetName(capsule));
    if (ptr != NULL) enif_release_resource(ptr);
}
static PyObject *actor_resource_capsule(void *ptr, const char *name) {
    enif_keep_resource(ptr);
    PyObject *result = PyCapsule_New(ptr, name, actor_resource_capsule_destroy);
    if (result == NULL) enif_release_resource(ptr);
    return result;
}
static ERL_NIF_TERM actor_data_to_term(ErlNifEnv *env, PyObject *value) {
    void *ptr = PyCapsule_GetPointer(value, PyCapsule_GetName(value));
    return enif_make_resource(env, ptr);
}
static PyObject *actor_data_from_term(ErlNifEnv *env, ERL_NIF_TERM value) {
    void *ptr;
    if (WORK_ADMISSION_RESOURCE_TYPE != NULL &&
        enif_get_resource(env, value, WORK_ADMISSION_RESOURCE_TYPE, &ptr))
        return actor_resource_capsule(ptr, ACTOR_GATE_CAPSULE);
    if (ACTOR_TICKET_RESOURCE_TYPE != NULL &&
        enif_get_resource(env, value, ACTOR_TICKET_RESOURCE_TYPE, &ptr))
        return actor_resource_capsule(ptr, ACTOR_TICKET_CAPSULE);
    return NULL;
}
static void actor_ticket_abort(actor_ticket_t *ticket) {
    pthread_mutex_lock(&ticket->mutex);
    if (ticket->state == ACTOR_RESERVED) {
        ticket->state = ACTOR_ABORTED;
        work_ticket_dispose(ticket->work);
        ticket->work = NULL;
    }
    pthread_mutex_unlock(&ticket->mutex);
}
static void actor_ticket_destroy(ErlNifEnv *env, void *ptr) {
    (void)env;
    actor_ticket_t *ticket = ptr;
    if (!ticket->mutex_initialized) return;
    actor_ticket_abort(ticket);
    if (ticket->work != NULL) {
        /* Lost completion is not evidence of stopped execution. */
        work_admission_close(ticket->gate);
        enif_release_resource(ticket->work->gate);
        enif_free(ticket->work);
    }
    enif_release_resource(ticket->gate);
    pthread_mutex_destroy(&ticket->mutex);
}
static int actor_data_init(ErlNifEnv *env) {
    ACTOR_TICKET_RESOURCE_TYPE = enif_open_resource_type(env, NULL,
        "py_actor_ticket", actor_ticket_destroy,
        ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER, NULL);
    return ACTOR_TICKET_RESOURCE_TYPE == NULL ? -1 : 0;
}
static ERL_NIF_TERM nif_actor_gate_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    ErlNifUInt64 count, bytes;
    ErlNifPid owner;
    if (!enif_get_uint64(env, argv[0], &count) || count == 0 ||
        !enif_get_uint64(env, argv[1], &bytes) || bytes == 0 || !enif_self(env, &owner))
        return enif_make_badarg(env);
    work_admission_t *gate = work_admission_new(env, &owner, count, bytes);
    if (gate == NULL) return make_error(env, "alloc_failed");
    ERL_NIF_TERM result = enif_make_resource(env, gate);
    enif_release_resource(gate);
    return result;
}
static ERL_NIF_TERM nif_actor_gate_info(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    work_admission_t *gate;
    if (!enif_get_resource(env, argv[0], WORK_ADMISSION_RESOURCE_TYPE, (void **)&gate))
        return enif_make_badarg(env);
    ERL_NIF_TERM result = work_admission_info(env, gate);
    pthread_mutex_lock(&gate->mutex);
    uint64_t unsettled = gate->unsettled;
    pthread_mutex_unlock(&gate->mutex);
    enif_make_map_put(env, result, enif_make_atom(env, "unsettled"),
        enif_make_uint64(env, unsettled), &result);
    return result;
}
static ERL_NIF_TERM nif_actor_ticket_commit(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    actor_ticket_t *ticket;
    work_admission_t *gate;
    ErlNifUInt64 bytes;
    if (!enif_get_resource(env, argv[0], ACTOR_TICKET_RESOURCE_TYPE, (void **)&ticket) ||
        !enif_get_resource(env, argv[1], WORK_ADMISSION_RESOURCE_TYPE, (void **)&gate) ||
        !enif_get_uint64(env, argv[2], &bytes)) return enif_make_badarg(env);
    pthread_mutex_lock(&ticket->mutex);
    const char *error = NULL;
    if (ticket->gate != gate || bytes != ticket->bytes) error = "ticket_mismatch";
    else if (ticket->state != ACTOR_RESERVED && ticket->state != ACTOR_ENQUEUED)
        error = "ticket_used";
    else {
        pthread_mutex_lock(&gate->mutex);
        if (!enif_is_process_alive(env, &gate->owner)) gate->closed = true;
        if (gate->closed) error = "admission_closed";
        else {
            if (ticket->state == ACTOR_RESERVED) gate->unsettled++;
            ticket->state = ACTOR_COMMITTED;
        }
        pthread_mutex_unlock(&gate->mutex);
    }
    pthread_mutex_unlock(&ticket->mutex);
    return error == NULL ? ATOM_OK : make_error(env, error);
}
/* Only the send failure/overflow paths possess proof that queued work will
 * never be dispatched. Caller abandonment cannot use this transition. */
static void actor_ticket_reject(actor_ticket_t *ticket) {
    pthread_mutex_lock(&ticket->mutex);
    if (ticket->state == ACTOR_RESERVED || ticket->state == ACTOR_ENQUEUED) {
        if (ticket->state == ACTOR_ENQUEUED) {
            pthread_mutex_lock(&ticket->gate->mutex);
            ticket->gate->unsettled--;
            pthread_mutex_unlock(&ticket->gate->mutex);
        }
        ticket->state = ACTOR_ABORTED;
        work_ticket_dispose(ticket->work);
        ticket->work = NULL;
    }
    pthread_mutex_unlock(&ticket->mutex);
}
static ERL_NIF_TERM nif_actor_ticket_reject(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    actor_ticket_t *ticket;
    if (!enif_get_resource(env, argv[0], ACTOR_TICKET_RESOURCE_TYPE, (void **)&ticket))
        return enif_make_badarg(env);
    actor_ticket_reject(ticket);
    return ATOM_OK;
}
static int actor_data_prepare(ErlNifEnv *env, PyObject *args) {
    if (PyTuple_Size(args) != 4) {
        PyErr_SetString(PyExc_TypeError, "Expected destination, gate, ticket, bytes");
        return -1;
    }
    work_admission_t *gate = PyCapsule_GetPointer(PyTuple_GetItem(args, 1), ACTOR_GATE_CAPSULE);
    if (gate == NULL) return -1;
    actor_ticket_t *ticket = PyCapsule_GetPointer(PyTuple_GetItem(args, 2), ACTOR_TICKET_CAPSULE);
    if (ticket == NULL) return -1;
    PyObject *destination = PyTuple_GetItem(args, 0);
    if (!Py_IS_TYPE(destination, &ErlangPidType) ||
        enif_compare_pids(&((ErlangPidObject *)destination)->pid, &gate->owner) != 0) {
        PyErr_SetString(PyExc_ValueError, "ticket_destination_mismatch");
        return -1;
    }
    PyObject *payload = PyTuple_GetItem(args, 3);
    if (!PyBytes_CheckExact(payload)) {
        PyErr_SetString(PyExc_TypeError, "Actor payload must be immutable bytes");
        return -1;
    }
    pthread_mutex_lock(&ticket->mutex);
    const char *error = NULL;
    if (ticket->gate != gate || ticket->bytes != (uint64_t)PyBytes_GET_SIZE(payload))
        error = "ticket_mismatch";
    else if (ticket->state != ACTOR_RESERVED) error = "ticket_used";
    else {
        pthread_mutex_lock(&gate->mutex);
        if (!enif_is_process_alive(env, &gate->owner)) gate->closed = true;
        if (gate->closed) error = "admission_closed";
        else {
            gate->unsettled++;
            ticket->state = ACTOR_ENQUEUED;
        }
        pthread_mutex_unlock(&gate->mutex);
    }
    pthread_mutex_unlock(&ticket->mutex);
    if (error != NULL) { PyErr_SetString(PyExc_RuntimeError, error); return -1; }
    return 0;
}
static void actor_data_send_failed(PyObject *args) {
    actor_ticket_t *ticket = PyCapsule_GetPointer(PyTuple_GetItem(args, 2), ACTOR_TICKET_CAPSULE);
    if (ticket != NULL) actor_ticket_reject(ticket);
}
static PyObject *python_actor_reserve(PyObject *self, PyObject *args) {
    (void)self;
    PyObject *capsule;
    unsigned long long bytes;
    if (!PyArg_ParseTuple(args, "OK", &capsule, &bytes)) return NULL;
    work_admission_t *gate = PyCapsule_GetPointer(capsule, ACTOR_GATE_CAPSULE);
    if (gate == NULL) return NULL;
    actor_ticket_t *ticket = enif_alloc_resource(ACTOR_TICKET_RESOURCE_TYPE, sizeof(*ticket));
    if (ticket == NULL) return PyErr_NoMemory();
    memset(ticket, 0, sizeof(*ticket));
    if (pthread_mutex_init(&ticket->mutex, NULL) != 0) {
        enif_release_resource(ticket);
        return PyErr_NoMemory();
    }
    ticket->mutex_initialized = true;
    ticket->gate = gate;
    ticket->bytes = bytes;
    ticket->state = ACTOR_ABORTED;
    enif_keep_resource(gate);
    ErlNifEnv *env = enif_alloc_env();
    const char *error = env == NULL ? "alloc_failed" :
        work_admission_reserve(env, gate, 0, bytes, &ticket->work);
    if (env != NULL) enif_free_env(env);
    if (error != NULL) {
        enif_release_resource(ticket);
        if (strcmp(error, "alloc_failed") == 0) return PyErr_NoMemory();
        PyObject *module = PyImport_ImportModule("_erlang_impl._actor_data");
        PyObject *exception = module == NULL ? NULL : PyObject_GetAttrString(module,
            strcmp(error, "overloaded") == 0 ? "ActorOverloaded" : "ActorAdmissionClosed");
        if (exception != NULL) PyErr_SetString(exception, error);
        Py_XDECREF(exception);
        Py_XDECREF(module);
        return NULL;
    }
    ticket->state = ACTOR_RESERVED;
    PyObject *result = actor_resource_capsule(ticket, ACTOR_TICKET_CAPSULE);
    enif_release_resource(ticket);
    return result;
}
static PyObject *python_actor_abort(PyObject *self, PyObject *capsule) {
    (void)self;
    actor_ticket_t *ticket = PyCapsule_GetPointer(capsule, ACTOR_TICKET_CAPSULE);
    if (ticket == NULL) return NULL;
    actor_ticket_abort(ticket);
    Py_RETURN_NONE;
}
static PyObject *python_actor_complete(PyObject *self, PyObject *capsule) {
    (void)self;
    actor_ticket_t *ticket = PyCapsule_GetPointer(capsule, ACTOR_TICKET_CAPSULE);
    if (ticket == NULL) return NULL;
    pthread_mutex_lock(&ticket->mutex);
    if (ticket->state != ACTOR_COMMITTED) {
        pthread_mutex_unlock(&ticket->mutex);
        PyErr_SetString(PyExc_RuntimeError, "ticket_not_committed");
        return NULL;
    }
    ticket->state = ACTOR_COMPLETE;
    pthread_mutex_lock(&ticket->gate->mutex);
    ticket->gate->unsettled--;
    pthread_mutex_unlock(&ticket->gate->mutex);
    work_ticket_dispose(ticket->work);
    ticket->work = NULL;
    pthread_mutex_unlock(&ticket->mutex);
    Py_RETURN_NONE;
}
