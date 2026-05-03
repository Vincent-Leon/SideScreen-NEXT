---
name: Bug 报告 / Bug report
about: 反馈缺陷或异常行为
title: "[BUG] "
labels: bug
---

## 现象
<!-- 简述发生了什么 -->

## 复现步骤
1.
2.
3.

## 期望
<!-- 你期望发生的 -->

## 环境
- Mac 端版本（Settings → 关于）：
- macOS 版本：
- 平板系统：HarmonyOS NEXT / HMOS 2.x / Android（请勾选）
- 平板型号：
- 客户端版本：
- 连接通道：USB / Wi-Fi / mDNS

## 日志（如有）
- Mac 端：`tail -200 /tmp/sidescreen.log`
- 鸿蒙端：`hdc shell "hilog -x" | grep -E "JSAPP.*sidescreennext"`
- Android 端：`adb logcat | grep -E "SideScreen|StreamClient"`

```
（粘贴关键 log 段）
```

## 截图 / 录屏
<!-- 可选，但对 UI 问题强烈建议附 -->
