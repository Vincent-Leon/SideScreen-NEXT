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
const KEY_SHOW_STATS: string = 'showStats'
const KEY_OPACITY: string = 'overlayOpacity'
const KEY_BTN_POS: string = 'settingsBtnPos'
const TAG: string = '[Prefs]'

export interface SavedConnection {
  host: string
  port: number
}

export interface SavedUiPrefs {
  /** 是否在视频流上显示 stats 浮层 */
  showStats: boolean
  /** 浮层透明度 (0.2 - 1.0)，0.8 = 80% */
  overlayOpacity: number
  /** 设置按钮位置：0=BR, 1=BL, 2=TR, 3=TL, 4=TC, 5=BC, 6=CL, 7=CR */
  settingsBtnPos: number
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
    const fallback: SavedUiPrefs = { showStats: true, overlayOpacity: 0.8, settingsBtnPos: 0 }
    if (Prefs.store == null) return fallback
    try {
      const showStats = await Prefs.store.get(KEY_SHOW_STATS, true) as boolean
      const overlayOpacity = await Prefs.store.get(KEY_OPACITY, 0.8) as number
      const settingsBtnPos = await Prefs.store.get(KEY_BTN_POS, 0) as number
      return { showStats, overlayOpacity, settingsBtnPos }
    } catch (e) {
      console.warn(TAG, `loadUi failed: ${(e as Error).message}`)
      return fallback
    }
  }

  static async saveUi(cfg: SavedUiPrefs): Promise<void> {
    if (Prefs.store == null) return
    try {
      await Prefs.store.put(KEY_SHOW_STATS, cfg.showStats)
      await Prefs.store.put(KEY_OPACITY, cfg.overlayOpacity)
      await Prefs.store.put(KEY_BTN_POS, cfg.settingsBtnPos)
      await Prefs.store.flush()
    } catch (e) {
      console.warn(TAG, `saveUi failed: ${(e as Error).message}`)
    }
  }
}
