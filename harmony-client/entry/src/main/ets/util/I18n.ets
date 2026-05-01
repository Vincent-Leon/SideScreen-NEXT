/*
 * I18n — 极简 string resource 助手。
 *
 * 静态 UI 标签直接用 $r('app.string.X') 给 Text/Button 等组件即可（ArkUI 接受 ResourceStr）。
 * 动态字符串（含参数）走 I18n.s(...)，会调 resourceManager.getStringSync 应用 %s/%d 替换。
 */

import { common } from '@kit.AbilityKit'

export class I18n {
  private static ctx: common.UIAbilityContext | null = null

  static init(ctx: common.UIAbilityContext): void {
    I18n.ctx = ctx
  }

  /** 替代 Text($r) 用于动态字符串 — 例:I18n.s($r('app.string.status_retry_in'), 1, 3, 5) */
  static s(res: Resource, ...args: Array<string | number>): string {
    if (I18n.ctx == null) return ''
    try {
      return I18n.ctx.resourceManager.getStringSync(res.id, ...args)
    } catch (e) {
      console.warn('[I18n]', `getStringSync ${res.id} failed: ${(e as Error).message}`)
      return ''
    }
  }
}
