package com.osfans.trime.qi

import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import com.osfans.trime.BuildConfig
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import java.io.File
import java.util.concurrent.TimeUnit

object QiUpdate {
    class Release(val version: String, val url: String)

    private const val RELEASES = "https://api.github.com/repos/Arthur-Null/YiQi/releases?per_page=10"
    private val http = OkHttpClient.Builder().callTimeout(5, TimeUnit.MINUTES).build()

    val current: String get() = BuildConfig.VERSION_NAME

    fun isNewer(a: String, b: String): Boolean {
        val x = a.split(".").map { it.toIntOrNull() ?: 0 }
        val y = b.split(".").map { it.toIntOrNull() ?: 0 }
        for (i in 0 until maxOf(x.size, y.size)) {
            val p = x.getOrElse(i) { 0 }
            val q = y.getOrElse(i) { 0 }
            if (p != q) return p > q
        }
        return false
    }

    fun check(): Release? = checkWithStatus().first

    fun checkWithStatus(): Pair<Release?, Boolean> = runCatching { checkOrThrow() to true }.getOrElse { null to false }

    private fun checkOrThrow(): Release? = run {
        val body = http.newCall(Request.Builder().url(RELEASES).header("Accept", "application/vnd.github+json").build())
            .execute().use { it.body?.string() } ?: error("no response")
        val list = JSONArray(body)
        var found: Release? = null
        for (i in 0 until list.length()) {
            val r = list.getJSONObject(i)
            if (r.optBoolean("draft")) continue
            val assets = r.getJSONArray("assets")
            for (j in 0 until assets.length()) {
                val a = assets.getJSONObject(j)
                if (a.optString("name") != "YiQi-Android.apk") continue
                val v = r.getString("tag_name").trimStart('v')
                if (found == null || isNewer(v, found.version)) found = Release(v, a.getString("browser_download_url"))
            }
        }
        found?.takeIf { isNewer(it.version, current) }
    }

    fun download(context: Context, r: Release): File? = runCatching {
        val f = File(context.cacheDir, "YiQi-${r.version}.apk")
        if (f.length() > 0) return f
        val part = File(context.cacheDir, "YiQi-${r.version}.apk.part")
        http.newCall(Request.Builder().url(r.url).build()).execute().use { resp ->
            if (!resp.isSuccessful) return null
            part.outputStream().use { out -> resp.body!!.byteStream().copyTo(out) }
        }
        part.renameTo(f)
        f
    }.getOrNull()

    fun install(context: Context, apk: File) {
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", apk)
        context.startActivity(
            Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }
}
