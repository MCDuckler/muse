package dance.duckduck.wetowl.core

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.Request

// Your account, and — for an admin — everybody's.

data class Me(val user: String, val userId: Int, val device: String?, val score: Int, val avatarVersion: String?)
data class Account(val id: Int, val name: String, val devices: Int, val lastSeen: String?, val needsPassword: Boolean, val score: Int)
data class Invite(val code: String, val note: String?, val expiresAt: String?)

suspend fun Api.meFull(): Me {
    val o = obj("GET", "/me")
    return Me(o.str("user") ?: "", o.int("user_id") ?: 0, o.str("device"), o.int("score") ?: 0, o.str("avatar_version"))
}

suspend fun Api.changePassword(password: String) { raw("POST", "/auth/password", json = buildJsonObject { put("password", password) }) }

suspend fun Api.setAvatar(bytes: ByteArray) { raw("POST", "/me/avatar", bytes = bytes) }
suspend fun Api.clearAvatar() { raw("DELETE", "/me/avatar") }

suspend fun Api.redeem(code: String, user: String, password: String, device: String): Pair<String, String> {
    val o = obj("POST", "/auth/redeem",
        form = mapOf("code" to code, "user" to user, "password" to password, "device" to device, "platform" to "android"))
    val t = o.str("token") ?: throw ApiError(-1, "No token in the answer")
    token = t
    return t to (o.str("user") ?: user)
}

/** Everybody on the house, and whether you may run it. */
suspend fun Api.accounts(): Pair<Boolean, List<Account>> {
    val o = obj("GET", "/accounts")
    return (o.bool("admin") ?: false) to o.arr("items").objects {
        Account(it.int("id")!!, it.str("name") ?: "", it.int("devices") ?: 0, it.str("last_seen"),
            it.bool("needs_password") ?: false, it.int("score") ?: 0)
    }
}
suspend fun Api.createAccount(name: String, password: String) {
    raw("POST", "/accounts", json = buildJsonObject { put("name", name); put("password", password) })
}
suspend fun Api.deleteAccount(id: Int) { raw("DELETE", "/accounts/$id") }
suspend fun Api.resetPassword(id: Int, password: String) {
    raw("POST", "/accounts/$id/password", json = buildJsonObject { put("password", password); put("sign_out_devices", true) })
}
suspend fun Api.invites(): List<Invite> = obj("GET", "/accounts/invites").arr("items").objects {
    Invite(it.str("code") ?: return@objects null, it.str("note"), it.str("expires_at"))
}
suspend fun Api.createInvite(note: String?): Invite {
    val o = obj("POST", "/accounts/invites", json = buildJsonObject { note?.let { put("note", it) } })
    return Invite(o.str("code") ?: "", note, o.str("expires_at"))
}
suspend fun Api.revokeInvite(code: String) { raw("DELETE", "/accounts/invites/" + android.net.Uri.encode(code)) }

/** A newer build of this app, from where its builds are published. */
data class Update(val versionCode: Int, val versionName: String, val url: String, val notes: String?)

const val UPDATES_URL = "https://files.89-58-49-140.nip.io/wetowl-android/latest.json"

suspend fun Api.checkUpdate(current: Int): Update? = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
    runCatching {
        http.newCall(Request.Builder().url(UPDATES_URL).build()).execute().use { r ->
            if (!r.isSuccessful) return@use null
            val o = Api.JSON.parseToJsonElement(r.body.string()) as kotlinx.serialization.json.JsonObject
            val code = o.int("version_code") ?: return@use null
            if (code <= current) null
            else Update(code, o.str("version_name") ?: "", o.str("url") ?: return@use null, o.str("notes"))
        }
    }.getOrNull()
}

suspend fun Api.sendPlaybackLog(device: String, build: String, lines: List<String>) {
    raw("POST", "/playback-log", json = buildJsonObject {
        put("device", device); put("build", build)
        put("lines", kotlinx.serialization.json.buildJsonArray { lines.forEach { add(kotlinx.serialization.json.JsonPrimitive(it)) } })
    })
}
