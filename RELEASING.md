# Release checklist

每次发版按这个清单走，避免误把鸿蒙 hap 公开（鸿蒙端商业模式：AGC 应用商店免费下载 + IAP 解锁 Pro）。

## 商业模式约定

| 端 | 分发渠道 | 是否进 GitHub Release | 收费模式 |
|---|---|---|---|
| Mac (`machost-fork`) | GitHub Release，免费 | ✅ `SideScreenNEXT-vX.Y.Z.zip` | 免费 |
| Android / HMOS 2.x (`android-client`) | GitHub Release，免费 | ✅ `SideScreenNEXT-vX.Y.Z-android.apk` | 免费 |
| HarmonyOS NEXT (`harmony-client`) | 华为 / 鸿蒙应用商店上架 | ❌ **不进 GitHub Release** | 应用免费 + 一次性 IAP 解锁 Pro 自动化 |

源码三端均开源（MIT），用户可自行 build；鸿蒙端走"应用商店免费下载 + IAP 一次性付费解锁 Pro 便利特性"模型。

### Pro 功能边界

应用商店免费版 = 完整核心功能（投屏 + 触控 + 手动连接 + 通过 Mac 端 Settings 手动旋转）。
IAP 一次性付费解锁 3 项**自动化**便利特性：

1. **自动发现设备** — mDNS 扫描 + 已保存预设。免费用户走 USB 自动 + 手动 Host:Port 输入。
2. **自动重连** — 断线（锁屏 / USB 拔 / 网络抖动）后自动恢复。免费用户手动点 Connect 重连。
3. **自动旋转** — 平板物理方向变化时同步 Mac 副屏。免费用户在 Mac 端 Settings 选 0/90/180/270。

**功能完整性承诺**：免费用户可以完成投屏 + 触控的 100% 体验。Pro 仅锁定"零操作便利性"。

## AGC IAP 商品配置

发首版（含 IAP）前完成一次：

1. 登录 [AppGallery Connect](https://developer.huawei.com/consumer/cn/service/josp/agc/)
2. 选择 SideScreen-NEXT 应用 → **运营 ▸ 商品管理 ▸ 商品**
3. **创建商品**：
   - **商品类型**：非消耗型（一次买断终身）
   - **商品 ID**：`tech.visionflow.sidescreennext.pro_unlock`（需与 [`harmony-client/entry/src/main/ets/util/LicenseManager.ets`](harmony-client/entry/src/main/ets/util/LicenseManager.ets) 里的 `PRO_PRODUCT_ID` 严格一致；不一致就改其中一边）
   - **价格**：建议 ¥6（中国大陆区）/ $2（海外区）
   - **商品名称 / 简介**：填好——会显示在 IAP 收银台 + 应用 UI 拉取的商品信息里
4. **保存并激活**
5. 提交应用版本时勾选「启用 IAP」

### 沙盒测试

AGC 后台 ▸ **运营 ▸ 测试人员管理** 把测试设备的华为账号加入沙盒名单。沙盒账号买东西不真实扣款，方便回归 IAP 流程。

测试 checklist：
- 免费态启动：3 个 Pro toggle 灰显 + 🔒 PRO 标签，Settings「自动行为」分组顶部显示蓝色「升级 Pro」banner
- 点 Pro toggle → 弹 Pro modal，价格从 AGC 拉取并显示
- 沙盒账号点购买 → 收银台 → 完成 → toggle 解锁 + Pro banner 变绿色「✓ Pro unlocked」
- 重启 app → Pro 状态保留（本地缓存 + AGC 同步）
- 「恢复购买」按钮：测试在另一台设备登录同账号能恢复

### 应用上架审核要点

提交版本时需要：
- 在「应用信息」里勾选「应用内含付费内容」
- 在「合规性 ▸ 内购说明」里描述 Pro 解锁的内容（自动发现 / 自动重连 / 自动旋转）
- 上传一份免费版本截图 + Pro 已解锁版截图（华为审核常要求展示 IAP 收银台流程）

## 步骤

1. **版本号 bump**
   - `VERSION` → `X.Y.Z`
   - `harmony-client/AppScope/app.json5` → `versionName: "X.Y.Z"`、`versionCode: X*1000000 + Y*10000 + Z`
   - Android 端无需手动改（gradle 从 `VERSION` 文件读）
   - Mac 端无 versionString 字段（Bundle Info.plist 由 codesign 时实际不影响功能）

2. **构建三端 artifact**

   ```bash
   # Mac
   cd machost-fork && swift build -c release
   cp -R /Applications/SideScreen.app ../release/SideScreenNEXT-vX.Y.Z.app
   cp .build/release/SideScreen ../release/SideScreenNEXT-vX.Y.Z.app/Contents/MacOS/SideScreen
   rm -f ../release/SideScreenNEXT-vX.Y.Z.app/Contents/MacOS/SideScreen.original.bak
   codesign --force --deep --sign - ../release/SideScreenNEXT-vX.Y.Z.app
   xattr -cr ../release/SideScreenNEXT-vX.Y.Z.app
   ditto -c -k --keepParent ../release/SideScreenNEXT-vX.Y.Z.app ../release/SideScreenNEXT-vX.Y.Z.zip

   # Android
   cd ../android-client && JAVA_HOME=/opt/homebrew/opt/openjdk@17 ./gradlew assembleDebug
   cp app/build/outputs/apk/debug/app-debug.apk ../release/SideScreenNEXT-vX.Y.Z-android.apk

   # 鸿蒙 — build 出 hap 用于 AGC 上传，不要进 release/ 目录
   cd ../harmony-client
   # 先把 build-profile.json5 切到 AGC release cert（DevEco Studio ▸ Project Structure）
   hvigorw assembleHap --mode module -p product=default -p buildMode=release
   # entry/build/default/outputs/default/entry-default-signed.hap → 单独上传到 AGC 后台
   ```

3. **Tag**

   ```bash
   git tag -a vX.Y.Z -m "vX.Y.Z — short title"
   git push --tags origin main
   ```

4. **GitHub Release**

   ```bash
   gh release create vX.Y.Z \
     release/SideScreenNEXT-vX.Y.Z.zip \
     release/SideScreenNEXT-vX.Y.Z-android.apk \
     --title "vX.Y.Z — title" \
     --notes "..."
   ```

   ⚠️ **不要**把 `*.hap` 加进 `gh release create` 的 asset 列表。

5. **AGC 上架**（鸿蒙端）

   把第 2 步生成的 release-cert 签名 hap 上传到 [AppGallery Connect](https://developer.huawei.com/consumer/cn/service/josp/agc/)，提交审核。审核期间 GitHub Release 可以先发（v1.0.0 的 release notes 已注明鸿蒙端走应用商店）。

6. **同步分支**

   ```bash
   git branch -f harmony-dev main
   git branch -f macos-dev main
   git push --force origin harmony-dev macos-dev
   ```

## 防误发自检

发布前最后一次确认：

```bash
# release/ 目录应该只有 .zip 和 .apk 进 GitHub。看一眼有没有 hap 混进来
ls release/SideScreenNEXT-vX.Y.Z*

# gh release create 命令里不应出现 .hap
```

`release/` 目录已在 `.gitignore` 内，本地 hap 不会进仓，但 `gh release` 是手动 upload，需要靠这个 checklist 把关。
