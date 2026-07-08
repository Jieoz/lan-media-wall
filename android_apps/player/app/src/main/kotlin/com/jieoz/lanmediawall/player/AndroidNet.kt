package com.jieoz.lanmediawall.player

import java.net.Inet4Address
import java.net.NetworkInterface

/** Android 4.4/YunOS LAN helpers.
 *
 * Some QZX_C1 builds report a valid DHCP address in `ip addr`/`getprop` while
 * Java's NetworkInterface enumeration returns no usable IPv4 to the app. Keep
 * the Java path first, then fall back to the same system facts operators can see
 * over adb (`dhcp.wlan0.ipaddress`, `netcfg`).
 */
object AndroidNet {
    private val IPV4 = Regex("\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b")
    private const val CACHE_MS = 5000L

    @Volatile private var cachedIp: String? = null
    @Volatile private var cachedAtMs: Long = 0L

    fun detectLanIp(
        command: (String) -> String? = ::runShell,
        javaIp: () -> String? = ::javaInterfaceIp,
        nowMs: () -> Long = { System.currentTimeMillis() },
        forceRefresh: Boolean = false,
    ): String {
        val now = nowMs()
        cachedIp?.takeIf { !forceRefresh && isUsableIpv4(it) && now - cachedAtMs < CACHE_MS }
            ?.let { return it }
        javaIp()?.let { return remember(it, now) }
        propIp(command, "dhcp.wlan0.ipaddress")?.let { return remember(it, now) }
        propIp(command, "dhcp.eth0.ipaddress")?.let { return remember(it, now) }
        netcfgIp(command)?.let { return remember(it, now) }
        ipAddrIp(command)?.let { return remember(it, now) }
        return "0.0.0.0"
    }

    fun clearCacheForTest() {
        cachedIp = null
        cachedAtMs = 0L
    }

    fun firstUsableIpv4(text: String?): String? =
        IPV4.findAll(text ?: "")
            .map { it.value }
            .firstOrNull { isUsableIpv4(it) }

    private fun javaInterfaceIp(): String? {
        return try {
            val ifaces = NetworkInterface.getNetworkInterfaces() ?: return null
            for (iface in ifaces) {
                if (!iface.isUp || iface.isLoopback) continue
                val addrs = iface.inetAddresses
                for (addr in addrs) {
                    if (addr is Inet4Address && !addr.isLoopbackAddress) {
                        val ip = addr.hostAddress
                        if (isUsableIpv4(ip)) return ip
                    }
                }
            }
            null
        } catch (_: Throwable) {
            null
        }
    }

    private fun propIp(command: (String) -> String?, key: String): String? =
        firstUsableIpv4(command("getprop $key"))

    private fun netcfgIp(command: (String) -> String?): String? =
        command("netcfg")
            ?.lineSequence()
            ?.filter { it.contains(" UP ") }
            ?.firstNotNullOfOrNull { firstUsableIpv4(it) }

    private fun ipAddrIp(command: (String) -> String?): String? =
        command("ip addr")
            ?.lineSequence()
            ?.firstNotNullOfOrNull { firstUsableIpv4(it) }

    private fun isUsableIpv4(ip: String?): Boolean {
        if (ip.isNullOrBlank()) return false
        if (ip == "0.0.0.0" || ip.startsWith("127.")) return false
        val parts = ip.split('.')
        return parts.size == 4 && parts.all { p ->
            p.toIntOrNull()?.let { it in 0..255 } == true
        }
    }

    private fun remember(ip: String, now: Long): String {
        cachedIp = ip
        cachedAtMs = now
        return ip
    }

    private fun runShell(cmd: String): String? = try {
        val proc = Runtime.getRuntime().exec(arrayOf("sh", "-c", cmd))
        val out = proc.inputStream.bufferedReader().readText()
        proc.waitFor()
        out
    } catch (_: Throwable) {
        null
    }
}