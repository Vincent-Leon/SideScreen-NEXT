/** 配置并启动 HEVC 硬解码器，绑定到当前 XComponent surface。
 *  surface 必须先 onLoad（OH_NativeXComponent OnSurfaceCreated 触发）。
 *  返回 false 表示 surface 未就绪 / decoder 配置失败。 */
export const nativeStart: (width: number, height: number) => boolean;

/** 喂一个完整的 H.265 帧（Annex-B，含 VPS/SPS/PPS 前缀）。线程安全。 */
export const nativePush: (frame: ArrayBuffer | Uint8Array) => void;

/** 停止并销毁 decoder。可重复调用。 */
export const nativeStop: () => void;

/** XComponent surface 是否已就绪（OnSurfaceCreated 已触发且未 destroy）。 */
export const nativeIsReady: () => boolean;
