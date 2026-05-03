/*
 * StreamClient — 把 @ohos.net.socket TCPSocket 与 Protocol.ets 串起来。
 *
 * 职责：
 *   - TCP 连 Mac IP:8888，启用 TCP_NODELAY
 *   - 接收回调路由给 ProtocolParser
 *   - 1 Hz 发 ping，匹配 pong 算 RTT
 *   - 错误/断开时清理 timer 与 socket，回调上层
 *
 * 不做触控（v1 只单向显示）。
 */

import { socket } from '@kit.NetworkKit'
import { BusinessError } from '@kit.BasicServicesKit'
import {
  ProtocolParser,
  ProtocolHandler,
  DisplayConfig,
  TouchPoint,
  encodePing,
  encodeClientRotation,
  encodeTouch,
} from './Protocol'

const TAG: string = '[StreamClient]'
const PING_INTERVAL_MS: number = 1000
const CONNECT_TIMEOUT_MS: number = 5000

/** 特殊 disconnect 原因常量。Index 用 reason 来区分主动 / 服务端主动 / 异常断开。 */
export const REASON_SERVER_SHUTDOWN: string = 'server-shutdown'

export interface StreamClientCallbacks {
  onConnected: () => void
  onDisconnected: (reason: string) => void
  onDisplayConfig: (width: number, height: number, rotation: number) => void
  onVideoFrame: (annexbHevc: Uint8Array) => void
  onLatency: (rttMs: number) => void
  onError: (err: Error) => void
  /** Mac 用户主动 Stop 时触发（type=0x06）。紧接着 socket 会被服务端关掉，
   *  onDisconnected 也会触发，reason 会是 REASON_SERVER_SHUTDOWN。 */
  onServerShutdown: () => void
}

export class StreamClient {
  private tcp: socket.TCPSocket | null = null
  private parser: ProtocolParser = new ProtocolParser()
  private pingTimer: number = -1
  private connected: boolean = false
  /** ping nanos (字符串化) → 发送时本地 Date.now() ms，用于算 RTT */
  private outstandingPings: Map<string, number> = new Map()
  /** Mac 在关 socket 之前发了 type=0x06 → handleClose 知道这是有意停服 */
  private serverShutdownReceived: boolean = false
  private cb: StreamClientCallbacks

  constructor(callbacks: StreamClientCallbacks) {
    this.cb = callbacks
  }

  isConnected(): boolean {
    return this.connected
  }

  /** 通知 Mac 客户端的当前方向（0/90/180/270），Mac 收到后重建虚拟显示器。 */
  sendRotation(degrees: number): void {
    if (!this.connected || this.tcp == null) return
    const packet = encodeClientRotation(degrees)
    const sendOpts: socket.TCPSendOptions = { data: packet.buffer }
    this.tcp.send(sendOpts).catch((err: BusinessError): void => {
      console.error(TAG, `sendRotation: code=${err.code} msg=${err.message}`)
    })
  }

  /** 触控事件：归一化坐标 (0..1)，最多 2 指，action = DOWN/MOVE/UP。
   *  fire-and-forget — send 失败只记 log 不影响 UI（手指仍在划，下一帧又会发）。 */
  sendTouch(pointers: TouchPoint[], action: number): void {
    if (!this.connected || this.tcp == null) return
    if (pointers.length === 0) return
    const packet = encodeTouch(pointers, action)
    const sendOpts: socket.TCPSendOptions = { data: packet.buffer }
    this.tcp.send(sendOpts).catch((err: BusinessError): void => {
      console.warn(TAG, `sendTouch: code=${err.code} msg=${err.message}`)
    })
  }

  async connect(host: string, port: number): Promise<void> {
    if (this.tcp != null) {
      await this.disconnect()
    }
    this.parser.reset()
    this.serverShutdownReceived = false

    const tcp = socket.constructTCPSocketInstance()
    this.tcp = tcp

    // 先订阅事件再 connect，避免错过首个 type=0x01 displayConfig
    tcp.on('message', (value: socket.SocketMessageInfo): void => {
      this.handleIncoming(value.message)
    })
    tcp.on('close', (): void => {
      console.info(TAG, 'socket closed by peer')
      this.handleClose('peer closed')
    })
    tcp.on('error', (err: BusinessError): void => {
      console.error(TAG, `socket error: code=${err.code} msg=${err.message}`)
      this.cb.onError(new Error(`socket error ${err.code}: ${err.message}`))
      this.handleClose(`error: ${err.message}`)
    })

    const addr: socket.NetAddress = { address: host, port: port }
    const opts: socket.TCPConnectOptions = { address: addr, timeout: CONNECT_TIMEOUT_MS }
    try {
      await tcp.connect(opts)
    } catch (e) {
      this.tcp = null
      const err = e as BusinessError
      throw new Error(`connect failed: ${err.message ?? String(e)}`)
    }

    // 低延迟视频流必备
    const extra: socket.TCPExtraOptions = {
      TCPNoDelay: true,
      receiveBufferSize: 65536,
    }
    try {
      await tcp.setExtraOptions(extra)
    } catch (e) {
      console.warn(TAG, `setExtraOptions failed (non-fatal): ${String(e)}`)
    }

    this.connected = true
    this.startPingTimer()
    this.cb.onConnected()
  }

  async disconnect(): Promise<void> {
    this.stopPingTimer()
    const tcp = this.tcp
    this.tcp = null
    this.connected = false
    if (tcp != null) {
      try {
        tcp.off('message')
        tcp.off('close')
        tcp.off('error')
        await tcp.close()
      } catch (e) {
        // 忽略清理错误
      }
    }
    this.parser.reset()
    this.outstandingPings.clear()
  }

  private handleIncoming(buf: ArrayBuffer): void {
    const chunk = new Uint8Array(buf)
    const self = this
    const handler: ProtocolHandler = {
      onDisplayConfig: (cfg: DisplayConfig): void => {
        self.cb.onDisplayConfig(cfg.width, cfg.height, cfg.rotation)
      },
      onVideoFrame: (frame: Uint8Array): void => {
        self.cb.onVideoFrame(frame)
      },
      onPong: (nanos: bigint): void => {
        const key = nanos.toString()
        const sentMs = self.outstandingPings.get(key)
        if (sentMs !== undefined) {
          self.outstandingPings.delete(key)
          self.cb.onLatency(Date.now() - sentMs)
        }
      },
      onServerShutdown: (): void => {
        console.info(TAG, 'received server-shutdown notice (type=0x06)')
        self.serverShutdownReceived = true
        self.cb.onServerShutdown()
      },
    }
    try {
      this.parser.feed(chunk, handler)
    } catch (e) {
      const err = e as Error
      console.error(TAG, `parse error: ${err.message}`)
      this.cb.onError(err)
      this.handleClose(`parse error: ${err.message}`)
    }
  }

  private handleClose(reason: string): void {
    if (!this.connected) {
      return
    }
    this.connected = false
    this.stopPingTimer()
    // 如果先收到了 0x06，那么这次 close 必然是服务端主动停 — 用专属 reason。
    const finalReason = this.serverShutdownReceived ? REASON_SERVER_SHUTDOWN : reason
    this.cb.onDisconnected(finalReason)
  }

  private startPingTimer(): void {
    this.pingTimer = setInterval((): void => {
      this.sendPing()
    }, PING_INTERVAL_MS)
  }

  private stopPingTimer(): void {
    if (this.pingTimer >= 0) {
      clearInterval(this.pingTimer)
      this.pingTimer = -1
    }
  }

  private sendPing(): void {
    if (!this.connected || this.tcp == null) {
      return
    }
    const sentMs = Date.now()
    // 用 Date.now() ms × 1e6 当作 nanos 标识 — 跟 Mac 的 System.uptimeNanoseconds
    // 不是同一时钟，但只用作 ping/pong 的 echo 匹配，无需对齐。
    const nanos: bigint = BigInt(sentMs) * 1000000n
    this.outstandingPings.set(nanos.toString(), sentMs)

    const packet = encodePing(nanos)
    const sendOpts: socket.TCPSendOptions = { data: packet.buffer }
    this.tcp.send(sendOpts).catch((err: BusinessError): void => {
      console.error(TAG, `ping send error: code=${err.code} msg=${err.message}`)
      // socket 已断 → 停 ping timer + 触发 disconnect 流程，避免每秒 spam 错误
      this.handleClose(`ping send: ${err.message ?? 'socket dead'}`)
    })
  }
}
