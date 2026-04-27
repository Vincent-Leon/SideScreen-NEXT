/*
 * 主页面 — 未连接时显示连接表单；连接后切到 XComponent 全屏视频 + 浮层状态。
 *
 * 视频解码链路：
 *   onVideoFrame → nativePush(uint8) → C++ 排队 → onNeedInputBuffer → PushInputBuffer
 *   → MediaCodec 硬解 → onNewOutputBuffer → RenderOutputBuffer (zero-copy 到 surface)
 */

import { StreamClient, StreamClientCallbacks } from '../net/StreamClient'
import { nativeStart, nativePush, nativeStop, nativeIsReady } from 'libentry.so'

const TAG: string = '[Index]'

@Entry
@Component
struct Index {
  @State host: string = ''
  @State port: number = 8888

  @State connecting: boolean = false
  @State connected: boolean = false
  @State status: string = '未连接'

  @State displayInfo: string = '—'
  @State streamWidth: number = 0
  @State streamHeight: number = 0
  @State rttMs: number = 0
  @State frameCount: number = 0
  @State totalBytes: number = 0
  @State lastError: string = ''

  @State surfaceLoaded: boolean = false
  @State decoderRunning: boolean = false

  private client: StreamClient | null = null

  aboutToDisappear(): void {
    if (this.decoderRunning) {
      nativeStop()
      this.decoderRunning = false
    }
    if (this.client != null) {
      this.client.disconnect().catch((_: Error): void => {})
      this.client = null
    }
  }

  private buildCallbacks(): StreamClientCallbacks {
    return {
      onConnected: (): void => {
        this.connecting = false
        this.connected = true
        this.status = '已连接,等待 display config…'
      },
      onDisconnected: (reason: string): void => {
        this.connecting = false
        this.connected = false
        this.status = `已断开: ${reason}`
        if (this.decoderRunning) {
          nativeStop()
          this.decoderRunning = false
        }
        this.streamWidth = 0
        this.streamHeight = 0
      },
      onDisplayConfig: (w: number, h: number, rot: number): void => {
        this.displayInfo = `${w} × ${h} @ ${rot}°`
        this.streamWidth = w
        this.streamHeight = h
        this.status = '推流中'
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

  /** 当 surface 就绪 + display config 已知时启动 decoder */
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
      this.status = '解码渲染中'
    } else {
      this.lastError = 'decoder 启动失败,看 hilog ssn_native'
    }
  }

  private async doConnect(): Promise<void> {
    if (this.host.length === 0) {
      this.lastError = '请输入 Mac IP'
      return
    }
    this.lastError = ''
    this.frameCount = 0
    this.totalBytes = 0
    this.rttMs = 0
    this.displayInfo = '—'
    this.streamWidth = 0
    this.streamHeight = 0
    this.connecting = true
    this.status = `连接 ${this.host}:${this.port}…`

    this.client = new StreamClient(this.buildCallbacks())
    try {
      await this.client.connect(this.host, this.port)
    } catch (e) {
      const err = e as Error
      this.connecting = false
      this.connected = false
      this.status = '连接失败'
      this.lastError = err.message
      this.client = null
    }
  }

  private async doDisconnect(): Promise<void> {
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
    this.status = '已断开'
  }

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      // ============= 背景层 =============
      if (this.connected && this.streamWidth > 0 && this.streamHeight > 0) {
        // XComponent surface — 解码后的视频帧 zero-copy 渲染到这里
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
        // 连接表单
        Column({ space: 16 }) {
          Text('SideScreen-NEXT')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .margin({ bottom: 8 })

          Row({ space: 8 }) {
            TextInput({ placeholder: 'Mac IP (例: 192.168.1.5)', text: this.host })
              .layoutWeight(2)
              .enabled(!this.connecting)
              .onChange((v: string): void => {
                this.host = v.trim()
              })
            TextInput({ placeholder: 'port', text: this.port.toString() })
              .layoutWeight(1)
              .type(InputType.Number)
              .enabled(!this.connecting)
              .onChange((v: string): void => {
                const n = parseInt(v)
                this.port = isNaN(n) ? 8888 : n
              })
          }
          .width('100%')

          Button(this.connecting ? '连接中…' : '连接')
            .width('100%')
            .height(44)
            .enabled(!this.connecting)
            .backgroundColor('#1976D2')
            .onClick((): void => {
              this.doConnect().catch((e: Error): void => {
                console.error(TAG, `connect: ${e.message}`)
              })
            })

          Divider()

          Column() {
            Row() {
              Text('状态').fontSize(14).width(80).fontColor('#666666')
              Text(this.status).fontSize(14).fontColor('#222222').layoutWeight(1)
            }.width('100%').padding({ top: 4, bottom: 4 })

            if (this.lastError.length > 0) {
              Row() {
                Text('错误').fontSize(14).width(80).fontColor('#cc0000')
                Text(this.lastError).fontSize(14).fontColor('#cc0000').layoutWeight(1)
              }.width('100%').padding({ top: 4, bottom: 4 })
            }
          }
          .width('100%')
        }
        .padding(20)
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Start)
      }

      // ============= 浮层（仅连接后）=============
      if (this.connected) {
        Column({ space: 4 }) {
          Text(this.status)
            .fontSize(12).fontColor('#FFFFFF')
          Text(`${this.displayInfo}`)
            .fontSize(12).fontColor('#FFFFFF')
          Text(`RTT ${this.rttMs > 0 ? this.rttMs + ' ms' : '—'}`)
            .fontSize(12).fontColor('#FFFFFF')
          Text(`${this.frameCount} f · ${(this.totalBytes / 1024 / 1024).toFixed(1)} MB`)
            .fontSize(12).fontColor('#FFFFFF')
          Button('断开')
            .fontSize(12)
            .height(28)
            .backgroundColor('#cc4444')
            .onClick((): void => {
              this.doDisconnect().catch((e: Error): void => {
                console.error(TAG, `disconnect: ${e.message}`)
              })
            })
        }
        .padding(8)
        .backgroundColor('#80000000')
        .borderRadius(6)
        .margin({ top: 16, right: 16 })
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .height('100%')
  }
}
