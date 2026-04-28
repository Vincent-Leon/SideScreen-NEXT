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
  encodePing,
  encodeClientRotation,
} from './Protocol'

const TAG: string = '[StreamClient]'
const PING_INTERVAL_MS: number = 1000
const CONNECT_TIMEOUT_MS: number = 5000

export interface StreamClientCallbacks {
  onConnected: () => void
  onDisconnected: (reason: string) => void
  onDisplayConfig: (width: number, height: number, rotation: number) => void
  onVideoFrame: (annexbHevc: Uint8Array) => void
  onLatency: (rttMs: number) => void
  onError: (err: Error) => void
}

export class StreamClient {
  private tcp: socket.TCPSocket | null = null
  private parser: ProtocolParser = new ProtocolParser()
  private pingTimer: number = -1
  private connected: boolean = false
  /** ping nanos (字符串化) → 发送时本地 Date.now() ms，用于算 RTT */
  private outstandingPings: Map<string, number> = new Map()
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

  async connect(host: string, port: number): Promise<void> {
    if (this.tcp != null) {
      await this.disconnect()
    }
    this.parser.reset()

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
    this.cb.onDisconnected(reason)
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
