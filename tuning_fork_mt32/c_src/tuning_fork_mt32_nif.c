#include <erl_nif.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
typedef HMODULE library_handle;
#else
#include <dlfcn.h>
typedef void *library_handle;
#endif

#define MUNT_QUEUE_FULL (-6)
#define MUNT_FAILED (-100)
#define FRAMES_BETWEEN_QUEUE_RETRIES 64
#define REASON_SIZE 512

typedef struct munt_data munt_data;

typedef union {
    const void *v0;
} munt_report_handler;

typedef struct {
    int (*get_version_id)(munt_report_handler);
    void (*print_debug)(void *, const char *, va_list);
    void (*on_error_control_rom)(void *);
    void (*on_error_pcm_rom)(void *);
    void (*show_lcd_message)(void *, const char *);
    void (*on_midi_message_played)(void *);
    int (*on_midi_queue_overflow)(void *);
    void (*on_midi_system_realtime)(void *, uint8_t);
    void (*on_device_reset)(void *);
    void (*on_device_reconfig)(void *);
    void (*on_new_reverb_mode)(void *, uint8_t);
    void (*on_new_reverb_time)(void *, uint8_t);
    void (*on_new_reverb_level)(void *, uint8_t);
    void (*on_poly_state_changed)(void *, uint8_t);
    void (*on_program_changed)(void *, uint8_t, const char *, const char *);
} munt_report_handler_v0;

typedef void (*munt_function)(void);
typedef munt_data *(*create_context_function)(munt_report_handler, void *);
typedef void (*context_function)(munt_data *);
typedef int (*add_rom_data_function)(munt_data *, const uint8_t *, size_t, const void *);
typedef int (*best_analog_output_mode_function)(double);
typedef void (*set_analog_output_mode_function)(munt_data *, int);
typedef void (*set_samplerate_function)(munt_data *, double);
typedef int (*open_synth_function)(munt_data *);
typedef uint32_t (*actual_samplerate_function)(munt_data *);
typedef int (*play_msg_function)(munt_data *, uint32_t);
typedef int (*play_sysex_function)(munt_data *, const uint8_t *, uint32_t);
typedef void (*render_bit16s_function)(munt_data *, int16_t *, uint32_t);
typedef const char *(*version_string_function)(void);

typedef struct {
    create_context_function create_context;
    context_function free_context;
    add_rom_data_function add_rom_data;
    best_analog_output_mode_function get_best_analog_output_mode;
    set_analog_output_mode_function set_analog_output_mode;
    set_samplerate_function set_stereo_output_samplerate;
    open_synth_function open_synth;
    context_function close_synth;
    actual_samplerate_function get_actual_stereo_output_samplerate;
    play_msg_function play_msg;
    play_sysex_function play_sysex;
    render_bit16s_function render_bit16s;
    version_string_function get_library_version_string;
} munt_api;

typedef struct {
    library_handle handle;
    munt_api api;
} munt_library;

typedef struct {
    munt_library *library;
    munt_data *context;
    ErlNifMutex *lock;
    uint8_t *control_rom;
    uint8_t *pcm_rom;
    int open;
} munt_synth;

static ErlNifResourceType *LIBRARY_TYPE;
static ErlNifResourceType *SYNTH_TYPE;

static int report_handler_version(munt_report_handler handler)
{
    (void)handler;
    return 0;
}

static void ignore_debug(void *instance, const char *format, va_list arguments)
{
    (void)instance;
    (void)format;
    (void)arguments;
}

static void ignore_event(void *instance)
{
    (void)instance;
}

static void ignore_text(void *instance, const char *text)
{
    (void)instance;
    (void)text;
}

static int decline_queue_overflow_retry(void *instance)
{
    (void)instance;
    return 0;
}

static void ignore_byte(void *instance, uint8_t value)
{
    (void)instance;
    (void)value;
}

static void ignore_program_change(void *instance, uint8_t part, const char *group,
                                  const char *patch)
{
    (void)instance;
    (void)part;
    (void)group;
    (void)patch;
}

static const munt_report_handler_v0 QUIET_REPORTS = {
    report_handler_version, ignore_debug, ignore_event, ignore_event,
    ignore_text,            ignore_event, decline_queue_overflow_retry,
    ignore_byte,            ignore_event, ignore_event,
    ignore_byte,            ignore_byte,  ignore_byte,
    ignore_byte,            ignore_program_change};

static ERL_NIF_TERM make_error(ErlNifEnv *env, ERL_NIF_TERM reason)
{
    return enif_make_tuple2(env, enif_make_atom(env, "error"), reason);
}

static ERL_NIF_TERM make_tagged_error(ErlNifEnv *env, const char *tag, ERL_NIF_TERM detail)
{
    return make_error(env, enif_make_tuple2(env, enif_make_atom(env, tag), detail));
}

static ERL_NIF_TERM make_string(ErlNifEnv *env, const char *text)
{
    ERL_NIF_TERM term;
    size_t length = strlen(text);
    unsigned char *bytes = enif_make_new_binary(env, length, &term);

    memcpy(bytes, text, length);
    return term;
}

static library_handle open_library(const char *path, char *reason)
{
#ifdef _WIN32
    int wide_length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
    wchar_t *wide_path;
    HMODULE handle;

    if (wide_length == 0) {
        snprintf(reason, REASON_SIZE, "the path is not valid UTF-8");
        return NULL;
    }

    wide_path = enif_alloc(sizeof(wchar_t) * (size_t)wide_length);
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide_path, wide_length);
    handle = LoadLibraryExW(wide_path, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
    enif_free(wide_path);

    if (handle == NULL) {
        snprintf(reason, REASON_SIZE, "LoadLibrary failed with error %lu", GetLastError());
    }

    return handle;
#else
    void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);

    if (handle == NULL) {
        const char *message = dlerror();
        snprintf(reason, REASON_SIZE, "%s", message == NULL ? "dlopen failed" : message);
    }

    return handle;
#endif
}

static void close_library(library_handle handle)
{
#ifdef _WIN32
    FreeLibrary(handle);
#else
    dlclose(handle);
#endif
}

static munt_function lookup_function(library_handle handle, const char *name)
{
#ifdef _WIN32
    return (munt_function)GetProcAddress(handle, name);
#else
    return (munt_function)dlsym(handle, name);
#endif
}

static munt_function find_function(munt_library *library, const char *name,
                                   const char **missing)
{
    munt_function found = lookup_function(library->handle, name);

    if (found == NULL && *missing == NULL) {
        *missing = name;
    }

    return found;
}

static const char *resolve_api(munt_library *library)
{
    const char *missing = NULL;
    munt_api *api = &library->api;

    api->create_context = (create_context_function)find_function(
        library, "mt32emu_create_context", &missing);
    api->free_context =
        (context_function)find_function(library, "mt32emu_free_context", &missing);
    api->add_rom_data =
        (add_rom_data_function)find_function(library, "mt32emu_add_rom_data", &missing);
    api->get_best_analog_output_mode = (best_analog_output_mode_function)find_function(
        library, "mt32emu_get_best_analog_output_mode", &missing);
    api->set_analog_output_mode = (set_analog_output_mode_function)find_function(
        library, "mt32emu_set_analog_output_mode", &missing);
    api->set_stereo_output_samplerate = (set_samplerate_function)find_function(
        library, "mt32emu_set_stereo_output_samplerate", &missing);
    api->open_synth =
        (open_synth_function)find_function(library, "mt32emu_open_synth", &missing);
    api->close_synth =
        (context_function)find_function(library, "mt32emu_close_synth", &missing);
    api->get_actual_stereo_output_samplerate = (actual_samplerate_function)find_function(
        library, "mt32emu_get_actual_stereo_output_samplerate", &missing);
    api->play_msg = (play_msg_function)find_function(library, "mt32emu_play_msg", &missing);
    api->play_sysex =
        (play_sysex_function)find_function(library, "mt32emu_play_sysex", &missing);
    api->render_bit16s =
        (render_bit16s_function)find_function(library, "mt32emu_render_bit16s", &missing);
    api->get_library_version_string = (version_string_function)find_function(
        library, "mt32emu_get_library_version_string", &missing);

    return missing;
}

static void library_destructor(ErlNifEnv *env, void *object)
{
    munt_library *library = (munt_library *)object;

    (void)env;

    if (library->handle != NULL) {
        close_library(library->handle);
    }
}

static void free_bytes(uint8_t **bytes)
{
    if (*bytes != NULL) {
        enif_free(*bytes);
        *bytes = NULL;
    }
}

static void release_synth_context(munt_synth *synth)
{
    if (synth->open) {
        synth->library->api.close_synth(synth->context);
        synth->open = 0;
    }

    if (synth->context != NULL) {
        synth->library->api.free_context(synth->context);
        synth->context = NULL;
    }

    free_bytes(&synth->control_rom);
    free_bytes(&synth->pcm_rom);
}

static void synth_destructor(ErlNifEnv *env, void *object)
{
    munt_synth *synth = (munt_synth *)object;

    (void)env;

    if (synth->library != NULL) {
        release_synth_context(synth);
        enif_release_resource(synth->library);
    }

    if (synth->lock != NULL) {
        enif_mutex_destroy(synth->lock);
    }
}

static char *copy_as_c_string(const ErlNifBinary *binary)
{
    char *text = enif_alloc(binary->size + 1);

    memcpy(text, binary->data, binary->size);
    text[binary->size] = '\0';
    return text;
}

static uint8_t *copy_bytes(const ErlNifBinary *binary)
{
    uint8_t *bytes = enif_alloc(binary->size == 0 ? 1 : binary->size);

    memcpy(bytes, binary->data, binary->size);
    return bytes;
}

static ERL_NIF_TERM load_library_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifBinary path;
    char reason[REASON_SIZE];
    char *c_path;
    library_handle handle;
    munt_library *library;
    const char *missing;
    ERL_NIF_TERM term;

    if (argc != 1 || !enif_inspect_binary(env, argv[0], &path)) {
        return enif_make_badarg(env);
    }

    c_path = copy_as_c_string(&path);
    handle = open_library(c_path, reason);
    enif_free(c_path);

    if (handle == NULL) {
        return make_tagged_error(env, "not_a_library", make_string(env, reason));
    }

    library = enif_alloc_resource(LIBRARY_TYPE, sizeof(munt_library));
    memset(library, 0, sizeof(munt_library));
    library->handle = handle;
    missing = resolve_api(library);

    if (missing != NULL) {
        enif_release_resource(library);
        return make_tagged_error(env, "missing_function", make_string(env, missing));
    }

    term = enif_make_resource(env, library);
    enif_release_resource(library);
    return enif_make_tuple2(env, enif_make_atom(env, "ok"), term);
}

static ERL_NIF_TERM library_version_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    munt_library *library;
    const char *version;

    if (argc != 1 || !enif_get_resource(env, argv[0], LIBRARY_TYPE, (void **)&library)) {
        return enif_make_badarg(env);
    }

    version = library->api.get_library_version_string();
    return make_string(env, version == NULL ? "" : version);
}

static munt_synth *new_synth(munt_library *library, const ErlNifBinary *control,
                             const ErlNifBinary *pcm)
{
    munt_synth *synth = enif_alloc_resource(SYNTH_TYPE, sizeof(munt_synth));
    munt_report_handler handler;

    memset(synth, 0, sizeof(munt_synth));
    enif_keep_resource(library);
    synth->library = library;
    synth->lock = enif_mutex_create("tuning_fork_mt32_synth");
    synth->control_rom = copy_bytes(control);
    synth->pcm_rom = copy_bytes(pcm);
    handler.v0 = &QUIET_REPORTS;
    synth->context = library->api.create_context(handler, NULL);
    return synth;
}

static ERL_NIF_TERM start_synth(ErlNifEnv *env, munt_synth *synth, size_t control_size,
                                size_t pcm_size, unsigned int rate)
{
    munt_api *api = &synth->library->api;
    int result;

    if (synth->context == NULL) {
        return make_tagged_error(env, "open_failed", enif_make_int(env, MUNT_FAILED));
    }

    if (api->add_rom_data(synth->context, synth->control_rom, control_size, NULL) <= 0) {
        return make_tagged_error(env, "rom_rejected", enif_make_atom(env, "control"));
    }

    if (api->add_rom_data(synth->context, synth->pcm_rom, pcm_size, NULL) <= 0) {
        return make_tagged_error(env, "rom_rejected", enif_make_atom(env, "pcm"));
    }

    api->set_analog_output_mode(synth->context, api->get_best_analog_output_mode(rate));
    api->set_stereo_output_samplerate(synth->context, (double)rate);
    result = api->open_synth(synth->context);

    if (result != 0) {
        return make_tagged_error(env, "open_failed", enif_make_int(env, result));
    }

    synth->open = 1;
    return enif_make_uint(env, api->get_actual_stereo_output_samplerate(synth->context));
}

static ERL_NIF_TERM open_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    munt_library *library;
    ErlNifBinary control;
    ErlNifBinary pcm;
    unsigned int rate;
    munt_synth *synth;
    ERL_NIF_TERM started;
    ERL_NIF_TERM term;

    if (argc != 4 || !enif_get_resource(env, argv[0], LIBRARY_TYPE, (void **)&library) ||
        !enif_inspect_binary(env, argv[1], &control) ||
        !enif_inspect_binary(env, argv[2], &pcm) || !enif_get_uint(env, argv[3], &rate) ||
        rate == 0) {
        return enif_make_badarg(env);
    }

    synth = new_synth(library, &control, &pcm);
    started = start_synth(env, synth, control.size, pcm.size, rate);

    if (!synth->open) {
        enif_release_resource(synth);
        return started;
    }

    term = enif_make_resource(env, synth);
    enif_release_resource(synth);
    return enif_make_tuple3(env, enif_make_atom(env, "ok"), term, started);
}

static uint32_t pack_short_message(const ErlNifBinary *message)
{
    uint32_t packed = 0;
    size_t index;

    for (index = 0; index < message->size && index < 3; index++) {
        packed |= (uint32_t)message->data[index] << (8 * index);
    }

    return packed;
}

static int play_message(munt_synth *synth, const ErlNifBinary *message)
{
    munt_api *api = &synth->library->api;

    if (message->data[0] == 0xF0) {
        return api->play_sysex(synth->context, message->data, (uint32_t)message->size);
    }

    return api->play_msg(synth->context, pack_short_message(message));
}

static void render_until(munt_synth *synth, int16_t *pcm, uint32_t *position,
                         uint32_t target)
{
    if (target > *position) {
        synth->library->api.render_bit16s(synth->context, pcm + (size_t)*position * 2,
                                          target - *position);
        *position = target;
    }
}

static int deliver_message(munt_synth *synth, const ErlNifBinary *message, int16_t *pcm,
                           uint32_t *position, uint32_t frames)
{
    int result = play_message(synth, message);

    while (result == MUNT_QUEUE_FULL && *position < frames) {
        uint32_t step = frames - *position;

        if (step > FRAMES_BETWEEN_QUEUE_RETRIES) {
            step = FRAMES_BETWEEN_QUEUE_RETRIES;
        }

        render_until(synth, pcm, position, *position + step);
        result = play_message(synth, message);
    }

    return result;
}

static int read_timed_message(ErlNifEnv *env, ERL_NIF_TERM term, unsigned int *frame,
                              ErlNifBinary *message)
{
    const ERL_NIF_TERM *pair;
    int arity;

    return enif_get_tuple(env, term, &arity, &pair) && arity == 2 &&
           enif_get_uint(env, pair[0], frame) && enif_inspect_binary(env, pair[1], message) &&
           message->size > 0;
}

static int timed_messages_valid(ErlNifEnv *env, ERL_NIF_TERM list)
{
    ERL_NIF_TERM head;
    unsigned int frame;
    unsigned int previous = 0;
    ErlNifBinary message;

    while (enif_get_list_cell(env, list, &head, &list)) {
        if (!read_timed_message(env, head, &frame, &message) || frame < previous) {
            return 0;
        }

        previous = frame;
    }

    return enif_is_empty_list(env, list);
}

static unsigned int render_timed_messages(ErlNifEnv *env, munt_synth *synth,
                                          ERL_NIF_TERM list, int16_t *pcm, uint32_t frames)
{
    ERL_NIF_TERM head;
    unsigned int frame;
    unsigned int dropped = 0;
    uint32_t position = 0;
    ErlNifBinary message;

    while (enif_get_list_cell(env, list, &head, &list)) {
        read_timed_message(env, head, &frame, &message);
        render_until(synth, pcm, &position, frame < frames ? frame : frames);

        if (deliver_message(synth, &message, pcm, &position, frames) < 0) {
            dropped++;
        }
    }

    render_until(synth, pcm, &position, frames);
    return dropped;
}

static ERL_NIF_TERM render_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    munt_synth *synth;
    unsigned int frames;
    unsigned int dropped;
    ErlNifBinary pcm;

    if (argc != 3 || !enif_get_resource(env, argv[0], SYNTH_TYPE, (void **)&synth) ||
        !timed_messages_valid(env, argv[1]) || !enif_get_uint(env, argv[2], &frames)) {
        return enif_make_badarg(env);
    }

    if (!enif_alloc_binary((size_t)frames * 2 * sizeof(int16_t), &pcm)) {
        return make_error(env, enif_make_atom(env, "out_of_memory"));
    }

    enif_mutex_lock(synth->lock);

    if (!synth->open) {
        enif_mutex_unlock(synth->lock);
        enif_release_binary(&pcm);
        return make_error(env, enif_make_atom(env, "closed"));
    }

    dropped = render_timed_messages(env, synth, argv[1], (int16_t *)pcm.data, frames);
    enif_mutex_unlock(synth->lock);

    return enif_make_tuple3(env, enif_make_atom(env, "ok"), enif_make_binary(env, &pcm),
                            enif_make_uint(env, dropped));
}

static ERL_NIF_TERM play_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    munt_synth *synth;
    ErlNifBinary message;
    int result;

    if (argc != 2 || !enif_get_resource(env, argv[0], SYNTH_TYPE, (void **)&synth) ||
        !enif_inspect_binary(env, argv[1], &message) || message.size == 0) {
        return enif_make_badarg(env);
    }

    enif_mutex_lock(synth->lock);

    if (!synth->open) {
        enif_mutex_unlock(synth->lock);
        return make_error(env, enif_make_atom(env, "closed"));
    }

    result = play_message(synth, &message);
    enif_mutex_unlock(synth->lock);

    return result < 0 ? make_error(env, enif_make_int(env, result)) : enif_make_atom(env, "ok");
}

static ERL_NIF_TERM close_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    munt_synth *synth;

    if (argc != 1 || !enif_get_resource(env, argv[0], SYNTH_TYPE, (void **)&synth)) {
        return enif_make_badarg(env);
    }

    enif_mutex_lock(synth->lock);
    release_synth_context(synth);
    enif_mutex_unlock(synth->lock);

    return enif_make_atom(env, "ok");
}

static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info)
{
    (void)priv_data;
    (void)load_info;

    LIBRARY_TYPE = enif_open_resource_type(env, NULL, "tuning_fork_mt32_library",
                                           library_destructor, ERL_NIF_RT_CREATE, NULL);
    SYNTH_TYPE = enif_open_resource_type(env, NULL, "tuning_fork_mt32_synth", synth_destructor,
                                         ERL_NIF_RT_CREATE, NULL);

    return LIBRARY_TYPE == NULL || SYNTH_TYPE == NULL ? 1 : 0;
}

static ErlNifFunc nif_functions[] = {
    {"load_library", 1, load_library_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"library_version", 1, library_version_nif, 0},
    {"open", 4, open_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"render", 3, render_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"play", 2, play_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"close", 1, close_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND}};

ERL_NIF_INIT(Elixir.TuningFork.Mt32.Nif, nif_functions, load, NULL, NULL, NULL)
