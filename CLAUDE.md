# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project goal

让华为平板（**安卓鸿蒙和纯血鸿蒙**）作为 MacBook 的低延迟副屏，基于开源 [SideScreen](https://github.com/tranvuongquocdat/SideScreen)（MIT）派生。

## Repository layout（三子项目并存）

```
SideScreen-NEXT/
├── PROJECT_BRIEF.md      # 用户实测背景 + 规划（早期分析，部分结论已被 PROTOCOL.md §5 修正）
├── PROTOCOL.md           # 协议规范（已逆向 + 实测 + 字节序确定）
├── machost-fork/         # Mac Host fork（基于上游 0.6.8 = commit 049caf8）
├── harmony-client/       # HarmonyOS NEXT 客户端（DevEco，包名 tech.visionflow.sidescreennext）
└── android-client/       # Android 客户端 fork（基于上游 0.6.8 = commit 049caf8）
                          # 用途：HMOS 2.x（MatePad Paper），及任意 Android 8.0+ 平板
```

## Build / install

环境变量（zshrc 已加）：
- `DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk`
- `PATH` 包含 `…/sdk/default/openharmony/toolchains`（hdc）和 `…/tools/hvigor/bin`（hvigorw）

### Mac host（machost-fork/）

Swift Package Manager，平台 macOS 14+。

```bash
cd machost-fork
swift build -c release
# 替换已安装的 SideScreen.app
killall SideScreen 2>/dev/null
cp .build/release/SideScreen /Applications/SideScreen.app/Contents/MacOS/SideScreen
codesign --force --deep --sign - /Applications/SideScreen.app
open /Applications/SideScreen.app
```

回滚到原版：`cp /Applications/SideScreen.app/Contents/MacOS/SideScreen.original.bak …`

调试日志：`tail -f /tmp/sidescreen.log`

### 鸿蒙端（harmony-client/）

```bash
cd harmony-client
hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
hdc shell aa start -a EntryAbility -b tech.visionflow.sidescreennext

# 看 ArkTS 端日志（console.* 走 hilog tag JSAPP）
hdc shell "hilog -x" | grep -E "JSAPP.*sidescreennext"
```

DevEco 项目 SDK：targetSdkVersion=API 23（DevEco 自带），compatibleSdkVersion=API 12（覆盖 MatePad mini API 22+ 设备）。

### Android 端（android-client/）

Gradle 项目，最低 Android 8.0 (API 26)。从上游 fork，本地 Mac 端协议无变更，可直连本仓库 machost-fork。

```bash
cd android-client
./gradlew assembleDebug
# APK 路径：app/build/outputs/apk/debug/app-debug.apk

# MatePad Paper / 任意 Android 设备安装
adb install -r app/build/outputs/apk/debug/app-debug.apk

# HMOS 2.x 设备（MatePad Paper 走 hdc 而不是 adb）
hdc install app/build/outputs/apk/debug/app-debug.apk
```

**HMOS 2.x 兼容性**：HarmonyOS 2.x 基于 AOSP 应用层，可运行 Android APK。MatePad Paper（HMOS 2.1）是首要目标设备，e-ink 屏的渲染节流由系统/驱动负责，APK 不需特殊改造即可运行（首期）。

**fork provenance**：上游 commit 049caf8（v0.6.8），与 machost-fork 同基线。harmony-client 这边的 UX 改动（mDNS、USB 优先、状态浮层、自动重连等）尚**未** port 到 Android 端，待后续按需迁移（详见 `~/.claude/plans/matepad-paper-bright-corbato.md` 的 porting backlog）。

## Architecture

```
MacBook                                       MatePad mini
─────────                                     ─────────
SideScreen.app (forked)                       SideScreen-NEXT App
  CGVirtualDisplay 创建虚拟显示器
  ScreenCaptureKit 捕获
  VideoToolbox H.265 全 I 帧编码（Annex-B）
  StreamingServer (BSD socket *:8888) ─────► @ohos.net.socket TCPSocket
                                              ProtocolParser → 5 种 type 分派
                                              （C4 待实现：OH_VideoDecoder + XComponent）
                                          ◄── 1Hz ping (type=0x04)
       pong (type=0x05) ──────────────────►   RTT 测量
```

详细协议 / 字节序见 [PROTOCOL.md](PROTOCOL.md)。

## 重要 gotcha（已踩过的坑，不要重复）

### 1. Mac 上游 NWConnection 在 macOS 26 卡死

**症状**：用上游 SideScreen.app 时，外部 LAN 设备 TCP 三次握手成功，但 Mac NWConnection 状态卡在 `.preparing`，永远不进 `.ready` → 应用层数据零字节。

**根因**：macOS 26 的 Network.framework 对 ad-hoc 签名 App + Local Network 隐私机制结合下的隐性收紧。即使
- `Info.plist` 加了 `NSLocalNetworkUsageDescription`
- 系统设置 → 隐私 → 本地网络里 SideScreen 已开

仍然不会触发授权弹框，NWConnection 一直卡。

**修法**：[`machost-fork/Sources/StreamingServer.swift`](machost-fork/Sources/StreamingServer.swift) 把 NWListener/NWConnection 替换成 BSD POSIX socket（走 kernel 层，不经 Network.framework）。**公共接口与上游 100% 兼容**，AppDelegate 等其他文件零改动。

**验证**：日志里出现 `BSD TCP Server listening on port 8888` 而不是上游的 `TCP Server listening`。

### 2. AppDelegate `startServer()` 双 Start race

**症状**：连点 Start 两次（或前一实例没干净退出），日志里出现 `bind() failed: errno=48 Address already in use`。结果是有两个 streamingServer 实例：一个 listener 活着但没有 encoder；另一个 encoder 在产帧但 bind 失败 → MatePad 连上但帧数永远 0。

**修法**：[`machost-fork/Sources/AppDelegate.swift`](machost-fork/Sources/AppDelegate.swift) 加同步 `startInFlight: Bool` 标志，第二次点击直接打日志 `startServer ignored — start already in flight` 跳过。

### 3. 鸿蒙 ArkTS 严格模式

- **`@Builder` 的 primitive 参数不会响应 `@State` 变化重渲染**：要么用 `$$:` 对象传参，要么直接把 Row inline 进 build()。详见 [`harmony-client/entry/src/main/ets/pages/Index.ets`](harmony-client/entry/src/main/ets/pages/Index.ets) 的最终结构。
- **`interface` 用 method shorthand 时，对象字面量赋值通不过 `arkts-no-untyped-obj-literals`**：interface 字段必须用 function-typed 属性 (`onX: (a: A) => B`)，不能用方法 shorthand (`onX(a: A): B`)。详见 [`Protocol.ets`](harmony-client/entry/src/main/ets/net/Protocol.ets) 的 `ProtocolHandler`。

### 4. 协议字节序混合

- type=0x00 视频帧 size：**大端**
- type=0x01 显示配置 width/height/rotation：**大端**（早期猜测是小端，错误）
- type=0x02 触控 x/y/action：**小端**
- type=0x04 ping nanos：**小端**
- type=0x05 pong nanos：**小端**（原样回显 ping 字节）

来源 + 行号引用见 PROTOCOL.md §2。

## 重启 Mac SideScreen 干净流程

binary 替换/双 Start race 状态紊乱时：

```bash
killall -9 SideScreen 2>/dev/null
sleep 2
lsof -iTCP:8888 -sTCP:LISTEN  # 必须空
: > /tmp/sidescreen.log       # 清日志
open /Applications/SideScreen.app
# 等菜单栏图标出来 → 设置面板里**单击**一次 Start
```

## 协议字节调试

抓包看协议字节流：
```bash
sudo tcpdump -i en0 -n -X 'tcp port 8888 and host <MatePad-IP>' | head -40
```

每条消息首字节是 type，对照 PROTOCOL.md §1 表。

Mac 端 loopback 回显测试（不依赖 MatePad）：
```bash
python3 -c '
import socket
s = socket.socket(); s.settimeout(3); s.connect(("127.0.0.1", 8888))
data = b""
try:
    while len(data) < 32:
        c = s.recv(4096)
        if not c: break
        data += c
except: pass
print(f"got {len(data)} bytes: {data.hex()}")'
```

应当输出 `got 13 bytes: 01 00000XXX 00000XXX 00000000`（type=0x01 + 真实 width/height/rotation 大端）。
