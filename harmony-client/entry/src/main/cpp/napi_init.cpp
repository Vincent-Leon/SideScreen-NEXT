/*
 * SideScreen-NEXT native module
 *
 * 接 ArkTS 收到的 H.265 (Annex-B) 字节流喂给 OH_VideoDecoder，解码后
 * 直接渲染到 XComponent 的 surface（OH_VideoDecoder_RenderOutputBuffer 是
 * zero-copy 渲染，不经过 CPU 拷贝）。
 *
 * 暴露给 ArkTS 的 3 个函数（详见 types/libentry/Index.d.ts）：
 *   nativeStart(width, height) → bool   配置并启动 decoder（XComponent surface 必须已就绪）
 *   nativePush(buffer)                  喂 1 个完整帧（Annex-B，每帧含 VPS/SPS/PPS 因 Mac 全 I 帧）
 *   nativeStop()                        停止并销毁 decoder
 *
 * XComponent surface 的生命周期通过 OH_NativeXComponent_RegisterCallback 监听，
 * OnSurfaceCreated 时保存 OHNativeWindow* 到全局，nativeStart 用它配 decoder。
 */

#include "napi/native_api.h"
#include <ace/xcomponent/native_interface_xcomponent.h>
#include <native_window/external_window.h>
#include <multimedia/player_framework/native_avcodec_videodecoder.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <hilog/log.h>

#include <atomic>
#include <cstdint>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <vector>

namespace ssn {

#define SSN_DOMAIN 0xC0FF
#define SSN_TAG "ssn_native"
#define LOGI(fmt, ...) OH_LOG_Print(LOG_APP, LOG_INFO,  SSN_DOMAIN, SSN_TAG, fmt, ##__VA_ARGS__)
#define LOGW(fmt, ...) OH_LOG_Print(LOG_APP, LOG_WARN,  SSN_DOMAIN, SSN_TAG, fmt, ##__VA_ARGS__)
#define LOGE(fmt, ...) OH_LOG_Print(LOG_APP, LOG_ERROR, SSN_DOMAIN, SSN_TAG, fmt, ##__VA_ARGS__)

// ============================================================================
// HEVC decoder wrapper
// ============================================================================

struct InputSlot {
    uint32_t index;
    OH_AVBuffer *buffer;
};

class HevcDecoder {
public:
    ~HevcDecoder() { stop(); }

    bool start(int width, int height, OHNativeWindow *window) {
        std::lock_guard<std::mutex> lock(state_mutex_);
        if (codec_) {
            LOGW("decoder already started");
            return true;
        }
        if (!window) {
            LOGE("start: window is null");
            return false;
        }

        codec_ = OH_VideoDecoder_CreateByMime(OH_AVCODEC_MIMETYPE_VIDEO_HEVC);
        if (!codec_) {
            LOGE("OH_VideoDecoder_CreateByMime failed");
            return false;
        }

        OH_AVCodecCallback cb = {};
        cb.onError = &HevcDecoder::onError;
        cb.onStreamChanged = &HevcDecoder::onStreamChanged;
        cb.onNeedInputBuffer = &HevcDecoder::onNeedInputBuffer;
        cb.onNewOutputBuffer = &HevcDecoder::onNewOutputBuffer;

        OH_AVErrCode err = OH_VideoDecoder_RegisterCallback(codec_, cb, this);
        if (err != AV_ERR_OK) { LOGE("RegisterCallback failed: %{public}d", err); destroyLocked(); return false; }

        OH_AVFormat *format = OH_AVFormat_Create();
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_WIDTH, width);
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_HEIGHT, height);
        // 低延迟模式（部分 SoC 可能不支持，失败也不致命）
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY, 1);

        err = OH_VideoDecoder_Configure(codec_, format);
        OH_AVFormat_Destroy(format);
        if (err != AV_ERR_OK) { LOGE("Configure failed: %{public}d", err); destroyLocked(); return false; }

        err = OH_VideoDecoder_SetSurface(codec_, window);
        if (err != AV_ERR_OK) { LOGE("SetSurface failed: %{public}d", err); destroyLocked(); return false; }

        err = OH_VideoDecoder_Prepare(codec_);
        if (err != AV_ERR_OK) { LOGE("Prepare failed: %{public}d", err); destroyLocked(); return false; }

        err = OH_VideoDecoder_Start(codec_);
        if (err != AV_ERR_OK) { LOGE("Start failed: %{public}d", err); destroyLocked(); return false; }

        running_.store(true);
        push_count_ = 0;
        feed_count_ = 0;
        out_count_ = 0;
        render_count_ = 0;
        LOGI("decoder started %{public}dx%{public}d", width, height);
        return true;
    }

    void pushFrame(const uint8_t *data, size_t size) {
        if (!running_.load() || size == 0) return;

        push_count_++;
        if (push_count_ <= 3 || push_count_ % 60 == 0) {
            uint8_t h0 = data[0], h1 = size > 1 ? data[1] : 0, h2 = size > 2 ? data[2] : 0,
                    h3 = size > 3 ? data[3] : 0, h4 = size > 4 ? data[4] : 0,
                    h5 = size > 5 ? data[5] : 0;
            LOGI("pushFrame #%{public}llu size=%{public}zu head=%{public}02x %{public}02x %{public}02x %{public}02x %{public}02x %{public}02x | feed=%{public}llu out=%{public}llu render=%{public}llu drop=%{public}llu",
                 (unsigned long long)push_count_, size,
                 h0, h1, h2, h3, h4, h5,
                 (unsigned long long)feed_count_,
                 (unsigned long long)out_count_,
                 (unsigned long long)render_count_,
                 (unsigned long long)dropped_);
        }

        // 优先：如果有 idle 的 input buffer，直接喂
        InputSlot slot{};
        bool haveSlot = false;
        {
            std::lock_guard<std::mutex> lk(input_mutex_);
            if (!available_input_.empty()) {
                slot = available_input_.front();
                available_input_.pop_front();
                haveSlot = true;
            }
        }
        if (haveSlot) {
            feedSlot(slot, data, size);
            return;
        }

        // 否则排队等 onNeedInputBuffer 回调来取
        std::lock_guard<std::mutex> lk(frames_mutex_);
        pending_frames_.emplace_back(data, data + size);
        // 超过 8 帧丢最旧（防止反压时内存膨胀）
        while (pending_frames_.size() > 8) {
            pending_frames_.pop_front();
            dropped_++;
        }
    }

    void stop() {
        std::lock_guard<std::mutex> lock(state_mutex_);
        running_.store(false);
        destroyLocked();
        std::lock_guard<std::mutex> lk1(input_mutex_);
        available_input_.clear();
        std::lock_guard<std::mutex> lk2(frames_mutex_);
        pending_frames_.clear();
    }

    uint64_t droppedCount() const { return dropped_; }

private:
    OH_AVCodec *codec_ = nullptr;
    std::atomic<bool> running_{false};
    std::mutex state_mutex_;

    std::deque<InputSlot> available_input_;
    std::mutex input_mutex_;

    std::deque<std::vector<uint8_t>> pending_frames_;
    std::mutex frames_mutex_;

    uint64_t dropped_ = 0;
    uint64_t push_count_ = 0;
    uint64_t feed_count_ = 0;
    uint64_t out_count_ = 0;
    uint64_t render_count_ = 0;

    void destroyLocked() {
        if (codec_) {
            OH_VideoDecoder_Stop(codec_);
            OH_VideoDecoder_Destroy(codec_);
            codec_ = nullptr;
        }
    }

    void feedSlot(const InputSlot &slot, const uint8_t *data, size_t size) {
        if (!codec_) return;
        uint8_t *dst = OH_AVBuffer_GetAddr(slot.buffer);
        if (!dst) { LOGE("AVBuffer_GetAddr null"); return; }
        int32_t cap = OH_AVBuffer_GetCapacity(slot.buffer);
        if ((int32_t)size > cap) {
            LOGE("frame %{public}zu > capacity %{public}d", size, cap);
            return;
        }
        memcpy(dst, data, size);

        OH_AVCodecBufferAttr attr{};
        attr.pts = 0;
        attr.size = (int32_t)size;
        attr.offset = 0;
        // 鸿蒙 HEVC 解码器需要明确标识 IDR / sync 帧。Mac 端全 I 帧编码，每帧都是 IDR。
        // 不设此 flag 可能导致解码器一直丢帧（被当成非关键帧）。
        attr.flags = AVCODEC_BUFFER_FLAGS_SYNC_FRAME;
        OH_AVBuffer_SetBufferAttr(slot.buffer, &attr);

        OH_AVErrCode err = OH_VideoDecoder_PushInputBuffer(codec_, slot.index);
        if (err != AV_ERR_OK) {
            LOGE("PushInputBuffer failed: %{public}d", err);
        } else {
            feed_count_++;
        }
    }

    static void onError(OH_AVCodec * /*codec*/, int32_t errorCode, void * /*userData*/) {
        LOGE("decoder onError: %{public}d", errorCode);
    }
    static void onStreamChanged(OH_AVCodec * /*codec*/, OH_AVFormat *format, void * /*userData*/) {
        int32_t w = 0, h = 0;
        if (format) {
            OH_AVFormat_GetIntValue(format, OH_MD_KEY_WIDTH, &w);
            OH_AVFormat_GetIntValue(format, OH_MD_KEY_HEIGHT, &h);
        }
        LOGI("decoder onStreamChanged → %{public}dx%{public}d", w, h);
    }
    static void onNeedInputBuffer(OH_AVCodec * /*codec*/, uint32_t index, OH_AVBuffer *buffer, void *userData) {
        auto *self = static_cast<HevcDecoder *>(userData);
        if (!self || !self->running_.load()) return;

        // 队列里有帧就立刻喂掉
        std::vector<uint8_t> frame;
        bool have = false;
        {
            std::lock_guard<std::mutex> lk(self->frames_mutex_);
            if (!self->pending_frames_.empty()) {
                frame = std::move(self->pending_frames_.front());
                self->pending_frames_.pop_front();
                have = true;
            }
        }
        if (have) {
            InputSlot slot{index, buffer};
            self->feedSlot(slot, frame.data(), frame.size());
        } else {
            // 没帧，把 slot 存起来等 pushFrame
            std::lock_guard<std::mutex> lk(self->input_mutex_);
            self->available_input_.push_back({index, buffer});
        }
    }
    static void onNewOutputBuffer(OH_AVCodec *codec, uint32_t index, OH_AVBuffer * /*buffer*/, void *userData) {
        auto *self = static_cast<HevcDecoder *>(userData);
        if (!self || !self->running_.load() || !codec) return;
        self->out_count_++;
        // 直接送显（zero-copy 到 surface）
        OH_AVErrCode err = OH_VideoDecoder_RenderOutputBuffer(codec, index);
        if (err != AV_ERR_OK) {
            LOGE("RenderOutputBuffer failed: %{public}d", err);
        } else {
            self->render_count_++;
            if (self->render_count_ <= 3 || self->render_count_ % 60 == 0) {
                LOGI("rendered #%{public}llu", (unsigned long long)self->render_count_);
            }
        }
    }
};

// ============================================================================
// 全局状态：当前 XComponent 的 NativeWindow + 单例 decoder
// ============================================================================

static OHNativeWindow *g_window = nullptr;
static std::mutex g_window_mutex;
static std::unique_ptr<HevcDecoder> g_decoder;
static std::mutex g_decoder_mutex;

// ============================================================================
// XComponent native callbacks
// ============================================================================

static void OnSurfaceCreatedCB(OH_NativeXComponent *component, void *window) {
    char id[OH_XCOMPONENT_ID_LEN_MAX + 1] = {0};
    uint64_t idLen = OH_XCOMPONENT_ID_LEN_MAX;
    OH_NativeXComponent_GetXComponentId(component, id, &idLen);
    LOGI("OnSurfaceCreated id=%s window=%p", id, window);

    std::lock_guard<std::mutex> lock(g_window_mutex);
    g_window = static_cast<OHNativeWindow *>(window);
}

static void OnSurfaceChangedCB(OH_NativeXComponent *component, void * /*window*/) {
    char id[OH_XCOMPONENT_ID_LEN_MAX + 1] = {0};
    uint64_t idLen = OH_XCOMPONENT_ID_LEN_MAX;
    OH_NativeXComponent_GetXComponentId(component, id, &idLen);
    uint64_t w = 0, h = 0;
    OH_NativeXComponent_GetXComponentSize(component, nullptr, &w, &h);
    LOGI("OnSurfaceChanged id=%s %llux%llu", id, (unsigned long long)w, (unsigned long long)h);
}

static void OnSurfaceDestroyedCB(OH_NativeXComponent * /*component*/, void * /*window*/) {
    LOGI("OnSurfaceDestroyed — stopping decoder");
    {
        std::lock_guard<std::mutex> lock(g_decoder_mutex);
        if (g_decoder) {
            g_decoder->stop();
            g_decoder.reset();
        }
    }
    std::lock_guard<std::mutex> lock(g_window_mutex);
    g_window = nullptr;
}

static void DispatchTouchEventCB(OH_NativeXComponent * /*component*/, void * /*window*/) {
    // v1 不做触控反控
}

static OH_NativeXComponent_Callback g_xc_callback{
    OnSurfaceCreatedCB,
    OnSurfaceChangedCB,
    OnSurfaceDestroyedCB,
    DispatchTouchEventCB,
};

// ============================================================================
// NAPI 暴露的函数
// ============================================================================

static napi_value NapiBool(napi_env env, bool v) {
    napi_value r;
    napi_get_boolean(env, v, &r);
    return r;
}

// nativeStart(width: number, height: number): boolean
static napi_value JS_nativeStart(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) return NapiBool(env, false);

    int32_t width = 0, height = 0;
    napi_get_value_int32(env, args[0], &width);
    napi_get_value_int32(env, args[1], &height);
    if (width <= 0 || height <= 0) {
        LOGE("nativeStart: invalid size %dx%d", width, height);
        return NapiBool(env, false);
    }

    OHNativeWindow *window;
    {
        std::lock_guard<std::mutex> lock(g_window_mutex);
        window = g_window;
    }
    if (!window) {
        LOGE("nativeStart: no surface yet (XComponent not loaded)");
        return NapiBool(env, false);
    }

    std::lock_guard<std::mutex> lock(g_decoder_mutex);
    if (g_decoder) {
        g_decoder->stop();
        g_decoder.reset();
    }
    auto dec = std::make_unique<HevcDecoder>();
    if (!dec->start(width, height, window)) {
        return NapiBool(env, false);
    }
    g_decoder = std::move(dec);
    return NapiBool(env, true);
}

// nativePush(frame: ArrayBuffer | Uint8Array): void
static napi_value JS_nativePush(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) return nullptr;

    bool isTypedArray = false;
    napi_is_typedarray(env, args[0], &isTypedArray);

    void *data = nullptr;
    size_t size = 0;
    if (isTypedArray) {
        napi_typedarray_type type;
        napi_value arrbuf;
        size_t offset = 0;
        size_t length = 0;
        napi_get_typedarray_info(env, args[0], &type, &length, &data, &arrbuf, &offset);
        size = length;
    } else {
        napi_get_arraybuffer_info(env, args[0], &data, &size);
    }
    if (!data || size == 0) return nullptr;

    std::lock_guard<std::mutex> lock(g_decoder_mutex);
    if (g_decoder) g_decoder->pushFrame(static_cast<const uint8_t *>(data), size);
    return nullptr;
}

// nativeStop(): void
static napi_value JS_nativeStop(napi_env /*env*/, napi_callback_info /*info*/) {
    std::lock_guard<std::mutex> lock(g_decoder_mutex);
    if (g_decoder) {
        g_decoder->stop();
        g_decoder.reset();
    }
    return nullptr;
}

// nativeIsReady(): boolean — 测试 XComponent surface 是否已就绪
static napi_value JS_nativeIsReady(napi_env env, napi_callback_info /*info*/) {
    std::lock_guard<std::mutex> lock(g_window_mutex);
    return NapiBool(env, g_window != nullptr);
}

// ============================================================================
// 模块初始化
// ============================================================================

static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"nativeStart",   nullptr, JS_nativeStart,   nullptr, nullptr, nullptr, napi_default, nullptr},
        {"nativePush",    nullptr, JS_nativePush,    nullptr, nullptr, nullptr, napi_default, nullptr},
        {"nativeStop",    nullptr, JS_nativeStop,    nullptr, nullptr, nullptr, napi_default, nullptr},
        {"nativeIsReady", nullptr, JS_nativeIsReady, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);

    // 注册 XComponent native 回调（声明 type='surface' libraryname='entry' 的 XComponent 渲染时会触发）
    napi_value exportInstance = nullptr;
    napi_status st = napi_get_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ, &exportInstance);
    if (st == napi_ok && exportInstance) {
        OH_NativeXComponent *xc = nullptr;
        if (napi_unwrap(env, exportInstance, reinterpret_cast<void **>(&xc)) == napi_ok && xc) {
            OH_NativeXComponent_RegisterCallback(xc, &g_xc_callback);
            LOGI("XComponent native callback registered in Init");
        }
    } else {
        LOGI("OH_NATIVE_XCOMPONENT_OBJ not present at Init time (XComponent not yet rendered)");
    }
    return exports;
}

}  // namespace ssn

extern "C" __attribute__((constructor))
void RegisterEntryModule() {
    static napi_module mod = {
        .nm_version = 1,
        .nm_flags = 0,
        .nm_filename = nullptr,
        .nm_register_func = ssn::Init,
        .nm_modname = "entry",
        .nm_priv = nullptr,
        .reserved = {0},
    };
    napi_module_register(&mod);
}
