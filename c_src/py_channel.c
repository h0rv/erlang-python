/*
 * Copyright 2026 Benoit Chesneau
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#include "py_channel.h"
#include "py_event_loop.h"

ErlNifResourceType *CHANNEL_RESOURCE_TYPE = NULL;
static _Atomic uint64_t g_channel_id_counter = 1;
static ERL_NIF_TERM ATOM_BUSY, ATOM_CLOSED, ATOM_EMPTY;

/* Readiness carries no delivery. Wake every eligible reader: cancelling one
 * notification cannot strand another reader behind data it never consumed.
 * These entries hold callbacks only, never producer payloads. */
static void wake_ready_locked(py_channel_t *channel) {
    channel_ready_waiter_t **link = &channel->ready_waiters;
    while (*link != NULL) {
        channel_ready_waiter_t *waiter = *link;
        bool ready = channel->closed || (waiter->writing
            ? ((channel->max_messages == 0 || channel->message_count < channel->max_messages)
                && (channel->max_size == 0 || (waiter->requested_size <= channel->max_size
                    && channel->current_size <= channel->max_size - waiter->requested_size)))
            : channel->message_count > 0);
        if (!ready) {
            link = &waiter->next;
            continue;
        }
        *link = waiter->next;
        event_loop_dispatch_reserved(waiter->loop, waiter->reserved_event, waiter->callback_id);
        enif_release_resource(waiter->loop);
        enif_free(waiter);
    }
}

/* Legacy waiter and condition-variable users share this resource. */
static void notify_locked(py_channel_t *channel) {
    wake_ready_locked(channel);
    if ((channel->message_count > 0 || channel->closed) && channel->has_waiter) {
        erlang_event_loop_t *loop = channel->waiter_loop;
        uint64_t id = channel->waiter_callback_id;
        channel->has_waiter = false;
        channel->waiter_loop = NULL;
        channel->waiter_callback_id = 0;
        event_loop_add_pending(loop, EVENT_TYPE_TIMER, id, -1);
        enif_release_resource(loop);
    }
    if ((channel->message_count > 0 || channel->closed) && channel->has_sync_waiter) {
        ErlNifEnv *env = enif_alloc_env();
        if (env != NULL) {
            enif_send(NULL, &channel->sync_waiter_pid, env,
                enif_make_atom(env, channel->closed ? "channel_closed" : "channel_data_ready"));
            enif_free_env(env);
        }
        channel->has_sync_waiter = false;
    }
    pthread_cond_broadcast(&channel->data_cond);
}

void channel_resource_dtor(ErlNifEnv *env, void *obj) {
    (void)env;
    py_channel_t *channel = obj;
    channel_ready_waiter_t *waiter = channel->ready_waiters;
    while (waiter != NULL) {
        channel_ready_waiter_t *next = waiter->next;
        event_loop_cancel_reserved(waiter->loop, waiter->reserved_event);
        enif_release_resource(waiter->loop);
        enif_free(waiter);
        waiter = next;
    }
    if (channel->waiter_loop != NULL) enif_release_resource(channel->waiter_loop);
    if (channel->queue != NULL) enif_ioq_destroy(channel->queue);
    if (channel->condition_initialized) pthread_cond_destroy(&channel->data_cond);
    if (channel->mutex_initialized) pthread_mutex_destroy(&channel->mutex);
}

py_channel_t *channel_alloc(size_t max_size) {
    if (CHANNEL_RESOURCE_TYPE == NULL) return NULL;
    py_channel_t *channel = enif_alloc_resource(CHANNEL_RESOURCE_TYPE, sizeof(*channel));
    if (channel == NULL) return NULL;
    memset(channel, 0, sizeof(*channel));
    /* Initialize destruction-safe members before any fallible allocation. */
    if (pthread_mutex_init(&channel->mutex, NULL) != 0) {
        enif_release_resource(channel);
        return NULL;
    }
    channel->mutex_initialized = true;
    if (pthread_cond_init(&channel->data_cond, NULL) != 0) {
        enif_release_resource(channel);
        return NULL;
    }
    channel->condition_initialized = true;
    channel->queue = enif_ioq_create(ERL_NIF_IOQ_NORMAL);
    if (channel->queue == NULL) {
        enif_release_resource(channel);
        return NULL;
    }
    channel->max_size = max_size;
    channel->channel_id = atomic_fetch_add(&g_channel_id_counter, 1);
    return channel;
}

int channel_send(py_channel_t *channel, const unsigned char *data, size_t size) {
    pthread_mutex_lock(&channel->mutex);
    if (channel->closed) {
        pthread_mutex_unlock(&channel->mutex);
        return -1;
    }
    if ((channel->max_size > 0 &&
            (size > channel->max_size || channel->current_size > channel->max_size - size)) ||
        (channel->max_messages > 0 && channel->message_count >= channel->max_messages)) {
        pthread_mutex_unlock(&channel->mutex);
        return 1;
    }
    if (size > SIZE_MAX - sizeof(size_t)) {
        pthread_mutex_unlock(&channel->mutex);
        return -2;
    }
    /* A length prefix preserves zero-byte messages and message boundaries even
     * if IOQueue coalesces adjacent vectors. Prefix bytes are not byte credits. */
    ErlNifBinary bin;
    if (!enif_alloc_binary(sizeof(size_t) + size, &bin)) {
        pthread_mutex_unlock(&channel->mutex);
        return -2;
    }
    memcpy(bin.data, &size, sizeof(size_t));
    if (size != 0) memcpy(bin.data + sizeof(size_t), data, size);
    if (!enif_ioq_enq_binary(channel->queue, &bin, 0)) {
        enif_release_binary(&bin);
        pthread_mutex_unlock(&channel->mutex);
        return -2;
    }
    channel->current_size += size;
    channel->message_count++;
    notify_locked(channel);
    pthread_mutex_unlock(&channel->mutex);
    return 0;
}

int channel_send_owned_binary(py_channel_t *channel, ErlNifBinary *bin) {
    int result = channel_send(channel, bin->data, bin->size);
    enif_release_binary(bin);
    return result;
}

static void copy_vectors(SysIOVec *iov, int count, size_t skip, unsigned char *out, size_t size) {
    for (int i = 0; i < count && size > 0; i++) {
        size_t length = iov[i].iov_len;
        if (skip >= length) {
            skip -= length;
            continue;
        }
        size_t take = length - skip;
        if (take > size) take = size;
        memcpy(out, (unsigned char *)iov[i].iov_base + skip, take);
        out += take;
        size -= take;
        skip = 0;
    }
}

int channel_pop_locked(py_channel_t *channel, unsigned char **out_data, size_t *out_size) {
    if (channel->message_count == 0) return channel->closed ? -1 : 1;
    int count;
    SysIOVec *iov = enif_ioq_peek(channel->queue, &count);
    if (iov == NULL || count == 0) return -2;
    size_t size;
    copy_vectors(iov, count, 0, (unsigned char *)&size, sizeof(size));
    unsigned char *data = enif_alloc(size == 0 ? 1 : size);
    if (data == NULL) return -2;
    copy_vectors(iov, count, sizeof(size), data, size);
    enif_ioq_deq(channel->queue, sizeof(size) + size, NULL);
    channel->current_size -= size;
    channel->message_count--;
    *out_data = data;
    *out_size = size;
    wake_ready_locked(channel);
    return 0;
}

int channel_try_receive(py_channel_t *channel, unsigned char **out_data, size_t *out_size) {
    pthread_mutex_lock(&channel->mutex);
    int result = channel_pop_locked(channel, out_data, out_size);
    pthread_mutex_unlock(&channel->mutex);
    return result;
}

int channel_receive_blocking(py_channel_t *channel, unsigned char **out_data,
                            size_t *out_size, long timeout_ms) {
    pthread_mutex_lock(&channel->mutex);
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    if (timeout_ms > 0) {
        deadline.tv_sec += timeout_ms / 1000;
        deadline.tv_nsec += (timeout_ms % 1000) * 1000000;
        if (deadline.tv_nsec >= 1000000000) {
            deadline.tv_sec++;
            deadline.tv_nsec -= 1000000000;
        }
    }
    while (channel->message_count == 0 && !channel->closed) {
        if (timeout_ms == 0 || (timeout_ms > 0 &&
            pthread_cond_timedwait(&channel->data_cond, &channel->mutex, &deadline) == ETIMEDOUT)) {
            pthread_mutex_unlock(&channel->mutex);
            return 1;
        }
        if (timeout_ms < 0) pthread_cond_wait(&channel->data_cond, &channel->mutex);
    }
    int result = channel_pop_locked(channel, out_data, out_size);
    pthread_mutex_unlock(&channel->mutex);
    return result;
}

int channel_wait_ready(py_channel_t *channel, erlang_event_loop_t *loop,
                       uint64_t callback_id, bool writing, size_t requested_size) {
    pthread_mutex_lock(&channel->mutex);
    bool ready = channel->closed || (writing
        ? ((channel->max_messages == 0 || channel->message_count < channel->max_messages)
            && (channel->max_size == 0 || (requested_size <= channel->max_size
                && channel->current_size <= channel->max_size - requested_size)))
        : channel->message_count > 0);
    if (ready) {
        pthread_mutex_unlock(&channel->mutex);
        return 1;
    }
    channel_ready_waiter_t *waiter = enif_alloc(sizeof(*waiter));
    if (waiter == NULL) {
        pthread_mutex_unlock(&channel->mutex);
        return -2;
    }
    bool overloaded;
    waiter->reserved_event = event_loop_reserve_pending(loop, &overloaded);
    if (waiter->reserved_event == NULL) {
        enif_free(waiter);
        pthread_mutex_unlock(&channel->mutex);
        return overloaded ? -3 : -2;
    }
    enif_keep_resource(loop);
    waiter->loop = loop;
    waiter->callback_id = callback_id;
    waiter->writing = writing;
    waiter->requested_size = requested_size;
    waiter->next = channel->ready_waiters;
    channel->ready_waiters = waiter;
    pthread_mutex_unlock(&channel->mutex);
    return 0;
}

void channel_cancel_ready(py_channel_t *channel, uint64_t callback_id) {
    pthread_mutex_lock(&channel->mutex);
    channel_ready_waiter_t **link = &channel->ready_waiters;
    while (*link != NULL) {
        channel_ready_waiter_t *waiter = *link;
        if (waiter->callback_id != callback_id) {
            link = &waiter->next;
            continue;
        }
        *link = waiter->next;
        event_loop_cancel_reserved(waiter->loop, waiter->reserved_event);
        enif_release_resource(waiter->loop);
        enif_free(waiter);
        break;
    }
    /* Eligibility changes broadcast readiness before cancellation can run.
     * No delivery or credit was reserved by the cancelled waiter. */
    pthread_mutex_unlock(&channel->mutex);
}

void channel_close(py_channel_t *channel) {
    pthread_mutex_lock(&channel->mutex);
    channel->closed = true;
    notify_locked(channel);
    pthread_mutex_unlock(&channel->mutex);
}

void channel_abort(py_channel_t *channel) {
    pthread_mutex_lock(&channel->mutex);
    channel->closed = true;
    channel->aborted = true;
    enif_ioq_deq(channel->queue, enif_ioq_size(channel->queue), NULL);
    channel->current_size = 0;
    channel->message_count = 0;
    notify_locked(channel);
    pthread_mutex_unlock(&channel->mutex);
}

int channel_init(ErlNifEnv *env) {
    ATOM_BUSY = enif_make_atom(env, "busy");
    ATOM_CLOSED = enif_make_atom(env, "closed");
    ATOM_EMPTY = enif_make_atom(env, "empty");
    return 0;
}

static ERL_NIF_TERM nif_channel_create(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifUInt64 bytes = 0, messages = 0;
    if ((argc > 0 && !enif_get_uint64(env, argv[0], &bytes)) ||
        (argc > 1 && !enif_get_uint64(env, argv[1], &messages))) return enif_make_badarg(env);
    py_channel_t *channel = channel_alloc(bytes);
    if (channel == NULL) return make_error(env, "alloc_failed");
    channel->max_messages = messages;
    enif_self(env, &channel->owner);
    ERL_NIF_TERM ref = enif_make_resource(env, channel);
    enif_release_resource(channel);
    return enif_make_tuple2(env, ATOM_OK, ref);
}

static ERL_NIF_TERM send_result(ErlNifEnv *env, int result) {
    if (result == 0) return ATOM_OK;
    if (result == 1) return ATOM_BUSY;
    return make_error(env, result == -1 ? "closed" : "alloc_failed");
}

static ERL_NIF_TERM nif_channel_send(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    py_channel_t *channel;
    if (!enif_get_resource(env, argv[0], CHANNEL_RESOURCE_TYPE, (void **)&channel))
        return make_error(env, "invalid_channel");
    ErlNifBinary bin;
    if (!enif_term_to_binary(env, argv[1], &bin)) return make_error(env, "term_to_binary_failed");
    return send_result(env, channel_send_owned_binary(channel, &bin));
}

static ERL_NIF_TERM receive_result(ErlNifEnv *env, int result, unsigned char *data, size_t size, bool bytes) {
    if (result == 1) return enif_make_tuple2(env, ATOM_ERROR, ATOM_EMPTY);
    if (result != 0) return make_error(env, result == -1 ? "closed" : "alloc_failed");
    ERL_NIF_TERM term;
    if (bytes) {
        unsigned char *out = enif_make_new_binary(env, size, &term);
        if (out == NULL && size > 0) { enif_free(data); return make_error(env, "alloc_failed"); }
        if (size > 0) memcpy(out, data, size);
    } else if (!enif_binary_to_term(env, data, size, &term, ERL_NIF_BIN2TERM_SAFE)) {
        enif_free(data);
        return make_error(env, "binary_to_term_failed");
    }
    enif_free(data);
    return enif_make_tuple2(env, ATOM_OK, term);
}

static ERL_NIF_TERM receive_nif(ErlNifEnv *env, ERL_NIF_TERM ref, bool bytes) {
    py_channel_t *channel;
    if (!enif_get_resource(env, ref, CHANNEL_RESOURCE_TYPE, (void **)&channel))
        return make_error(env, "invalid_channel");
    unsigned char *data = NULL;
    size_t size = 0;
    int result = channel_try_receive(channel, &data, &size);
    return receive_result(env, result, data, size, bytes);
}

static ERL_NIF_TERM nif_channel_receive(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    py_context_t *ctx;
    if (!enif_get_resource(env, argv[0], PY_CONTEXT_RESOURCE_TYPE, (void **)&ctx))
        return make_error(env, "invalid_context");
    return receive_nif(env, argv[1], false);
}
static ERL_NIF_TERM nif_channel_try_receive(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    return receive_nif(env, argv[0], false);
}
ERL_NIF_TERM nif_byte_channel_try_receive_bytes(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    return receive_nif(env, argv[0], true);
}
ERL_NIF_TERM nif_byte_channel_send_bytes(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    py_channel_t *channel;
    ErlNifBinary bin;
    if (!enif_get_resource(env, argv[0], CHANNEL_RESOURCE_TYPE, (void **)&channel))
        return make_error(env, "invalid_channel");
    if (!enif_inspect_binary(env, argv[1], &bin)) return make_error(env, "invalid_binary");
    return send_result(env, channel_send(channel, bin.data, bin.size));
}
static ERL_NIF_TERM nif_channel_reply(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    py_context_t *ctx;
    ErlNifPid pid;
    if (!enif_get_resource(env, argv[0], PY_CONTEXT_RESOURCE_TYPE, (void **)&ctx))
        return make_error(env, "invalid_context");
    if (!enif_get_local_pid(env, argv[1], &pid)) return make_error(env, "invalid_pid");
    return enif_send(env, &pid, NULL, argv[2]) ? ATOM_OK : make_error(env, "send_failed");
}
static ERL_NIF_TERM nif_channel_close(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    py_channel_t *channel;
    if (!enif_get_resource(env, argv[0], CHANNEL_RESOURCE_TYPE, (void **)&channel))
        return make_error(env, "invalid_channel");
    channel_close(channel);
    return ATOM_OK;
}
static ERL_NIF_TERM nif_channel_info(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    py_channel_t *channel;
    if (!enif_get_resource(env, argv[0], CHANNEL_RESOURCE_TYPE, (void **)&channel))
        return make_error(env, "invalid_channel");
    pthread_mutex_lock(&channel->mutex);
    ERL_NIF_TERM keys[] = {enif_make_atom(env,"size"), enif_make_atom(env,"max_size"),
        enif_make_atom(env,"closed"), enif_make_atom(env,"count"), enif_make_atom(env,"max_messages")};
    ERL_NIF_TERM values[] = {enif_make_uint64(env,channel->current_size),
        enif_make_uint64(env,channel->max_size), channel->closed ? ATOM_TRUE : ATOM_FALSE,
        enif_make_uint64(env,channel->message_count), enif_make_uint64(env,channel->max_messages)};
    pthread_mutex_unlock(&channel->mutex);
    ERL_NIF_TERM map;
    enif_make_map_from_arrays(env, keys, values, 5, &map);
    return map;
}

static ERL_NIF_TERM wait_nif(ErlNifEnv *env, const ERL_NIF_TERM argv[], bool bytes) {
    py_channel_t *channel;
    erlang_event_loop_t *loop;
    ErlNifUInt64 id;
    if (!enif_get_resource(env, argv[0], CHANNEL_RESOURCE_TYPE, (void **)&channel))
        return make_error(env, "invalid_channel");
    if (!enif_get_uint64(env, argv[1], &id)) return make_error(env, "invalid_callback_id");
    if (!enif_get_resource(env, argv[2], EVENT_LOOP_RESOURCE_TYPE, (void **)&loop))
        return make_error(env, "invalid_loop");
    pthread_mutex_lock(&channel->mutex);
    unsigned char *data = NULL;
    size_t size = 0;
    int result = channel_pop_locked(channel, &data, &size);
    if (result != 1) {
        pthread_mutex_unlock(&channel->mutex);
        return receive_result(env, result, data, size, bytes);
    }
    if (channel->has_waiter || channel->has_sync_waiter) {
        pthread_mutex_unlock(&channel->mutex);
        return make_error(env, "waiter_exists");
    }
    enif_keep_resource(loop);
    channel->waiter_loop = loop;
    channel->waiter_callback_id = id;
    channel->has_waiter = true;
    pthread_mutex_unlock(&channel->mutex);
    return ATOM_OK;
}
ERL_NIF_TERM nif_channel_wait(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc; return wait_nif(env, argv, false);
}
ERL_NIF_TERM nif_byte_channel_wait_bytes(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc; return wait_nif(env, argv, true);
}
ERL_NIF_TERM nif_channel_cancel_wait(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    py_channel_t *channel;
    ErlNifUInt64 id;
    if (!enif_get_resource(env, argv[0], CHANNEL_RESOURCE_TYPE, (void **)&channel))
        return make_error(env, "invalid_channel");
    if (!enif_get_uint64(env, argv[1], &id)) return make_error(env, "invalid_callback_id");
    pthread_mutex_lock(&channel->mutex);
    if (channel->has_waiter && channel->waiter_callback_id == id) {
        enif_release_resource(channel->waiter_loop);
        channel->waiter_loop = NULL;
        channel->has_waiter = false;
        channel->waiter_callback_id = 0;
    }
    pthread_mutex_unlock(&channel->mutex);
    return ATOM_OK;
}
ERL_NIF_TERM nif_channel_register_sync_waiter(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    py_channel_t *channel;
    if (!enif_get_resource(env, argv[0], CHANNEL_RESOURCE_TYPE, (void **)&channel))
        return make_error(env, "invalid_channel");
    pthread_mutex_lock(&channel->mutex);
    ERL_NIF_TERM result = ATOM_OK;
    if (channel->message_count > 0) result = enif_make_atom(env, "has_data");
    else if (channel->closed) result = make_error(env, "closed");
    else if (channel->has_waiter || channel->has_sync_waiter) result = make_error(env, "waiter_exists");
    else if (!enif_self(env, &channel->sync_waiter_pid)) result = make_error(env, "no_calling_process");
    else channel->has_sync_waiter = true;
    pthread_mutex_unlock(&channel->mutex);
    return result;
}

#define PY_CHANNEL_NIFS \
    {"channel_create", 0, nif_channel_create, 0}, \
    {"channel_create", 1, nif_channel_create, 0}, \
    {"channel_create", 2, nif_channel_create, 0}, \
    {"channel_send", 2, nif_channel_send, 0}, \
    {"channel_receive", 2, nif_channel_receive, 0}, \
    {"channel_try_receive", 1, nif_channel_try_receive, 0}, \
    {"channel_reply", 3, nif_channel_reply, 0}, \
    {"channel_close", 1, nif_channel_close, 0}, \
    {"channel_info", 1, nif_channel_info, 0}, \
    {"channel_wait", 3, nif_channel_wait, 0}, \
    {"channel_cancel_wait", 2, nif_channel_cancel_wait, 0}, \
    {"channel_register_sync_waiter", 1, nif_channel_register_sync_waiter, 0}, \
    {"byte_channel_send_bytes", 2, nif_byte_channel_send_bytes, 0}, \
    {"byte_channel_try_receive_bytes", 1, nif_byte_channel_try_receive_bytes, 0}, \
    {"byte_channel_wait_bytes", 3, nif_byte_channel_wait_bytes, 0}
