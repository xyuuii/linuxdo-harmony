#include "napi/native_api.h"
#include <atomic>
#include <memory>
#include <string>

extern "C" char *ech_probe_run(const char *);
extern "C" void ech_probe_free(char *);
extern "C" void ech_probe_cancel();
extern "C" void ech_probe_prepare();
static std::atomic<bool> busy{false};
struct ProbeWork {
    napi_async_work work{};
    napi_deferred deferred{};
    std::string input;
    std::string result;
};

static napi_value Run(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, "One JSON argument required"); return nullptr;
    }
    size_t size = 0;
    if (napi_get_value_string_utf8(env, argv[0], nullptr, 0, &size) != napi_ok || size > 65536) {
        napi_throw_type_error(env, nullptr, "Probe input must be a bounded string"); return nullptr;
    }
    if (busy.exchange(true)) { napi_throw_error(env, nullptr, "A native probe is already running"); return nullptr; }
    ech_probe_prepare();
    auto work = std::make_unique<ProbeWork>();
    work->input.resize(size + 1);
    napi_get_value_string_utf8(env, argv[0], work->input.data(), size + 1, &size);
    work->input.resize(size);
    napi_value promise, name;
    napi_create_promise(env, &work->deferred, &promise);
    napi_create_string_utf8(env, "LinuxDoECHProbe", NAPI_AUTO_LENGTH, &name);
    const napi_status created = napi_create_async_work(env, nullptr, name,
        [](napi_env, void *data) {
            auto *work = static_cast<ProbeWork *>(data);
            char *result = ech_probe_run(work->input.c_str());
            work->result = result ? result : "[]";
            ech_probe_free(result);
        },
        [](napi_env env, napi_status status, void *data) {
            std::unique_ptr<ProbeWork> work(static_cast<ProbeWork *>(data));
            napi_value result;
            napi_create_string_utf8(env, work->result.c_str(), work->result.size(), &result);
            if (status == napi_ok) napi_resolve_deferred(env, work->deferred, result);
            else napi_reject_deferred(env, work->deferred, result);
            napi_delete_async_work(env, work->work);
            busy = false;
        }, work.get(), &work->work);
    if (created != napi_ok || napi_queue_async_work(env, work->work) != napi_ok) {
        if (created == napi_ok) napi_delete_async_work(env, work->work);
        busy = false;
        napi_value error;
        napi_create_string_utf8(env, "Native work could not be queued", NAPI_AUTO_LENGTH, &error);
        napi_reject_deferred(env, work->deferred, error);
        return promise;
    }
    work.release();
    return promise;
}

static napi_value Cancel(napi_env env, napi_callback_info) {
    ech_probe_cancel();
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor methods[] = {
        {"run", nullptr, Run, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cancel", nullptr, Cancel, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, 2, methods);
    return exports;
}
static napi_module module = {1, 0, nullptr, Init, "echprobe", nullptr, {0}};
extern "C" __attribute__((constructor)) void RegisterECHProbe() { napi_module_register(&module); }
