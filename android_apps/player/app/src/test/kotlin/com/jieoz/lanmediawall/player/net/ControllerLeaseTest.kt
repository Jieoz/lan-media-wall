package com.jieoz.lanmediawall.player.net

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class ControllerLeaseTest {
    private class Conn(val name: String)

    @Test
    fun `first connection acquires ownership`() {
        val leases = ControllerLease<Conn>(leaseMs = 15_000)
        val first = Conn("first")

        val result = leases.acquire(first, nowMs = 100)

        assertTrue(result is ControllerLease.Acquire.Acquired<*>)
        assertSame(first, leases.current())
    }

    @Test
    fun `active first connection rejects second`() {
        val leases = ControllerLease<Conn>(leaseMs = 15_000)
        val first = Conn("first")
        val second = Conn("second")
        leases.acquire(first, nowMs = 100)

        val result = leases.acquire(second, nowMs = 15_099)

        assertTrue(result is ControllerLease.Acquire.Rejected<*>)
        assertSame(first, leases.current())
    }

    @Test
    fun `expired connection is atomically replaced`() {
        val leases = ControllerLease<Conn>(leaseMs = 15_000)
        val first = Conn("first")
        val second = Conn("second")
        leases.acquire(first, nowMs = 100)

        val result = leases.acquire(second, nowMs = 15_100)

        assertTrue(result is ControllerLease.Acquire.Replaced<*>)
        assertSame(first, (result as ControllerLease.Acquire.Replaced<Conn>).stale.value)
        assertSame(second, leases.current())
    }

    @Test
    fun `stale finally cannot clear replacement generation`() {
        val leases = ControllerLease<Conn>(leaseMs = 15_000)
        val first = Conn("first")
        val second = Conn("second")
        val firstOwner = (leases.acquire(first, 0) as ControllerLease.Acquire.Acquired<Conn>).owner
        val secondOwner = (leases.acquire(second, 15_000) as ControllerLease.Acquire.Replaced<Conn>).owner

        assertFalse(leases.release(firstOwner))
        assertSame(second, leases.current())
        assertTrue(leases.release(secondOwner))
        assertNull(leases.current())
    }

    @Test
    fun `activity renews only current connection lease`() {
        val leases = ControllerLease<Conn>(leaseMs = 15_000)
        val first = Conn("first")
        val firstOwner = (leases.acquire(first, 0) as ControllerLease.Acquire.Acquired<Conn>).owner

        assertTrue(leases.renew(firstOwner, nowMs = 14_000))
        assertTrue(leases.acquire(Conn("too-soon"), nowMs = 28_999) is ControllerLease.Acquire.Rejected<*>)
        assertFalse(leases.renew(firstOwner.copy(generation = firstOwner.generation + 1), 29_000))
        assertEquals(14_000, leases.lastActivityMs())
        assertTrue(leases.acquire(Conn("replacement"), nowMs = 29_000) is ControllerLease.Acquire.Replaced<*>)
    }
}
