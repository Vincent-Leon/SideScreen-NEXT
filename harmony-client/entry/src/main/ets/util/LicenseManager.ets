/*
 * LicenseManager — Pro 权益管理（一次性内购解锁自动重连 + 自动旋转）
 *
 * 商业模式：App 应用商店免费下载，核心副屏 / 触控功能完整可用；自动重连 + 自动旋转
 * 两个便利特性 gate 在 IAP 之后（一次性买断终身解锁）。开源用户从源码 build 出的
 * 版本同样走 IAP 流程——AGC IAP API 在未登录或非应用商店来源时会失败，所以源码 build
 * 出来跑也是 free 体验，跟应用商店免费版一致；没有 "藏私货" 行为。
 *
 * 实现说明：
 *   - 用 @kit.IAPKit 的 NONCONSUMABLE 商品类型（一次买断终身权益）
 *   - 启动时调 queryPurchases(CURRENT_ENTITLEMENT) 拿当前权益，本地缓存到 Prefs
 *   - 用户购买走 createPurchase；成功后立即触发 finishPurchase 确认发货
 *   - 离线时降级到本地缓存（已付费用户出门也能用）
 *   - 不做 client-side JWS 验签——IAP API 自身签名机制 + 服务端兜底已足够；
 *     做 client-side 验签需要 AGC 公钥 + 复杂 RSA 实现，对 ¥6/$2 价位的 SKU 不值
 *
 * AGC 后台配置：在 AppGallery Connect ▸ 商品管理 ▸ 创建一个非消耗型商品，商品 ID
 * 与 PRO_PRODUCT_ID 一致（也可以改 PRO_PRODUCT_ID 匹配后台已有商品 ID）。
 */

import { iap } from '@kit.IAPKit'
import { common } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { buffer } from '@kit.ArkTS'
import { Prefs } from './Prefs'

/** JWS payload 包含的关键字段（IAP 服务端发回，已签名）。
 *  完整字段集见 PurchaseOrderPayload 文档：
 *  https://developer.huawei.com/consumer/cn/doc/harmonyos-references/iap-purchaseorderpayload */
interface PurchaseOrderPayload {
  productId: string
  productType: string  // "0"=consumable / "1"=non-consumable / "2"=non-renewable
  purchaseToken: string
  purchaseOrderId: string
  finishStatus?: string  // "0"=未发货 / "1"=已发货
}

/** 解 JWS payload —— 不验签（依赖 IAP Kit 端到端机制 + AGC 服务端兜底）。 */
function decodeJwsPayload(jws: string): PurchaseOrderPayload | null {
  try {
    const parts = jws.split('.')
    if (parts.length !== 3) return null
    let b64 = parts[1].replace(/-/g, '+').replace(/_/g, '/')
    const pad = b64.length % 4
    if (pad === 2) b64 += '=='
    else if (pad === 3) b64 += '='
    else if (pad === 1) return null
    const buf = buffer.from(b64, 'base64')
    const jsonStr = buf.toString('utf-8')
    return JSON.parse(jsonStr) as PurchaseOrderPayload
  } catch (_) {
    return null
  }
}

const TAG: string = '[License]'

/** AGC 商品 ID — 与后台配置一致 */
export const PRO_PRODUCT_ID: string = 'tech.visionflow.sidescreennext.pro_unlock'

/** 商品信息（从 AGC 拉，用于在 UI 显示价格 / 名称） */
export interface ProProductInfo {
  productId: string
  productName: string
  /** 已格式化好的本地化价格字符串，如 "¥6.00" */
  price: string
}

/** 购买流程结果 */
export enum PurchaseResultKind {
  Success = 'success',
  AlreadyOwned = 'already-owned',
  UserCanceled = 'user-canceled',
  NetworkError = 'network',
  NotLoggedIn = 'not-logged-in',
  NotSupported = 'not-supported',
  Unknown = 'unknown',
}

export interface PurchaseResult {
  kind: PurchaseResultKind
  message: string
}

/**
 * 单例式静态类——Index 页和 Settings modal 都直接调静态方法，
 * 通过 onProChange 回调通知 UI 刷新。
 */
export class LicenseManager {
  private static cachedPro: boolean = false
  private static syncedOnce: boolean = false
  private static listeners: Array<(isPro: boolean) => void> = []

  /** 当前是否已购买 Pro 权益（基于 cached + AGC 同步） */
  static isPro(): boolean {
    return LicenseManager.cachedPro
  }

  /** 启动时是否至少同步过一次（用于决定 UI 显示「加载中」还是「已确认」） */
  static hasSynced(): boolean {
    return LicenseManager.syncedOnce
  }

  /** 注册 Pro 状态变化监听 */
  static onChange(cb: (isPro: boolean) => void): void {
    LicenseManager.listeners.push(cb)
  }

  static offChange(cb: (isPro: boolean) => void): void {
    const idx = LicenseManager.listeners.indexOf(cb)
    if (idx >= 0) LicenseManager.listeners.splice(idx, 1)
  }

  /** 从本地缓存初始化（应用启动时调；同步） */
  static initFromCache(cached: boolean): void {
    LicenseManager.cachedPro = cached
    LicenseManager.fireChange()
  }

  /**
   * 从 AGC 同步当前权益状态。
   * 启动 + 用户点「恢复购买」时调。失败时不改 cachedPro，让用户继续按上次缓存使用。
   *
   * 实现：queryPurchases(CURRENT_ENTITLEMENT) 返回当前持有的非消耗商品。每条
   * purchaseDataList 元素是 JSON 字符串，外层有 jwsPurchaseOrder（JWS 编码）。
   * 解 JWS payload 拿 productId，匹配本应用的 PRO_PRODUCT_ID 即视为已购。
   */
  static async syncFromAGC(context: common.UIAbilityContext): Promise<boolean> {
    try {
      const param: iap.QueryPurchasesParameter = {
        productType: iap.ProductType.NONCONSUMABLE,
        queryType: iap.PurchaseQueryType.CURRENT_ENTITLEMENT,
      }
      const res: iap.QueryPurchaseResult = await iap.queryPurchases(context, param)
      const list: string[] = res.purchaseDataList ?? []
      let owned = false
      for (let i = 0; i < list.length; i++) {
        try {
          const wrap: Record<string, string> = JSON.parse(list[i]) as Record<string, string>
          const jws = wrap.jwsPurchaseOrder
          if (!jws) continue
          const payload = decodeJwsPayload(jws)
          if (payload && payload.productId === PRO_PRODUCT_ID) {
            owned = true
            break
          }
        } catch (_) { /* 单条解析失败不影响整体 */ }
      }
      LicenseManager.syncedOnce = true
      LicenseManager.cachedPro = owned
      LicenseManager.fireChange()
      Prefs.setProCached(owned).catch((e: Error): void =>
        console.warn(TAG, `persist pro cache: ${e.message}`))
      console.info(TAG, `synced from AGC: pro=${owned}`)
      return owned
    } catch (e) {
      const err = e as BusinessError
      console.warn(TAG, `syncFromAGC failed: code=${err.code} msg=${err.message}`)
      LicenseManager.syncedOnce = true
      return LicenseManager.cachedPro
    }
  }

  /**
   * 拉取商品信息（价格 / 名称）用于 UI 显示。失败返回 null。
   */
  static async queryProductInfo(context: common.UIAbilityContext): Promise<ProProductInfo | null> {
    try {
      const param: iap.QueryProductsParameter = {
        productType: iap.ProductType.NONCONSUMABLE,
        productIds: [PRO_PRODUCT_ID],
      }
      const products: Array<iap.Product> = await iap.queryProducts(context, param)
      if (!products || products.length === 0) return null
      const p: iap.Product = products[0]
      return {
        productId: PRO_PRODUCT_ID,
        productName: p.name,
        price: p.localPrice ?? p.price ?? '',
      } as ProProductInfo
    } catch (e) {
      const err = e as BusinessError
      console.warn(TAG, `queryProductInfo failed: code=${err.code} msg=${err.message}`)
      return null
    }
  }

  /**
   * 启动一次性内购流程。createPurchase 返回 CreatePurchaseResult（含单条 purchaseData 字符串）。
   * 解 JWS 拿 purchaseToken / purchaseOrderId 调 finishPurchase 确认发货，再 syncFromAGC 写缓存。
   */
  static async startPurchase(context: common.UIAbilityContext): Promise<PurchaseResult> {
    try {
      const param: iap.PurchaseParameter = {
        productType: iap.ProductType.NONCONSUMABLE,
        productId: PRO_PRODUCT_ID,
      }
      const result: iap.CreatePurchaseResult = await iap.createPurchase(context, param)
      const purchaseData = result.purchaseData
      if (purchaseData) {
        try {
          const wrap: Record<string, string> = JSON.parse(purchaseData) as Record<string, string>
          const jws = wrap.jwsPurchaseOrder
          if (jws) {
            const payload = decodeJwsPayload(jws)
            if (payload && payload.purchaseToken && payload.purchaseOrderId &&
                payload.finishStatus !== '1') {
              const finishParam: iap.FinishPurchaseParameter = {
                productType: Number(payload.productType),
                purchaseToken: payload.purchaseToken,
                purchaseOrderId: payload.purchaseOrderId,
              }
              try {
                await iap.finishPurchase(context, finishParam)
              } catch (e) {
                console.warn(TAG, `finishPurchase: ${(e as BusinessError).message}`)
              }
            }
          }
        } catch (e) {
          console.warn(TAG, `parse purchaseData: ${(e as Error).message}`)
        }
      }
      // 拿权威状态（写本地缓存 + 通知 listener）
      const owned = await LicenseManager.syncFromAGC(context)
      return {
        kind: owned ? PurchaseResultKind.Success : PurchaseResultKind.Unknown,
        message: owned ? 'Pro unlocked' : 'Purchase completed but entitlement not yet visible',
      } as PurchaseResult
    } catch (e) {
      const err = e as BusinessError
      console.error(TAG, `startPurchase failed: code=${err.code} msg=${err.message}`)
      return LicenseManager.classifyError(err)
    }
  }

  private static classifyError(err: BusinessError): PurchaseResult {
    // AGC IAP 错误码参考：https://developer.huawei.com/consumer/cn/doc/iap-errorcodes-V5
    const code = err.code
    let kind = PurchaseResultKind.Unknown
    if (code === 60050 || code === 60051) {
      kind = PurchaseResultKind.NotLoggedIn
    } else if (code === 60005 || code === 60055) {
      kind = PurchaseResultKind.NetworkError
    } else if (code === 60000) {
      kind = PurchaseResultKind.UserCanceled
    } else if (code === 60020) {
      kind = PurchaseResultKind.AlreadyOwned
    } else if (code === 60054) {
      kind = PurchaseResultKind.NotSupported
    }
    return { kind, message: `${err.code}: ${err.message}` } as PurchaseResult
  }

  private static fireChange(): void {
    const isPro = LicenseManager.cachedPro
    for (let i = 0; i < LicenseManager.listeners.length; i++) {
      try {
        LicenseManager.listeners[i](isPro)
      } catch (_) { /* listener 异常不影响 */ }
    }
  }
}
