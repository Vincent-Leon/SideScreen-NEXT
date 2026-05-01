/*
 * mDNS 发现 — 在同 LAN 内扫描 Mac 端发布的 _sidescreen._tcp 服务。
 *
 * Mac 端通过 NetService.publish() 广播；本工具用 @ohos.net.mdns 收听 → 收到 serviceFound
 * 后用 resolveLocalService 拿到真实 IP。timeoutMs 内停止扫描并返回结果。
 */

import { mdns } from '@kit.NetworkKit'
import { common } from '@kit.AbilityKit'

const TAG: string = '[Mdns]'
const SERVICE_TYPE: string = '_sidescreen._tcp'

export interface DiscoveredService {
  host: string
  port: number
  serviceName: string
}

export async function discoverSideScreen(
  ctx: common.UIAbilityContext,
  timeoutMs: number = 3000,
): Promise<DiscoveredService[]> {
  const found: DiscoveredService[] = []
  const seen: Set<string> = new Set()

  return new Promise<DiscoveredService[]>((
    resolve: (v: DiscoveredService[]) => void,
  ): void => {
    let stopped = false
    let ds: mdns.DiscoveryService | null = null
    try {
      ds = mdns.createDiscoveryService(ctx, SERVICE_TYPE)
    } catch (e) {
      console.warn(TAG, `createDiscoveryService failed: ${(e as Error).message}`)
      resolve(found)
      return
    }

    const stopAndResolve = (): void => {
      if (stopped) return
      stopped = true
      try {
        ds?.stopSearchingMDNS()
      } catch (_) { /* ignore */ }
      console.info(TAG, `discovery done, found ${found.length} services`)
      resolve(found)
    }

    const recordIfNew = (host: string, port: number, name: string): void => {
      const key = `${host}:${port}`
      if (seen.has(key)) return
      seen.add(key)
      found.push({ host, port, serviceName: name })
      console.info(TAG, `found ${name} → ${host}:${port}`)
    }

    ds.on('serviceFound', (info: mdns.LocalServiceInfo): void => {
      // info.host.address 一般为空,需要 resolveLocalService 拿真实 IP
      const port = info.port ?? 0
      const directAddr = info.host?.address
      if (directAddr && directAddr.length > 0 && directAddr !== '0.0.0.0' && port > 0) {
        recordIfNew(directAddr, port, info.serviceName)
        return
      }
      mdns.resolveLocalService(ctx, info)
        .then((resolved: mdns.LocalServiceInfo): void => {
          const a = resolved.host?.address
          const p = resolved.port ?? 0
          if (a && a.length > 0 && a !== '0.0.0.0' && p > 0) {
            recordIfNew(a, p, resolved.serviceName)
          }
        })
        .catch((e: Error): void => {
          console.warn(TAG, `resolve ${info.serviceName}: ${e.message}`)
        })
    })

    try {
      ds.startSearchingMDNS()
    } catch (e) {
      console.warn(TAG, `startSearchingMDNS: ${(e as Error).message}`)
      resolve(found)
      return
    }

    setTimeout(stopAndResolve, timeoutMs)
  })
}
