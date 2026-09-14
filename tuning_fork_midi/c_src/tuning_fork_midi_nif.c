/*
 * MIDI ports, in and out, over minimidio.
 *
 * A port is a resource holding its own minimidio context and device. Output is pushed from
 * the BEAM; input arrives on minimidio's backend thread and is sent to an owner process.
 *
 * The inbound path follows erlsci/midiio (Apache-2.0), which worked out the lifecycle this
 * needs: keep the resource across the callback's life, build the message in a fresh
 * process-independent env, send with a NULL caller_env because the backend thread is not an
 * ERTS scheduler, and monitor the owner so an abandoned port is reclaimed rather than leaked.
 */

#if defined(__APPLE__)
#define MM_BACKEND_COREMIDI
#elif defined(_WIN32)
#define MM_BACKEND_WINMM
#else
#define MM_BACKEND_ALSA
#endif

#define MINIMIDIO_IMPLEMENTATION
#include "minimidio.h"

#include <erl_nif.h>
#include <string.h>
#include <stdio.h>

typedef struct {
    mm_context ctx;
    mm_device dev;
    ErlNifMutex *lock;
    ErlNifPid owner;
    ErlNifMonitor monitor;
    int input;
    int live;
    int kept;
    int monitored;
} tf_port;

static ErlNifResourceType *TF_PORT_TYPE = NULL;

static ERL_NIF_TERM am_ok;
static ERL_NIF_TERM am_error;
static ERL_NIF_TERM am_midi_in;

static ERL_NIF_TERM reason(ErlNifEnv *env, mm_result result)
{
    const char *text;

    switch (result) {
    case MM_INVALID_ARG:  text = "invalid_arg";  break;
    case MM_NO_BACKEND:   text = "no_backend";   break;
    case MM_OUT_OF_RANGE: text = "out_of_range"; break;
    case MM_ALREADY_OPEN: text = "already_open"; break;
    case MM_NOT_OPEN:     text = "not_open";     break;
    case MM_ALLOC_FAILED: text = "alloc_failed"; break;
    default:              text = "error";        break;
    }

    return enif_make_tuple2(env, am_error, enif_make_atom(env, text));
}

/* Shut a port down once, whoever gets there first: an explicit close, the owner dying, or
 * the resource being collected. */
static void reclaim(tf_port *port)
{
    int release = 0;

    enif_mutex_lock(port->lock);

    if (port->live) {
        port->live = 0;

        if (port->input) {
            mm_in_stop(&port->dev);
            mm_in_close(&port->dev);
        } else {
            mm_out_close(&port->dev);
        }

        mm_context_uninit(&port->ctx);
    }

    if (port->kept) {
        port->kept = 0;
        release = 1;
    }

    enif_mutex_unlock(port->lock);

    if (release)
        enif_release_resource(port);
}

static void tf_port_dtor(ErlNifEnv *env, void *obj)
{
    tf_port *port = (tf_port *)obj;

    (void)env;

    reclaim(port);

    if (port->lock != NULL) {
        enif_mutex_destroy(port->lock);
        port->lock = NULL;
    }
}

static void tf_port_down(ErlNifEnv *env, void *obj, ErlNifPid *pid, ErlNifMonitor *mon)
{
    (void)env;
    (void)pid;
    (void)mon;

    reclaim((tf_port *)obj);
}

/* Runs on minimidio's backend thread. The bytes are only valid for the length of this call,
 * so they are copied into the binary here rather than aliased. */
static void tf_recv(mm_device *dev, const uint8_t *bytes, size_t length, double stamp,
                    void *userdata)
{
    tf_port *port = (tf_port *)userdata;
    ErlNifEnv *env = enif_alloc_env();
    ERL_NIF_TERM payload;
    unsigned char *into = enif_make_new_binary(env, length, &payload);
    ErlNifPid owner;
    ERL_NIF_TERM message;

    (void)dev;

    if (length > 0)
        memcpy(into, bytes, length);

    message = enif_make_tuple4(env, am_midi_in, enif_make_resource(env, port), payload,
                               enif_make_int64(env, (ErlNifSInt64)(stamp * 1.0e9)));

    enif_mutex_lock(port->lock);
    owner = port->owner;
    enif_mutex_unlock(port->lock);

    enif_send(NULL, &owner, env, message);
    enif_free_env(env);
}

static tf_port *new_port(int input)
{
    tf_port *port = enif_alloc_resource(TF_PORT_TYPE, sizeof(tf_port));

    if (port == NULL)
        return NULL;

    memset(port, 0, sizeof(tf_port));
    port->input = input;
    port->lock = enif_mutex_create("tuning_fork_midi_port");

    if (port->lock == NULL) {
        enif_release_resource(port);
        return NULL;
    }

    return port;
}

static ERL_NIF_TERM named(ErlNifEnv *env, int input)
{
    mm_context ctx;
    mm_result result = mm_context_init(&ctx, "tuning_fork");
    ERL_NIF_TERM list;
    uint32_t count;
    uint32_t index;

    if (result != MM_SUCCESS)
        return reason(env, result);

    count = input ? mm_in_count(&ctx) : mm_out_count(&ctx);
    list = enif_make_list(env, 0);

    for (index = count; index > 0; index--) {
        char buffer[256];
        uint32_t at = index - 1;
        ERL_NIF_TERM name;

        buffer[0] = '\0';

        if (input)
            mm_in_name(&ctx, at, buffer, sizeof buffer);
        else
            mm_out_name(&ctx, at, buffer, sizeof buffer);

        name = enif_make_string(env, buffer, ERL_NIF_LATIN1);
        list = enif_make_list_cell(env, enif_make_tuple2(env, enif_make_uint(env, at), name),
                                   list);
    }

    mm_context_uninit(&ctx);

    return enif_make_tuple2(env, am_ok, list);
}

static ERL_NIF_TERM tf_outputs(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    (void)argv;

    return named(env, 0);
}

static ERL_NIF_TERM tf_inputs(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    (void)argv;

    return named(env, 1);
}

static ERL_NIF_TERM tf_open_output(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    unsigned int index;
    tf_port *port;
    mm_result result;
    ERL_NIF_TERM handle;

    (void)argc;

    if (!enif_get_uint(env, argv[0], &index))
        return enif_make_badarg(env);

    port = new_port(0);

    if (port == NULL)
        return reason(env, MM_ALLOC_FAILED);

    result = mm_context_init(&port->ctx, "tuning_fork");

    if (result != MM_SUCCESS) {
        enif_release_resource(port);
        return reason(env, result);
    }

    result = mm_out_open(&port->ctx, &port->dev, index);

    if (result != MM_SUCCESS) {
        mm_context_uninit(&port->ctx);
        enif_release_resource(port);
        return reason(env, result);
    }

    port->live = 1;
    handle = enif_make_resource(env, port);
    enif_release_resource(port);

    return enif_make_tuple2(env, am_ok, handle);
}

/* A source of our own that other applications can read from, so a DAW can be driven with no
 * hardware and no loopback bus set up first. */
static ERL_NIF_TERM tf_open_virtual_output(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    char name[64];
    tf_port *port;
    mm_result result;
    ERL_NIF_TERM handle;

    (void)argc;

    if (enif_get_string(env, argv[0], name, sizeof name, ERL_NIF_LATIN1) < 1)
        return enif_make_badarg(env);

    port = new_port(0);

    if (port == NULL)
        return reason(env, MM_ALLOC_FAILED);

    result = mm_context_init(&port->ctx, name);

    if (result != MM_SUCCESS) {
        enif_release_resource(port);
        return reason(env, result);
    }

    result = mm_out_open_virtual(&port->ctx, &port->dev);

    if (result != MM_SUCCESS) {
        mm_context_uninit(&port->ctx);
        enif_release_resource(port);
        return reason(env, result);
    }

    port->live = 1;
    handle = enif_make_resource(env, port);
    enif_release_resource(port);

    return enif_make_tuple2(env, am_ok, handle);
}

static ERL_NIF_TERM tf_open_virtual_input(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    char name[64];
    ErlNifPid owner;
    tf_port *port;
    mm_result result;
    ERL_NIF_TERM handle;

    (void)argc;

    if (enif_get_string(env, argv[0], name, sizeof name, ERL_NIF_LATIN1) < 1)
        return enif_make_badarg(env);

    if (!enif_get_local_pid(env, argv[1], &owner))
        return enif_make_badarg(env);

    port = new_port(1);

    if (port == NULL)
        return reason(env, MM_ALLOC_FAILED);

    port->owner = owner;
    result = mm_context_init(&port->ctx, name);

    if (result != MM_SUCCESS) {
        enif_release_resource(port);
        return reason(env, result);
    }

    result = mm_in_open_virtual_raw(&port->ctx, &port->dev, tf_recv, port);

    if (result != MM_SUCCESS) {
        mm_context_uninit(&port->ctx);
        enif_release_resource(port);
        return reason(env, result);
    }

    port->live = 1;
    enif_keep_resource(port);
    port->kept = 1;

    if (enif_monitor_process(env, port, &port->owner, &port->monitor) != 0) {
        reclaim(port);
        enif_release_resource(port);
        return reason(env, MM_NOT_OPEN);
    }

    port->monitored = 1;
    handle = enif_make_resource(env, port);
    enif_release_resource(port);

    return enif_make_tuple2(env, am_ok, handle);
}

static ERL_NIF_TERM tf_open_input(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    unsigned int index;
    ErlNifPid owner;
    tf_port *port;
    mm_result result;
    ERL_NIF_TERM handle;

    (void)argc;

    if (!enif_get_uint(env, argv[0], &index) || !enif_get_local_pid(env, argv[1], &owner))
        return enif_make_badarg(env);

    port = new_port(1);

    if (port == NULL)
        return reason(env, MM_ALLOC_FAILED);

    port->owner = owner;
    result = mm_context_init(&port->ctx, "tuning_fork");

    if (result != MM_SUCCESS) {
        enif_release_resource(port);
        return reason(env, result);
    }

    result = mm_in_open_raw(&port->ctx, &port->dev, index, tf_recv, port);

    if (result != MM_SUCCESS) {
        mm_context_uninit(&port->ctx);
        enif_release_resource(port);
        return reason(env, result);
    }

    port->live = 1;

    /* The backend thread holds the port as its userdata, so it is kept alive for as long as a
     * callback might fire. Released exactly once, in reclaim. */
    enif_keep_resource(port);
    port->kept = 1;

    if (enif_monitor_process(env, port, &port->owner, &port->monitor) != 0) {
        reclaim(port);
        enif_release_resource(port);
        return reason(env, MM_NOT_OPEN);
    }

    port->monitored = 1;
    handle = enif_make_resource(env, port);
    enif_release_resource(port);

    return enif_make_tuple2(env, am_ok, handle);
}

static ERL_NIF_TERM tf_listen(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    tf_port *port = NULL;
    mm_result result;

    (void)argc;

    if (!enif_get_resource(env, argv[0], TF_PORT_TYPE, (void **)&port))
        return enif_make_badarg(env);

    enif_mutex_lock(port->lock);
    result = (port->live && port->input) ? mm_in_start(&port->dev) : MM_NOT_OPEN;
    enif_mutex_unlock(port->lock);

    return (result == MM_SUCCESS) ? am_ok : reason(env, result);
}

static ERL_NIF_TERM tf_send(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    tf_port *port = NULL;
    ErlNifBinary bytes;
    mm_result result;

    (void)argc;

    if (!enif_get_resource(env, argv[0], TF_PORT_TYPE, (void **)&port))
        return enif_make_badarg(env);

    if (!enif_inspect_binary(env, argv[1], &bytes))
        return enif_make_badarg(env);

    enif_mutex_lock(port->lock);

    if (port->live && !port->input)
        result = mm_out_send_raw(&port->dev, bytes.data, bytes.size);
    else
        result = MM_NOT_OPEN;

    enif_mutex_unlock(port->lock);

    return (result == MM_SUCCESS) ? am_ok : reason(env, result);
}

static ERL_NIF_TERM tf_close(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    tf_port *port = NULL;

    (void)argc;

    if (!enif_get_resource(env, argv[0], TF_PORT_TYPE, (void **)&port))
        return enif_make_badarg(env);

    reclaim(port);

    return am_ok;
}

static int tf_load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info)
{
    ErlNifResourceTypeInit init = {tf_port_dtor, NULL, tf_port_down};

    (void)priv;
    (void)info;

    TF_PORT_TYPE = enif_open_resource_type_x(env, "tuning_fork_midi_port", &init,
                                             ERL_NIF_RT_CREATE, NULL);

    if (TF_PORT_TYPE == NULL)
        return 1;

    am_ok = enif_make_atom(env, "ok");
    am_error = enif_make_atom(env, "error");
    am_midi_in = enif_make_atom(env, "midi_in");

    return 0;
}

static ErlNifFunc tf_funcs[] = {
    {"outputs", 0, tf_outputs},
    {"inputs", 0, tf_inputs},
    {"open_output", 1, tf_open_output},
    {"open_input", 2, tf_open_input},
    {"open_virtual_output_nif", 1, tf_open_virtual_output},
    {"open_virtual_input_nif", 2, tf_open_virtual_input},
    {"listen", 1, tf_listen},
    {"send", 2, tf_send},
    {"close", 1, tf_close},
};

ERL_NIF_INIT(Elixir.TuningFork.Midi.Port, tf_funcs, tf_load, NULL, NULL, NULL)
