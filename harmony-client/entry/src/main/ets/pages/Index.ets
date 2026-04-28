/*
 * 主页面 — UI 风格仿照 Side Screen Android APK：
 *   未连接：纯黑底 + 居中半透明黑色圆角卡片 + 大蓝色 Connect 按钮 + Advanced 折叠 host/port
 *   连接后：全屏 XComponent + 顶部右半透明圆角浮层（4 列：FPS/BITRATE/RESOLUTION/RTT）
 *
 * 视频解码链路：
 *   onVideoFrame → nativePush(uint8) → C++ 排队 → onNeedInputBuffer → PushInputBuffer
 *   → MediaCodec 硬解 → onNewOutputBuffer → RenderOutputBuffer (zero-copy 到 surface)
 *
 * v1 增强（C5）：
 *   - 历史 host/port 持久化 (Prefs)，未存过时默认 127.0.0.1（USB hdc rport 模式）
 *   - 断线自动重连：3s,5s,8s 三次后退，三次失败后停止
 *   - stats 浮层：fps + Mbps + 分辨率 + RTT 每秒更新
 */

import { common } from '@kit.AbilityKit'
import { batteryInfo } from '@kit.BasicServicesKit'
import { StreamClient, StreamClientCallbacks } from '../net/StreamClient'
import { Prefs, SavedConnection } from '../util/Prefs'
import { nativeStart, nativePush, nativeStop, nativeIsReady } from 'libentry.so'

const TAG: string = '[Index]'
const RECONNECT_DELAYS_MS: number[] = [3000, 5000, 8000]

// 配色（与 Side Screen Android APK 对齐）
const COLOR_BG: string = '#000000'
const COLOR_CARD: string = '#E6000000'
const COLOR_OVERLAY: string = '#CC000000'
const COLOR_PRIMARY: string = '#007AFF'
const COLOR_TEXT: string = '#FFFFFF'
const COLOR_SUBTEXT: string = '#999999'
const COLOR_HINT: string = '#AAAAAA'
const COLOR_DIM: string = '#888888'
const COLOR_STATS_LABEL: string = '#88FFFFFF'
const COLOR_FPS: string = '#4CAF50'
const COLOR_BITRATE: string = '#2196F3'
const COLOR_RES: string = '#FF9800'
const COLOR_RTT: string = '#E91E63'
const COLOR_BAT: string = '#9C27B0'        // 紫色 — 跟其他几个 stats 颜色互不重复
const COLOR_BAT_LOW: string = '#FF453A'    // 低电量阈值警示
const COLOR_BAT_CHG: string = '#4CAF50'    // 充电中
const COLOR_ERR: string = '#FF453A'

interface StatColumnParams {
  label: string
  value: string
  color: string
}

@Entry
@Component
struct Index {
  @State host: string = '127.0.0.1'
  @State port: number = 8888
  @State advancedExpanded: boolean = false

  @State connecting: boolean = false
  @State connected: boolean = false
  @State status: string = 'Ready to connect'

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

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext
    Prefs.init(ctx)
      .then((): Promise<SavedConnection> => Prefs.load())
      .then((cfg: SavedConnection): void => {
        if (cfg.host.length > 0) this.host = cfg.host
        if (cfg.port > 0) this.port = cfg.port
        console.info(TAG, `restored host=${cfg.host} port=${cfg.port}`)
      })
      .catch((e: Error): void => {
        console.warn(TAG, `prefs init/load failed: ${e.message}`)
      })
    this.refreshBattery()
    // 每 60s 刷新一次电量（@ohos.batteryInfo 是同步 getter，开销很小）
    this.batteryTimer = setInterval((): void => {
      this.refreshBattery()
    }, 60000)
  }

  private refreshBattery(): void {
    try {
      this.batteryLevel = batteryInfo.batterySOC
      this.batteryCharging =
        batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.ENABLE
    } catch (e) {
      console.warn(TAG, `battery read: ${(e as Error).message}`)
    }
  }

  aboutToDisappear(): void {
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
        Prefs.save({ host: this.host, port: this.port } as SavedConnection)
          .catch((e: Error): void => console.warn(TAG, `prefs.save: ${e.message}`))
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
        } else {
          this.status = `Disconnected: ${reason}`
          this.scheduleReconnect()
        }
      },
      onDisplayConfig: (w: number, h: number, _rot: number): void => {
        this.streamWidth = w
        this.streamHeight = h
        this.status = 'Streaming'
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
      console.info(TAG, 'tryStartDecoder: surface not ready yet')
      return
    }
    const ok = nativeStart(this.streamWidth, this.streamHeight)
    console.info(TAG, `nativeStart(${this.streamWidth}, ${this.streamHeight}) → ${ok}`)
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
  }

  private scheduleReconnect(): void {
    if (this.reconnectAttempts >= RECONNECT_DELAYS_MS.length) {
      this.status = `Failed after ${RECONNECT_DELAYS_MS.length} retries`
      this.reconnectAttempts = 0
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
  // UI 子组件
  // ============================================================================

  /** 4 列浮层中的一列：上 label，下数值 */
  @Builder
  StatColumn($$: StatColumnParams) {
    Column() {
      Text($$.label)
        .fontSize(10)
        .fontColor(COLOR_STATS_LABEL)
        .letterSpacing(0.5)
      Text($$.value)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($$.color)
    }
    .alignItems(HorizontalAlign.Start)
    .margin({ right: 16 })
  }

  /** Connection card 内的输入行 */
  @Builder
  AdvancedInput() {
    Column({ space: 12 }) {
      TextInput({ placeholder: 'Host', text: this.host })
        .placeholderColor(COLOR_DIM)
        .fontColor(COLOR_TEXT)
        .backgroundColor('#1A1A1A')
        .borderRadius(12)
        .height(48)
        .padding({ left: 16, right: 16 })
        .enabled(!this.connecting)
        .onChange((v: string): void => {
          this.host = v.trim()
        })

      TextInput({ placeholder: 'Port', text: this.port.toString() })
        .type(InputType.Number)
        .placeholderColor(COLOR_DIM)
        .fontColor(COLOR_TEXT)
        .backgroundColor('#1A1A1A')
        .borderRadius(12)
        .height(48)
        .padding({ left: 16, right: 16 })
        .enabled(!this.connecting)
        .onChange((v: string): void => {
          const n = parseInt(v)
          this.port = isNaN(n) ? 8888 : n
        })
    }
    .width('100%')
  }

  // ============================================================================
  // build
  // ============================================================================

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      // 整页黑底
      Column().width('100%').height('100%').backgroundColor(COLOR_BG)

      if (this.connected && this.streamWidth > 0 && this.streamHeight > 0) {
        // ============= 视频层 =============
        XComponent({
          id: 'mainSurface',
          type: XComponentType.SURFACE,
          libraryname: 'entry',
        })
          .width('100%')
          .height('100%')
          .onLoad((): void => {
            console.info(TAG, 'XComponent onLoad — surface ready')
            this.surfaceLoaded = true
            this.tryStartDecoder()
          })
          .onDestroy((): void => {
            console.info(TAG, 'XComponent onDestroy')
            this.surfaceLoaded = false
            if (this.decoderRunning) {
              nativeStop()
              this.decoderRunning = false
            }
          })
      } else {
        // ============= 连接面板 =============
        Stack({ alignContent: Alignment.Center }) {
          Column({ space: 0 }) {
            // 图标占位（80×80 圆形蓝色，模拟 Side Screen 的 connection icon）
            Stack({ alignContent: Alignment.Center }) {
              Text('🖥️')
                .fontSize(40)
            }
            .width(80)
            .height(80)
            .borderRadius(40)
            .backgroundColor('#1A2A4A')
            .margin({ bottom: 24 })

            // 标题
            Text('Side Screen')
              .fontSize(28)
              .fontWeight(FontWeight.Bold)
              .fontColor(COLOR_TEXT)
              .margin({ bottom: 8 })

            Text('Turn your tablet into a second display')
              .fontSize(14)
              .fontColor(COLOR_SUBTEXT)
              .margin({ bottom: 28 })

            // 主连接按钮
            Button(this.connecting ? 'Connecting…' : 'Connect')
              .width('100%')
              .height(60)
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor(COLOR_TEXT)
              .backgroundColor(COLOR_PRIMARY)
              .borderRadius(20)
              .enabled(!this.connecting)
              .onClick((): void => {
                this.doConnect(false).catch((e: Error): void => {
                  console.error(TAG, `connect: ${e.message}`)
                })
              })
              .margin({ bottom: 18 })

            // 状态行
            Row() {
              Circle({ width: 10, height: 10 })
                .fill(this.connecting ? COLOR_PRIMARY :
                      (this.lastError.length > 0 ? COLOR_ERR : COLOR_SUBTEXT))
                .margin({ right: 10 })
              Text(this.lastError.length > 0 ? this.lastError : this.status)
                .fontSize(13)
                .fontColor(this.lastError.length > 0 ? COLOR_ERR : COLOR_HINT)
                .layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .margin({ bottom: 8 })

            // Advanced Settings 折叠
            if (this.advancedExpanded) {
              this.AdvancedInput()
            }

            Text(this.advancedExpanded ? 'Hide Advanced' : 'Advanced Settings')
              .fontSize(13)
              .fontColor(COLOR_PRIMARY)
              .margin({ top: 8 })
              .padding(8)
              .onClick((): void => {
                this.advancedExpanded = !this.advancedExpanded
              })
          }
          .width('100%')
          .padding(36)
          .backgroundColor(COLOR_CARD)
          .borderRadius(32)
          .alignItems(HorizontalAlign.Center)
        }
        .width('100%')
        .height('100%')
        .padding({ left: 32, right: 32 })
      }

      // ============= 浮层（仅连接后）=============
      if (this.connected) {
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

          // 关闭按钮（小圆形，跟着 4 列同行）
          Button({ type: ButtonType.Circle }) {
            Text('✕').fontSize(14).fontColor(COLOR_TEXT)
          }
          .width(32)
          .height(32)
          .backgroundColor('#33FFFFFF')
          .onClick((): void => {
            this.doDisconnect().catch((e: Error): void => {
              console.error(TAG, `disconnect: ${e.message}`)
            })
          })
        }
        .padding({ top: 12, bottom: 12, left: 16, right: 12 })
        .backgroundColor(COLOR_OVERLAY)
        .borderRadius(20)
        .margin({ top: 16, right: 16 })
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
  }
}
