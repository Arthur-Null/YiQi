package com.osfans.trime.qi

import android.graphics.Typeface
import android.os.Bundle
import android.os.CountDownTimer
import android.text.InputType
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding
import androidx.lifecycle.lifecycleScope
import com.osfans.trime.core.data.DataManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

class QiSyncActivity : AppCompatActivity() {
    private lateinit var status: TextView
    private lateinit var message: TextView
    private lateinit var paired: LinearLayout
    private lateinit var unpaired: LinearLayout
    private lateinit var invite: LinearLayout
    private lateinit var inviteCode: TextView
    private lateinit var inviteTimer: TextView
    private var timer: CountDownTimer? = null

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    private fun text(s: String, size: Float = 15f, bold: Boolean = false) = TextView(this).apply {
        text = s
        textSize = size
        if (bold) setTypeface(typeface, Typeface.BOLD)
        setPadding(0, dp(6), 0, dp(6))
    }

    private fun button(s: String, onClick: () -> Unit) = Button(this).apply {
        text = s
        setOnClickListener { onClick() }
    }

    private fun vertical() = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = "一炁输入法"
        val col = vertical().apply { setPadding(dp(20), dp(16), dp(20), dp(24)) }

        // C2: 界面可见可点的输入方式切换（与键盘工具栏按钮、电脑端共用同一记录）
        col.addView(text("输入方式", 18f, true))
        val group = RadioGroup(this)
        group.addView(RadioButton(this).apply { text = "小鹤双拼"; id = 1 })
        group.addView(RadioButton(this).apply { text = "全拼"; id = 2 })
        group.check(if (currentScheme() == QUANPIN) 2 else 1)
        group.setOnCheckedChangeListener { _, id -> requestScheme(if (id == 2) QUANPIN else FLYPY) }
        col.addView(group)
        col.addView(text("打字时也可以点键盘左上方的「小鹤 / 全拼」按钮随时切换。", 13f))

        // C3, C5, C7: 剪贴板同步：注册同步组、加入、添加设备
        col.addView(text("剪贴板同步", 18f, true).apply { setPadding(0, dp(24), 0, dp(6)) })
        status = text("")
        col.addView(status)

        paired = vertical()
        paired.addView(button("添加设备") { startInvite() })
        paired.addView(text("要让电脑或另一台手机加入，点「添加设备」，会生成一个 6 位临时密码。", 13f))
        paired.addView(button("退出同步组") { leave() })
        col.addView(paired)

        invite = vertical()
        invite.addView(text("在新设备的一炁设置里填写："))
        inviteCode = text("", 26f, true)
        invite.addView(inviteCode)
        inviteTimer = text("", 13f)
        invite.addView(inviteTimer)
        invite.addView(button("完成") { stopInvite() })
        col.addView(invite)

        unpaired = vertical()
        val server = EditText(this).apply {
            hint = "服务器地址，例如 yiqi.example.com"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
            isSingleLine = true
        }
        val code = EditText(this).apply {
            hint = "6 位临时密码"
            inputType = InputType.TYPE_CLASS_NUMBER
            isSingleLine = true
        }
        unpaired.addView(server)
        unpaired.addView(code)
        unpaired.addView(button("加入同步组") { pair(false, server.text.toString(), code.text.toString()) })
        unpaired.addView(text("临时密码在已同步的设备上点「添加设备」获得。", 13f))
        unpaired.addView(button("注册新同步组") { pair(true, server.text.toString(), code.text.toString()) })
        unpaired.addView(text("第一台设备用这个；临时密码在部署服务器时显示。", 13f))
        col.addView(unpaired)

        message = text("", 14f)
        col.addView(message)
        col.addView(
            text(
                "同步后，在电脑上复制的文字会加密传到手机：打开键盘时顶部会出现这段文字，点一下即可输入；也可以在输入框长按「粘贴」。手机上复制的文字同样会出现在电脑上。",
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

        lifecycleScope.launch {
            QiSync.status.collect { refresh() }
        }
    }

    private fun refresh() {
        val host = QiSync.server?.let { android.net.Uri.parse(it).host }
        status.text = "状态：${QiSync.status.value.label}" + (host?.let { "\n服务器：$it" } ?: "")
        val isPaired = QiSync.server != null
        val inviting = QiSync.inviteCode != null
        unpaired.visibility = if (isPaired) View.GONE else View.VISIBLE
        paired.visibility = if (isPaired && !inviting) View.VISIBLE else View.GONE
        invite.visibility = if (isPaired && inviting) View.VISIBLE else View.GONE
    }

    private fun pair(register: Boolean, server: String, code: String) {
        message.text = if (register) "正在注册…" else "正在加入…"
        lifecycleScope.launch {
            val r = withContext(Dispatchers.IO) {
                if (register) QiPairing.register(server, code) else QiPairing.join(server, code)
            }
            when (r) {
                is QiPairing.Outcome.Ok -> {
                    QiSync.save(r.key)
                    message.text = ""
                }
                is QiPairing.Outcome.Fail -> message.text = r.message
            }
            refresh()
        }
    }

    private fun startInvite() {
        val code = QiSync.startInvite() ?: run {
            message.text = "需要先连上服务器才能添加设备。"
            return
        }
        val host = QiSync.server?.let { android.net.Uri.parse(it).host } ?: ""
        inviteCode.text = "服务器地址  $host\n临时密码  ${code.take(3)} ${code.takeLast(3)}"
        timer?.cancel()
        timer = object : CountDownTimer(300_000, 1000) {
            override fun onTick(left: Long) {
                val s = left / 1000
                inviteTimer.text = "${s / 60}:${String.format(java.util.Locale.ROOT, "%02d", s % 60)} 内有效，请保持此页面打开"
            }

            override fun onFinish() = stopInvite()
        }.start()
        message.text = ""
        refresh()
    }

    private fun stopInvite() {
        timer?.cancel()
        QiSync.stopInvite()
        refresh()
    }

    private fun leave() {
        AlertDialog.Builder(this)
            .setMessage("让这台手机退出同步组？之后需要在其他已同步的设备上点「添加设备」才能重新加入。")
            .setPositiveButton("退出") { _, _ ->
                QiSync.leave()
                refresh()
            }.setNegativeButton("取消", null)
            .show()
    }

    override fun onDestroy() {
        stopInvite()
        super.onDestroy()
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
