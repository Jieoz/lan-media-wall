package com.jieoz.lanmediawall.player.net

import java.math.BigInteger

/**
 * Tiny ergonomic builders for constructing [Json] payloads in Kotlin without a
 * serialization framework. Keeps call sites readable:
 *
 *     jsonObj {
 *         put("device_id", deviceId)
 *         put("online", true)
 *         put("screen", jsonObj { put("w", 1920); put("h", 1080) })
 *     }
 */
class JsonObjectBuilder {
    private val map = LinkedHashMap<String, Json>()

    fun put(key: String, value: Json) { map[key] = value }
    fun put(key: String, value: String?) { map[key] = value?.let { Json.Str(it) } ?: Json.Null }
    fun put(key: String, value: Int) { map[key] = Json.Num.of(value) }
    fun put(key: String, value: Long) { map[key] = Json.Num.of(value) }
    fun put(key: String, value: BigInteger) { map[key] = Json.Num.of(value) }
    fun put(key: String, value: Boolean) { map[key] = Json.Bool(value) }
    fun putNull(key: String) { map[key] = Json.Null }

    fun build(): Json.Obj = Json.Obj(map)
}

inline fun jsonObj(block: JsonObjectBuilder.() -> Unit): Json.Obj =
    JsonObjectBuilder().apply(block).build()

fun jsonArr(items: List<Json>): Json.Arr = Json.Arr(items)

fun jsonStrArr(items: List<String>): Json.Arr = Json.Arr(items.map { Json.Str(it) })

// --- read helpers for inbound payloads -------------------------------------

fun Json.asObjOrNull(): Json.Obj? = this as? Json.Obj

operator fun Json.get(key: String): Json? = (this as? Json.Obj)?.entries?.get(key)

fun Json?.asString(): String? = (this as? Json.Str)?.value

fun Json?.asLongOrNull(): Long? = when (this) {
    // Protocol integer fields are lexical integers. Never truncate decimals,
    // accept NaN/Infinity, or wrap values outside the target range.
    is Json.Num -> raw.toLongOrNull()
    else -> null
}

fun Json?.asIntOrNull(): Int? = when (this) {
    is Json.Num -> raw.toIntOrNull()
    else -> null
}

fun Json?.asBoolOrNull(): Boolean? = (this as? Json.Bool)?.value

fun Json?.asArrayOrNull(): List<Json>? = (this as? Json.Arr)?.items
