package com.osfans.trime.qi

import android.content.ClipData
import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.os.Build
import android.util.Base64
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import splitties.systemservices.clipboardManager
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

// C5: 与 sync/protocol 相同：配对密钥派生认证令牌与内容密钥，内容用 AES-GCM 加密后才离开手机。
class QiKey(val server: String, val raw: ByteArray) {
    companion object {
        fun parse(code: String): QiKey? {
            val uri = runCatching { Uri.parse(code.trim()) }.getOrNull() ?: return null
            if (uri.scheme != "qi" || uri.host != "pair") return null
            val server = uri.getQueryParameter("s")?.takeIf { it.isNotEmpty() } ?: return null
            val k = uri.getQueryParameter("k") ?: return null
            val raw = runCatching { Base64.decode(k, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP) }
                .getOrNull() ?: return null
            if (raw.size != 32) return null
            return QiKey(server, raw)
        }
    }

    private fun derive(label: String): ByteArray = Mac.getInstance("HmacSHA256").run {
        init(SecretKeySpec(raw, "HmacSHA256"))
        doFinal(label.toByteArray())
    }

    // C5: 本机保存的同步组凭据（服务器地址与同步组密钥）
    val pairCode: String
        get() = Uri.Builder().scheme("qi").authority("pair")
            .appendQueryParameter("s", server)
            .appendQueryParameter("k", Base64.encodeToString(raw, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP))
            .build().toString()

    val verifier: String
        get() = Base64.encodeToString(
            java.security.MessageDigest.getInstance("SHA-256").digest(authToken.toByteArray()),
            Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP,
        )

    val authToken: String =
        Base64.encodeToString(derive("qi-auth-v1"), Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
    private val encKey = SecretKeySpec(derive("qi-enc-v1"), "AES")

    fun seal(plain: ByteArray): String {
        val nonce = ByteArray(12).also { SecureRandom().nextBytes(it) }
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, encKey, GCMParameterSpec(128, nonce))
        return Base64.encodeToString(nonce + c.doFinal(plain), Base64.NO_WRAP)
    }

    fun open(d: String): ByteArray {
        val raw = Base64.decode(d, Base64.NO_WRAP)
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, encKey, GCMParameterSpec(128, raw, 0, 12))
        return c.doFinal(raw, 12, raw.size - 12)
    }
}

// C3: 同步最新一条文本；收到后写入系统剪贴板（常规粘贴可用），同时出现在候选栏的剪贴板提示里。
object QiSync : CoroutineScope by CoroutineScope(SupervisorJob() + Dispatchers.IO) {
    enum class Status(val label: String) {
        Unpaired("未配对"),
        Connecting("连接中…"),
        Connected("已连接"),
        Offline("暂时连不上服务器，稍后自动重试"),
        Invalid("这台设备已不在同步组中，请重新加入"),
    }

    private val _status = MutableStateFlow(Status.Unpaired)
    val status: StateFlow<Status> = _status

    private lateinit var prefs: SharedPreferences
    private val client = OkHttpClient.Builder().pingInterval(30, TimeUnit.SECONDS).build()
    private var key: QiKey? = null
    private var socket: WebSocket? = null
    private var generation = 0
    private var retryDelay = 1000L
    private var retryJob: Job? = null

    private val lock = Any()
    private var lastText: String? = null
    private var lastTs = 0L
    private var pending: JSONObject? = null

    private val deviceId: String by lazy {
        prefs.getString("device_id", null) ?: UUID.randomUUID().toString().also {
            prefs.edit().putString("device_id", it).apply()
        }
    }

    val pairCode: String? get() = prefs.getString("pair_code", null)

    fun init(context: Context) {
        val ctx = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            context.createDeviceProtectedStorageContext()
        } else {
            context
        }
        prefs = ctx.getSharedPreferences("qi_sync", Context.MODE_PRIVATE)
        key = pairCode?.let { QiKey.parse(it) }
        connect()
    }

    fun save(k: QiKey) {
        prefs.edit().putString("pair_code", k.pairCode).apply()
        key = k
        retryDelay = 1000L
        connect()
    }

    fun leave() {
        stopInvite()
        prefs.edit().remove("pair_code").apply()
        key = null
        connect()
    }

    val server: String? get() = key?.server

    // C5: 「添加设备」：生成 6 位临时密码，新设备凭它取得同步组密钥
    @Volatile
    var inviteCode: String? = null
        private set

    fun startInvite(): String? {
        val s = socket ?: return null
        if (_status.value != Status.Connected) return null
        val code = String.format(java.util.Locale.ROOT, "%06d", SecureRandom().nextInt(1_000_000))
        inviteCode = code
        s.send(JSONObject().put("t", "invite").toString())
        return code
    }

    fun stopInvite() {
        if (inviteCode == null) return
        inviteCode = null
        socket?.send(JSONObject().put("t", "invite-end").toString())
    }

    fun reconnectNow() {
        if (_status.value == Status.Connected) return
        retryDelay = 1000L
        connect()
    }

    @Synchronized
    private fun connect() {
        generation++
        retryJob?.cancel()
        socket?.cancel()
        socket = null
        val k = key ?: run {
            _status.value = Status.Unpaired
            return
        }
        _status.value = Status.Connecting
        val gen = generation
        val req = Request.Builder().url(k.server).header("Authorization", "Bearer ${k.authToken}").build()
        socket = client.newWebSocket(
            req,
            object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    if (gen != generation) return
                    _status.value = Status.Connected
                    retryDelay = 1000L
                    synchronized(lock) { pending?.also { pending = null } }?.let { send(it) }
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    if (gen != generation) return
                    runCatching { receive(text) }
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    if (gen != generation) return
                    // C5: 服务器不再认可这台设备（同步组已在服务器上重置）时不再重试
                    if (response?.code == 401) {
                        _status.value = Status.Invalid
                    } else {
                        retry(gen)
                    }
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    if (gen == generation) retry(gen)
                }
            },
        )
    }

    private fun retry(gen: Int) {
        _status.value = Status.Offline
        val wait = retryDelay
        retryDelay = (retryDelay * 2).coerceAtMost(30_000L)
        retryJob = launch {
            delay(wait)
            if (gen == generation) connect()
        }
    }

    private fun receive(frame: String) {
        val f = JSONObject(frame)
        val k = key ?: return
        if (f.optString("t") == "join") {
            val code = inviteCode ?: return
            val reply = QiPairing.sealGroupKey(f.getString("d"), code, k)
            socket?.send(JSONObject().put("t", "join-ok").put("j", f.getString("j")).put("d", reply).toString())
            return
        }
        if (f.optString("t") != "clip") return
        val clip = JSONObject(String(k.open(f.getString("d")), Charsets.UTF_8))
        val text = clip.getString("text")
        synchronized(lock) {
            if (clip.optString("from") == deviceId || clip.getLong("ts") <= lastTs) return
            lastTs = clip.getLong("ts")
            lastText = text
        }
        launch(Dispatchers.Main) {
            clipboardManager.setPrimaryClip(ClipData.newPlainText("Qi", text))
        }
    }

    fun onLocalCopy(text: String) {
        if (!::prefs.isInitialized || key == null) return
        val clip = synchronized(lock) {
            if (text == lastText) return
            lastText = text
            lastTs = System.currentTimeMillis()
            JSONObject()
                .put("id", UUID.randomUUID().toString())
                .put("from", deviceId)
                .put("ts", lastTs)
                .put("text", text)
        }
        send(clip)
    }

    private fun send(clip: JSONObject) {
        val k = key ?: return
        val s = socket
        val frame = JSONObject().put("t", "clip").put("d", k.seal(clip.toString().toByteArray(Charsets.UTF_8)))
        if (s == null || _status.value != Status.Connected || !s.send(frame.toString())) {
            synchronized(lock) { pending = clip }
            reconnectNow()
        }
    }
}

// C5, C7: 注册同步组与新设备加入（与电脑端、服务器同一协议：P-256 密钥交换 + 6 位临时密码）
object QiPairing {
    sealed class Outcome {
        class Ok(val key: QiKey) : Outcome()
        class Fail(val message: String) : Outcome()
    }

    private val http = OkHttpClient.Builder().callTimeout(40, TimeUnit.SECONDS).build()

    // C7: 服务器地址由用户填写
    fun serverUrl(input: String): String? {
        var t = input.trim()
        if (t.isEmpty()) return null
        if (t.startsWith("https://")) t = "wss://" + t.removePrefix("https://")
        if (t.startsWith("http://")) t = "ws://" + t.removePrefix("http://")
        if (!t.startsWith("wss://") && !t.startsWith("ws://")) t = "wss://$t"
        val u = Uri.parse(t)
        if (u.host.isNullOrEmpty()) return null
        return if (u.path.isNullOrEmpty() || u.path == "/") u.buildUpon().path("/v1/ws").build().toString() else t
    }

    private fun endpoint(server: String, path: String): String {
        val u = Uri.parse(server)
        return u.buildUpon().scheme(if (u.scheme == "ws") "http" else "https").path(path).build().toString()
    }

    private fun post(url: String, body: JSONObject): Pair<Int, String?> = try {
        val req = okhttp3.Request.Builder().url(url)
            .post(body.toString().toRequestBody("application/json".toMediaType())).build()
        http.newCall(req).execute().use { it.code to it.body?.string() }
    } catch (e: Exception) {
        -1 to e.message
    }

    private fun randomRaw() = ByteArray(32).also { SecureRandom().nextBytes(it) }

    fun register(serverInput: String, code: String): Outcome {
        val server = serverUrl(serverInput) ?: return Outcome.Fail("服务器地址不对，请填写例如 yiqi.example.com。")
        val k = QiKey(server, randomRaw())
        val (status, err) = post(endpoint(server, "/v1/claim"), JSONObject().put("code", code.filter(Char::isDigit)).put("v", k.verifier))
        return when (status) {
            200 -> Outcome.Ok(k)
            403 -> Outcome.Fail("临时密码不对或已过期，请核对后重试。")
            409 -> Outcome.Fail("这台服务器已经注册过同步组。请在已同步的设备上点「添加设备」，用它给出的 6 位临时密码加入。")
            else -> Outcome.Fail("连不上服务器（${err ?: "HTTP $status"}），请检查地址和网络。")
        }
    }

    fun join(serverInput: String, code: String): Outcome {
        val server = serverUrl(serverInput) ?: return Outcome.Fail("服务器地址不对，请填写例如 yiqi.example.com。")
        val kp = newKeyPair()
        val (status, body) = post(endpoint(server, "/v1/join"), JSONObject().put("t", "join").put("d", encode(kp.public)))
        return when (status) {
            200 -> try {
                val reply = JSONObject(body ?: "").getString("d")
                Outcome.Ok(QiKey(server, openGroupKey(kp, reply, code.filter(Char::isDigit))))
            } catch (e: Exception) {
                Outcome.Fail("临时密码不对，请核对后重试。")
            }
            404 -> Outcome.Fail("没有找到等待加入的邀请。请先在已同步的设备上点「添加设备」，并保持那个窗口打开。")
            429 -> Outcome.Fail("尝试次数过多，请在已同步的设备上重新点「添加设备」获取新的临时密码。")
            else -> Outcome.Fail("连不上服务器（${body ?: "HTTP $status"}），请检查地址和网络。")
        }
    }

    private fun newKeyPair(): java.security.KeyPair = java.security.KeyPairGenerator.getInstance("EC").run {
        initialize(java.security.spec.ECGenParameterSpec("secp256r1"))
        generateKeyPair()
    }

    private fun pad32(b: java.math.BigInteger): ByteArray {
        val raw = b.toByteArray()
        return when {
            raw.size == 32 -> raw
            raw.size > 32 -> raw.copyOfRange(raw.size - 32, raw.size)
            else -> ByteArray(32 - raw.size) + raw
        }
    }

    private fun encode(pub: java.security.PublicKey): String {
        val w = (pub as java.security.interfaces.ECPublicKey).w
        return Base64.encodeToString(byteArrayOf(4) + pad32(w.affineX) + pad32(w.affineY), Base64.NO_WRAP)
    }

    private fun decode(b64: String, params: java.security.spec.ECParameterSpec): java.security.PublicKey {
        val b = Base64.decode(b64, Base64.NO_WRAP)
        require(b.size == 65 && b[0] == 4.toByte())
        val point = java.security.spec.ECPoint(
            java.math.BigInteger(1, b.copyOfRange(1, 33)),
            java.math.BigInteger(1, b.copyOfRange(33, 65)),
        )
        return java.security.KeyFactory.getInstance("EC").generatePublic(java.security.spec.ECPublicKeySpec(point, params))
    }

    private fun joinKey(kp: java.security.KeyPair, peer: java.security.PublicKey, code: String): SecretKeySpec {
        val shared = javax.crypto.KeyAgreement.getInstance("ECDH").run {
            init(kp.private)
            doPhase(peer, true)
            generateSecret()
        }
        val k = Mac.getInstance("HmacSHA256").run {
            init(SecretKeySpec(shared, "HmacSHA256"))
            doFinal("yiqi-join-v1|$code".toByteArray())
        }
        return SecretKeySpec(k, "AES")
    }

    fun sealGroupKey(peerB64: String, code: String, key: QiKey): String {
        val kp = newKeyPair()
        val peer = decode(peerB64, (kp.public as java.security.interfaces.ECPublicKey).params)
        val nonce = ByteArray(12).also { SecureRandom().nextBytes(it) }
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, joinKey(kp, peer, code), GCMParameterSpec(128, nonce))
        return encode(kp.public) + "." + Base64.encodeToString(nonce + c.doFinal(key.raw), Base64.NO_WRAP)
    }

    private fun openGroupKey(kp: java.security.KeyPair, reply: String, code: String): ByteArray {
        val (pa, e) = reply.split(".", limit = 2)
        val peer = decode(pa, (kp.public as java.security.interfaces.ECPublicKey).params)
        val raw = Base64.decode(e, Base64.NO_WRAP)
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, joinKey(kp, peer, code), GCMParameterSpec(128, raw, 0, 12))
        val k = c.doFinal(raw, 12, raw.size - 12)
        require(k.size == 32)
        return k
    }
}
