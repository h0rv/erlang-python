/* Included by py_nif.c. Execution uses the owning worker thread. Resource
 * destruction acquires the main interpreter GIL on the collecting thread. */

typedef struct {
    PyObject *value;
    py_context_t *ctx;
    py_env_resource_t *env;
} local_object_t;

static ErlNifResourceType *LOCAL_OBJECT_RESOURCE_TYPE;

static void local_object_destructor(ErlNifEnv *env, void *resource) {
    (void)env;
    local_object_t *ref = resource;
    /* Only main-interpreter references can be constructed. A context resource
     * is retained for identity, not kept running after explicit destruction. */
    if (ref->value != NULL && runtime_is_running()) {
        PyGILState_STATE gil = PyGILState_Ensure();
        Py_DECREF(ref->value);
        PyGILState_Release(gil);
    }
    if (ref->env != NULL) enif_release_resource(ref->env);
    if (ref->ctx != NULL) enif_release_resource(ref->ctx);
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
    if (ref->ctx != ctx) {
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
        PyObject *closed = PyObject_CallMethod(value, "close", NULL);
        Py_XDECREF(closed);
        Py_DECREF(value);
        PyErr_SetString(PyExc_RuntimeError, "An interpreter worker loop is already running");
        return NULL;
    }
    /* Reuse the interpreter's existing driver. Closing a fresh asyncio.Runner
     * after each call would invalidate loop-bound objects in actor state. */
    PyObject *driver = loop != NULL && loop->py_loop_valid && loop->py_loop != NULL
        ? Py_NewRef(loop->py_loop) : NULL;
    if (driver == NULL) {
        PyObject *module = PyImport_ImportModule("_erlang_impl");
        driver = module == NULL ? NULL : PyObject_CallMethod(module, "new_event_loop", NULL);
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
