# Side Screen NEXT — 隐私政策 / Privacy Policy

**最近更新 / Last updated: 2026-05-01**

> 本页面是 Side Screen NEXT（HarmonyOS 客户端）的隐私政策原文。
> 上架华为应用市场（AppGallery）时使用本页面的公开 URL 作为隐私政策链接。
> 建议通过 GitHub Pages 发布：
> `https://vincentembp.github.io/SideScreen-NEXT/PRIVACY.html`
>（启用方式：仓库 Settings → Pages → Source 选 `main` branch / `/docs` 或根目录）

---

## 🇨🇳 中文版

### 一句话承诺

**Side Screen NEXT 不收集、不存储、不上传任何用户数据。** 所有连接均为本地或局域网内的点对点直连。

### 1. 我们收集的信息

**我们不收集任何个人信息或使用数据。**

具体来说：

- ❌ 不收集姓名、邮箱、手机号、身份证号等任何身份信息
- ❌ 不收集设备 IMEI / OAID / Mac 地址 等设备唯一标识
- ❌ 不收集位置信息（GPS / Wi-Fi / 基站）
- ❌ 不收集通讯录、相册、文件、剪贴板内容
- ❌ 不收集相机、麦克风音频
- ❌ 不上传应用使用日志、崩溃日志、性能数据
- ❌ 不集成任何第三方 SDK（无广告、无统计、无埋点）

### 2. 应用申请的系统权限及用途

| 权限 | 用途 | 是否上传 |
| --- | --- | --- |
| `ohos.permission.INTERNET` | 与同一台 MacBook 上运行的 Side Screen Mac 主机程序建立 TCP 连接，接收屏幕画面 | 否，仅用于点对点本地传输 |

应用不申请定位、相机、麦克风、存储、通讯录、电话等任何敏感权限。

### 3. 数据流向

```text
MacBook (Side Screen Mac host)  ◀────TCP─────▶  本设备 (Side Screen NEXT)
                                  局域网 / USB
```

- 屏幕画面、显示配置、心跳数据均在 MacBook 与本设备之间直连传输
- 不经过任何第三方服务器
- 不进入开发者控制的任何后端
- 应用关闭后，所有传输立即终止，本地不保留任何录像或截图

### 4. 应用本地存储的内容

应用仅在设备本地保存以下信息（用户偏好），不会上传：

- 上次成功连接的 Mac 主机 IP 与端口（用作下次自动连接的回退）
- 用户偏好（状态浮层各列开关、浮层透明度、设置按钮位置）

这些信息存储在 HarmonyOS 应用沙箱内，卸载应用时全部清除。

### 5. 第三方服务

**不使用任何第三方服务**：无广告 SDK、无统计分析 SDK、无云服务、无远程配置、无消息推送。

应用商店付费购买流程由华为 AppGallery 处理，与本应用无关。

### 6. 儿童隐私

本应用不专门面向 14 岁以下儿童设计，不收集儿童的任何数据。

### 7. 政策更新

如本隐私政策有任何更新，会同步发布在本 GitHub 仓库的 `PRIVACY.md` 文件中，并在更新时间标注。

### 8. 联系方式

- GitHub Issues: <https://github.com/vincenteMBP/SideScreen-NEXT/issues>

---

## 🌐 English version

### One-line promise

**Side Screen NEXT does not collect, store, or upload any user data.** All connections are direct peer-to-peer over local networks or USB.

### 1. Information we collect

**We collect no personal information or usage data.**

Specifically:

- ❌ No name, email, phone number, or any identity information
- ❌ No device IMEI / OAID / MAC address or other device identifiers
- ❌ No location data (GPS / Wi-Fi / cell)
- ❌ No contacts, photos, files, or clipboard contents
- ❌ No camera or microphone audio
- ❌ No usage logs, crash reports, or telemetry
- ❌ No third-party SDKs (no ads, analytics, or tracking)

### 2. Permissions requested by the app

| Permission | Purpose | Uploaded? |
| --- | --- | --- |
| `ohos.permission.INTERNET` | Establish a TCP connection to the Side Screen Mac host program running on a MacBook to receive screen frames | No — peer-to-peer local transport only |

The app does **not** request location, camera, microphone, storage, contacts, or telephony permissions.

### 3. Data flow

```text
MacBook (Side Screen Mac host)  ◀────TCP─────▶  This device (Side Screen NEXT)
                                  Local network / USB
```

- Screen frames, display config, and heartbeat packets are exchanged directly between your MacBook and this device.
- No third-party servers are involved.
- No data reaches any developer-controlled backend.
- When the app closes, all transport ends immediately. No recording or screenshot is retained.

### 4. Locally stored data

The app only stores the following user preferences inside the HarmonyOS app sandbox. These are never uploaded:

- The last successfully connected Mac host IP and port (used as a fallback for the next auto-connect)
- UI preferences (per-stat overlay toggles, overlay opacity, settings button position)

All of this data is removed when the app is uninstalled.

### 5. Third-party services

**No third-party services are used**: no ad SDK, no analytics SDK, no cloud services, no remote config, no push notifications.

The paid-app purchase flow is handled entirely by Huawei AppGallery and is independent of this application.

### 6. Children's privacy

This app is not directed to children under 14 and does not knowingly collect any data from children.

### 7. Updates to this policy

Any updates to this privacy policy will be published in `PRIVACY.md` in this GitHub repository, with the modification date noted at the top.

### 8. Contact

- GitHub Issues: <https://github.com/vincenteMBP/SideScreen-NEXT/issues>
