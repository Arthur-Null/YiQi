package com.osfans.trime.qi

import com.osfans.trime.core.data.DataManager
import com.osfans.trime.daemon.RimeDaemon
import kotlinx.coroutines.withTimeout
import java.io.File

// C9: 用户词库快照文件：Rime 同步用户资料时把本机词库导出到 sync/<本机安装号>/，并合并 sync/ 下其他文件夹里的快照。
// 其他设备的快照以设备号为文件夹名放进同一个 sync/ 目录。
object QiDict {
    private const val FILE = "rime_frost.userdb.txt"
    private val dir get() = DataManager.userDataDir
    private val idRegex = Regex("^[A-Za-z0-9_-]{1,64}$")

    fun valid(id: String) = idRegex.matches(id)

    fun ownSnapshot(): ByteArray? {
        val yaml = File(dir, "installation.yaml").takeIf { it.exists() }?.readText() ?: return null
        val id = Regex("(?m)^installation_id:\\s*\"?([^\"\\s]+)\"?").find(yaml)?.groupValues?.get(1) ?: return null
        return File(dir, "sync/$id/$FILE").takeIf { it.exists() && it.length() > 0 }?.readBytes()
    }

    // 只看词条，不看文件头（版本、tick 等），避免只因合并导致头部变化而反复上传
    fun fingerprint(text: ByteArray): Int =
        String(text, Charsets.UTF_8).lineSequence().filter { it.isNotEmpty() && !it.startsWith("#") }.toList().hashCode()

    fun store(from: String, text: ByteArray): Boolean {
        val f = File(dir, "sync/$from/$FILE")
        if (f.exists() && f.readBytes().contentEquals(text)) return false
        f.parentFile?.mkdirs()
        val tmp = File(f.parentFile, "$FILE.tmp")
        tmp.writeBytes(text)
        return tmp.renameTo(f)
    }

    suspend fun sync() {
        val session = RimeDaemon.createSession("qi-dict")
        try {
            withTimeout(5 * 60_000L) { session.runOnReady { syncUserData() } }
        } finally {
            RimeDaemon.destroySession("qi-dict")
        }
    }
}
