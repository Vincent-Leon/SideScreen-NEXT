/*
 * 主页面 — UI 仿 Side Screen Android APK，分两态：
 *
 *   未连接：黑底 + 居中卡片 + Side Screen 标题 + Connection Checklist + 大蓝色 Connect
 *           + Advanced Settings 折叠 host/port
 *   连接后：全屏 XComponent + 浮层（FPS/BITRATE/RESOLUTION/RTT/BAT，可关）
 *           + 浮动 ⚙ 设置按钮（8 个位置可选） + 点击展开 Settings Modal
 *
 * Settings Modal: Show Stats toggle | Overlay Opacity slider | 8-pos picker | Disconnect | DONE
 */

import { common, bundleManager } from '@kit.AbilityKit'
import { batteryInfo } from '@kit.BasicServicesKit'
import { display, promptAction } from '@kit.ArkUI'
import { socket } from '@kit.NetworkKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { StreamClient, StreamClientCallbacks } from '../net/StreamClient'
import { Prefs, SavedConnection, SavedUiPrefs, Preset } from '../util/Prefs'
import { discoverSideScreen, DiscoveredService } from '../util/MdnsDiscovery'
import { I18n } from '../util/I18n'
import { nativeStart, nativePush, nativeStop, nativeIsReady } from 'libentry.so'

const TAG: string = '[Index]'
const RECONNECT_DELAYS_MS: number[] = [3000, 5000, 8000]
const PROBE_INTERVAL_MS: number = 5000
const SOURCE_URL: string = 'https://github.com/vincenteMBP/SideScreen-NEXT'

// 配色（与 Side Screen Android APK 对齐）
const COLOR_BG: string = '#000000'
const COLOR_CARD: string = '#E6000000'
const COLOR_OVERLAY: string = '#CC000000'
const COLOR_PRIMARY: string = '#007AFF'
const COLOR_TEXT: string = '#FFFFFF'
const COLOR_SUBTEXT: string = '#999999'
const COLOR_HINT: string = '#AAAAAA'
const COLOR_DIM: string = '#888888'
const COLOR_BBB: string = '#BBBBBB'
const COLOR_STATS_LABEL: string = '#88FFFFFF'
const COLOR_FPS: string = '#4CAF50'
const COLOR_BITRATE: string = '#2196F3'
const COLOR_RES: string = '#FF9800'
const COLOR_RTT: string = '#E91E63'
const COLOR_BAT: string = '#9C27B0'
const COLOR_BAT_LOW: string = '#FF453A'
const COLOR_BAT_CHG: string = '#4CAF50'
const COLOR_NET_USB: string = '#26C6DA'    // 青 — USB 通道
const COLOR_NET_WIFI: string = '#7E57C2'   // 紫 — Wi-Fi/mDNS 通道
const COLOR_ERR: string = '#FF453A'
const COLOR_OK: string = '#4CAF50'
const COLOR_BAD: string = '#FF453A'
const COLOR_PANEL_BG: string = '#1AFFFFFF'
const COLOR_INPUT_BG: string = '#1A1A1A'

interface StatColumnParams {
  label: string
  value: string
  color: string
}

interface ChecklistItemParams {
  label: ResourceStr
  ok: boolean
}

interface PosButtonParams {
  arrow: string
  pos: number
}

interface ConnectCandidate {
  host: string
  port: number
  /** 'USB' / 'mDNS' / 'Saved' / 'Manual' — 只用于 status 文案 */
  label: string
}

interface ReachableTarget {
  host: string
  port: number
  label: string
  /** mDNS 服务名称(只对 'mDNS' label 有意义,其他空字符串) */
  serviceName: string
}

interface StatToggleParams {
  label: ResourceStr
  hint: ResourceStr
  isOn: boolean
  onChange: (v: boolean) => void
}

@Entry
@Component
struct Index {
  // ---- 连接状态 ----
  @State host: string = '127.0.0.1'
  @State port: number = 8888
  @State advancedExpanded: boolean = false
  @State connecting: boolean = false
  @State connected: boolean = false
  @State status: string = ''

  // ---- 流状态 ----
  @State streamWidth: number = 0
  @State streamHeight: number = 0
  @State rttMs: number = 0
  @State frameCount: number = 0
  @State totalBytes: number = 0
  @State fps: number = 0
  @State mbps: number = 0
  @State lastError: string = ''
  @State surfaceLoaded: boolean = false
  @State decoderRunning: boolean = false

  // ---- 电量 ----
  @State batteryLevel: number = -1
  @State batteryCharging: boolean = false
  private batteryTimer: number = -1

  // ---- 设备方向 ----
  private lastSentRotationDeg: number = -1
  private nativeIsLandscape: boolean = true
  private nativeDetected: boolean = false

  // ---- UI 偏好（持久化）----
  @State showSettings: boolean = false  // settings modal
  @State showAbout: boolean = false     // about modal
  @State appVersion: string = ''
  @State showTransport: boolean = true
  @State showFps: boolean = true
  @State showBitrate: boolean = true
  @State showResolution: boolean = true
  @State showRtt: boolean = true
  @State showBattery: boolean = true
  @State overlayOpacity: number = 0.8
  @State settingsBtnPos: number = 0     // 0=BR / 1=BL / 2=TR / 3=TL / 4=TC / 5=BC / 6=CL / 7=CR

  // ---- Connection Checklist:实时发现的所有可达目标(USB / mDNS / 已保存预设)----
  @State reachableTargets: ReachableTarget[] = []
  private probeTimer: number = -1
  private discoveryInProgress: boolean = false

  // ---- 已保存预设（list 用 @State 让 settings modal 实时刷新）----
  @State presets: Preset[] = []

  // ---- 当前传输通道（'USB'/'mDNS'/'Saved'/'Manual'）+ USB 上线监视 ----
  @State currentTransport: string = ''
  private usbWatchTimer: number = -1

  private client: StreamClient | null = null

  // ---- 重连 ----
  private userInitiatedDisconnect: boolean = false
  private reconnectAttempts: number = 0
  private reconnectTimer: number = -1

  // ---- stats 浮层 1Hz timer ----
  private statsTimer: number = -1
  private bytesAtWindowStart: number = 0
  private framesAtWindowStart: number = 0
  private windowStartMs: number = 0

  // ============================================================================
  // Lifecycle
  // ============================================================================

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext
    I18n.init(ctx)
    this.status = I18n.s($r('app.string.status_ready'))
    try {
      const info = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
      this.appVersion = info.versionName
    } catch (e) {
      console.warn(TAG, `getBundleInfoForSelfSync: ${(e as Error).message}`)
    }
    Prefs.init(ctx)
      .then((): Promise<SavedConnection> => Prefs.load())
      .then((cfg: SavedConnection): Promise<SavedUiPrefs> => {
        if (cfg.host.length > 0) this.host = cfg.host
        if (cfg.port > 0) this.port = cfg.port
        return Prefs.loadUi()
      })
      .then((ui: SavedUiPrefs): Promise<Preset[]> => {
        this.showTransport = ui.showTransport
        this.showFps = ui.showFps
        this.showBitrate = ui.showBitrate
        this.showResolution = ui.showResolution
        this.showRtt = ui.showRtt
        this.showBattery = ui.showBattery
        this.overlayOpacity = ui.overlayOpacity
        this.settingsBtnPos = ui.settingsBtnPos
        return Prefs.loadPresets()
      })
      .then((list: Preset[]): void => {
        this.presets = list
        console.info(TAG, `presets loaded: ${list.length}`)
        this.startProbeTimer()
      })
      .catch((e: Error): void => {
        console.warn(TAG, `prefs init/load failed: ${e.message}`)
        this.startProbeTimer()
      })

    this.refreshBattery()
    this.batteryTimer = setInterval((): void => {
      this.refreshBattery()
    }, 60000)

    this.detectNativeOrientation()

    display.on('change', (id: number): void => {
      this.handleRotationChange()
    })
  }

  aboutToDisappear(): void {
    this.stopProbeTimer()
    this.stopUsbWatch()
    if (this.batteryTimer >= 0) {
      clearInterval(this.batteryTimer)
      this.batteryTimer = -1
    }
    this.cancelReconnect()
    this.stopStatsTimer()
    if (this.decoderRunning) {
      nativeStop()
      this.decoderRunning = false
    }
    if (this.client != null) {
      this.client.disconnect().catch((_: Error): void => {})
      this.client = null
    }
  }

  // ============================================================================
  // 电量
  // ============================================================================

  private refreshBattery(): void {
    try {
      this.batteryLevel = batteryInfo.batterySOC
      this.batteryCharging =
        batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.ENABLE
    } catch (e) {
      console.warn(TAG, `battery read: ${(e as Error).message}`)
    }
  }

  // ============================================================================
  // 方向（rotation 0=landscape, 90=portrait）
  // ============================================================================

  private detectNativeOrientation(): void {
    try {
      const d = display.getDefaultDisplaySync()
      const r = d.rotation as number
      const w = d.width as number
      const h = d.height as number
      const wIsBigger = w > h
      const isHalfTurn = (r % 2) === 1
      this.nativeIsLandscape = wIsBigger !== isHalfTurn
      this.nativeDetected = true
      console.info(TAG, `native orientation: ${this.nativeIsLandscape ? 'landscape' : 'portrait'} (rot=${r}, w=${w}, h=${h})`)
    } catch (e) {
      console.warn(TAG, `detectNativeOrientation: ${(e as Error).message}`)
    }
  }

  private currentRotationDegrees(): number {
    if (!this.nativeDetected) {
      this.detectNativeOrientation()
    }
    try {
      const d = display.getDefaultDisplaySync()
      const r = d.rotation as number
      const isHalfTurn = (r % 2) === 1
      const isLandscape = this.nativeIsLandscape !== isHalfTurn
      return isLandscape ? 0 : 90
    } catch (e) {
      return 0
    }
  }

  private handleRotationChange(): void {
    if (!this.connected || this.client == null) return
    const deg = this.currentRotationDegrees()
    if (deg === this.lastSentRotationDeg) return
    console.info(TAG, `device rotated → sending ${deg}° (${deg === 0 ? 'landscape' : 'portrait'})`)
    this.lastSentRotationDeg = deg
    this.client.sendRotation(deg)
  }

  // ============================================================================
  // Server probe (Connection Checklist)
  // ============================================================================

  private startProbeTimer(): void {
    this.stopProbeTimer()
    this.discoverAllTargets()
    this.probeTimer = setInterval((): void => {
      this.discoverAllTargets()
    }, PROBE_INTERVAL_MS)
  }

  private stopProbeTimer(): void {
    if (this.probeTimer >= 0) {
      clearInterval(this.probeTimer)
      this.probeTimer = -1
    }
  }

  /** 全网扫描:USB + mDNS + 已保存预设,所有可达目标都列出来。
   *  顺序与 doAutoConnect 一致 — 列表第 1 个就是 Connect 会用的优先目标。 */
  private async discoverAllTargets(): Promise<void> {
    if (this.discoveryInProgress) return
    if (this.connected || this.connecting) return
    this.discoveryInProgress = true

    const found: ReachableTarget[] = []
    try {
      // 1) USB(127.0.0.1:8888)
      const usb = await this.probeServer('127.0.0.1', 8888)
      if (usb.isSideScreen) {
        found.push({ host: '127.0.0.1', port: 8888, label: 'USB', serviceName: '' })
      }

      // 2) mDNS 扫描(3s)
      try {
        const ctx = getContext(this) as common.UIAbilityContext
        const services = await discoverSideScreen(ctx, 3000)
        for (let i = 0; i < services.length; i++) {
          const svc = services[i]
          // 跳过和 USB 重复（loopback IP 不会撞，但保险起见）
          const dup = found.some((t: ReachableTarget): boolean =>
            t.host === svc.host && t.port === svc.port)
          if (!dup) {
            found.push({ host: svc.host, port: svc.port, label: 'mDNS', serviceName: svc.serviceName })
          }
        }
      } catch (_) { /* mDNS 失败不影响其他探测 */ }

      // 3) 已保存预设(只 probe 不在前两步里的)
      for (let i = 0; i < this.presets.length; i++) {
        const p = this.presets[i]
        const dup = found.some((t: ReachableTarget): boolean =>
          t.host === p.host && t.port === p.port)
        if (dup) continue
        try {
          const r = await this.probeServer(p.host, p.port)
          if (r.isSideScreen) {
            found.push({ host: p.host, port: p.port, label: 'Saved', serviceName: '' })
          }
        } catch (_) { /* skip */ }
      }

      this.reachableTargets = found
      // 闲置时根据扫描结果更新状态文案,避免 "Scanning…" 卡死
      if (!this.connected && !this.connecting && this.reconnectAttempts === 0) {
        if (found.length > 0) {
          this.status = I18n.s($r('app.string.status_targets_available'), found.length)
        } else {
          this.status = I18n.s($r('app.string.status_searching'))
        }
      }
    } finally {
      this.discoveryInProgress = false
    }
  }

  /** TCP 连过去 + 读首字节,首字节 == 0x01（type=displayConfig）证明对端是 Side Screen */
  private async probeServer(host: string, port: number): Promise<ProbeResult> {
    const result: ProbeResult = { reachable: false, isSideScreen: false }
    const tcp = socket.constructTCPSocketInstance()
    let firstByte: number = -1
    let resolveByte: ((v: number) => void) | null = null
    const bytePromise = new Promise<number>((resolve: (v: number) => void): void => {
      resolveByte = resolve
    })
    tcp.on('message', (info: socket.SocketMessageInfo): void => {
      const arr = new Uint8Array(info.message)
      if (arr.length > 0 && resolveByte != null) {
        resolveByte(arr[0])
        resolveByte = null
      }
    })
    try {
      const opts: socket.TCPConnectOptions = {
        address: { address: host, port: port } as socket.NetAddress,
        timeout: 1000,
      }
      await tcp.connect(opts)
      result.reachable = true

      // 等首字节,200ms 超时
      firstByte = await Promise.race<number>([
        bytePromise,
        new Promise<number>((resolve: (v: number) => void): void => {
          setTimeout((): void => resolve(-1), 200)
        }),
      ])
      result.isSideScreen = (firstByte === 0x01)
    } catch (e) {
      // ignore - will return default false
    } finally {
      try {
        tcp.off('message')
        await tcp.close()
      } catch (_) { /* ignore */ }
    }
    return result
  }

  // ============================================================================
  // StreamClient callbacks
  // ============================================================================

  private buildCallbacks(): StreamClientCallbacks {
    return {
      onConnected: (): void => {
        this.connecting = false
        this.connected = true
        this.reconnectAttempts = 0
        this.lastError = ''
        this.status = I18n.s($r('app.string.status_streaming_via'),
          this.currentTransport.length > 0 ? this.currentTransport : 'TCP')
        this.startStatsTimer()
        this.stopProbeTimer()
        Prefs.save({ host: this.host, port: this.port } as SavedConnection)
          .catch((e: Error): void => console.warn(TAG, `prefs.save: ${e.message}`))
        // 把成功的 host upsert 到预设列表（127.0.0.1 是 USB 通道，不存）
        if (this.host !== '127.0.0.1' && this.host !== 'localhost') {
          Prefs.upsertPreset({ host: this.host, port: this.port } as Preset)
            .then((updated: Preset[]): void => { this.presets = updated })
            .catch((e: Error): void => console.warn(TAG, `upsertPreset: ${e.message}`))
        }
        const deg = this.currentRotationDegrees()
        this.lastSentRotationDeg = deg
        if (this.client != null) {
          this.client.sendRotation(deg)
        }
        // 非 USB 时启动 USB 上线监视器,插数据线时自动升级到有线
        if (this.currentTransport !== 'USB') {
          this.startUsbWatch()
        } else {
          this.stopUsbWatch()
        }
      },
      onDisconnected: (reason: string): void => {
        this.connecting = false
        this.connected = false
        this.stopStatsTimer()
        this.stopUsbWatch()
        if (this.decoderRunning) {
          nativeStop()
          this.decoderRunning = false
        }
        this.streamWidth = 0
        this.streamHeight = 0
        if (this.userInitiatedDisconnect) {
          this.status = I18n.s($r('app.string.status_disconnected'))
          this.userInitiatedDisconnect = false
          this.startProbeTimer()
        } else {
          this.status = I18n.s($r('app.string.status_disconnected_reason'), reason)
          this.scheduleReconnect()
        }
      },
      onDisplayConfig: (w: number, h: number, _rot: number): void => {
        const dimsChanged = (w !== this.streamWidth || h !== this.streamHeight)
        this.streamWidth = w
        this.streamHeight = h
        this.status = I18n.s($r('app.string.status_streaming_via'),
          this.currentTransport.length > 0 ? this.currentTransport : 'TCP')
        if (this.decoderRunning && dimsChanged) {
          console.info(TAG, `displayConfig dims changed → restart decoder`)
          nativeStop()
          this.decoderRunning = false
        }
        this.tryStartDecoder()
      },
      onVideoFrame: (frame: Uint8Array): void => {
        this.frameCount = this.frameCount + 1
        this.totalBytes = this.totalBytes + frame.length
        if (this.decoderRunning) {
          nativePush(frame)
        }
      },
      onLatency: (rtt: number): void => {
        this.rttMs = rtt
      },
      onError: (err: Error): void => {
        this.lastError = err.message
        console.error(TAG, err.message)
      },
    }
  }

  // ============================================================================
  // Decoder
  // ============================================================================

  private tryStartDecoder(): void {
    if (this.decoderRunning) return
    if (this.streamWidth <= 0 || this.streamHeight <= 0) return
    if (!this.surfaceLoaded || !nativeIsReady()) {
      return
    }
    const ok = nativeStart(this.streamWidth, this.streamHeight)
    if (ok) {
      this.decoderRunning = true
    } else {
      this.lastError = I18n.s($r('app.string.err_decoder_start'))
    }
  }

  // ============================================================================
  // Auto Connect: USB → mDNS → 已保存预设 → 手动 host
  // ============================================================================

  private async doAutoConnect(fromReconnect: boolean = false): Promise<void> {
    if (this.connecting || this.connected) return
    this.lastError = ''
    this.connecting = true
    this.userInitiatedDisconnect = false
    if (!fromReconnect) {
      this.cancelReconnect()
    }
    this.stopProbeTimer()

    const candidates: ConnectCandidate[] = []

    // 1) USB（hdc rport tunnel 时本地回环最快）
    candidates.push({ host: '127.0.0.1', port: 8888, label: 'USB' })

    // 2) mDNS scan（3 秒）
    this.status = I18n.s($r('app.string.status_scanning'))
    try {
      const ctx = getContext(this) as common.UIAbilityContext
      const found = await discoverSideScreen(ctx, 3000)
      for (let i = 0; i < found.length; i++) {
        const svc = found[i]
        candidates.push({ host: svc.host, port: svc.port, label: 'mDNS' })
      }
    } catch (e) {
      console.warn(TAG, `mdns scan failed: ${(e as Error).message}`)
    }

    // 3) 已保存预设
    for (let i = 0; i < this.presets.length; i++) {
      const p = this.presets[i]
      // 已经在 candidates 里(USB/mDNS hit) 不再重复
      const dup = candidates.some((c: ConnectCandidate): boolean =>
        c.host === p.host && c.port === p.port)
      if (!dup) {
        candidates.push({ host: p.host, port: p.port, label: 'Saved' })
      }
    }

    // 4) 手动输入的 host（advanced settings 里）
    if (this.host.length > 0 && this.host !== '127.0.0.1' && this.host !== 'localhost') {
      const dup = candidates.some((c: ConnectCandidate): boolean =>
        c.host === this.host && c.port === this.port)
      if (!dup) {
        candidates.push({ host: this.host, port: this.port, label: 'Manual' })
      }
    }

    console.info(TAG, `autoConnect: ${candidates.length} candidates`)

    // 用快速 probe（1s 超时 + 200ms 等首字节）逐个试
    for (let i = 0; i < candidates.length; i++) {
      const c = candidates[i]
      if (this.userInitiatedDisconnect) {
        this.connecting = false
        this.status = I18n.s($r('app.string.status_cancelled'))
        return
      }
      this.status = I18n.s($r('app.string.status_trying'), c.label, c.host, c.port)
      try {
        const probe = await this.probeServer(c.host, c.port)
        if (probe.isSideScreen) {
          // 找到 — 真正连接
          this.host = c.host
          this.port = c.port
          this.currentTransport = c.label
          this.status = I18n.s($r('app.string.status_connecting_via'), c.label)
          this.connecting = false  // doConnect 会重新设
          await this.doConnect(false)
          return
        }
      } catch (_) { /* 跳过 */ }
    }

    // 都不通
    this.connecting = false
    this.status = I18n.s($r('app.string.status_no_screen'))
    this.lastError = candidates.length > 0
      ? I18n.s($r('app.string.status_no_screen_tried'), candidates.length)
      : I18n.s($r('app.string.status_no_targets'))
    if (fromReconnect && this.reconnectAttempts < RECONNECT_DELAYS_MS.length) {
      // reconnect 循环中,继续重试
      this.scheduleReconnect()
    } else {
      this.reconnectAttempts = 0
      this.startProbeTimer()
    }
  }

  // ============================================================================
  // Connect / disconnect / reconnect
  // ============================================================================

  private async doConnect(fromReconnect: boolean = false): Promise<void> {
    if (this.host.length === 0) {
      this.lastError = I18n.s($r('app.string.err_host_required'))
      return
    }
    this.lastError = ''
    if (!fromReconnect) {
      this.reconnectAttempts = 0
      this.cancelReconnect()
    }
    this.frameCount = 0
    this.totalBytes = 0
    this.fps = 0
    this.mbps = 0
    this.rttMs = 0
    this.streamWidth = 0
    this.streamHeight = 0
    this.connecting = true
    this.userInitiatedDisconnect = false
    this.status = I18n.s($r('app.string.status_connecting_via'), `${this.host}:${this.port}`)
    this.stopProbeTimer()

    this.client = new StreamClient(this.buildCallbacks())
    try {
      await this.client.connect(this.host, this.port)
    } catch (e) {
      const err = e as Error
      this.connecting = false
      this.connected = false
      this.status = I18n.s($r('app.string.status_connect_failed'))
      this.lastError = err.message
      this.client = null
      if (!this.userInitiatedDisconnect) {
        this.scheduleReconnect()
      }
    }
  }

  private async doDisconnect(): Promise<void> {
    this.userInitiatedDisconnect = true
    this.cancelReconnect()
    this.stopStatsTimer()
    this.stopUsbWatch()
    if (this.decoderRunning) {
      nativeStop()
      this.decoderRunning = false
    }
    if (this.client != null) {
      await this.client.disconnect()
      this.client = null
    }
    this.connected = false
    this.connecting = false
    this.streamWidth = 0
    this.streamHeight = 0
    this.currentTransport = ''
    this.status = I18n.s($r('app.string.status_disconnected'))
    this.showSettings = false
    this.startProbeTimer()
  }

  // ============================================================================
  // USB watch — 在 Wi-Fi 连接时每 10s 探测 USB 隧道,插上数据线就自动升级到有线
  // ============================================================================

  private startUsbWatch(): void {
    this.stopUsbWatch()
    this.usbWatchTimer = setInterval((): void => {
      this.checkUsbAvailable().catch((e: Error): void => {
        console.warn(TAG, `usbWatch: ${e.message}`)
      })
    }, 10000)
  }

  private stopUsbWatch(): void {
    if (this.usbWatchTimer >= 0) {
      clearInterval(this.usbWatchTimer)
      this.usbWatchTimer = -1
    }
  }

  private async checkUsbAvailable(): Promise<void> {
    if (!this.connected) return
    if (this.connecting) return
    if (this.currentTransport === 'USB') return
    const probe = await this.probeServer('127.0.0.1', 8888)
    if (!probe.isSideScreen) return
    console.info(TAG, 'USB tunnel detected, upgrading from Wi-Fi to USB')
    await this.switchToUsb()
  }

  /** 当前 Wi-Fi 连着,但 USB 也通了 → 切到 USB（更低延迟）。
   *  关键：保留 connected/streamWidth/streamHeight @State,XComponent 不卸载,UI 不闪回连接页。
   *  屏幕中间弹一个 toast 自动消失,新连接的 onDisplayConfig 会触发解码器重启。 */
  private async switchToUsb(): Promise<void> {
    if (!this.connected) return
    this.stopUsbWatch()
    this.cancelReconnect()
    this.stopStatsTimer()

    // toast 居中,自动 2s 消失
    promptAction.showToast({
      message: $r('app.string.status_switching_usb'),
      duration: 1500,
      bottom: 'center',  // HarmonyOS toast 默认底部,设为 center 居中
    })

    // 停 decoder（关键: 让 nativePush 别再喂老连接的尾帧到新 decoder）
    if (this.decoderRunning) {
      nativeStop()
      this.decoderRunning = false
    }
    // 关掉旧 socket — disconnect() 会先 off events 再 close,不会触发 onDisconnected
    if (this.client != null) {
      try {
        await this.client.disconnect()
      } catch (_) { /* ignore */ }
      this.client = null
    }
    // 注意: 不动 connected / streamWidth / streamHeight,XComponent 保持挂载

    // 建新 client 连 USB
    this.host = '127.0.0.1'
    this.port = 8888
    this.currentTransport = 'USB'
    this.userInitiatedDisconnect = false
    this.client = new StreamClient(this.buildCallbacks())
    try {
      await this.client.connect(this.host, this.port)
      // 成功 — onConnected 已经把 status 更新为 "Streaming via USB",toast 还会自然消失
    } catch (e) {
      const err = e as Error
      this.lastError = err.message
      this.client = null
      // USB 切换失败 → fall back: 走标准 reconnect cycle 找回 Wi-Fi
      this.connected = false
      this.streamWidth = 0
      this.streamHeight = 0
      this.scheduleReconnect()
    }
  }

  private scheduleReconnect(): void {
    if (this.reconnectAttempts >= RECONNECT_DELAYS_MS.length) {
      this.status = I18n.s($r('app.string.status_failed_after'), RECONNECT_DELAYS_MS.length)
      this.reconnectAttempts = 0
      this.startProbeTimer()
      return
    }
    const delay = RECONNECT_DELAYS_MS[this.reconnectAttempts]
    this.reconnectAttempts = this.reconnectAttempts + 1
    this.status = I18n.s($r('app.string.status_retry_in'),
      this.reconnectAttempts, RECONNECT_DELAYS_MS.length, delay / 1000)
    this.reconnectTimer = setTimeout((): void => {
      this.reconnectTimer = -1
      // 走 autoConnect — USB 拔掉时会自动 fall back 到 mDNS / Wi-Fi
      this.doAutoConnect(true).catch((e: Error): void => {
        console.error(TAG, `reconnect: ${e.message}`)
      })
    }, delay)
  }

  private cancelReconnect(): void {
    if (this.reconnectTimer >= 0) {
      clearTimeout(this.reconnectTimer)
      this.reconnectTimer = -1
    }
    this.reconnectAttempts = 0
  }

  // ============================================================================
  // Stats 1Hz timer
  // ============================================================================

  private startStatsTimer(): void {
    this.stopStatsTimer()
    this.bytesAtWindowStart = this.totalBytes
    this.framesAtWindowStart = this.frameCount
    this.windowStartMs = Date.now()
    this.statsTimer = setInterval((): void => {
      const now = Date.now()
      const elapsedSec = (now - this.windowStartMs) / 1000
      if (elapsedSec <= 0) return
      const dBytes = this.totalBytes - this.bytesAtWindowStart
      const dFrames = this.frameCount - this.framesAtWindowStart
      this.fps = dFrames / elapsedSec
      this.mbps = (dBytes * 8) / elapsedSec / 1_000_000
      this.bytesAtWindowStart = this.totalBytes
      this.framesAtWindowStart = this.frameCount
      this.windowStartMs = now
    }, 1000)
  }

  private stopStatsTimer(): void {
    if (this.statsTimer >= 0) {
      clearInterval(this.statsTimer)
      this.statsTimer = -1
    }
  }

  // ============================================================================
  // 持久化 helpers
  // ============================================================================

  private persistUi(): void {
    Prefs.saveUi({
      showTransport: this.showTransport,
      showFps: this.showFps,
      showBitrate: this.showBitrate,
      showResolution: this.showResolution,
      showRtt: this.showRtt,
      showBattery: this.showBattery,
      overlayOpacity: this.overlayOpacity,
      settingsBtnPos: this.settingsBtnPos,
    } as SavedUiPrefs).catch((e: Error): void => console.warn(TAG, `saveUi: ${e.message}`))
  }

  private hasAnyStat(): boolean {
    return this.showTransport || this.showFps || this.showBitrate ||
           this.showResolution || this.showRtt || this.showBattery
  }

  private posToAlignment(): Alignment {
    switch (this.settingsBtnPos) {
      case 0: return Alignment.BottomEnd
      case 1: return Alignment.BottomStart
      case 2: return Alignment.TopEnd
      case 3: return Alignment.TopStart
      case 4: return Alignment.Top
      case 5: return Alignment.Bottom
      case 6: return Alignment.Start
      case 7: return Alignment.End
      default: return Alignment.BottomEnd
    }
  }

  // ============================================================================
  // UI sub-builders
  // ============================================================================

  @Builder
  StatColumn($$: StatColumnParams) {
    Column() {
      Text($$.label).fontSize(10).fontColor(COLOR_STATS_LABEL).letterSpacing(0.5)
      Text($$.value).fontSize(16).fontWeight(FontWeight.Bold).fontColor($$.color)
    }
    .alignItems(HorizontalAlign.Start)
    .margin({ right: 16 })
  }

  @Builder
  ChecklistRow($$: ChecklistItemParams) {
    Row() {
      Circle({ width: 10, height: 10 })
        .fill($$.ok ? COLOR_OK : COLOR_BAD)
        .margin({ right: 10 })
      Text($$.label).fontSize(13).fontColor(COLOR_BBB).layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  StatToggleRow($$: StatToggleParams) {
    Row() {
      Column() {
        Text($$.label).fontSize(14).fontWeight(FontWeight.Bold).fontColor(COLOR_TEXT)
        Text($$.hint).fontSize(11).fontColor(COLOR_SUBTEXT).margin({ top: 2 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: $$.isOn })
        .onChange((on: boolean): void => { $$.onChange(on) })
    }
    .width('100%').padding({ top: 6, bottom: 6 }).alignItems(VerticalAlign.Center)
  }

  @Builder
  PosButton($$: PosButtonParams) {
    Button($$.arrow)
      .layoutWeight(1)
      .height(44)
      .fontSize(18)
      .fontColor(COLOR_TEXT)
      .backgroundColor(this.settingsBtnPos === $$.pos ? '#1A4CAF50' : 'transparent')
      .borderRadius(10)
      .borderColor(this.settingsBtnPos === $$.pos ? COLOR_OK : '#33FFFFFF')
      .borderWidth(1)
      .onClick((): void => {
        this.settingsBtnPos = $$.pos
        this.persistUi()
      })
  }

  @Builder
  ConnectionChecklist() {
    Column() {
      Row() {
        Text($r('app.string.targets_header'))
          .fontSize(14).fontWeight(FontWeight.Bold).fontColor(COLOR_TEXT).layoutWeight(1)
        Text(`${this.reachableTargets.length}`)
          .fontSize(12).fontColor(COLOR_HINT)
      }.width('100%').margin({ bottom: 8 })

      if (this.reachableTargets.length === 0) {
        Row() {
          Circle({ width: 10, height: 10 }).fill(COLOR_BAD).margin({ right: 10 })
          Text($r('app.string.targets_searching'))
            .fontSize(13).fontColor(COLOR_BBB).layoutWeight(1)
        }.width('100%').padding({ top: 4, bottom: 4 }).alignItems(VerticalAlign.Center)
      } else {
        ForEach(this.reachableTargets, (t: ReachableTarget, idx: number): void => {
          Row() {
            // 第 1 个实心绿,其他半透明
            Circle({ width: 10, height: 10 })
              .fill(idx === 0 ? COLOR_OK : '#664CAF50')
              .margin({ right: 10 })
            Column() {
              Row() {
                Text(t.label)
                  .fontSize(13)
                  .fontWeight(idx === 0 ? FontWeight.Bold : FontWeight.Normal)
                  .fontColor(idx === 0 ? COLOR_OK : COLOR_TEXT)
                  .margin({ right: 8 })
                Text(`${t.host}:${t.port}`)
                  .fontSize(13).fontColor(COLOR_BBB).layoutWeight(1)
              }.width('100%')
              if (idx === 0) {
                Text($r('app.string.targets_primary_hint')).fontSize(11).fontColor(COLOR_OK)
              } else if (t.serviceName.length > 0) {
                Text(t.serviceName).fontSize(11).fontColor(COLOR_DIM)
              }
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          }.width('100%').padding({ top: 6, bottom: 6 }).alignItems(VerticalAlign.Top)
        }, (t: ReachableTarget): string => `${t.host}:${t.port}`)
      }
    }
    .padding(16)
    .backgroundColor(COLOR_PANEL_BG)
    .borderRadius(12)
    .width('100%')
    .margin({ bottom: 20 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  ConnectView() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 0 }) {
        // 应用图标 — 复用 layered_image 合成版
        Image($r('app.media.app_icon_round'))
          .width(96).height(96)
          .objectFit(ImageFit.Contain)
          .margin({ bottom: 24 })

        Text($r('app.string.title_main')).fontSize(28).fontWeight(FontWeight.Bold).fontColor(COLOR_TEXT)
          .margin({ bottom: 8 })
        Text($r('app.string.subtitle_main'))
          .fontSize(14).fontColor(COLOR_SUBTEXT).margin({ bottom: 24 })

        this.ConnectionChecklist()

        Button(this.connecting ? $r('app.string.btn_connecting') : $r('app.string.btn_connect'))
          .width('100%').height(60).fontSize(18).fontWeight(FontWeight.Bold)
          .fontColor(COLOR_TEXT).backgroundColor(COLOR_PRIMARY).borderRadius(20)
          .enabled(!this.connecting)
          .onClick((): void => {
            this.doAutoConnect().catch((e: Error): void => {
              console.error(TAG, `autoConnect: ${e.message}`)
            })
          })
          .margin({ bottom: 16 })

        Row() {
          Circle({ width: 10, height: 10 })
            .fill(this.connecting ? COLOR_PRIMARY :
                  (this.lastError.length > 0 ? COLOR_ERR : COLOR_SUBTEXT))
            .margin({ right: 10 })
          Text(this.lastError.length > 0 ? this.lastError : this.status)
            .fontSize(13).fontColor(this.lastError.length > 0 ? COLOR_ERR : COLOR_HINT)
            .layoutWeight(1)
        }.width('100%').alignItems(VerticalAlign.Center).margin({ bottom: 8 })

        if (this.advancedExpanded) {
          Column({ space: 12 }) {
            TextInput({ placeholder: $r('app.string.ph_host'), text: this.host })
              .placeholderColor(COLOR_DIM).fontColor(COLOR_TEXT)
              .backgroundColor(COLOR_INPUT_BG).borderRadius(12).height(48)
              .padding({ left: 16, right: 16 }).enabled(!this.connecting)
              .onChange((v: string): void => {
                this.host = v.trim()
              })
            TextInput({ placeholder: $r('app.string.ph_port'), text: this.port.toString() })
              .type(InputType.Number).placeholderColor(COLOR_DIM).fontColor(COLOR_TEXT)
              .backgroundColor(COLOR_INPUT_BG).borderRadius(12).height(48)
              .padding({ left: 16, right: 16 }).enabled(!this.connecting)
              .onChange((v: string): void => {
                const n = parseInt(v)
                this.port = isNaN(n) ? 8888 : n
              })
          }.width('100%').margin({ top: 4 })
        }

        Text(this.advancedExpanded ? $r('app.string.hide_advanced') : $r('app.string.show_advanced'))
          .fontSize(13).fontColor(COLOR_PRIMARY).margin({ top: 8 }).padding(8)
          .onClick((): void => {
            this.advancedExpanded = !this.advancedExpanded
          })
      }
      .width('100%').padding(36).backgroundColor(COLOR_CARD).borderRadius(32)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%').height('100%').padding({ left: 32, right: 32 })
  }

  @Builder
  StatsOverlay() {
    Row() {
      if (this.showTransport) {
        this.StatColumn({
          label: 'NET',
          value: this.currentTransport.length > 0 ? this.currentTransport : '—',
          color: this.currentTransport === 'USB' ? COLOR_NET_USB : COLOR_NET_WIFI,
        })
      }
      if (this.showFps) {
        this.StatColumn({
          label: 'FPS',
          value: this.fps > 0 ? this.fps.toFixed(0) : '—',
          color: COLOR_FPS,
        })
      }
      if (this.showBitrate) {
        this.StatColumn({
          label: 'BITRATE',
          value: this.mbps > 0 ? `${this.mbps.toFixed(1)} M` : '—',
          color: COLOR_BITRATE,
        })
      }
      if (this.showResolution) {
        this.StatColumn({
          label: 'RESOLUTION',
          value: this.streamWidth > 0 ? `${this.streamWidth}×${this.streamHeight}` : '—',
          color: COLOR_RES,
        })
      }
      if (this.showRtt) {
        this.StatColumn({
          label: 'RTT',
          value: this.rttMs > 0 ? `${this.rttMs}ms` : '—',
          color: COLOR_RTT,
        })
      }
      if (this.showBattery) {
        this.StatColumn({
          label: this.batteryCharging ? 'BAT⚡' : 'BAT',
          value: this.batteryLevel >= 0 ? `${this.batteryLevel}%` : '—',
          color: this.batteryCharging ? COLOR_BAT_CHG :
                 (this.batteryLevel >= 0 && this.batteryLevel <= 20 ? COLOR_BAT_LOW : COLOR_BAT),
        })
      }
    }
    .padding({ top: 12, bottom: 12, left: 16, right: 16 })
    .backgroundColor(COLOR_OVERLAY)
    .borderRadius(20)
    .opacity(this.overlayOpacity)
    .margin({ top: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  SettingsIcon() {
    Stack({ alignContent: Alignment.Center }) {
      Image($r('app.media.ic_settings'))
        .width(22)
        .height(22)
        .fillColor(COLOR_TEXT)
    }
    .width(48).height(48)
    .borderRadius(24)
    .backgroundColor(COLOR_OVERLAY)
    .opacity(this.overlayOpacity)
    .onClick((): void => {
      this.showSettings = true
    })
    .margin(20)
  }

  @Builder
  SettingsModal() {
    Stack({ alignContent: Alignment.Center }) {
      // dim 背景,点空白处关闭
      Column().width('100%').height('100%').backgroundColor('#80000000')
        .onClick((): void => { this.showSettings = false })

      // 设置卡片(scrollable)
      Scroll() {
        Column({ space: 16 }) {
          Text($r('app.string.settings_title')).fontSize(28).fontWeight(FontWeight.Bold)
            .fontColor(COLOR_TEXT).textAlign(TextAlign.Center).width('100%')
            .margin({ bottom: 8 })

          // Stats 浮层各列单独开关（全 false 时浮层隐藏）
          Column() {
            Text($r('app.string.stats_overlay_title')).fontSize(17).fontWeight(FontWeight.Bold)
              .fontColor(COLOR_TEXT).margin({ bottom: 8 }).width('100%')
            Text($r('app.string.stats_overlay_hint'))
              .fontSize(11).fontColor(COLOR_SUBTEXT).margin({ bottom: 12 }).width('100%')

            this.StatToggleRow({
              label: $r('app.string.stats_net_label'),
              hint: $r('app.string.stats_net_hint'),
              isOn: this.showTransport,
              onChange: (v: boolean): void => { this.showTransport = v; this.persistUi() },
            })
            this.StatToggleRow({
              label: $r('app.string.stats_fps_label'),
              hint: $r('app.string.stats_fps_hint'),
              isOn: this.showFps,
              onChange: (v: boolean): void => { this.showFps = v; this.persistUi() },
            })
            this.StatToggleRow({
              label: $r('app.string.stats_bitrate_label'),
              hint: $r('app.string.stats_bitrate_hint'),
              isOn: this.showBitrate,
              onChange: (v: boolean): void => { this.showBitrate = v; this.persistUi() },
            })
            this.StatToggleRow({
              label: $r('app.string.stats_resolution_label'),
              hint: $r('app.string.stats_resolution_hint'),
              isOn: this.showResolution,
              onChange: (v: boolean): void => { this.showResolution = v; this.persistUi() },
            })
            this.StatToggleRow({
              label: $r('app.string.stats_rtt_label'),
              hint: $r('app.string.stats_rtt_hint'),
              isOn: this.showRtt,
              onChange: (v: boolean): void => { this.showRtt = v; this.persistUi() },
            })
            this.StatToggleRow({
              label: $r('app.string.stats_battery_label'),
              hint: $r('app.string.stats_battery_hint'),
              isOn: this.showBattery,
              onChange: (v: boolean): void => { this.showBattery = v; this.persistUi() },
            })
          }
          .padding(16).backgroundColor(COLOR_PANEL_BG).borderRadius(12).width('100%')
          .alignItems(HorizontalAlign.Start)

          // Opacity
          Column() {
            Row() {
              Text($r('app.string.opacity_title')).fontSize(17).fontWeight(FontWeight.Bold).fontColor(COLOR_TEXT)
                .layoutWeight(1)
              Text(`${Math.round(this.overlayOpacity * 100)}%`)
                .fontSize(15).fontColor(COLOR_OK)
            }.width('100%').margin({ bottom: 8 })
            Slider({
              value: this.overlayOpacity * 100,
              min: 20, max: 100, step: 5,
              style: SliderStyle.OutSet,
            })
              .selectedColor(COLOR_OK)
              .trackColor('#33FFFFFF')
              .onChange((value: number, _mode: SliderChangeMode): void => {
                this.overlayOpacity = value / 100
                this.persistUi()
              })
          }
          .padding(16).backgroundColor(COLOR_PANEL_BG).borderRadius(12).width('100%')
          .alignItems(HorizontalAlign.Start)

          // 8-pos picker
          Column() {
            Text($r('app.string.pos_title')).fontSize(17).fontWeight(FontWeight.Bold)
              .fontColor(COLOR_TEXT).margin({ bottom: 12 })
            Row({ space: 6 }) {
              this.PosButton({ arrow: '↖', pos: 3 })
              this.PosButton({ arrow: '↑', pos: 4 })
              this.PosButton({ arrow: '↗', pos: 2 })
            }.width('100%').margin({ bottom: 6 })
            Row({ space: 6 }) {
              this.PosButton({ arrow: '←', pos: 6 })
              Column().layoutWeight(1)
              this.PosButton({ arrow: '→', pos: 7 })
            }.width('100%').margin({ bottom: 6 })
            Row({ space: 6 }) {
              this.PosButton({ arrow: '↙', pos: 1 })
              this.PosButton({ arrow: '↓', pos: 5 })
              this.PosButton({ arrow: '↘', pos: 0 })
            }.width('100%')
          }
          .padding(16).backgroundColor(COLOR_PANEL_BG).borderRadius(12).width('100%')
          .alignItems(HorizontalAlign.Start)

          // Saved Locations
          Column() {
            Row() {
              Text($r('app.string.saved_title')).fontSize(17).fontWeight(FontWeight.Bold)
                .fontColor(COLOR_TEXT).layoutWeight(1)
              Text(`${this.presets.length}`).fontSize(13).fontColor(COLOR_HINT)
            }.width('100%').margin({ bottom: 8 })

            Text($r('app.string.saved_hint'))
              .fontSize(11).fontColor(COLOR_SUBTEXT).margin({ bottom: 12 }).width('100%')

            if (this.presets.length === 0) {
              Text($r('app.string.saved_empty'))
                .fontSize(13).fontColor(COLOR_DIM).width('100%').textAlign(TextAlign.Center)
                .padding({ top: 8, bottom: 8 })
            } else {
              ForEach(this.presets, (p: Preset): void => {
                Row() {
                  Column() {
                    Text(`${p.host}:${p.port}`).fontSize(14).fontColor(COLOR_TEXT)
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  Button('×')
                    .width(32).height(32).fontSize(18)
                    .fontColor(COLOR_BAD).backgroundColor('transparent')
                    .borderRadius(16).borderColor('#33FFFFFF').borderWidth(1)
                    .onClick((): void => {
                      Prefs.removePreset(p.host, p.port)
                        .then((updated: Preset[]): void => { this.presets = updated })
                        .catch((e: Error): void => console.warn(TAG, `removePreset: ${e.message}`))
                    })
                }
                .width('100%').padding({ top: 6, bottom: 6 })
                .alignItems(VerticalAlign.Center)
              }, (p: Preset): string => `${p.host}:${p.port}`)
            }
          }
          .padding(16).backgroundColor(COLOR_PANEL_BG).borderRadius(12).width('100%')
          .alignItems(HorizontalAlign.Start)

          // Disconnect (red)
          Button($r('app.string.btn_disconnect'))
            .width('100%').height(48).fontSize(13).fontColor(COLOR_BAD)
            .backgroundColor('#1AFF453A').borderRadius(14)
            .borderColor(COLOR_BAD).borderWidth(1)
            .onClick((): void => {
              this.showSettings = false
              this.doDisconnect().catch((e: Error): void => {
                console.error(TAG, `disconnect: ${e.message}`)
              })
            })

          // About (轻量、灰底)
          Button($r('app.string.btn_about'))
            .width('100%').height(44).fontSize(13).fontColor(COLOR_BBB)
            .backgroundColor('transparent').borderRadius(14)
            .borderColor('#33FFFFFF').borderWidth(1)
            .onClick((): void => {
              this.showAbout = true
            })

          // DONE (big green)
          Button($r('app.string.btn_done'))
            .width('100%').height(56).fontSize(16).fontWeight(FontWeight.Bold)
            .fontColor(COLOR_TEXT).backgroundColor(COLOR_OK).borderRadius(16)
            .onClick((): void => {
              this.showSettings = false
            })
        }
        .padding(28)
        .backgroundColor(COLOR_CARD)
        .borderRadius(28)
        .width('100%')
      }
      .width('86%').constraintSize({ maxHeight: '85%' })
      .scrollBar(BarState.Auto)
      // 阻止背景的 onClick 穿透关闭
      .onClick((): void => { /* eat */ })
    }
    .width('100%').height('100%')
  }

  @Builder
  AboutModal() {
    Stack({ alignContent: Alignment.Center }) {
      // dim 背景,点空白处关闭
      Column().width('100%').height('100%').backgroundColor('#80000000')
        .onClick((): void => { this.showAbout = false })

      Scroll() {
        Column({ space: 16 }) {
          Text($r('app.string.about_title'))
            .fontSize(28).fontWeight(FontWeight.Bold).fontColor(COLOR_TEXT)
            .textAlign(TextAlign.Center).width('100%').margin({ bottom: 4 })

          Text($r('app.string.app_name'))
            .fontSize(18).fontWeight(FontWeight.Bold).fontColor(COLOR_TEXT)
            .textAlign(TextAlign.Center).width('100%')

          Text($r('app.string.about_tagline'))
            .fontSize(13).fontColor(COLOR_SUBTEXT)
            .textAlign(TextAlign.Center).width('100%').margin({ bottom: 8 })

          // 版本信息
          Row() {
            Text($r('app.string.about_version_label'))
              .fontSize(13).fontColor(COLOR_HINT).layoutWeight(1)
            Text(this.appVersion.length > 0 ? this.appVersion : '—')
              .fontSize(13).fontColor(COLOR_TEXT)
          }.width('100%').padding(16).backgroundColor(COLOR_PANEL_BG).borderRadius(12)

          // 源代码链接
          Column() {
            Text($r('app.string.about_source_label'))
              .fontSize(13).fontColor(COLOR_HINT).width('100%').margin({ bottom: 4 })
            Text(SOURCE_URL)
              .fontSize(13).fontColor(COLOR_PRIMARY).width('100%')
              .copyOption(CopyOptions.LocalDevice)
          }
          .padding(16).backgroundColor(COLOR_PANEL_BG).borderRadius(12).width('100%')
          .alignItems(HorizontalAlign.Start)

          // 开源致谢
          Column({ space: 12 }) {
            Text($r('app.string.about_open_source_title'))
              .fontSize(15).fontWeight(FontWeight.Bold).fontColor(COLOR_TEXT)
              .width('100%').margin({ bottom: 4 })

            Text($r('app.string.about_credit_sidescreen'))
              .fontSize(12).fontColor(COLOR_BBB).width('100%').lineHeight(18)
            Text($r('app.string.about_credit_hdc'))
              .fontSize(12).fontColor(COLOR_BBB).width('100%').lineHeight(18)
            Text($r('app.string.about_credit_libusb'))
              .fontSize(12).fontColor(COLOR_BBB).width('100%').lineHeight(18)
          }
          .padding(16).backgroundColor(COLOR_PANEL_BG).borderRadius(12).width('100%')
          .alignItems(HorizontalAlign.Start)

          Button($r('app.string.about_close'))
            .width('100%').height(48).fontSize(15).fontWeight(FontWeight.Bold)
            .fontColor(COLOR_TEXT).backgroundColor(COLOR_OK).borderRadius(14)
            .onClick((): void => { this.showAbout = false })
        }
        .padding(28)
        .backgroundColor(COLOR_CARD)
        .borderRadius(28)
        .width('100%')
      }
      .width('86%').constraintSize({ maxHeight: '85%' })
      .scrollBar(BarState.Auto)
      .onClick((): void => { /* eat */ })
    }
    .width('100%').height('100%')
  }

  // ============================================================================
  // Build
  // ============================================================================

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      // 整页黑底
      Column().width('100%').height('100%').backgroundColor(COLOR_BG)

      if (this.connected && this.streamWidth > 0 && this.streamHeight > 0) {
        // 视频层
        XComponent({
          id: 'mainSurface',
          type: XComponentType.SURFACE,
          libraryname: 'entry',
        })
          .width('100%').height('100%')
          .onLoad((): void => {
            this.surfaceLoaded = true
            this.tryStartDecoder()
          })
          .onDestroy((): void => {
            this.surfaceLoaded = false
            if (this.decoderRunning) {
              nativeStop()
              this.decoderRunning = false
            }
          })

        // Stats 浮层（任何一项 stat 开着才渲染）
        if (this.hasAnyStat()) {
          this.StatsOverlay()
        }

        // 设置按钮（位置由 settingsBtnPos 决定，独立 Stack 层）
        Stack({ alignContent: this.posToAlignment() }) {
          this.SettingsIcon()
        }
        .width('100%').height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
      } else {
        this.ConnectView()
      }

      // Settings Modal（始终在最上层,只在 showSettings 时渲染）
      if (this.showSettings) {
        this.SettingsModal()
      }

      // About Modal（叠在 Settings 之上）
      if (this.showAbout) {
        this.AboutModal()
      }
    }
    .width('100%').height('100%')
  }
}

interface ProbeResult {
  reachable: boolean
  isSideScreen: boolean
}
