package com.sidescreen.app

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.net.InetAddress
import java.util.concurrent.atomic.AtomicBoolean

/**
 * One-shot mDNS scan for `_sidescreen._tcp` services published by the Mac fork.
 *
 * Mirrors the harmony-client Bonjour discovery design:
 * - Scan window default 3s, single result callback when window closes
 * - Resolves each found service to a real IP (NsdServiceInfo.host)
 * - De-dupes by "host:port"
 *
 * Use one instance per scan — discard after `onComplete` fires.
 */
class MdnsDiscovery(
    context: Context,
) {
    companion object {
        const val SERVICE_TYPE = "_sidescreen._tcp."
        private const val TAG = "MdnsDiscovery"
        private const val DEFAULT_TIMEOUT_MS = 3000L
    }

    data class Found(
        val host: String,
        val port: Int,
        val name: String?,
    )

    private val nsd: NsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val main = Handler(Looper.getMainLooper())
    private val seen = HashSet<String>()
    private val results = mutableListOf<Found>()
    private val finished = AtomicBoolean(false)
    private var listener: NsdManager.DiscoveryListener? = null

    fun scan(
        timeoutMs: Long = DEFAULT_TIMEOUT_MS,
        onComplete: (List<Found>) -> Unit,
    ) {
        val l =
            object : NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(serviceType: String) {
                    Log.d(TAG, "Discovery started for $serviceType")
                }

                override fun onDiscoveryStopped(serviceType: String) {
                    Log.d(TAG, "Discovery stopped")
                }

                override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                    Log.e(TAG, "Start discovery failed: $errorCode")
                    finish(onComplete)
                }

                override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                    Log.e(TAG, "Stop discovery failed: $errorCode")
                }

                override fun onServiceFound(info: NsdServiceInfo) {
                    Log.d(TAG, "Service found: ${info.serviceName}")
                    nsd.resolveService(info, makeResolveListener())
                }

                override fun onServiceLost(info: NsdServiceInfo) {
                    Log.d(TAG, "Service lost: ${info.serviceName}")
                }
            }
        listener = l
        nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, l)

        main.postDelayed({ finish(onComplete) }, timeoutMs)
    }

    private fun makeResolveListener() =
        object : NsdManager.ResolveListener {
            override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "Resolve failed for ${info.serviceName}: $errorCode")
            }

            override fun onServiceResolved(info: NsdServiceInfo) {
                val host = info.host?.hostAddress ?: return
                val port = info.port
                if (port <= 0) return
                val key = "$host:$port"
                synchronized(seen) {
                    if (seen.add(key)) {
                        results.add(Found(host, port, info.serviceName))
                    }
                }
                Log.d(TAG, "Resolved ${info.serviceName} → $host:$port")
            }
        }

    private fun finish(onComplete: (List<Found>) -> Unit) {
        if (!finished.compareAndSet(false, true)) return
        listener?.let {
            try {
                nsd.stopServiceDiscovery(it)
            } catch (_: Exception) {
                // already stopped
            }
        }
        val snapshot = synchronized(seen) { results.toList() }
        main.post { onComplete(snapshot) }
    }
}
