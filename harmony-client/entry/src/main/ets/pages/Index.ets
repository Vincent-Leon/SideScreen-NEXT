/*
 * 调试 UI — 最小输入框 + 状态监视器，用于 C3 验证 TCP/协议在 MatePad 真机上跑通。
 * 还没接 OH_VideoDecoder（C4 才做），所以视频帧只统计字节数不解码。
 */

import { StreamClient, StreamClientCallbacks } from '../net/StreamClient'

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
  @State rttMs: number = 0
  @State frameCount: number = 0
  @State totalBytes: number = 0
  @State lastError: string = ''

  private client: StreamClient | null = null

  aboutToDisappear(): void {
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
      },
      onDisplayConfig: (w: number, h: number, rot: number): void => {
        this.displayInfo = `${w} × ${h} @ ${rot}°`
        this.status = `推流中`
      },
      onVideoFrame: (frame: Uint8Array): void => {
        this.frameCount = this.frameCount + 1
        this.totalBytes = this.totalBytes + frame.length
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
    if (this.client != null) {
      await this.client.disconnect()
      this.client = null
    }
    this.connected = false
    this.connecting = false
    this.status = '已断开'
  }

  build() {
    Column({ space: 16 }) {
      Text('SideScreen-NEXT')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .margin({ bottom: 8 })

      Row({ space: 8 }) {
        TextInput({ placeholder: 'Mac IP (例: 192.168.1.5)', text: this.host })
          .layoutWeight(2)
          .enabled(!this.connected && !this.connecting)
          .onChange((v: string): void => {
            this.host = v.trim()
          })
        TextInput({ placeholder: 'port', text: this.port.toString() })
          .layoutWeight(1)
          .type(InputType.Number)
          .enabled(!this.connected && !this.connecting)
          .onChange((v: string): void => {
            const n = parseInt(v)
            this.port = isNaN(n) ? 8888 : n
          })
      }
      .width('100%')

      Button(this.connected ? '断开' : (this.connecting ? '连接中…' : '连接'))
        .width('100%')
        .height(44)
        .enabled(!this.connecting)
        .backgroundColor(this.connected ? '#cc4444' : '#1976D2')
        .onClick((): void => {
          if (this.connected) {
            this.doDisconnect().catch((e: Error): void => {
              console.error(TAG, `disconnect: ${e.message}`)
            })
          } else {
            this.doConnect().catch((e: Error): void => {
              console.error(TAG, `connect: ${e.message}`)
            })
          }
        })

      Divider()

      Column() {
        Row() {
          Text('状态').fontSize(14).width(80).fontColor('#666666')
          Text(this.status).fontSize(14).fontColor('#222222').layoutWeight(1)
        }.width('100%').padding({ top: 4, bottom: 4 })

        Row() {
          Text('Display').fontSize(14).width(80).fontColor('#666666')
          Text(this.displayInfo).fontSize(14).fontColor('#222222').layoutWeight(1)
        }.width('100%').padding({ top: 4, bottom: 4 })

        Row() {
          Text('RTT').fontSize(14).width(80).fontColor('#666666')
          Text(this.rttMs > 0 ? `${this.rttMs} ms` : '—')
            .fontSize(14).fontColor('#222222').layoutWeight(1)
        }.width('100%').padding({ top: 4, bottom: 4 })

        Row() {
          Text('帧数').fontSize(14).width(80).fontColor('#666666')
          Text(this.frameCount.toString())
            .fontSize(14).fontColor('#222222').layoutWeight(1)
        }.width('100%').padding({ top: 4, bottom: 4 })

        Row() {
          Text('累计').fontSize(14).width(80).fontColor('#666666')
          Text(`${(this.totalBytes / 1024 / 1024).toFixed(2)} MB`)
            .fontSize(14).fontColor('#222222').layoutWeight(1)
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
}
