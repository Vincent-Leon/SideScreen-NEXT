# Side Screen NEXT — 应用商店上架文案

> 上架华为应用市场（AppGallery）需要分别填写中文和英文文案。本文档汇总了两份。
> 字数限制以 AGC 后台为准（截至本次撰写：应用名 ≤ 16 字，简介 ≤ 80 字，介绍 ≤ 8000 字）。

---

## 📋 元信息

| 字段 | 值 |
| --- | --- |
| 应用名（中） | Side Screen NEXT |
| 应用名（英） | Side Screen NEXT |
| Bundle Name | dev.sidescreen.next |
| Version | 0.2.0 |
| 一级分类 | 工具 / Utilities |
| 二级分类 | 实用工具 / Productivity |
| 价格 | ¥6 / $1（一次性内购，无订阅） |
| 适配设备 | 平板（HarmonyOS NEXT 5.0+） |
| 推荐机型 | MatePad mini、MatePad Pro |
| 隐私权限 | INTERNET（必需）；本地网络发现（mDNS） |
| 不收集任何用户数据 | ✅ |

---

## 🇨🇳 中文文案

### 应用名

```
Side Screen NEXT
```

### 一句话简介（≤ 80 字）

```
把华为平板变成 MacBook 的低延迟有线副屏。USB-C 直连延迟 30 ms，支持自动旋转、Wi-Fi 备用。
```

### 详细介绍

```
Side Screen NEXT 让你的鸿蒙平板秒变 Mac 第二屏幕。

🚀 极致低延迟
通过 USB-C 数据线直连 MacBook，端到端延迟低至 30 ms（接近原生显示器水平）。
H.265 硬件解码 + Surface 直渲染管线，60 FPS 全程跟手。

🔌 零配置上手
- USB-C 模式：插线即用，自动建立 hdc 反向隧道，无需 IP 配置
- Wi-Fi 模式：基于 mDNS 自动发现同网段 Mac 主机，无需手动输入 IP
- 智能切换：Wi-Fi 连接时插入数据线会自动升级到 USB，无需断开重连

🔄 横竖屏自动切换
旋转平板时，Mac 副屏会自动重建为对应朝向，工作流不被打断。

🎨 投屏状态浮层
NET / FPS / BITRATE / RESOLUTION / RTT / BAT 六项参数可独立开关，浮层透明度、按钮位置（8 个角点）全部可调。

🆓 配套 Mac 端 100% 开源
本应用仅是双端方案的鸿蒙侧客户端，配套的 Mac 主机程序在 GitHub 完全开源（MIT），可自行下载编译。本应用付费仅用于覆盖开发者账号、应用商店分成与长期维护成本。

📦 包含开源致谢
本应用 Mac 侧捕获管线和通信协议派生自上游开源项目 Side Screen（MIT 许可证 © Tran Vuong Quoc Dat），并在「设置 → 关于」页面致谢所有依赖（Side Screen / hdc / libusb）。

⚠️ 使用须知
- 需要在 MacBook 上配套运行 Side Screen Mac 主机程序（开源、免费下载）
- macOS 14+ 系统
- 首次使用需在 Mac 上授予「屏幕录制」与「本地网络」权限
- USB-C 模式需要支持数据传输的 USB-C 数据线（非纯充电线）

📂 源代码
github.com/vincenteMBP/SideScreen-NEXT
```

### 更新日志（v0.2.0）

```
首次发布 ✨
- USB-C / Wi-Fi 双通道，自动切换以最低延迟为优先
- 平板旋转 → Mac 副屏自动重建为对应朝向
- mDNS 自动发现 Mac 主机
- 状态浮层各列可独立开关，⚙ 按钮 8 位置可选
- 内置完整开源致谢页（设置 → 关于）
```

### 关键词（搜索优化）

```
副屏, 第二屏幕, Mac, MacBook, 投屏, 扩展显示器, USB-C, Sidecar, 平板副屏, 华为副屏, MatePad
```

---

## 🌐 English copy

### App name

```
Side Screen NEXT
```

### Short description (≤ 80 chars)

```
Turn your HarmonyOS tablet into a low-latency wired second display for MacBook.
```

### Long description

```
Side Screen NEXT turns your HarmonyOS tablet into a second display for your MacBook.

🚀 Ultra-low latency
USB-C direct connection delivers ~30 ms end-to-end latency — close to a native external monitor. H.265 hardware decoding + zero-copy surface rendering at a smooth 60 FPS.

🔌 Zero configuration
- USB-C mode: plug in and go. The hdc reverse tunnel is established automatically — no IP, no port to configure.
- Wi-Fi mode: same-network Mac hosts are auto-discovered via mDNS.
- Smart upgrade: while connected over Wi-Fi, plugging in a USB-C cable seamlessly upgrades to USB without dropping the session.

🔄 Auto rotation
Rotate the tablet and the Mac's virtual display rebuilds in the matching orientation — your workspace follows.

🎨 Configurable stats overlay
Toggle each metric individually (NET / FPS / BITRATE / RESOLUTION / RTT / BAT). Pick from 8 anchor positions for the gear button. Adjust overlay opacity to taste.

🆓 Companion Mac host is 100% open source
This app is the HarmonyOS client of a two-sided system. The Mac host program is fully open-sourced under MIT on GitHub — anyone can build from source. The paid app on the store covers developer-account, listing, and long-term maintenance costs only.

📦 Open source acknowledgements
The Mac-side capture pipeline and wire protocol of this app are derived from the upstream Side Screen project (MIT, © Tran Vuong Quoc Dat). All dependencies (Side Screen, hdc, libusb) are credited in Settings → About.

⚠️ Requirements
- A companion Mac host program (free, open source) running on your MacBook
- macOS 14 or later
- Grant Screen Recording and Local Network permissions on first launch
- USB-C mode requires a data-capable USB-C cable (charging-only cables won't work)

📂 Source code
github.com/vincenteMBP/SideScreen-NEXT
```

### Release notes (v0.2.0)

```
Initial release ✨
- USB-C and Wi-Fi transports, auto-priority for lowest latency
- Tablet rotation → Mac virtual display rebuilds to match
- mDNS auto-discovery for Mac hosts on the same network
- Per-stat overlay toggles, 8 settings-button positions
- Full open-source attribution screen (Settings → About)
```

### Keywords

```
second display, sidecar, mac, macbook, screen extender, usb-c, harmonyos, matepad, external monitor, mirror, second screen
```

---

## ⚖️ 合规要点（重要 — 上架前确认）

1. **MIT 上游致谢已落地**
   - About 页面包含完整 attribution（Side Screen 上游、hdc、libusb），位置：进入投屏 → ⚙ → About
   - LICENSE 文件需附带 MIT 许可证全文（待添加）

2. **付费定价合规**
   - AppGallery 不允许 0.99 / 1.99 USD 这种带 .99 的尾价 → 用整数（$1 / $2 等）
   - 国内 ¥6 一档对应 AGC 价梯档（参考 AGC 价格档列表）

3. **隐私声明**
   - Manifest 仅声明 `ohos.permission.INTERNET`，无定位 / 无录音 / 无相机 / 无存储
   - 应用本身不收集任何用户数据，无埋点 / 无远程日志
   - 隐私政策可一行写明：本应用不收集、不上传任何数据；所有连接均为本地 / 局域网点对点

4. **上架材料**
   - App icon（512 × 512 PNG，矢量来源）
   - 截图：未连接（含 Available Targets 列表）/ 投屏中（含状态浮层）/ 设置面板 / About 页面 — 各 2 张以上（横竖各一组）
   - 应用宣传视频（可选，60 秒以内）

5. **海外上架（可选）**
   - 同步在 AppGallery 海外版上架，英文文案直接复用
   - 价格用 $1（避免 .99 后缀，AGC 不允许）
