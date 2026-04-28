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

import { common } from '@kit.AbilityKit'
import { batteryInfo } from '@kit.BasicServicesKit'
import { display } from '@kit.ArkUI'
import { socket } from '@kit.NetworkKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { StreamClient, StreamClientCallbacks } from '../net/StreamClient'
import { Prefs, SavedConnection, SavedUiPrefs } from '../util/Prefs'
import { nativeStart, nativePush, nativeStop, nativeIsReady } from 'libentry.so'

const TAG: string = '[Index]'
const RECONNECT_DELAYS_MS: number[] = [3000, 5000, 8000]
const PROBE_INTERVAL_MS: number = 5000

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
  label: string
  ok: boolean
}

interface PosButtonParams {
  arrow: string
  pos: number
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
  @State status: string = 'Ready to connect'

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
  @State showStats: boolean = true
  @State overlayOpacity: number = 0.8
  @State settingsBtnPos: number = 0     // 0=BR / 1=BL / 2=TR / 3=TL / 4=TC / 5=BC / 6=CL / 7=CR

  // ---- Connection Checklist 探测 ----
  @State serverReachable: boolean = false
  @State serverIsSideScreen: boolean = false
  private probeTimer: number = -1

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
    Prefs.init(ctx)
      .then((): Promise<SavedConnection> => Prefs.load())
      .then((cfg: SavedConnection): Promise<SavedUiPrefs> => {
        if (cfg.host.length > 0) this.host = cfg.host
        if (cfg.port > 0) this.port = cfg.port
        return Prefs.loadUi()
      })
      .then((ui: SavedUiPrefs): void => {
        this.showStats = ui.showStats
        this.overlayOpacity = ui.overlayOpacity
        this.settingsBtnPos = ui.settingsBtnPos
        console.info(TAG, `prefs: stats=${ui.showStats} opacity=${ui.overlayOpacity} btnPos=${ui.settingsBtnPos}`)
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
    this.runProbe()
    this.probeTimer = setInterval((): void => {
      this.runProbe()
    }, PROBE_INTERVAL_MS)
  }

  private stopProbeTimer(): void {
    if (this.probeTimer >= 0) {
      clearInterval(this.probeTimer)
      this.probeTimer = -1
    }
  }

  private async runProbe(): Promise<void> {
    // 已连接 / 正在连接时不探测,避免抢占真实连接（Mac handleConnection 会替换 clientFd）
    if (this.connected || this.connecting) return
    if (this.host.length === 0) return
    try {
      const result = await this.probeServer(this.host, this.port)
      this.serverReachable = result.reachable
      this.serverIsSideScreen = result.isSideScreen
    } catch (e) {
      this.serverReachable = false
      this.serverIsSideScreen = false
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
        this.status = 'Waiting for display config…'
        this.startStatsTimer()
        this.stopProbeTimer()
        Prefs.save({ host: this.host, port: this.port } as SavedConnection)
          .catch((e: Error): void => console.warn(TAG, `prefs.save: ${e.message}`))
        const deg = this.currentRotationDegrees()
        this.lastSentRotationDeg = deg
        if (this.client != null) {
          this.client.sendRotation(deg)
        }
      },
      onDisconnected: (reason: string): void => {
        this.connecting = false
        this.connected = false
        this.stopStatsTimer()
        if (this.decoderRunning) {
          nativeStop()
          this.decoderRunning = false
        }
        this.streamWidth = 0
        this.streamHeight = 0
        if (this.userInitiatedDisconnect) {
          this.status = 'Disconnected'
          this.userInitiatedDisconnect = false
          this.startProbeTimer()
        } else {
          this.status = `Disconnected: ${reason}`
          this.scheduleReconnect()
        }
      },
      onDisplayConfig: (w: number, h: number, _rot: number): void => {
        const dimsChanged = (w !== this.streamWidth || h !== this.streamHeight)
        this.streamWidth = w
        this.streamHeight = h
        this.status = 'Streaming'
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
      this.lastError = 'Decoder start failed (see hilog ssn_native)'
    }
  }

  // ============================================================================
  // Connect / disconnect / reconnect
  // ============================================================================

  private async doConnect(fromReconnect: boolean = false): Promise<void> {
    if (this.host.length === 0) {
      this.lastError = 'Host required'
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
    this.status = `Connecting ${this.host}:${this.port}…`
    this.stopProbeTimer()

    this.client = new StreamClient(this.buildCallbacks())
    try {
      await this.client.connect(this.host, this.port)
    } catch (e) {
      const err = e as Error
      this.connecting = false
      this.connected = false
      this.status = 'Connect failed'
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
    this.status = 'Disconnected'
    this.showSettings = false
    this.startProbeTimer()
  }

  private scheduleReconnect(): void {
    if (this.reconnectAttempts >= RECONNECT_DELAYS_MS.length) {
      this.status = `Failed after ${RECONNECT_DELAYS_MS.length} retries`
      this.reconnectAttempts = 0
      this.startProbeTimer()
      return
    }
    const delay = RECONNECT_DELAYS_MS[this.reconnectAttempts]
    this.reconnectAttempts = this.reconnectAttempts + 1
    this.status = `Retry ${this.reconnectAttempts}/${RECONNECT_DELAYS_MS.length} in ${delay / 1000}s…`
    this.reconnectTimer = setTimeout((): void => {
      this.reconnectTimer = -1
      this.doConnect(true).catch((e: Error): void => {
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
      showStats: this.showStats,
      overlayOpacity: this.overlayOpacity,
      settingsBtnPos: this.settingsBtnPos,
    } as SavedUiPrefs).catch((e: Error): void => console.warn(TAG, `saveUi: ${e.message}`))
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
      Text('Connection Checklist')
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(COLOR_TEXT)
        .margin({ bottom: 8 })
        .width('100%')

      this.ChecklistRow({
        label: `Server reachable at ${this.host}:${this.port}`,
        ok: this.serverReachable,
      })
      this.ChecklistRow({
        label: 'Mac SideScreen ready',
        ok: this.serverIsSideScreen,
      })
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
        // 图标占位
        Stack({ alignContent: Alignment.Center }) {
          Text('🖥️').fontSize(40)
        }
        .width(80).height(80).borderRadius(40).backgroundColor('#1A2A4A')
        .margin({ bottom: 24 })

        Text('Side Screen').fontSize(28).fontWeight(FontWeight.Bold).fontColor(COLOR_TEXT)
          .margin({ bottom: 8 })
        Text('Turn your tablet into a second display')
          .fontSize(14).fontColor(COLOR_SUBTEXT).margin({ bottom: 24 })

        this.ConnectionChecklist()

        Button(this.connecting ? 'Connecting…' : 'Connect')
          .width('100%').height(60).fontSize(18).fontWeight(FontWeight.Bold)
          .fontColor(COLOR_TEXT).backgroundColor(COLOR_PRIMARY).borderRadius(20)
          .enabled(!this.connecting)
          .onClick((): void => {
            this.doConnect(false).catch((e: Error): void => {
              console.error(TAG, `connect: ${e.message}`)
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
            TextInput({ placeholder: 'Host', text: this.host })
              .placeholderColor(COLOR_DIM).fontColor(COLOR_TEXT)
              .backgroundColor(COLOR_INPUT_BG).borderRadius(12).height(48)
              .padding({ left: 16, right: 16 }).enabled(!this.connecting)
              .onChange((v: string): void => {
                this.host = v.trim()
              })
            TextInput({ placeholder: 'Port', text: this.port.toString() })
              .type(InputType.Number).placeholderColor(COLOR_DIM).fontColor(COLOR_TEXT)
              .backgroundColor(COLOR_INPUT_BG).borderRadius(12).height(48)
              .padding({ left: 16, right: 16 }).enabled(!this.connecting)
              .onChange((v: string): void => {
                const n = parseInt(v)
                this.port = isNaN(n) ? 8888 : n
              })
          }.width('100%').margin({ top: 4 })
        }

        Text(this.advancedExpanded ? 'Hide Advanced' : 'Advanced Settings')
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
      this.StatColumn({
        label: 'FPS',
        value: this.fps > 0 ? this.fps.toFixed(0) : '—',
        color: COLOR_FPS,
      })
      this.StatColumn({
        label: 'BITRATE',
        value: this.mbps > 0 ? `${this.mbps.toFixed(1)} M` : '—',
        color: COLOR_BITRATE,
      })
      this.StatColumn({
        label: 'RESOLUTION',
        value: this.streamWidth > 0 ? `${this.streamWidth}×${this.streamHeight}` : '—',
        color: COLOR_RES,
      })
      this.StatColumn({
        label: 'RTT',
        value: this.rttMs > 0 ? `${this.rttMs}ms` : '—',
        color: COLOR_RTT,
      })
      this.StatColumn({
        label: this.batteryCharging ? 'BAT⚡' : 'BAT',
        value: this.batteryLevel >= 0 ? `${this.batteryLevel}%` : '—',
        color: this.batteryCharging ? COLOR_BAT_CHG :
               (this.batteryLevel >= 0 && this.batteryLevel <= 20 ? COLOR_BAT_LOW : COLOR_BAT),
      })
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
          Text('Display Settings').fontSize(28).fontWeight(FontWeight.Bold)
            .fontColor(COLOR_TEXT).textAlign(TextAlign.Center).width('100%')
            .margin({ bottom: 8 })

          // Show Stats
          Row() {
            Column() {
              Text('Show Stats').fontSize(17).fontWeight(FontWeight.Bold).fontColor(COLOR_TEXT)
              Text('FPS, bitrate, resolution, RTT, battery')
                .fontSize(13).fontColor(COLOR_SUBTEXT).margin({ top: 2 })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.showStats })
              .onChange((on: boolean): void => {
                this.showStats = on
                this.persistUi()
              })
          }
          .padding(16).backgroundColor(COLOR_PANEL_BG).borderRadius(12).width('100%')
          .alignItems(VerticalAlign.Center)

          // Opacity
          Column() {
            Row() {
              Text('Overlay Opacity').fontSize(17).fontWeight(FontWeight.Bold).fontColor(COLOR_TEXT)
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
            Text('Settings Button Position').fontSize(17).fontWeight(FontWeight.Bold)
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

          // Disconnect (red)
          Button('Disconnect')
            .width('100%').height(48).fontSize(13).fontColor(COLOR_BAD)
            .backgroundColor('#1AFF453A').borderRadius(14)
            .borderColor(COLOR_BAD).borderWidth(1)
            .onClick((): void => {
              this.showSettings = false
              this.doDisconnect().catch((e: Error): void => {
                console.error(TAG, `disconnect: ${e.message}`)
              })
            })

          // DONE (big green)
          Button('DONE')
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

        // Stats 浮层（条件渲染）
        if (this.showStats) {
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
    }
    .width('100%').height('100%')
  }
}

interface ProbeResult {
  reachable: boolean
  isSideScreen: boolean
}
