/*
 * A playback device and a ring buffer between the BEAM and the audio thread.
 *
 * Elixir writes PCM into the ring; miniaudio's callback drains it on its own thread and
 * never calls back into the VM. Only what miniaudio needs for a playback device is
 * compiled — no decoding, encoding, resource manager or node graph.
 */

#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

#include <erl_nif.h>
#include <string.h>

typedef struct {
    ma_device device;
    ma_pcm_rb ring;
    ma_uint32 channels;
    int open;
} tf_device;

static ErlNifResourceType *TF_DEVICE_TYPE = NULL;

/* Runs on the audio thread. Pulls whatever the ring has and pads the rest with silence, so
 * an underrun is a gap rather than a glitch or a stall. */
static void tf_data_callback(ma_device *device, void *output, const void *input, ma_uint32 frames)
{
    tf_device *state = (tf_device *)device->pUserData;
    ma_int16 *out = (ma_int16 *)output;
    ma_uint32 written = 0;

    (void)input;

    while (written < frames) {
        ma_uint32 wanted = frames - written;
        void *read_ptr = NULL;

        if (ma_pcm_rb_acquire_read(&state->ring, &wanted, &read_ptr) != MA_SUCCESS || wanted == 0) {
            break;
        }

        memcpy(out + (size_t)written * state->channels, read_ptr,
               (size_t)wanted * state->channels * sizeof(ma_int16));

        ma_pcm_rb_commit_read(&state->ring, wanted);
        written += wanted;
    }

    if (written < frames) {
        memset(out + (size_t)written * state->channels, 0,
               (size_t)(frames - written) * state->channels * sizeof(ma_int16));
    }
}

static void tf_device_dtor(ErlNifEnv *env, void *obj)
{
    tf_device *state = (tf_device *)obj;

    (void)env;

    if (state->open) {
        ma_device_uninit(&state->device);
        ma_pcm_rb_uninit(&state->ring);
        state->open = 0;
    }
}

static ERL_NIF_TERM tf_error(ErlNifEnv *env, const char *reason)
{
    return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, reason));
}

/* open(Rate, Channels, BufferFrames) -> {ok, Device} | {error, Reason} */
static ERL_NIF_TERM tf_open(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    unsigned int rate, channels, buffer_frames;
    tf_device *state;
    ERL_NIF_TERM result;
    ma_device_config config;

    if (argc != 3 || !enif_get_uint(env, argv[0], &rate) ||
        !enif_get_uint(env, argv[1], &channels) || !enif_get_uint(env, argv[2], &buffer_frames)) {
        return enif_make_badarg(env);
    }

    state = (tf_device *)enif_alloc_resource(TF_DEVICE_TYPE, sizeof(tf_device));
    if (state == NULL) {
        return tf_error(env, "alloc");
    }

    memset(state, 0, sizeof(tf_device));
    state->channels = channels;

    if (ma_pcm_rb_init(ma_format_s16, channels, buffer_frames, NULL, NULL, &state->ring) !=
        MA_SUCCESS) {
        enif_release_resource(state);
        return tf_error(env, "ring_buffer");
    }

    config = ma_device_config_init(ma_device_type_playback);
    config.playback.format = ma_format_s16;
    config.playback.channels = channels;
    config.sampleRate = rate;
    config.dataCallback = tf_data_callback;
    config.pUserData = state;
    /* The device asks for small buffers so its own queue is short. Latency is however much
     * audio is already committed, and a sound cannot be put into audio already handed over. */
    config.periodSizeInFrames = 128;
    config.periods = 2;
    config.performanceProfile = ma_performance_profile_low_latency;

    if (ma_device_init(NULL, &config, &state->device) != MA_SUCCESS) {
        ma_pcm_rb_uninit(&state->ring);
        enif_release_resource(state);
        return tf_error(env, "no_device");
    }

    if (ma_device_start(&state->device) != MA_SUCCESS) {
        ma_device_uninit(&state->device);
        ma_pcm_rb_uninit(&state->ring);
        enif_release_resource(state);
        return tf_error(env, "start_failed");
    }

    state->open = 1;
    result = enif_make_resource(env, state);
    enif_release_resource(state);

    return enif_make_tuple2(env, enif_make_atom(env, "ok"), result);
}

/* write(Device, Pcm) -> {ok, FramesWritten}. Short writes are the caller's signal to wait. */
static ERL_NIF_TERM tf_write(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    tf_device *state;
    ErlNifBinary pcm;
    ma_uint32 frames, written = 0;

    if (argc != 2 || !enif_get_resource(env, argv[0], TF_DEVICE_TYPE, (void **)&state) ||
        !enif_inspect_binary(env, argv[1], &pcm)) {
        return enif_make_badarg(env);
    }

    if (!state->open) {
        return tf_error(env, "closed");
    }

    frames = (ma_uint32)(pcm.size / (state->channels * sizeof(ma_int16)));

    while (written < frames) {
        ma_uint32 wanted = frames - written;
        void *write_ptr = NULL;

        if (ma_pcm_rb_acquire_write(&state->ring, &wanted, &write_ptr) != MA_SUCCESS ||
            wanted == 0) {
            break;
        }

        memcpy(write_ptr, pcm.data + (size_t)written * state->channels * sizeof(ma_int16),
               (size_t)wanted * state->channels * sizeof(ma_int16));

        ma_pcm_rb_commit_write(&state->ring, wanted);
        written += wanted;
    }

    return enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_uint(env, written));
}

/* space(Device) -> Frames the ring will take right now. */
static ERL_NIF_TERM tf_space(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    tf_device *state;

    if (argc != 1 || !enif_get_resource(env, argv[0], TF_DEVICE_TYPE, (void **)&state)) {
        return enif_make_badarg(env);
    }

    if (!state->open) {
        return enif_make_uint(env, 0);
    }

    return enif_make_uint(env, ma_pcm_rb_available_write(&state->ring));
}

static ERL_NIF_TERM tf_close(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    tf_device *state;

    if (argc != 1 || !enif_get_resource(env, argv[0], TF_DEVICE_TYPE, (void **)&state)) {
        return enif_make_badarg(env);
    }

    if (state->open) {
        ma_device_uninit(&state->device);
        ma_pcm_rb_uninit(&state->ring);
        state->open = 0;
    }

    return enif_make_atom(env, "ok");
}

static int tf_load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info)
{
    (void)priv_data;
    (void)load_info;

    TF_DEVICE_TYPE = enif_open_resource_type(env, NULL, "tuning_fork_device", tf_device_dtor,
                                             ERL_NIF_RT_CREATE, NULL);

    return TF_DEVICE_TYPE == NULL ? 1 : 0;
}

static ErlNifFunc tf_funcs[] = {
    {"open", 3, tf_open, 0},
    {"write", 2, tf_write, 0},
    {"space", 1, tf_space, 0},
    {"close", 1, tf_close, 0}};

ERL_NIF_INIT(Elixir.TuningFork.Speaker.Device, tf_funcs, tf_load, NULL, NULL, NULL)
