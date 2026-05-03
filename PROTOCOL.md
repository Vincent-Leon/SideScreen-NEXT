# SideScreen Wire Protocol

逆向自上游 [tranvuongquocdat/SideScreen@049caf8](https://github.com/tranvuongquocdat/SideScreen/commit/049caf8) (v0.6.8)。所有引用为 `<上游文件>:<行号>` 格式，可在 `~/scratch/sidescreen-upstream/` 找到本地副本。

## TL;DR

- 单 TCP 连接到 Mac:8888，无握手
- 5 种消息，首字节是 type
- **字节序混合**：HEVC 帧 size + 显示尺寸字段是**大端**，触控/ping/pong 是**小端**
- HEVC：Main profile，**全 I 帧**（每帧前缀 VPS/SPS/PPS），Annex-B 4 字节起始码
- **Mac 端无 ADB 守卫**：源码确认任何 TCP 连接进入 `.ready` 即推流（实测发现的"Mac 只 ACK"另有原因，见 §5）

---

## 1. 消息表

| Type | 方向 | Payload 字节布局 | 总长（字节） |
|---|---|---|---|
| `0x00` | M→T | `int32 size`（**大端**）+ `size` bytes Annex-B HEVC | 5 + size |
| `0x01` | M→T | `int32 width` + `int32 height` + `int32 rotation`（全部**大端**） | 13 |
| `0x02` | T→M | `byte n`（指数）+ n × (`float32 x` + `float32 y`，**小端**) + `int32 action`（小端，0=down/1=move/2=up） | 1 指 14 / 2 指 22 |
| `0x03` | T→M | `int32 rotation`（**小端**，0/90/180/270） | 5 |
| `0x04` | T→M | `int64 nanos`（**小端**，`System.nanoTime()`） | 9 |
| `0x05` | M→T | `int64 nanos`（**小端**，原样回显 ping 的 8 字节） | 9 |
| `0x06` | M→T | （无 payload） | 1 |

> 📌 **type=0x06 server-shutdown**：Mac 端"用户主动 Stop"时，先发 0x06 再关 socket。客户端收到此消息后应区别于 USB 拔出 / 锁屏断开，回到 idle 连接页而非自动重连/暂停态。本 fork 新增（上游无），鸿蒙端实现见 [Protocol.ets](harmony-client/entry/src/main/ets/net/Protocol.ets) `TYPE_SERVER_SHUTDOWN`。

> ✅ **9 字节心跳验证**：抓包看到的 9 字节包正是 type=0x04 ping。源码 [StreamClient.kt:223-228](https://github.com/tranvuongquocdat/SideScreen/blob/main/AndroidClient/app/src/main/java/com/sidescreen/app/StreamClient.kt#L223-L228) 写得很清楚：`ByteBuffer.allocate(9).order(ByteOrder.LITTLE_ENDIAN); buffer.put(4.toByte()); buffer.putLong(System.nanoTime())`。MainActivity.kt:864-869 在连接后启动 1 Hz 定时器持续发。

---

## 2. 各消息字节序证据

### Type=0x00 视频帧
- Mac 发送：[StreamingServer.swift:210-214](https://github.com/tranvuongquocdat/SideScreen/blob/main/MacHost/Sources/StreamingServer.swift#L210-L214)
  ```swift
  packet.append(0) // Type: Video frame
  var frameSize = Int32(data.count).bigEndian
  withUnsafeBytes(of: &frameSize) { packet.append(contentsOf: $0) }
  ```
- Android 接收：[StreamClient.kt:122-131](https://github.com/tranvuongquocdat/SideScreen/blob/main/AndroidClient/app/src/main/java/com/sidescreen/app/StreamClient.kt#L122-L131)
  ```kotlin
  0 -> { // Video frame
      val frameSize = input.readInt()  // DataInputStream.readInt() = big-endian (Java 默认)
  ```

### Type=0x01 显示配置
- Mac 发送：[StreamingServer.swift:119-123](https://github.com/tranvuongquocdat/SideScreen/blob/main/MacHost/Sources/StreamingServer.swift#L119-L123)
  ```swift
  data.append(1) // Type: Display size + rotation
  data.append(contentsOf: withUnsafeBytes(of: Int32(displayWidth).bigEndian)  { Data($0) })
  data.append(contentsOf: withUnsafeBytes(of: Int32(displayHeight).bigEndian) { Data($0) })
  data.append(contentsOf: withUnsafeBytes(of: Int32(rotation).bigEndian)      { Data($0) })
  ```
- Android 接收：[StreamClient.kt:146-152](https://github.com/tranvuongquocdat/SideScreen/blob/main/AndroidClient/app/src/main/java/com/sidescreen/app/StreamClient.kt#L146-L152) — `readInt()` 三次（默认 BE）

> ⚠️ 修正：早期分析推断 type=0x01 是小端，**实际是大端**。鸿蒙端实现要用 `ntohl` 或手工拼字节。

### Type=0x02 触控
- Android 发送：[StreamClient.kt:194-205](https://github.com/tranvuongquocdat/SideScreen/blob/main/AndroidClient/app/src/main/java/com/sidescreen/app/StreamClient.kt#L194-L205)
  ```kotlin
  val buffer = ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN)
  buffer.put(2.toByte())
  buffer.put(count.toByte())
  buffer.putFloat(x); buffer.putFloat(y)
  if (count == 2) { buffer.putFloat(x2); buffer.putFloat(y2) }
  buffer.putInt(action)
  ```
- Mac 接收：[StreamingServer.swift:151-184](https://github.com/tranvuongquocdat/SideScreen/blob/main/MacHost/Sources/StreamingServer.swift#L151-L184) — `loadUnaligned(fromByteOffset:as:Float.self)` 用宿主字节序（macOS x86_64 / arm64 都是 LE）。**坐标归一化**到 0–1（[MainActivity.kt:902-911](https://github.com/tranvuongquocdat/SideScreen/blob/main/AndroidClient/app/src/main/java/com/sidescreen/app/MainActivity.kt#L902-L911)：`event.x / view.width.toFloat()`），由 Mac 用 `CGDisplayBounds(displayID)` 反算到屏幕坐标（AppDelegate.swift:511-516）。

### Type=0x04 ping / Type=0x05 pong
- Android 发送 ping：[StreamClient.kt:223-228](https://github.com/tranvuongquocdat/SideScreen/blob/main/AndroidClient/app/src/main/java/com/sidescreen/app/StreamClient.kt#L223-L228) — 1 字节 0x04 + 8 字节 LE int64
- Mac 收 ping → 回 pong：[StreamingServer.swift:185-191](https://github.com/tranvuongquocdat/SideScreen/blob/main/MacHost/Sources/StreamingServer.swift#L185-L191)
  ```swift
  } else if msgType == 4 && data.count >= 9 {
      let clientTimestamp = data.subdata(in: 1..<9)
      var pong = Data(capacity: 9)
      pong.append(5)
      pong.append(clientTimestamp)  // 原样回显，不重新打包
      connection.send(...)
  }
  ```
- Android 收 pong → 算 RTT：[StreamClient.kt:154-159](https://github.com/tranvuongquocdat/SideScreen/blob/main/AndroidClient/app/src/main/java/com/sidescreen/app/StreamClient.kt#L154-L159)

---

## 3. HEVC 编码与 Annex-B 帧格式

[VideoEncoder.swift:60-86](https://github.com/tranvuongquocdat/SideScreen/blob/main/MacHost/Sources/VideoEncoder.swift#L60-L86) — 关键参数：

```swift
// 实时模式 + Main profile
VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                     value: kVTProfileLevel_HEVC_Main_AutoLevel)

// 全 I 帧
VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 1)
VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 0.0)

// 无 B 帧、零延迟
VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0)
```

**每帧字节布局**（[VideoEncoder.swift:142-225](https://github.com/tranvuongquocdat/SideScreen/blob/main/MacHost/Sources/VideoEncoder.swift#L142-L225) `encodingOutputCallback`）：

```
[ 00 00 00 01 ] [ VPS NAL ] [ 00 00 00 01 ] [ SPS NAL ] [ 00 00 00 01 ] [ PPS NAL ] [ 00 00 00 01 ] [ IDR slice NAL ] ...
```

由于 `MaxKeyFrameInterval=1`，**每一帧都是 IDR**，所以**每一帧都前缀完整 VPS/SPS/PPS**（line 190-205 的 `if isKeyframe` 对每一帧都成立）。鸿蒙 `OH_VideoDecoder` 的 AnnexB 模式直接接受这种字节流。

源码把 VideoToolbox 输出的 length-prefixed AVCC 转成 Annex-B 起始码（line 209-223）。

**码率配置**（line 67-69）：默认 60 Mbps，gamingBoost 模式 50 Mbps、其他模式至少 60 Mbps。USB-C 5 Gbps 上完全跑得开，但 Wi-Fi 5GHz 上 60 Mbps 就够吃带宽 — 鸿蒙端连接时若实测拥塞需要在 fork Mac 端加可调档（不在一期范围）。

---

## 4. 连接生命周期

```
   Tablet                                Mac
     │                                    │
     │  TCP SYN → 8888                    │
     │ ◄────────── SYN-ACK ─────────────  │
     │  ACK ────────────────────────────► │
     │                                    │ NWConnection.state = .ready
     │ ◄─ type=0x01 width/height/rot ──── │ StreamingServer.handleConnection +
     │                                    │ sendDisplaySize() (StreamingServer.swift:84-85)
     │                                    │
     │ ── type=0x04 ping (1 Hz) ────────► │ MainActivity.startPingTimer (line 864-869)
     │ ◄─ type=0x05 pong ──────────────── │ StreamingServer.swift:185-191
     │                                    │
     │ ◄─ type=0x00 video frame ──────────│ VideoEncoder → StreamingServer.sendFrame
     │ ◄─ type=0x00 video frame ──────────│ (一旦 connectionReady=true 就开闸)
     │ ── type=0x02 touch ──────────────► │ MainActivity.handleTouch (line 898-948)
     │                                    │
     │ ── TCP FIN ──────────────────────► │
```

**重连**：上游 Android 端**没有自动重连**，由用户手动按 Connect。鸿蒙端建议复刻这一行为（一期）。

---

## 5. 实测验证结论（2026-04-27）

PROJECT_BRIEF.md §3 之前抓包看到 "Mac 只 ACK，从不推流" 是**误判**，并非 ADB 守卫导致。源码确认 Mac 端推流流水线**对 ADB 完全解耦**：

1. **`setupADBReverse()` 找不到 adb 只 `print` 警告然后 return**（[AppDelegate.swift:264-268](https://github.com/tranvuongquocdat/SideScreen/blob/main/MacHost/Sources/AppDelegate.swift#L264-L268)），不影响后续 `streamingServer?.start()` 和 `screenCapture?.startStreaming(...)`
2. **`StreamingServer.handleConnection` 对任意 TCP 连接进入 `.ready` 即调 `sendDisplaySize()`**（[StreamingServer.swift:84-85](https://github.com/tranvuongquocdat/SideScreen/blob/main/MacHost/Sources/StreamingServer.swift#L84-L85)），无 device serial / ADB 校验
3. **客户端代码作者亲口确认**：[MainActivity.kt:1117-1119](https://github.com/tranvuongquocdat/SideScreen/blob/main/AndroidClient/app/src/main/java/com/sidescreen/app/MainActivity.kt#L1117-L1119) 注释 _"Mac server sends display config (type=1) immediately upon connection. ADB daemon doesn't send anything, so read will timeout"_

**实测复现已通过**：用 `python3 socket.recv` 直连 `127.0.0.1:8888` 拿到了 4109 字节（type=0x01 显示配置 + 多个 type=0x00 H.265 帧），Mac 端日志 35-40 fps、25-28 Mbps、frame age 11-12 ms，状态健康。

之前抓包失败的真实原因：**SideScreen 进程残留导致 8888 listener 端口冲突**（日志可见 `Server failed: POSIXErrorCode(rawValue: 48): Address already in use`），需要 `kill -9` 进程后从 Applications 重启 App 才能复位。

> **实操建议**：Mac 端如果出现 "Client Connected: Yes 但 FPS=0" 这种症状，先 `lsof -iTCP:8888` 看是否端口冲突，再 `kill -9 <pid>` + 从 Applications 重启 SideScreen.app（不要只点 Stop+Start，不一定释放 listener）。

---

## 6. 鸿蒙端实现要点摘要

- **TCP**：连 Mac IP:8888，启用 `TCP_NODELAY`，缓冲区至少 64KB
- **解析循环**：读 1 字节 type → 按 type 分派；type=0x00 时再读 4 字节 BE size 然后读 size 字节
- **HEVC**：`OH_VideoDecoder_CreateByMime("video/hevc")` + AnnexB + Surface 输出；不需要单独 setParameter（参数集每帧都来）
- **心跳**：1 Hz `System.now()` 发 type=0x04，收到 type=0x05 后 `(now - sent) / 1e6 = RTT(ms)`
- **触控**（一期可选不做）：归一化 `event.x / width`，2 指最多

---

## 附：源码本地路径

```
~/scratch/sidescreen-upstream/
├── MacHost/Sources/
│   ├── AppDelegate.swift          # 服务编排 + ADB 辅助 + 触控注入
│   ├── StreamingServer.swift      # TCP server，协议读写
│   ├── ScreenCapture.swift        # SCStream + 备用 CGDisplayStream
│   ├── VideoEncoder.swift         # VideoToolbox H.265 + Annex-B 封装
│   └── VirtualDisplayManager.swift # CGVirtualDisplay
└── AndroidClient/app/src/main/java/com/sidescreen/app/
    ├── StreamClient.kt            # TCP client，协议读写，buffer pool
    ├── VideoDecoder.kt            # MediaCodec HEVC 解码，3 级配置回退
    ├── MainActivity.kt            # UI、触控、checklist、Surface 接管
    └── InputPredictor.kt          # 5 样本速度外推
```
