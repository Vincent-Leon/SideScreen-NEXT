# Release checklist

每次发版按这个清单走，避免误把鸿蒙 hap 公开（鸿蒙端商业模式：AGC 应用商店上架收费）。

## 商业模式约定

| 端 | 分发渠道 | 是否进 GitHub Release |
|---|---|---|
| Mac (`machost-fork`) | GitHub Release，免费 | ✅ `SideScreenNEXT-vX.Y.Z.zip` |
| Android / HMOS 2.x (`android-client`) | GitHub Release，免费 | ✅ `SideScreenNEXT-vX.Y.Z-android.apk` |
| HarmonyOS NEXT (`harmony-client`) | 华为 / 鸿蒙应用商店上架 ¥6 / $2 | ❌ **不进 GitHub Release** |

源码三端均开源（MIT），用户可自行 build；鸿蒙端 hap 不一键发分发，是"便利付费"模型。

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
