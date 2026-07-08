package com.jieoz.lanmediawall.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AndroidNetTest {
    @Test
    fun uses_java_interface_ip_first() {
        AndroidNet.clearCacheForTest()
        val ip = AndroidNet.detectLanIp(
            command = { null },
            javaIp = { "10.10.8.137" },
        )
        assertEquals("10.10.8.137", ip)
    }

    @Test
    fun falls_back_to_dhcp_wlan0_property() {
        AndroidNet.clearCacheForTest()
        val ip = AndroidNet.detectLanIp(
            command = { cmd -> if (cmd == "getprop dhcp.wlan0.ipaddress") "10.10.8.137\n" else null },
            javaIp = { null },
        )
        assertEquals("10.10.8.137", ip)
    }

    @Test
    fun falls_back_to_netcfg_up_interface() {
        AndroidNet.clearCacheForTest()
        val netcfg = """
            teql0    DOWN                                   0.0.0.0/0   0x00000080 00:00:00:00:00:00
            wlan0    UP                                 10.10.8.137/22  0x00001043 44:b2:95:6d:c4:6d
            lo       UP                                   127.0.0.1/8   0x00000049 00:00:00:00:00:00
            eth0     UP                                     0.0.0.0/0   0x00001003 da:24:00:22:da:98
        """.trimIndent()
        val ip = AndroidNet.detectLanIp(
            command = { cmd -> if (cmd == "netcfg") netcfg else null },
            javaIp = { null },
        )
        assertEquals("10.10.8.137", ip)
    }

    @Test
    fun rejects_loopback_and_unspecified_ips() {
        AndroidNet.clearCacheForTest()
        assertNull(AndroidNet.firstUsableIpv4("lo 127.0.0.1/8 eth0 0.0.0.0/0"))
    }

    @Test
    fun caches_usable_ip_to_avoid_repeated_shell_probes() {
        AndroidNet.clearCacheForTest()
        var calls = 0
        val ip1 = AndroidNet.detectLanIp(
            command = { calls++; if (it == "getprop dhcp.wlan0.ipaddress") "10.10.8.137" else null },
            javaIp = { null },
            nowMs = { 1000L },
        )
        val ip2 = AndroidNet.detectLanIp(
            command = { calls++; "10.10.8.138" },
            javaIp = { null },
            nowMs = { 2000L },
        )
        assertEquals("10.10.8.137", ip1)
        assertEquals("10.10.8.137", ip2)
        assertEquals(1, calls)
    }
}
