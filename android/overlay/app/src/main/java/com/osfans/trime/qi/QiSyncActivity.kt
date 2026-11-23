package com.osfans.trime.qi

import android.graphics.Typeface
import android.os.Bundle
import android.view.Gravity
import android.widget.Button
import android.widget.LinearLayout
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding
import androidx.lifecycle.lifecycleScope
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import com.osfans.trime.core.data.DataManager
import kotlinx.coroutines.launch
import splitties.systemservices.clipboardManager
import java.io.File

class QiSyncActivity : AppCompatActivity() {
    private lateinit var status: TextView

    private val scan = registerForActivityResult(ScanContract()) { result ->
        result.contents?.let { pair(it) }
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    private fun text(s: String, size: Float = 15f, bold: Boolean = false) = TextView(this).apply {
        text = s
        textSize = size
        if (bold) setTypeface(typeface, Typeface.BOLD)
        setPadding(0, dp(6), 0, dp(6))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = "一炁输入法"
        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(16), dp(20), dp(24))
        }

        // C2: 界面可见可点的输入方式切换（与键盘工具栏按钮、电脑端共用同一记录）
        col.addView(text("输入方式", 18f, true))
        val group = RadioGroup(this)
        val flypy = RadioButton(this).apply { text = "小鹤双拼"; id = 1 }
        val quanpin = RadioButton(this).apply { text = "全拼"; id = 2 }
        group.addView(flypy)
        group.addView(quanpin)
        group.check(if (currentScheme() == QUANPIN) 2 else 1)
        group.setOnCheckedChangeListener { _, id -> requestScheme(if (id == 2) QUANPIN else FLYPY) }
        col.addView(group)
        col.addView(text("打字时也可以点键盘左上方的「小鹤 / 全拼」按钮随时切换。", 13f))

        // C3, C5: 剪贴板同步配对
        col.addView(text("剪贴板同步", 18f, true).apply { setPadding(0, dp(24), 0, dp(6)) })
        status = text("")
        col.addView(status)
        col.addView(
            text(
                "在电脑上打开一炁（菜单栏的「鹤 / 全」→「配对手机或其他电脑…」），然后点下面的「扫码配对」扫描电脑上的二维码。",
                14f,
            ),
        )
        col.addView(
            Button(this).apply {
                text = "扫码配对"
                setOnClickListener {
                    scan.launch(
                        ScanOptions()
                            .setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                            .setPrompt("扫描电脑上一炁显示的二维码")
                            .setBeepEnabled(false)
                            .setOrientationLocked(false),
                    )
                }
            },
        )
        col.addView(
            Button(this).apply {
                text = "粘贴配对码"
                setOnClickListener {
                    val s = clipboardManager.primaryClip?.getItemAt(0)?.coerceToText(this@QiSyncActivity)
                    pair(s?.toString() ?: "")
                }
            },
        )
        col.addView(
            text(
                "配对后，在电脑上复制的文字会加密传到手机：打开键盘时顶部会出现这段文字，点一下即可输入；也可以在输入框长按「粘贴」。手机上复制的文字同样会出现在电脑上。",
                13f,
            ).apply { setPadding(0, dp(16), 0, 0) },
        )

        val scroll = ScrollView(this).apply { addView(col) }
        ViewCompat.setOnApplyWindowInsetsListener(scroll) { v, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            v.updatePadding(top = bars.top, bottom = bars.bottom)
            insets
        }
        setContentView(scroll)

        intent?.data?.let { pair(it.toString()) }

        lifecycleScope.launch {
            QiSync.status.collect { s ->
                // C7: 显示当前使用的服务器（来自配对码）
                val host = QiSync.pairCode?.let { android.net.Uri.parse(it).getQueryParameter("s") }
                    ?.let { android.net.Uri.parse(it).host }
                status.text = "状态：${s.label}" + (host?.let { "\n服务器：$it" } ?: "")
                status.gravity = Gravity.START
            }
        }
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        intent.data?.let { pair(it.toString()) }
    }

    private fun pair(code: String) {
        if (QiSync.pair(code)) {
            Toast.makeText(this, "已配对", Toast.LENGTH_SHORT).show()
        } else {
            Toast.makeText(this, "这不是一炁的配对码", Toast.LENGTH_LONG).show()
        }
    }

    companion object {
        const val FLYPY = "double_pinyin_flypy"
        const val QUANPIN = "rime_ice"
        private val stateFile get() = File(DataManager.userDataDir, "qi_schema.txt")

        fun currentScheme(): String = runCatching { stateFile.readText().trim().split(" ").first() }.getOrNull()
            ?.takeIf { it == FLYPY || it == QUANPIN } ?: FLYPY

        fun requestScheme(id: String) {
            stateFile.writeText("$id ui-${System.currentTimeMillis()}\n")
        }
    }
}
