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
import okhttp3.OkHttpClient
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
class QiKey private constructor(val server: String, private val raw: ByteArray) {
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

    fun pair(code: String): Boolean {
        val k = QiKey.parse(code) ?: return false
        prefs.edit().putString("pair_code", code.trim()).apply()
        key = k
        retryDelay = 1000L
        connect()
        return true
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
                    if (gen == generation) retry(gen)
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
        if (f.optString("t") != "clip") return
        val k = key ?: return
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
