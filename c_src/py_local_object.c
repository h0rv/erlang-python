/* Included by py_nif.c. Execution uses the owning worker thread. Resource
 * destruction acquires the main interpreter GIL on the collecting thread. */

typedef struct {
    PyObject *value;
    PyObject *task_owner;
    py_context_t *ctx;
    py_env_resource_t *env;
    bool actor_owned;
    bool released;
    pthread_mutex_t mutex;
} local_object_t;

static ErlNifResourceType *LOCAL_OBJECT_RESOURCE_TYPE;
static atomic_size_t local_object_count;
static atomic_size_t local_object_value_count;
static atomic_size_t local_object_context_count;
static atomic_size_t local_object_env_count;

static PyObject *python_actor_retained_object_stats(PyObject *self, PyObject *unused) {
    (void)self;
    (void)unused;
    return Py_BuildValue("nnnn", (Py_ssize_t)atomic_load(&local_object_count),
        (Py_ssize_t)atomic_load(&local_object_value_count),
        (Py_ssize_t)atomic_load(&local_object_context_count),
        (Py_ssize_t)atomic_load(&local_object_env_count));
}

#define LOCAL_OBJECT_CAPSULE "erlang.local_object"

static void python_actor_capsule_destroy(PyObject *capsule) {
    void *ref = PyCapsule_GetPointer(capsule, LOCAL_OBJECT_CAPSULE);
    if (ref != NULL) enif_release_resource(ref);
}

/* Main-interpreter objects are portable across worker contexts, never across
 * interpreters. The capsule and every queued term own independent references. */
static PyObject *python_actor_retain(PyObject *self, PyObject *value) {
    (void)self;
    if (PyInterpreterState_GetID(PyInterpreterState_Get()) != 0) {
        PyErr_SetString(PyExc_RuntimeError, "Actors require the main interpreter");
        return NULL;
    }
    local_object_t *ref = enif_alloc_resource(LOCAL_OBJECT_RESOURCE_TYPE, sizeof(*ref));
    if (ref == NULL) return PyErr_NoMemory();
    ref->value = Py_NewRef(value);
    ref->ctx = NULL;
    ref->env = NULL;
    ref->actor_owned = false;
    atomic_fetch_add(&local_object_count, 1);
    atomic_fetch_add(&local_object_value_count, 1);
    PyObject *capsule = PyCapsule_New(ref, LOCAL_OBJECT_CAPSULE,
                                    python_actor_capsule_destroy);
    if (capsule == NULL) enif_release_resource(ref);
    return capsule;
}

static PyObject *python_actor_unwrap(PyObject *self, PyObject *value) {
    (void)self;
    if (PyInterpreterState_GetID(PyInterpreterState_Get()) != 0) {
        PyErr_SetString(PyExc_RuntimeError, "Actors require the main interpreter");
        return NULL;
    }
    local_object_t *ref = PyCapsule_GetPointer(value, LOCAL_OBJECT_CAPSULE);
    if (ref == NULL) return NULL;
    if (ref->actor_owned) {
        pthread_mutex_lock(&ref->mutex);
        PyObject *result = Py_XNewRef(ref->value);
        pthread_mutex_unlock(&ref->mutex);
        if (result == NULL)
            PyErr_SetString(PyExc_RuntimeError, "Actor object is uninitialized or released");
        return result;
    }
    if (ref->value == NULL) {
        PyErr_SetString(PyExc_RuntimeError, "Retained result was already transferred");
        return NULL;
    }
    return Py_NewRef(ref->value);
}

/* Only the task outcome consumer transfers terminal exceptions. GIL serializes
 * take/unwrap. Detach every edge before releasing native owners (which may
 * run destructors). The request/worker retain their own independent references;
 * taking a result never constitutes a completion or cleanup acknowledgement. */
static PyObject *python_actor_take_exception(PyObject *self, PyObject *value) {
    (void)self;
    if (PyInterpreterState_GetID(PyInterpreterState_Get()) != 0) {
        PyErr_SetString(PyExc_RuntimeError, "Actors require the main interpreter");
        return NULL;
    }
    local_object_t *ref = PyCapsule_GetPointer(value, LOCAL_OBJECT_CAPSULE);
    if (ref == NULL) return NULL;
    if (ref->value == NULL || !PyExceptionInstance_Check(ref->value)) {
        PyErr_SetString(PyExc_TypeError, "Expected an unconsumed retained exception");
        return NULL;
    }
    PyObject *error = ref->value;
    py_context_t *ctx = ref->ctx;
    py_env_resource_t *env = ref->env;
    ref->value = NULL;
    ref->ctx = NULL;
    ref->env = NULL;
    atomic_fetch_sub(&local_object_value_count, 1);
    if (env != NULL) {
        atomic_fetch_sub(&local_object_env_count, 1);
        enif_release_resource(env);
    }
    if (ctx != NULL) {
        atomic_fetch_sub(&local_object_context_count, 1);
        enif_release_resource(ctx);
    }
    return error;
}

static ERL_NIF_TERM python_actor_to_term(ErlNifEnv *env, PyObject *value) {
    void *ref = PyCapsule_GetPointer(value, LOCAL_OBJECT_CAPSULE);
    return enif_make_resource(env, ref);
}

static PyObject *python_actor_from_term(ErlNifEnv *env, ERL_NIF_TERM term) {
    local_object_t *ref;
    if (LOCAL_OBJECT_RESOURCE_TYPE == NULL ||
        !enif_get_resource(env, term, LOCAL_OBJECT_RESOURCE_TYPE, (void **)&ref))
        return NULL;
    if (PyInterpreterState_GetID(PyInterpreterState_Get()) != 0) {
        PyErr_SetString(PyExc_RuntimeError, "Actors require the main interpreter");
        return NULL;
    }
    enif_keep_resource(ref);
    PyObject *capsule = PyCapsule_New(ref, LOCAL_OBJECT_CAPSULE,
                                    python_actor_capsule_destroy);
    if (capsule == NULL) enif_release_resource(ref);
    return capsule;
}

static void local_object_destructor(ErlNifEnv *env, void *resource) {
    (void)env;
    local_object_t *ref = resource;
    atomic_fetch_sub(&local_object_count, 1);
    if (ref->value != NULL) atomic_fetch_sub(&local_object_value_count, 1);
    if (ref->ctx != NULL) atomic_fetch_sub(&local_object_context_count, 1);
    if (ref->env != NULL) atomic_fetch_sub(&local_object_env_count, 1);
    /* Only main-interpreter references can be constructed. A context resource
     * is retained for identity, not kept running after explicit destruction. */
    if ((ref->value != NULL || ref->actor_owned) && runtime_is_running()) {
        PyGILState_STATE gil = PyGILState_Ensure();
        Py_XDECREF(ref->value);
        if (ref->actor_owned) Py_XDECREF(ref->task_owner);
        PyGILState_Release(gil);
    }
    if (ref->env != NULL) enif_release_resource(ref->env);
    if (ref->ctx != NULL) enif_release_resource(ref->ctx);
    if (ref->actor_owned) pthread_mutex_destroy(&ref->mutex);
}

static ERL_NIF_TERM nif_actor_object_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    local_object_t *ref = enif_alloc_resource(LOCAL_OBJECT_RESOURCE_TYPE, sizeof(*ref));
    if (ref == NULL) return make_error(env, "alloc_failed");
    memset(ref, 0, sizeof(*ref));
    atomic_fetch_add(&local_object_count, 1);
    if (pthread_mutex_init(&ref->mutex, NULL) != 0) {
        enif_release_resource(ref);
        return make_error(env, "alloc_failed");
    }
    ref->actor_owned = true;
    ERL_NIF_TERM term = enif_make_resource(env, ref);
    enif_release_resource(ref);
    return term;
}

static PyObject *python_actor_construct(PyObject *self, PyObject *args) {
    PyObject *capsule, *factory_capsule, *owner;
    if (!PyArg_ParseTuple(args, "OOO", &capsule, &factory_capsule, &owner)) return NULL;
    if (PyInterpreterState_GetID(PyInterpreterState_Get()) != 0) {
        PyErr_SetString(PyExc_RuntimeError, "Actors require the main interpreter");
        return NULL;
    }
    local_object_t *ref = PyCapsule_GetPointer(capsule, LOCAL_OBJECT_CAPSULE);
    if (ref == NULL) return NULL;
    if (!ref->actor_owned) {
        PyErr_SetString(PyExc_TypeError, "Expected an actor-owned reference");
        return NULL;
    }
    PyObject *factory = python_actor_unwrap(self, factory_capsule);
    if (factory == NULL) return NULL;
    PyObject *value = PyObject_CallNoArgs(factory);
    Py_DECREF(factory);
    if (value == NULL) return NULL;
    pthread_mutex_lock(&ref->mutex);
    bool available = !ref->released && ref->value == NULL;
    if (available) {
        ref->value = Py_NewRef(value);
        ref->task_owner = Py_NewRef(owner);
        atomic_fetch_add(&local_object_value_count, 1);
    }
    pthread_mutex_unlock(&ref->mutex);
    Py_DECREF(value);
    if (!available) {
        PyErr_SetString(PyExc_RuntimeError, "Actor object is initialized or released");
        return NULL;
    }
    Py_RETURN_NONE;
}

static PyObject *python_actor_owner(PyObject *self, PyObject *capsule) {
    (void)self;
    local_object_t *ref = PyCapsule_GetPointer(capsule, LOCAL_OBJECT_CAPSULE);
    if (ref == NULL) return NULL;
    if (!ref->actor_owned) {
        PyErr_SetString(PyExc_TypeError, "Expected an actor-owned reference");
        return NULL;
    }
    pthread_mutex_lock(&ref->mutex);
    PyObject *owner = Py_XNewRef(ref->task_owner);
    pthread_mutex_unlock(&ref->mutex);
    if (owner == NULL)
        PyErr_SetString(PyExc_RuntimeError, "Actor object is uninitialized or released");
    return owner;
}

static ERL_NIF_TERM nif_actor_object_release(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    local_object_t *ref;
    if (!enif_get_resource(env, argv[0], LOCAL_OBJECT_RESOURCE_TYPE, (void **)&ref) ||
        !ref->actor_owned) return enif_make_badarg(env);
    PyGILState_STATE gil = PyGILState_Ensure();
    pthread_mutex_lock(&ref->mutex);
    PyObject *owner = Py_XNewRef(ref->task_owner);
    pthread_mutex_unlock(&ref->mutex);
    if (owner != NULL) {
        PyObject *module = PyImport_ImportModule("_erlang_impl._actor_data");
        PyObject *closed = module == NULL ? NULL : PyObject_CallMethod(module, "release", "O", owner);
        Py_DECREF(owner);
        Py_XDECREF(module);
        if (closed == NULL) {
            ERL_NIF_TERM error = make_py_error(env);
            PyGILState_Release(gil);
            return error;
        }
        Py_DECREF(closed);
    }
    pthread_mutex_lock(&ref->mutex);
    PyObject *value = ref->value;
    owner = ref->task_owner;
    ref->value = NULL;
    ref->task_owner = NULL;
    ref->released = true;
    pthread_mutex_unlock(&ref->mutex);
    if (value != NULL) atomic_fetch_sub(&local_object_value_count, 1);
    Py_XDECREF(value);
    Py_XDECREF(owner);
    PyGILState_Release(gil);
    return ATOM_OK;
}

/* Takes ownership of value, including on allocation failure. GIL held. */
static ERL_NIF_TERM local_object_result(py_context_t *ctx, py_env_resource_t *env,
                                         PyObject *value, const char *tag) {
    local_object_t *ref = enif_alloc_resource(LOCAL_OBJECT_RESOURCE_TYPE, sizeof(*ref));
    if (ref == NULL) {
        Py_DECREF(value);
        ctx->response_ok = false;
        return make_error(ctx->shared_env, "alloc_failed");
    }
    ref->value = value;
    ref->ctx = ctx;
    ref->env = env;
    ref->actor_owned = false;
    atomic_fetch_add(&local_object_count, 1);
    atomic_fetch_add(&local_object_value_count, 1);
    atomic_fetch_add(&local_object_context_count, 1);
    atomic_fetch_add(&local_object_env_count, 1);
    enif_keep_resource(ctx);
    enif_keep_resource(env);
    ERL_NIF_TERM term = enif_make_resource(ctx->shared_env, ref);
    enif_release_resource(ref);
    return enif_make_tuple2(ctx->shared_env, enif_make_atom(ctx->shared_env, tag), term);
}

static local_object_t *local_object_get(py_context_t *ctx, ERL_NIF_TERM term) {
    local_object_t *ref;
    if (!enif_get_resource(ctx->shared_env, term, LOCAL_OBJECT_RESOURCE_TYPE,
                           (void **)&ref)) {
        PyErr_SetString(PyExc_TypeError, "Expected a retained local object reference");
        return NULL;
    }
    if (ref->value == NULL) {
        PyErr_SetString(PyExc_RuntimeError, "Retained result was already transferred");
        return NULL;
    }
    if (ref->ctx != NULL && ref->ctx != ctx) {
        PyErr_SetString(PyExc_ValueError, "Local object belongs to another context");
        return NULL;
    }
    return ref;
}

static PyObject *local_object_eval(py_context_t *ctx, py_env_resource_t *penv,
                                    ERL_NIF_TERM code_term, ERL_NIF_TERM bindings) {
    ErlNifBinary code_bin;
    if (!enif_inspect_binary(ctx->shared_env, code_term, &code_bin) ||
        memchr(code_bin.data, '\0', code_bin.size) != NULL ||
        !enif_is_map(ctx->shared_env, bindings)) {
        PyErr_SetString(PyExc_TypeError, "Expected source and a map of local references");
        return NULL;
    }
    PyObject *locals = PyDict_Copy(penv->globals);
    if (locals == NULL) return NULL;
    ErlNifMapIterator iter;
    enif_map_iterator_create(ctx->shared_env, bindings, &iter, ERL_NIF_MAP_ITERATOR_FIRST);
    ERL_NIF_TERM key, term;
    bool valid = true;
    while (enif_map_iterator_get_pair(ctx->shared_env, &iter, &key, &term)) {
        ErlNifBinary name;
        local_object_t *ref = local_object_get(ctx, term);
        if (ref == NULL) { valid = false; break; }
        if (!enif_inspect_binary(ctx->shared_env, key, &name)) {
            PyErr_SetString(PyExc_TypeError, "Local binding names must be UTF-8 binaries");
            valid = false;
            break;
        }
        PyObject *py_name = PyUnicode_DecodeUTF8((char *)name.data, name.size, "strict");
        if (py_name == NULL || PyDict_SetItem(locals, py_name, ref->value) < 0) valid = false;
        Py_XDECREF(py_name);
        if (!valid) break;
        enif_map_iterator_next(ctx->shared_env, &iter);
    }
    enif_map_iterator_destroy(ctx->shared_env, &iter);
    PyObject *result = NULL;
    if (valid) {
        char *code = binary_to_string(&code_bin);
        if (code == NULL) PyErr_NoMemory();
        else {
            result = PyRun_String(code, Py_eval_input, penv->globals, locals);
            enif_free(code);
        }
    }
    Py_DECREF(locals);
    return result;
}

static PyObject *local_object_apply(py_context_t *ctx, const ERL_NIF_TERM *parts) {
    local_object_t *func = local_object_get(ctx, parts[1]);
    if (func == NULL) return NULL;
    local_object_t *args = local_object_get(ctx, parts[2]);
    if (args == NULL) return NULL;
    local_object_t *kwargs = local_object_get(ctx, parts[3]);
    if (kwargs == NULL) return NULL;
    if (!PyTuple_Check(args->value) || !PyDict_Check(kwargs->value)) {
        PyErr_SetString(PyExc_TypeError, "Expected a Python argument tuple and keyword dictionary");
        return NULL;
    }
    PyObject *value = PyObject_Call(func->value, args->value, kwargs->value);
    if (value == NULL || !PyCoro_CheckExact(value)) return value;

    erlang_event_loop_t *loop = get_interpreter_event_loop();
    if (loop != NULL && atomic_load(&loop->py_running)) {
        /* The owning context worker waits while the existing interpreter
         * driver executes the body. Future.result releases the GIL while
         * waiting; the OTP actor retains serialization and all input refs. */
        /* A successful task carrying an outcome preserves even an original
         * CancelledError/SystemExit object; Future cancellation translation
         * would otherwise replace it or stop the shared interpreter driver. */
        PyObject *module = PyImport_ImportModule("_erlang_impl._actors");
        PyObject *wrapped = module == NULL ? NULL
            : PyObject_CallMethod(module, "_outcome", "O", value);
        Py_XDECREF(module);
        PyObject *asyncio = wrapped == NULL ? NULL : PyImport_ImportModule("asyncio");
        bool submission_attempted = asyncio != NULL;
        PyObject *future = asyncio == NULL ? NULL : PyObject_CallMethod(
            asyncio, "run_coroutine_threadsafe", "OO", wrapped, loop->py_loop);
        Py_XDECREF(asyncio);
        PyObject *outcome = future == NULL ? NULL
            : PyObject_CallMethod(future, "result", NULL);
        Py_XDECREF(future);
        PyObject *result = NULL;
        if (outcome != NULL && PyTuple_Check(outcome) && PyTuple_Size(outcome) == 2) {
            PyObject *item = PyTuple_GetItem(outcome, 1);
            if (PyTuple_GetItem(outcome, 0) == Py_True) result = Py_NewRef(item);
            else if (PyExceptionInstance_Check(item)) PyErr_SetRaisedException(Py_NewRef(item));
            else PyErr_SetString(PyExc_RuntimeError, "Invalid actor exception outcome");
        } else if (outcome != NULL) {
            PyErr_SetString(PyExc_RuntimeError, "Invalid actor outcome");
        }
        Py_XDECREF(outcome);
        if (!submission_attempted && wrapped != NULL) {
            PyObject *error = PyErr_GetRaisedException();
            PyObject *closed = PyObject_CallMethod(wrapped, "close", NULL);
            Py_XDECREF(closed);
            PyErr_SetRaisedException(error);
        }
        Py_XDECREF(wrapped);
        /* A submission error may occur after a factory scheduled the real
         * task. Closing its coroutine would interrupt live async finalizers.
         * The task owner must retain credit until completion or sealed reap. */
        if (result == NULL && !submission_attempted) {
            PyObject *error = PyErr_GetRaisedException();
            PyObject *closed = PyObject_CallMethod(value, "close", NULL);
            Py_XDECREF(closed);
            PyErr_SetRaisedException(error);
        }
        Py_DECREF(value);
        return result;
    }
    /* Reuse the interpreter's existing driver. Closing a fresh asyncio.Runner
     * after each call would invalidate loop-bound objects in actor state. */
    PyObject *driver = loop != NULL && loop->py_loop_valid && loop->py_loop != NULL
        ? Py_NewRef(loop->py_loop) : NULL;
    if (driver == NULL) {
        PyObject *module = PyImport_ImportModule("_erlang_impl");
        driver = module == NULL ? NULL : PyObject_CallMethod(module, "_get_or_create_driver", NULL);
        Py_XDECREF(module);
    }
    PyObject *result = NULL;
    if (driver != NULL) {
        PyObject *asyncio = PyImport_ImportModule("asyncio");
        PyObject *set = asyncio == NULL ? NULL
            : PyObject_CallMethod(asyncio, "set_event_loop", "O", driver);
        Py_XDECREF(asyncio);
        if (set != NULL) {
            Py_DECREF(set);
            result = PyObject_CallMethod(driver, "run_until_complete", "O", value);
        }
        Py_DECREF(driver);
    }
    if (result == NULL && PyCoro_CheckExact(value)) {
        /* Closing an already awaited coroutine is harmless. Preserve the
         * original exception if startup failed before the coroutine ran. */
        PyObject *error = PyErr_GetRaisedException();
        PyObject *closed = PyObject_CallMethod(value, "close", NULL);
        Py_XDECREF(closed);
        PyErr_SetRaisedException(error);
    }
    Py_DECREF(value);
    return result;
}

static void ctx_execute_local_object(py_context_t *ctx) {
    py_env_resource_t *penv = ctx->local_env_ptr;
    ctx->local_env_ptr = NULL;
    if (penv == NULL || penv->interp_id != PyInterpreterState_GetID(PyInterpreterState_Get())) {
        ctx_set_error(ctx, "env_wrong_interpreter");
        return;
    }
    const ERL_NIF_TERM *parts;
    int arity;
    if (!enif_get_tuple(ctx->shared_env, ctx->request_term, &arity, &parts)) {
        ctx_set_error(ctx, "invalid_request");
        return;
    }
    py_context_t *prev_ctx = tl_current_context;
    py_env_resource_t *prev_env = tl_current_local_env;
    bool prev_suspend = tl_allow_suspension;
    tl_current_context = ctx;
    tl_current_local_env = penv;
    tl_allow_suspension = false;
    PyObject *value = NULL;
    if (ctx->request_type == CTX_REQ_LOCAL_EVAL && arity == 3)
        value = local_object_eval(ctx, penv, parts[1], parts[2]);
    else if (ctx->request_type == CTX_REQ_LOCAL_APPLY && arity == 4)
        value = local_object_apply(ctx, parts);
    else PyErr_SetString(PyExc_TypeError, "Invalid local object request");
    tl_current_context = prev_ctx;
    tl_current_local_env = prev_env;
    tl_allow_suspension = prev_suspend;
    if (value != NULL) {
        ctx->response_ok = true;
        ctx->response_term = local_object_result(ctx, penv, value, "ok");
    } else {
        PyObject *error = PyErr_GetRaisedException();
        if (error == NULL) error = PyObject_CallNoArgs(PyExc_RuntimeError);
        if (error == NULL) {
            PyErr_Clear();
            ctx_set_error(ctx, "alloc_failed");
            return;
        }
        ctx->response_term = local_object_result(ctx, penv, error, "python_error");
        ctx->response_ok = false;
    }
}

/* Request includes EnvRef as a term as well as local_env_ptr. The copied
 * request environment retains the namespace until queued/running work ends. */
static ERL_NIF_TERM nif_local_object_async(ErlNifEnv *env, int argc,
                                           const ERL_NIF_TERM argv[]) {
    (void)argc;
    py_context_t *ctx;
    py_env_resource_t *penv;
    ErlNifPid caller;
    if (!runtime_is_running()) return make_error(env, "python_not_running");
    if (!enif_get_resource(env, argv[0], PY_CONTEXT_RESOURCE_TYPE, (void **)&ctx))
        return make_error(env, "invalid_context");
    /* Main interpreter only until teardown-safe subinterpreter refs exist. */
    if (ctx->is_subinterp) return make_error(env, "local_objects_require_worker");
    if (!enif_get_local_pid(env, argv[1], &caller)) return make_error(env, "invalid_pid");
    if (!enif_get_resource(env, argv[4], PY_ENV_RESOURCE_TYPE, (void **)&penv))
        return make_error(env, "invalid_env");
    if (penv->interp_id != 0) return make_error(env, "env_wrong_interpreter");
    const ERL_NIF_TERM *parts;
    int arity;
    if (!enif_get_tuple(env, argv[3], &arity, &parts)) return make_error(env, "invalid_request");
    ctx_request_type_t type;
    if (arity == 3 && enif_is_identical(parts[0], enif_make_atom(env, "eval")))
        type = CTX_REQ_LOCAL_EVAL;
    else if (arity == 4 && enif_is_identical(parts[0], enif_make_atom(env, "apply")))
        type = CTX_REQ_LOCAL_APPLY;
    else return make_error(env, "invalid_request");
    /* Copy EnvRef and ContextRef into the queued request environment as well
     * as retaining all object inputs. A raw local_env_ptr does not own them. */
    ERL_NIF_TERM retained = enif_make_tuple3(env, argv[3], argv[4], argv[0]);
    ERL_NIF_TERM err;
    ctx_request_t *req = ctx_request_begin(env, ctx, type, &err);
    if (req == NULL) return err;
    ERL_NIF_TERM copy = enif_make_copy(req->request_env, retained);
    const ERL_NIF_TERM *retained_parts;
    enif_get_tuple(req->request_env, copy, &arity, &retained_parts);
    req->request_data = retained_parts[0];
    req->local_env_ptr = penv;
    req->async_mode = true;
    req->caller_pid = caller;
    req->request_id = enif_make_copy(req->request_env, argv[2]);
    ctx_queue_enqueue(ctx, req);
    return enif_make_tuple2(env, enif_make_atom(env, "enqueued"), argv[2]);
}
