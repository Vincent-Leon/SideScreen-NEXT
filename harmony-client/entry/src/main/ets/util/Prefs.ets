/*
 * Prefs — 持久化最近一次连接信息（host / port）+ UI 偏好（show stats / opacity / 设置按钮位置）。
 *
 * 文件存到 App 私有目录 /data/storage/el2/database/preferences/sidescreen-next.xml。
 * 不要存敏感信息。@ohos.data.preferences 是 key/value 平台 API。
 */

import { preferences } from '@kit.ArkData'
import { common } from '@kit.AbilityKit'

const STORE_NAME: string = 'sidescreen-next'
const KEY_HOST: string = 'host'
const KEY_PORT: string = 'port'
const KEY_SHOW_TRANSPORT: string = 'showTransport'
const KEY_SHOW_FPS: string = 'showFps'
const KEY_SHOW_BITRATE: string = 'showBitrate'
const KEY_SHOW_RESOLUTION: string = 'showResolution'
const KEY_SHOW_RTT: string = 'showRtt'
const KEY_SHOW_BATTERY: string = 'showBattery'
const KEY_OPACITY: string = 'overlayOpacity'
const KEY_BTN_POS: string = 'settingsBtnPos'
const KEY_WIFI_DISABLED: string = 'wifiDisabled'
const KEY_AUTO_RECONNECT: string = 'autoReconnect'
const KEY_PRESETS: string = 'presets'  // JSON string of Preset[]
const TAG: string = '[Prefs]'

export interface SavedConnection {
  host: string
  port: number
}

export interface SavedUiPrefs {
  /** 浮层每一列单独开关。全 false 时浮层完全隐藏。 */
  showTransport: boolean
  showFps: boolean
  showBitrate: boolean
  showResolution: boolean
  showRtt: boolean
  showBattery: boolean
  /** 浮层透明度 (0.2 - 1.0)，0.8 = 80% */
  overlayOpacity: number
  /** 设置按钮位置：0=BR, 1=BL, 2=TR, 3=TL, 4=TC, 5=BC, 6=CL, 7=CR */
  settingsBtnPos: number
  /** 仅 USB 模式：跳过 mDNS 扫描、saved presets，只走 127.0.0.1 USB 隧道。 */
  wifiDisabled: boolean
  /** 自动重连：断线后自动尝试恢复（USB-only 模式 = USB probe 循环；
   *  Wi-Fi 模式 = [3s, 5s, 8s] 重连 ladder）。关掉 = 断了就停在断开态。 */
  autoReconnect: boolean
}

export interface Preset {
  host: string
  port: number
  /** Optional human label (Wi-Fi SSID, room name, etc.) */
  label?: string
}

export class Prefs {
  private static store: preferences.Preferences | null = null

  static async init(ctx: common.UIAbilityContext): Promise<void> {
    if (Prefs.store != null) return
    try {
      Prefs.store = await preferences.getPreferences(ctx, STORE_NAME)
    } catch (e) {
      console.warn(TAG, `init failed: ${(e as Error).message}`)
    }
  }

  static async load(): Promise<SavedConnection> {
    const fallback: SavedConnection = { host: '', port: 8888 }
    if (Prefs.store == null) return fallback
    try {
      const host = await Prefs.store.get(KEY_HOST, '') as string
      const port = await Prefs.store.get(KEY_PORT, 8888) as number
      return { host, port }
    } catch (e) {
      console.warn(TAG, `load failed: ${(e as Error).message}`)
      return fallback
    }
  }

  static async save(cfg: SavedConnection): Promise<void> {
    if (Prefs.store == null) return
    try {
      await Prefs.store.put(KEY_HOST, cfg.host)
      await Prefs.store.put(KEY_PORT, cfg.port)
      await Prefs.store.flush()
    } catch (e) {
      console.warn(TAG, `save failed: ${(e as Error).message}`)
    }
  }

  static async loadUi(): Promise<SavedUiPrefs> {
    const fallback: SavedUiPrefs = {
      showTransport: true, showFps: true, showBitrate: true,
      showResolution: true, showRtt: true, showBattery: true,
      overlayOpacity: 0.8, settingsBtnPos: 0,
      wifiDisabled: false, autoReconnect: true,
    }
    if (Prefs.store == null) return fallback
    try {
      const showTransport = await Prefs.store.get(KEY_SHOW_TRANSPORT, true) as boolean
      const showFps = await Prefs.store.get(KEY_SHOW_FPS, true) as boolean
      const showBitrate = await Prefs.store.get(KEY_SHOW_BITRATE, true) as boolean
      const showResolution = await Prefs.store.get(KEY_SHOW_RESOLUTION, true) as boolean
      const showRtt = await Prefs.store.get(KEY_SHOW_RTT, true) as boolean
      const showBattery = await Prefs.store.get(KEY_SHOW_BATTERY, true) as boolean
      const overlayOpacity = await Prefs.store.get(KEY_OPACITY, 0.8) as number
      const settingsBtnPos = await Prefs.store.get(KEY_BTN_POS, 0) as number
      const wifiDisabled = await Prefs.store.get(KEY_WIFI_DISABLED, false) as boolean
      const autoReconnect = await Prefs.store.get(KEY_AUTO_RECONNECT, true) as boolean
      return {
        showTransport, showFps, showBitrate, showResolution, showRtt, showBattery,
        overlayOpacity, settingsBtnPos,
        wifiDisabled, autoReconnect,
      }
    } catch (e) {
      console.warn(TAG, `loadUi failed: ${(e as Error).message}`)
      return fallback
    }
  }

  static async saveUi(cfg: SavedUiPrefs): Promise<void> {
    if (Prefs.store == null) return
    try {
      await Prefs.store.put(KEY_SHOW_TRANSPORT, cfg.showTransport)
      await Prefs.store.put(KEY_SHOW_FPS, cfg.showFps)
      await Prefs.store.put(KEY_SHOW_BITRATE, cfg.showBitrate)
      await Prefs.store.put(KEY_SHOW_RESOLUTION, cfg.showResolution)
      await Prefs.store.put(KEY_SHOW_RTT, cfg.showRtt)
      await Prefs.store.put(KEY_SHOW_BATTERY, cfg.showBattery)
      await Prefs.store.put(KEY_OPACITY, cfg.overlayOpacity)
      await Prefs.store.put(KEY_BTN_POS, cfg.settingsBtnPos)
      await Prefs.store.put(KEY_WIFI_DISABLED, cfg.wifiDisabled)
      await Prefs.store.put(KEY_AUTO_RECONNECT, cfg.autoReconnect)
      await Prefs.store.flush()
    } catch (e) {
      console.warn(TAG, `saveUi failed: ${(e as Error).message}`)
    }
  }

  /** 读所有预设。无 / 解析失败 → 空数组。 */
  static async loadPresets(): Promise<Preset[]> {
    if (Prefs.store == null) return []
    try {
      const json = await Prefs.store.get(KEY_PRESETS, '[]') as string
      const arr = JSON.parse(json) as Preset[]
      return Array.isArray(arr) ? arr : []
    } catch (e) {
      console.warn(TAG, `loadPresets: ${(e as Error).message}`)
      return []
    }
  }

  static async savePresets(presets: Preset[]): Promise<void> {
    if (Prefs.store == null) return
    try {
      await Prefs.store.put(KEY_PRESETS, JSON.stringify(presets))
      await Prefs.store.flush()
    } catch (e) {
      console.warn(TAG, `savePresets: ${(e as Error).message}`)
    }
  }

  /** 把 host:port upsert 到列表（已存在的 host:port 忽略）。返回新列表。 */
  static async upsertPreset(p: Preset): Promise<Preset[]> {
    const list = await Prefs.loadPresets()
    const exists = list.some((x: Preset): boolean => x.host === p.host && x.port === p.port)
    if (exists) return list
    list.push(p)
    await Prefs.savePresets(list)
    return list
  }

  static async removePreset(host: string, port: number): Promise<Preset[]> {
    const list = await Prefs.loadPresets()
    const filtered = list.filter((x: Preset): boolean => !(x.host === host && x.port === port))
    if (filtered.length !== list.length) {
      await Prefs.savePresets(filtered)
    }
    return filtered
  }
}
