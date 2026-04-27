/*
 * SideScreen wire protocol — encode/decode for HarmonyOS NEXT client.
 *
 * 字节序约定（必须严格遵循，否则 Mac 端会丢包断连）：
 *   - type=0x00 视频帧 size:               BIG-endian
 *   - type=0x01 显示配置 width/height/rot: BIG-endian
 *   - type=0x02 触控 x/y/action:          LITTLE-endian
 *   - type=0x04 ping nanos:               LITTLE-endian
 *   - type=0x05 pong nanos:               LITTLE-endian (echo of ping bytes)
 *
 * 详见仓库根目录 PROTOCOL.md。
 *
 * 本文件不依赖任何 @ohos.* 包，纯 ArkTS + DataView。可在 Node 单测里跑。
 */

// ============================================================================
// 协议常量
// ============================================================================

export const TYPE_VIDEO: number = 0x00
export const TYPE_DISPLAY_CONFIG: number = 0x01
export const TYPE_TOUCH: number = 0x02
export const TYPE_PING: number = 0x04
export const TYPE_PONG: number = 0x05

export const TOUCH_ACTION_DOWN: number = 0
export const TOUCH_ACTION_MOVE: number = 1
export const TOUCH_ACTION_UP: number = 2

/** 上游 Android client 写死的最大帧大小（StreamClient.kt:290），用作分包合法性校验 */
export const MAX_FRAME_SIZE: number = 5 * 1024 * 1024

// ============================================================================
// 数据结构
// ============================================================================

export interface DisplayConfig {
  width: number
  height: number
  rotation: number
}

export interface TouchPoint {
  /** 0..1 归一化坐标（x / surface_width） */
  x: number
  /** 0..1 归一化坐标（y / surface_height） */
  y: number
}

/**
 * 流式分包器把每条完整消息回调给 handler。
 * 实现者应当尽快返回，I/O 重活放到独立线程。
 *
 * 字段都用 function-typed 属性（ArkTS arkts-no-untyped-obj-literals 要求；方法 shorthand
 * 会让对象字面量赋值通不过严格检查）。
 *
 * onVideoFrame.annexbHevc 是 ProtocolParser 内部 buffer 的 slice，handler 必须在返回前
 * 消费完毕（拷贝到 decoder 或自己持有）。
 */
export interface ProtocolHandler {
  onDisplayConfig: (config: DisplayConfig) => void
  onVideoFrame: (annexbHevc: Uint8Array) => void
  onPong: (nanos: bigint) => void
}

export class ProtocolError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'ProtocolError'
  }
}

// ============================================================================
// 流式分包器
// ============================================================================

/**
 * 累积 TCP 字节流，按 type 分派完整消息。
 * 不保证零拷贝（视频帧用 Uint8Array.slice 拷贝一次）—— v2 优化点：换成
 * ringbuffer + 视图。
 *
 * 用法：
 *   const parser = new ProtocolParser()
 *   socket.on('message', (chunk: ArrayBuffer) => {
 *     parser.feed(new Uint8Array(chunk), handler)
 *   })
 */
export class ProtocolParser {
  private buf: Uint8Array = new Uint8Array(0)

  /** 喂入新到达的字节并依次回调 handler */
  feed(chunk: Uint8Array, handler: ProtocolHandler): void {
    if (chunk.length === 0) {
      return
    }
    if (this.buf.length === 0) {
      this.buf = chunk
    } else {
      const merged = new Uint8Array(this.buf.length + chunk.length)
      merged.set(this.buf, 0)
      merged.set(chunk, this.buf.length)
      this.buf = merged
    }
    while (this.parseOne(handler)) {
      // continue
    }
  }

  /** 强制清空内部缓冲（重连时调） */
  reset(): void {
    this.buf = new Uint8Array(0)
  }

  /** 当前缓冲未消费字节数（调试用） */
  pendingBytes(): number {
    return this.buf.length
  }

  /**
   * 尝试消费缓冲头部一条完整消息。
   * @returns 消费成功返回 true，需要更多数据返回 false。
   * @throws ProtocolError 字节流错位或未知 type
   */
  private parseOne(handler: ProtocolHandler): boolean {
    if (this.buf.length < 1) {
      return false
    }
    const type = this.buf[0]

    if (type === TYPE_DISPLAY_CONFIG) {
      // 13 字节: 1 type + 3×4 BE int32
      if (this.buf.length < 13) {
        return false
      }
      const view = new DataView(this.buf.buffer, this.buf.byteOffset, 13)
      const config: DisplayConfig = {
        width: view.getInt32(1, false),
        height: view.getInt32(5, false),
        rotation: view.getInt32(9, false),
      }
      this.consume(13)
      handler.onDisplayConfig(config)
      return true
    }

    if (type === TYPE_VIDEO) {
      // 1 type + 4 BE int32 size + N bytes
      if (this.buf.length < 5) {
        return false
      }
      const sizeView = new DataView(this.buf.buffer, this.buf.byteOffset, 5)
      const size = sizeView.getInt32(1, false)  // BE
      if (size <= 0 || size > MAX_FRAME_SIZE) {
        throw new ProtocolError(
          `Invalid video frame size: ${size} (stream misaligned)`,
        )
      }
      const total = 5 + size
      if (this.buf.length < total) {
        return false
      }
      // slice 复制一份，让回调持有的 frame 与内部 buffer 解耦
      const frame = this.buf.slice(5, total)
      this.consume(total)
      handler.onVideoFrame(frame)
      return true
    }

    if (type === TYPE_PONG) {
      // 9 字节: 1 type + 8 LE int64
      if (this.buf.length < 9) {
        return false
      }
      const view = new DataView(this.buf.buffer, this.buf.byteOffset, 9)
      const nanos = view.getBigInt64(1, true)  // LE
      this.consume(9)
      handler.onPong(nanos)
      return true
    }

    throw new ProtocolError(
      `Unknown message type: 0x${type.toString(16).padStart(2, '0')} ` +
        `(stream misaligned, ${this.buf.length} bytes pending)`,
    )
  }

  private consume(n: number): void {
    if (n >= this.buf.length) {
      this.buf = new Uint8Array(0)
    } else {
      this.buf = this.buf.slice(n)
    }
  }
}

// ============================================================================
// 编码（客户端 → Mac）
// ============================================================================

/**
 * 编码 type=0x04 ping。
 * @param nanos 客户端本地单调时钟（System.now nanos / Date.now()*1e6 等），收到 pong 时计算 RTT
 */
export function encodePing(nanos: bigint): Uint8Array {
  const buf = new ArrayBuffer(9)
  const view = new DataView(buf)
  view.setUint8(0, TYPE_PING)
  view.setBigInt64(1, nanos, true)  // LE
  return new Uint8Array(buf)
}

/**
 * 编码 type=0x02 触控（v1 不发触控；保留供 v2 用）。
 * @param pointers 1 或 2 个触点；超过 2 点的会截断
 * @param action TOUCH_ACTION_DOWN / MOVE / UP
 */
export function encodeTouch(
  pointers: TouchPoint[],
  action: number,
): Uint8Array {
  if (pointers.length === 0) {
    throw new ProtocolError('encodeTouch requires at least one pointer')
  }
  const n = Math.min(pointers.length, 2)
  const size = 2 + n * 8 + 4  // type + count + n×(x,y) + action
  const buf = new ArrayBuffer(size)
  const view = new DataView(buf)
  view.setUint8(0, TYPE_TOUCH)
  view.setUint8(1, n)
  let offset = 2
  for (let i = 0; i < n; i++) {
    view.setFloat32(offset, pointers[i].x, true)      // LE
    view.setFloat32(offset + 4, pointers[i].y, true)  // LE
    offset += 8
  }
  view.setInt32(offset, action, true)  // LE
  return new Uint8Array(buf)
}

// ============================================================================
// 自检 fixture（实测可用 Mac 抓包对照验证；这里只放期望值）
// ============================================================================
//
// type=0x01 (1920×1200×0°) 应当生成 13 字节:
//   01 00 00 07 80   00 00 04 b0   00 00 00 00
//   ▲  ▲width=0x780  ▲height=0x4b0 ▲rotation=0    （全部 BE int32）
//
// type=0x04 ping(nanos=0x0123456789ABCDEF) 应当生成 9 字节:
//   04 ef cd ab 89 67 45 23 01     （LE int64）
//
// type=0x02 touch(1 指 (0.5, 0.25), DOWN) 应当生成 14 字节:
//   02 01    00 00 00 3f    00 00 80 3e    00 00 00 00
//   │  │     ▲ x=0.5 LE     ▲ y=0.25 LE   ▲ action=DOWN LE int32
//   │  └─ pointer count
//   └─ type=0x02
