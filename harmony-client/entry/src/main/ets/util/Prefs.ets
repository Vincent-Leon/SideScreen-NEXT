/*
 * Prefs — 持久化最近一次连接信息（host / port）。
 *
 * 文件存到 App 私有目录 /data/storage/el2/database/preferences/sidescreen-next.xml。
 * 不要存敏感信息。@ohos.data.preferences 是 key/value 平台 API。
 */

import { preferences } from '@kit.ArkData'
import { common } from '@kit.AbilityKit'

const STORE_NAME: string = 'sidescreen-next'
const KEY_HOST: string = 'host'
const KEY_PORT: string = 'port'
const TAG: string = '[Prefs]'

export interface SavedConnection {
  host: string
  port: number
}

export class Prefs {
  private static store: preferences.Preferences | null = null

  /** 在 aboutToAppear 调一次。失败不致命（首次安装时数据库不存在）。 */
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
}
