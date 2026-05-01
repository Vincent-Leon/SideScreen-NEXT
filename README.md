# SideScreen-NEXT

把 HarmonyOS NEXT 平板（如 MatePad mini）变成 MacBook 的低延迟有线副屏。

USB-C 模式延迟可降至 30 ms 以内，Wi-Fi LAN 模式约 60–80 ms。

派生自 [Side Screen](https://github.com/tranvuongquocdat/SideScreen)（MIT，© Tran Vuong Quoc Dat），适配鸿蒙端，并改写 Mac 侧的连接管线以支持非 ADB 设备 / hdc rport / Bonjour 自动发现。

---

## 仓库结构

```text
SideScreen-NEXT/
├── machost-fork/      Mac 端（Swift，开源）
│   └── 在原 Side Screen 基础上 fork，主要改动：
│       - 用 BSD POSIX socket 替换 NWConnection（绕开 macOS 26 Local Network 限制）
│       - 推流不再依赖 ADB 设备发现，任意 TCP 连接进来即可
│       - 内置 hdc 二进制 + 监视器,自动 hdc rport tcp:8888 tcp:8888
│       - Bonjour 发布 _sidescreen._tcp（鸿蒙端 mDNS 自动发现）
│       - 客户端方向上报后重建虚拟显示器（横竖屏切换）
│
├── harmony-client/    HarmonyOS NEXT 端（ArkTS + C++ NAPI）
│   ├── ets 层：UI / 协议 / mDNS 扫描 / 持久化
│   └── cpp 层：OH_VideoDecoder（HEVC 硬解）+ XComponent SURFACE 渲染
│
├── PROTOCOL.md        线协议规范（type 0/1/2/3/4/5）
├── PROJECT_BRIEF.md   项目调研与决策记录
└── CLAUDE.md          仓库工作约定
```

---

## 双端的发行模型

| 端 | 发行方式 | 价格 |
| --- | --- | --- |
| Mac 主机 | GitHub 开源仓库（本仓库 `machost-fork/`），自行编译或下载 Release 包 | 免费 |
| HarmonyOS 客户端 | 华为 / 鸿蒙应用商店上架 | ¥6（国内）/ $2（海外，一次性） |

> 鸿蒙端源码在本仓库公开（`harmony-client/`），任何人可自行用 DevEco Studio 构建并安装到自己的设备上。**应用商店付费**仅是为了覆盖开发者账号、证书续期、长期维护成本，并对希望免折腾安装的用户提供一键安装。

---

## Mac 端：从源码编译

依赖：Xcode 16+ / macOS 14+ / Swift 5.9+。

```bash
cd machost-fork
swift build -c release
./install.sh        # 签名 + 安装到 /Applications，自动重置相关 TCC 授权
open -a "Side Screen"
```

首次运行：

1. 系统设置 → 隐私与安全性 → **屏幕录制 / 录屏与系统录音** → 勾选 Side Screen
2. 系统设置 → 隐私与安全性 → **本地网络** → 勾选 Side Screen（Wi-Fi 模式必需）
3. 顶栏菜单点 **Start Server**，端口默认 8888

---

## HarmonyOS 端：从源码构建

依赖：DevEco Studio 5.0+，鸿蒙真机（API 12 / HarmonyOS 5.x 及以上）。

```bash
cd harmony-client
hvigorw assembleHap --mode module -p product=default -p buildMode=debug
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
```

> hdc 调试证书 90 天过期，到期后用 DevEco Studio 重签即可。

---

## 使用方式

1. Mac 端 **Start Server**
2. 平板端打开 SideScreen NEXT，会自动扫描：
   - **USB**（127.0.0.1:8888，hdc rport 隧道，最低延迟）
   - **mDNS**（同一 Wi-Fi 下的 Mac 主机）
   - **已保存预设**（曾经成功连过的 IP）
3. 列表第一项即"点击 Connect 会用的目标"。Wi-Fi 连着时插入数据线会自动升级到 USB 通道，无需断开重连。
4. 进入投屏后右下角 ⚙ 打开 Settings：
   - 状态浮层各列单独开关（NET / FPS / BITRATE / RESOLUTION / RTT / BAT）
   - 浮层透明度
   - ⚙ 按钮位置（8 个角点）
   - 已保存预设管理
   - About / 断开连接

---

## 协议

详见 [PROTOCOL.md](./PROTOCOL.md)。简要：5 种 type，TCP 长连接，HEVC Annex-B + per-IDR VPS/SPS/PPS，type=0x00 视频帧的 size 用大端，其余字段小端。

---

## 致谢与许可证

- **[Side Screen](https://github.com/tranvuongquocdat/SideScreen)** — MIT，© Tran Vuong Quoc Dat。本项目 Mac 侧捕获管线、HEVC 编码参数、线协议派生自该上游项目。
- **[hdc](https://gitee.com/openharmony/developtools_hdc)** — Apache License 2.0 © OpenHarmony。Mac 端附带其 hdc 二进制用于 USB 隧道。
- **[libusb](https://libusb.info/)** — LGPL 2.1。被 hdc 用于访问 USB 设备。

本仓库自身代码同样以 **MIT License** 发布。
