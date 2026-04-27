# MatePane — 鸿蒙 NEXT 平板作为 macOS 副屏

> 把华为 MatePad Mini（HarmonyOS NEXT）变成 MacBook 的低延迟有线副屏。
> 本项目基于开源项目 [Side Screen](https://github.com/tranvuongquocdat/SideScreen)（MIT 协议）适配鸿蒙端。

---

## 1. 项目目标

- **设备**：MacBook (macOS) + 华为 MatePad Mini（HarmonyOS NEXT 5.0+）
- **目标体验**：插上 USB-C → 平板自动变成 Mac 的扩展显示器
- **核心指标**：端到端延迟 < 80ms（Side Screen 原版 USB 模式 30ms，LAN 模式预期 50–80ms）
- **不需要的功能**：触控反控、压感笔、Wi-Fi 模式（一期只做有线）

---

## 2. 上游项目 Side Screen 简介

仓库：<https://github.com/tranvuongquocdat/SideScreen> （v0.6.8，MIT）

### 2.1 架构
```
┌──────────────────┐  USB-C  ┌─────────────────────┐
│  macOS App       │ ──────► │  Android Tablet App │
│  (Swift)         │         │  (Kotlin/Java)      │
│                  │         │                     │
│  ScreenCaptureKit│  H.265  │  MediaCodec (HW)    │
│  → VideoToolbox  │ ──────► │  → SurfaceView      │
│  → TCP Server    │         │  → Choreographer    │
└──────────────────┘         └─────────────────────┘
       │                              ▲
       │  adb reverse tcp:N tcp:N     │
       └──────────────────────────────┘
              (USB tunnel via ADB)
```

### 2.2 工作流程（USB 模式）
1. Android APK 启动 → 监听本机 TCP 端口
2. Mac 端通过 `adb` 检测设备 → 自动 `adb reverse` 把 Mac 的端口反向映射到 Android 设备
3. Android APK 通过 `localhost:port` 连接 Mac 服务端（实际经 USB 隧道）
4. Mac 端用 ScreenCaptureKit 捕获虚拟显示器，VideoToolbox 硬编码 H.265，通过 TCP 推流
5. Android 端用 MediaCodec 硬解，渲染到 SurfaceView

### 2.3 Mac 端关键技术
- ScreenCaptureKit (SCStream) 捕获
- VideoToolbox 硬件 H.265 编码
- 自动调用 `adb reverse` 命令做端口转发
- TCP_NODELAY 减少延迟

### 2.4 Android 端关键技术
- MediaCodec H.265 硬件解码
- SurfaceView + Choreographer vsync 对齐
- TCP_NODELAY socket
- 通过 localhost 连接（ADB 隧道）

---

## 3. 实测发现（关键！）

我已经在 MatePad Mini 上做了完整的可行性测试，**不要跳过这一节**——它直接决定开发方案。

### 3.1 验证清单

| 项目 | 结果 | 含义 |
|---|---|---|
| 卓易通安装 Side Screen APK | ✅ 成功 | iSulad 容器能跑这个 APK |
| 手动输入 Mac IP 连接 | ✅ TCP 三次握手成功 | 网络层、容器网络都通 |
| 视频画面显示 | ❌ 黑屏 | 服务端从未推流 |
| FPS / RTT 指标 | ❌ 全 `--` | 视频管线没初始化 |

### 3.2 抓包发现（最关键）

`tcpdump` 抓 `tcp port 8888` 的结果：

```
14:58:01.604440  Mac ← Tablet  [.]   ack=1                  握手完成
14:58:02.641673  Mac ← Tablet  [P.]  seq 1:10  len=9        客户端发送 9 字节
14:58:02.641814  Mac → Tablet  [.]   ack=10                 Mac 仅 ACK，无 payload
14:58:03.645416  Mac ← Tablet  [P.]  seq 10:19 len=9        恰好 1 秒后又 9 字节
14:58:03.645674  Mac → Tablet  [.]   ack=19                 Mac 又只 ACK
```

ASCII 数据尾部（每个 9 字节包）：
```
.fw..o...    第一个心跳
..iVo...     第二个心跳
```

**结论**：
- 客户端每秒发 9 字节 — 这是**心跳包**，不是握手
- Mac 端**从未发过任何应用层数据**
- 推断：Side Screen Mac 端的"开始推流"动作**绑定在 ADB 设备发现事件上**。绕过 ADB 走 LAN 连接时，TCP 是通的，但 Mac 端业务状态机不知道这条连接对应哪个"已选择的设备"，所以从不触发 SCStream 推流

### 3.3 这次测试排除的疑虑

之前预判过几个潜在问题，本次测试结果显示：

- ✅ **网络层 OK**：TCP 通信正常，9ms RTT，连容器网络都没有阻拦
- ✅ **容器隔离不是当前瓶颈**：心跳能稳定收发，说明卓易通的网络栈对这个流量是透明的
- ⚠️ **MediaCodec 硬件 H.265 解码器是否在卓易通里工作未知**：因为根本没收到视频流，没机会暴露
- ❌ **不能直接用 Side Screen 原版**：Mac 端"绑定 ADB"是死结

### 3.4 协议特征推断

基于抓包：
- 协议**极简**：客户端心跳 + 服务端推 H.265 流，仅此而已
- **9 字节心跳**结构待确认（看代码定）。最后 3 字节疑似魔术字 `o..`（0x6F xx xx），中间 6 字节每次变化，疑似递增序号或时间戳
- 协议是**单向流**模式（服务端推流为主），客户端不需要复杂控制消息
- **不依赖复杂握手字段**（不传 device serial / prop 等），这意味着鸿蒙端复刻协议门槛很低

---

## 4. 目标架构

### 4.1 总体方案

```
┌─────────────────────┐   USB-C   ┌─────────────────────────┐
│  Modified macOS App │ ────────► │  HarmonyOS NEXT App     │
│  (Swift, fork)      │           │  (ArkTS + C++ NAPI)     │
│                     │           │                         │
│  + Manual IP mode   │  H.265    │  OH_VideoDecoder        │
│  OR                 │ ────────► │  → XComponent           │
│  + LAN auto-trigger │           │  → OH_NativeVSync       │
│                     │           │                         │
│  TCP Server (8888)  │           │  TCP Client             │
└─────────────────────┘           └─────────────────────────┘
       │                                   ▲
       │   hdc fport tcp:N tcp:N           │
       └───────────────────────────────────┘
            (HDC tunnel — Phase 2)
```

### 4.2 两阶段交付

**Phase 1 — LAN 模式（同 Wi-Fi 局域网，先跑通端到端）**
- Mac 端：fork Side Screen，加"手动 IP / 自动接受任何连接"模式
- 鸿蒙端：原生 App 通过局域网连 Mac
- 不依赖 hdc / USB

**Phase 2 — USB 模式（hdc 隧道，达到 30ms 延迟目标）**
- Mac 端：检测到 hdc 设备时自动 `hdc fport`
- 鸿蒙端：连 `127.0.0.1:port`，通过 USB 隧道走

---

## 5. 开发任务分解

### 5.1 Task A — 拆 Side Screen 源码（首要任务，1–2 天）

仓库：<https://github.com/tranvuongquocdat/SideScreen>

**A1. 定位 9 字节心跳格式**

读 Android 端代码，找到第一个 `outputStream.write(...)` 后定时调用的位置。重点看：
- 心跳包的字节布局（魔术字 / type / timestamp / seq / checksum）
- 频率（抓包显示约 1Hz）
- 服务端是否需要回应特定格式

**输出**：一份 `PROTOCOL.md`，描述心跳和视频流的字节级格式。

**A2. 定位 Mac 端"开始推流"触发条件**

读 macOS 端代码，找：
- `ADBManager` / `DeviceManager` / `DeviceListViewModel` 之类的设备管理类
- `SCStream` 或 `ScreenCaptureKit` 启动的代码路径
- 从"用户点 Connect 按钮"到"开始推流"的完整调用链

**输出**：标注哪几个函数是"开始推流"的入口；标注哪些条件检查依赖 ADB。

**A3. 定位 H.265 流帧格式**

- NAL 单元如何打包到 TCP（带不带长度前缀？SPS/PPS/VPS 怎么传？）
- 是否有自定义帧头
- 关键帧间隔策略

### 5.2 Task B — Mac 端改造（3–5 天）

基于 Task A 的发现，最小改动：

```swift
// 伪代码示意
class StreamingService {
    func onTCPConnectionAccepted(connection: NWConnection) {
        // 原版：等 ADBManager 通知 device matched
        // 改后：任何连接进来就启动推流
        if isLANModeEnabled {
            startStreaming(to: connection)
        } else {
            // 保留原有 ADB 路径
            adbManager.matchDevice(connection)
        }
    }
}
```

**变更范围**：
- 设置面板加 "LAN Mode" 开关 + 端口配置
- 设备列表 UI 增加"Manual Connection"项
- 推流触发逻辑解耦 ADB 依赖

**保持不变**：
- ScreenCaptureKit / VideoToolbox 编码管线
- TCP 协议格式（确保鸿蒙端能直接对接）
- 心跳处理逻辑

### 5.3 Task C — 鸿蒙端原生客户端（1–2 周）

**项目结构**：
```
matepane-harmony/
├── entry/src/main/
│   ├── ets/
│   │   ├── pages/
│   │   │   └── Index.ets          # 主页面：IP 输入 + 连接按钮
│   │   └── components/
│   │       └── VideoView.ets      # XComponent 包装
│   ├── cpp/
│   │   ├── decoder.cpp            # OH_VideoDecoder 封装
│   │   ├── network.cpp            # TCP socket + 心跳
│   │   ├── renderer.cpp           # NativeBuffer → XComponent surface
│   │   └── napi_init.cpp          # ArkTS ↔ Native 桥接
│   └── resources/
└── AppScope/
```

**模块拆分**：

| 模块 | 实现 | 关键 API |
|---|---|---|
| UI 框架 | ArkTS + ArkUI | `@Component`, `@State` |
| 视频显示 | XComponent | `OH_NativeXComponent_Callback` |
| 视频解码 | C++ Native | `OH_VideoDecoder_CreateByMime("video/hevc")` |
| 帧渲染 | C++ Native | `OH_NativeBuffer` + `EGLImage` 或 surface 模式 |
| 网络 | C++ Native | POSIX socket + `TCP_NODELAY` |
| VSync 对齐 | C++ Native | `OH_NativeVSync_Create` |
| 心跳 | C++ Native | `std::thread` + 1Hz 定时器 |

### 5.4 Task D — 集成测试（2–3 天）

测试矩阵：
- LAN 模式 + 不同分辨率（720p / 1080p / 1600p）
- LAN 模式 + 不同帧率（30/60/90/120）
- Mac 主屏不同 DPI（Retina / 非 Retina）
- 平板横屏 / 竖屏

测量延迟：手机拍 Mac 屏 + 平板屏的视频，逐帧分析时间戳差。

---

## 6. 鸿蒙 NEXT API 速查

### 6.1 Android → 鸿蒙 NEXT API 对照表

| Android | HarmonyOS NEXT | 说明 |
|---|---|---|
| `MediaCodec` | `OH_VideoDecoder` | C API，namespace `multimedia/video_codec_base` |
| `SurfaceView` / `Surface` | `XComponent` + `OH_NativeWindow` | 从 ArkTS 拿到 NativeWindow 给 native 用 |
| `Choreographer` | `OH_NativeVSync` | namespace `native_vsync` |
| `Socket` (Java) | POSIX socket (C/C++) | 直接用，鸿蒙 NEXT 兼容 POSIX |
| `Handler` / `Looper` | `napi_threadsafe_function` | NAPI 跨线程回调 |
| `adb forward/reverse` | `hdc fport/rport` | 命令格式 `hdc rport tcp:N tcp:N` |

### 6.2 关键文档入口
- DevEco Studio: <https://developer.huawei.com/consumer/cn/deveco-studio/>
- HarmonyOS NEXT API 文档: <https://developer.huawei.com/consumer/cn/doc/harmonyos-references/>
- XComponent 使用指南：搜索 "XComponent native"
- OH_VideoDecoder：搜索 "音视频编解码 native"
- 必读项：`@ohos.multimedia.media`，`@ohos.graphics.displaySync`

### 6.3 注意事项
- 鸿蒙 NEXT App 必须用调试证书签名才能侧载，证书有效期短，需要重新签名
- `OH_VideoDecoder` 是 native API，需要在 C++ 层调用，ArkTS 层调不到
- XComponent 拿 surface 必须在 native 层通过 `OnSurfaceCreated` 回调获取

---

## 7. MatePad Mini 硬件已确认信息

- **SoC**：麒麟 9010 系列，硬件支持 H.264 / H.265 4K 60fps 解码
- **屏幕**：8.8" OLED 2560×1600 120Hz，做副屏完全够用
- **USB**：标准版/柔光版/典藏版 USB 3.0 (5Gbps)，悦读版 USB 2.0 (480Mbps)
  - H.265 副屏流约 20–50 Mbps，**两种规格都不会成为瓶颈**
- **DP Alt Mode**：❌ 不支持。但本方案不需要 DP，走的是 USB 数据通道
- **hdc**：完全支持 `fport`（正向）和 `rport`（反向）端口转发，等价于 `adb forward/reverse`

---

## 8. 风险与未知

| 风险项 | 概率 | 应对 |
|---|---|---|
| 鸿蒙 NEXT 的 `OH_VideoDecoder` 对未上架 App 有限制 | 低 | 实测，必要时申请 entitlement |
| H.265 解码器不支持流式输入（要完整文件） | 极低 | 鸿蒙官方示例就有流式解码场景 |
| XComponent 与 OH_NativeBuffer 集成问题 | 中 | 优先用 surface 模式而非 buffer 直渲 |
| Mac 端 fork 后被上游分歧 | 中 | rebase 策略保持小改动，争取上游 PR 合并 |
| 调试证书有效期短（90 天） | 必现 | 写自动重签脚本 |
| 卓易通解码层未来想兜底 | N/A | 暂不考虑，原生方案性能远超 |

---

## 9. 立即可执行的下一步

按依赖顺序：

1. **Clone Side Screen 源码**：
   ```bash
   git clone https://github.com/tranvuongquocdat/SideScreen.git
   cd SideScreen
   ```

2. **完成 Task A（拆协议）**，产出 `PROTOCOL.md`

3. **搭建鸿蒙开发环境**：
   - 装 DevEco Studio
   - MatePad Mini 开开发者模式 + USB 调试
   - 跑通 `Hello World` ArkTS App

4. **写鸿蒙端最小原型**：
   - 一个空 XComponent
   - C++ 层 TCP socket 连 Mac 测试服务（用 `nc -l 8888` + ffmpeg 推流验证）
   - 把任意 H.265 测试流（如 ffmpeg 的样例文件）解码到 XComponent

5. **完成 Task B（Mac 端 LAN 模式）**

6. **联调 Phase 1**

7. **Phase 2：hdc 隧道改造**

---

## 附录 A — 测试命令速查

**抓包**（Mac 端）：
```bash
sudo tcpdump -i en0 -A -s 0 'tcp port 8888'
# 或保存到文件：
sudo tcpdump -i en0 -s 0 -w sidescreen.pcap 'tcp port 8888'
```

**hdc 端口转发**（Phase 2 用）：
```bash
hdc list targets                          # 列设备
hdc fport tcp:8888 tcp:8888               # 正向
hdc rport tcp:8888 tcp:8888               # 反向（等价 adb reverse）
hdc fport ls                              # 看现有规则
```

**Mac 端测试推流**（验证鸿蒙端解码）：
```bash
# 用 ffmpeg 把测试视频以 H.265 推到 8888
ffmpeg -re -i sample.mp4 -c:v libx265 -preset ultrafast -tune zerolatency \
  -f hevc tcp://0.0.0.0:8888?listen
```

---

## 附录 B — 参考资料

- Side Screen 仓库：<https://github.com/tranvuongquocdat/SideScreen>
- Side Screen 官网：<https://www.sidescreen.dev/>
- HarmonyOS Native API：<https://developer.huawei.com/consumer/cn/doc/harmonyos-references/native-lib-overview>
- hdc 工具文档：<https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/dfx/hdc.md>
- 鸿蒙投屏研究（uitest + hdc 端口映射方案参考）：<https://zhuanlan.zhihu.com/p/1898276582335968000>
- 卓易通技术原理：<https://zhuanlan.zhihu.com/p/10576812652>
