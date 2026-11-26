package com.osfans.trime.qi

import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.CountDownTimer
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
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
    private lateinit var statusDot: View
    private lateinit var statusText: TextView
    private lateinit var serverHostText: TextView
    private lateinit var message: TextView
    private lateinit var paired: LinearLayout
    private lateinit var unpaired: LinearLayout
    private lateinit var invite: LinearLayout
    private lateinit var inviteHost: TextView
    private lateinit var inviteCode: TextView
    private lateinit var inviteTimer: TextView
    private var timer: CountDownTimer? = null
    private lateinit var updateCard: LinearLayout
    private lateinit var updateText: TextView
    private lateinit var updateButton: TextView
    private lateinit var updateStatus: TextView
    private lateinit var segFlypy: TextView
    private lateinit var segQuanpin: TextView

    private val isDark: Boolean
        get() = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES

    private val cBg get() = if (isDark) 0xFF121214.toInt() else 0xFFF2F3F7.toInt()
    private val cCard get() = if (isDark) 0xFF1E1E21.toInt() else 0xFFFFFFFF.toInt()
    private val cFieldBg get() = if (isDark) 0xFF2A2A2E.toInt() else 0xFFF5F6FA.toInt()
    private val cBorder get() = if (isDark) 0xFF3A3A3F.toInt() else 0xFFE2E4EA.toInt()
    private val cText get() = if (isDark) 0xFFF2F2F5.toInt() else 0xFF1F1F1F.toInt()
    private val cSub get() = if (isDark) 0xFF9A9AA0.toInt() else 0xFF7A7D85.toInt()
    private val cAccent get() = if (isDark) 0xFF4AA374.toInt() else 0xFF52B17F.toInt()
    private val cWarn get() = 0xFFE68A00.toInt()
    private val cDanger get() = 0xFFE05252.toInt()

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()
    private fun dpf(v: Float) = v * resources.displayMetrics.density

    private fun roundBg(fill: Int, radiusDp: Float, strokeColor: Int = 0, strokeDp: Int = 0) = GradientDrawable().apply {
        setColor(fill)
        cornerRadius = dpf(radiusDp)
        if (strokeDp > 0) setStroke(dp(strokeDp), strokeColor)
    }

    private fun vertical() = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
    private fun horizontal() = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
    }

    private fun card(): LinearLayout = vertical().apply {
        background = roundBg(cCard, 14f, cBorder, 1)
        setPadding(dp(16), dp(14), dp(16), dp(16))
        layoutParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT,
        ).apply { bottomMargin = dp(14) }
    }

    private fun label(s: String, size: Float = 15f, color: Int = cText, bold: Boolean = false) = TextView(this).apply {
        text = s
        textSize = size
        setTextColor(color)
        if (bold) setTypeface(typeface, Typeface.BOLD)
    }

    private fun pillButton(
        s: String,
        primary: Boolean = true,
        danger: Boolean = false,
        onClick: () -> Unit,
    ) = TextView(this).apply {
        text = s
        textSize = 14f
        gravity = Gravity.CENTER
        setTypeface(typeface, Typeface.BOLD)
        setPadding(dp(16), dp(10), dp(16), dp(10))
        when {
            primary -> {
                setTextColor(Color.WHITE)
                background = roundBg(cAccent, 10f)
            }
            danger -> {
                setTextColor(cDanger)
                background = roundBg(Color.TRANSPARENT, 10f, cBorder, 1)
            }
            else -> {
                setTextColor(cText)
                background = roundBg(cFieldBg, 10f, cBorder, 1)
            }
        }
        setOnClickListener { onClick() }
    }

    private fun styledInput(hintText: String, type: Int) = EditText(this).apply {
        hint = hintText
        setHintTextColor(cSub)
        setTextColor(cText)
        textSize = 15f
        inputType = type
        isSingleLine = true
        background = roundBg(cFieldBg, 10f, cBorder, 1)
        setPadding(dp(12), dp(11), dp(12), dp(11))
        layoutParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT,
        ).apply { topMargin = dp(10) }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = "一炁输入法"
        val col = vertical().apply {
            setBackgroundColor(cBg)
            setPadding(dp(16), dp(16), dp(16), dp(28))
        }

        // 在线更新卡片
        updateCard = card().apply { visibility = View.GONE }
        updateText = label("", 15f, cText, true)
        updateButton = pillButton("下载并安装", primary = true) {}
        updateButton.layoutParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT,
            LinearLayout.LayoutParams.WRAP_CONTENT,
        ).apply { topMargin = dp(10) }
        updateCard.addView(updateText)
        updateCard.addView(updateButton)
        col.addView(updateCard)
        checkUpdate(manual = false)

        // C2: 输入方式卡片（分段胶囊切换）
        val schemeCard = card()
        schemeCard.addView(label("输入方式", 16f, cText, true))
        val segContainer = horizontal().apply {
            background = roundBg(cFieldBg, 10f, cBorder, 1)
            setPadding(dp(3), dp(3), dp(3), dp(3))
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = dp(12) }
        }
        segFlypy = TextView(this).apply {
            text = "小鹤双拼"
            textSize = 14f
            gravity = Gravity.CENTER
            setPadding(0, dp(9), 0, dp(9))
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            setOnClickListener { chooseScheme(FLYPY) }
        }
        segQuanpin = TextView(this).apply {
            text = "全拼"
            textSize = 14f
            gravity = Gravity.CENTER
            setPadding(0, dp(9), 0, dp(9))
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            setOnClickListener { chooseScheme(QUANPIN) }
        }
        segContainer.addView(segFlypy)
        segContainer.addView(segQuanpin)
        schemeCard.addView(segContainer)
        schemeCard.addView(
            label("打字时也可以点键盘右上方的「双 / 全」图标随时切换。", 12.5f, cSub).apply {
                setPadding(0, dp(10), 0, 0)
            },
        )
        col.addView(schemeCard)
        updateSchemeSegment(currentScheme())

        // C3, C5, C7: 剪贴板同步卡片
        val syncCard = card()
        syncCard.addView(label("剪贴板同步", 16f, cText, true))

        val statusRow = horizontal().apply {
            setPadding(0, dp(10), 0, dp(4))
        }
        statusDot = View(this).apply {
            layoutParams = LinearLayout.LayoutParams(dp(9), dp(9)).apply { marginEnd = dp(8) }
        }
        statusText = label("", 14f, cText)
        serverHostText = label("", 13f, cSub).apply {
            setPadding(dp(10), 0, 0, 0)
        }
        statusRow.addView(statusDot)
        statusRow.addView(statusText)
        statusRow.addView(serverHostText)
        syncCard.addView(statusRow)

        // 已配对视图
        paired = vertical()
        val pairedBtns = horizontal().apply { setPadding(0, dp(10), 0, 0) }
        val inviteBtn = pillButton("添加设备…", primary = true) { startInvite() }
        val leaveBtn = pillButton("退出同步组…", primary = false, danger = true) { leave() }.apply {
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { marginStart = dp(10) }
        }
        pairedBtns.addView(inviteBtn)
        pairedBtns.addView(leaveBtn)
        paired.addView(pairedBtns)
        paired.addView(
            label("要让电脑或另一台手机加入，点「添加设备」，会生成一个 6 位临时密码。", 12.5f, cSub).apply {
                setPadding(0, dp(10), 0, 0)
            },
        )
        syncCard.addView(paired)

        // 邀请视图
        invite = vertical().apply {
            background = roundBg(cFieldBg, 10f, cBorder, 1)
            setPadding(dp(14), dp(12), dp(14), dp(14))
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = dp(10) }
        }
        invite.addView(label("在新设备的一炁设置里填写：", 13f, cSub))
        inviteHost = label("", 14f, cText, true).apply { setPadding(0, dp(6), 0, 0) }
        inviteCode = label("", 32f, cAccent, true).apply {
            typeface = Typeface.MONOSPACE
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(0, dp(8), 0, dp(4))
        }
        inviteTimer = label("", 12.5f, cSub).apply { gravity = Gravity.CENTER_HORIZONTAL }
        val invActions = horizontal().apply {
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(0, dp(12), 0, 0)
        }
        invActions.addView(pillButton("完成", primary = true) { stopInvite() })
        invActions.addView(
            pillButton("重新生成", primary = false) { startInvite() }.apply {
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                ).apply { marginStart = dp(10) }
            },
        )
        invite.addView(inviteHost)
        invite.addView(inviteCode)
        invite.addView(inviteTimer)
        invite.addView(invActions)
        syncCard.addView(invite)

        // 未配对视图
        unpaired = vertical()
        val server = styledInput("服务器地址，例如 yiqi.example.com", InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI)
        val code = styledInput("6 位临时密码", InputType.TYPE_CLASS_NUMBER)
        unpaired.addView(server)
        unpaired.addView(code)
        val joinBtn = pillButton("加入同步组", primary = true) { pair(false, server.text.toString(), code.text.toString()) }.apply {
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = dp(12) }
        }
        unpaired.addView(joinBtn)
        unpaired.addView(label("临时密码在已同步的设备上点「添加设备」获得。", 12f, cSub).apply { setPadding(0, dp(6), 0, 0) })
        val regBtn = pillButton("注册新同步组", primary = false) { pair(true, server.text.toString(), code.text.toString()) }.apply {
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = dp(12) }
        }
        unpaired.addView(regBtn)
        unpaired.addView(
            label("第一台设备用这个；临时密码在服务器上运行 yiqi-relay code 生成，10 分钟内有效。", 12f, cSub).apply {
                setPadding(0, dp(6), 0, 0)
            },
        )
        syncCard.addView(unpaired)

        message = label("", 13.5f, cWarn).apply {
            setPadding(0, dp(10), 0, 0)
            visibility = View.GONE
        }
        syncCard.addView(message)
        syncCard.addView(
            label(
                "同步后，电脑复制的文字会加密传到手机：打开键盘时顶部会出现卡片提示，点一下即可输入，也可长按「粘贴」。手机复制的文字同样会同步到电脑。",
                12.5f,
                cSub,
            ).apply { setPadding(0, dp(12), 0, 0) },
        )
        col.addView(syncCard)

        // 底部版本与手动检查更新
        val footer = horizontal().apply { setPadding(dp(4), dp(2), dp(4), 0) }
        updateStatus = label("", 12.5f, cSub).apply {
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        val verText = label("版本 ${QiUpdate.current}", 12.5f, cSub).apply {
            setPadding(0, 0, dp(12), 0)
        }
        val checkBtn = pillButton("检查更新", primary = false) { checkUpdate(manual = true) }.apply {
            textSize = 13f
            setPadding(dp(12), dp(6), dp(12), dp(6))
        }
        footer.addView(updateStatus)
        footer.addView(verText)
        footer.addView(checkBtn)
        col.addView(footer)
        col.addView(
            CheckBox(this).apply {
                text = "接受测试版更新"
                textSize = 13f
                setTextColor(cSub)
                isChecked = QiUpdate.betaEnabled(this@QiSyncActivity)
                setPadding(dp(4), dp(4), dp(4), 0)
                setOnCheckedChangeListener { _, on ->
                    QiUpdate.setBetaEnabled(this@QiSyncActivity, on)
                    checkUpdate(manual = true)
                }
            },
        )

        val scroll = ScrollView(this).apply {
            setBackgroundColor(cBg)
            isFillViewport = true
            addView(col)
        }
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

    private fun chooseScheme(id: String) {
        requestScheme(id)
        updateSchemeSegment(id)
    }

    private fun updateSchemeSegment(current: String) {
        val flypy = current != QUANPIN
        segFlypy.background = if (flypy) roundBg(cAccent, 8f) else null
        segFlypy.setTextColor(if (flypy) Color.WHITE else cText)
        segFlypy.setTypeface(null, if (flypy) Typeface.BOLD else Typeface.NORMAL)

        segQuanpin.background = if (!flypy) roundBg(cAccent, 8f) else null
        segQuanpin.setTextColor(if (!flypy) Color.WHITE else cText)
        segQuanpin.setTypeface(null, if (!flypy) Typeface.BOLD else Typeface.NORMAL)
    }

    private fun setMessage(s: String) {
        message.text = s
        message.visibility = if (s.isEmpty()) View.GONE else View.VISIBLE
    }

    private fun checkUpdate(manual: Boolean) {
        if (manual) updateStatus.text = "正在检查…"
        lifecycleScope.launch {
            val (r, ok) = withContext(Dispatchers.IO) { QiUpdate.checkWithStatus(this@QiSyncActivity) }
            if (r == null) {
                updateCard.visibility = View.GONE
                if (manual) updateStatus.text = if (ok) "已是最新版本" else "暂时无法检查更新"
                return@launch
            }
            updateStatus.text = ""
            updateText.text = "有新版本 ${r.version}（当前 ${QiUpdate.current}）"
            updateCard.visibility = View.VISIBLE
            updateButton.setOnClickListener {
                updateButton.isEnabled = false
                updateText.text = "正在下载 ${r.version}…"
                lifecycleScope.launch {
                    val apk = withContext(Dispatchers.IO) { QiUpdate.download(this@QiSyncActivity, r) }
                    updateButton.isEnabled = true
                    if (apk == null) {
                        updateText.text = "下载失败，请稍后重试"
                    } else {
                        updateText.text = "有新版本 ${r.version}，请在弹出的窗口里点「更新」"
                        QiUpdate.install(this@QiSyncActivity, apk)
                    }
                }
            }
        }
    }

    private fun refresh() {
        val st = QiSync.status.value
        val dotColor = when (st) {
            QiSync.Status.Connected -> cAccent
            QiSync.Status.Unpaired -> 0xFF8E8E93.toInt()
            else -> cWarn
        }
        statusDot.background = roundBg(dotColor, 5f)
        statusText.text = st.label
        val host = QiSync.server?.let { android.net.Uri.parse(it).host }
        serverHostText.text = host ?: ""
        serverHostText.visibility = if (host.isNullOrEmpty()) View.GONE else View.VISIBLE

        val isPaired = QiSync.server != null
        val inviting = QiSync.inviteCode != null
        unpaired.visibility = if (isPaired) View.GONE else View.VISIBLE
        paired.visibility = if (isPaired && !inviting) View.VISIBLE else View.GONE
        invite.visibility = if (isPaired && inviting) View.VISIBLE else View.GONE
    }

    private fun pair(register: Boolean, server: String, code: String) {
        setMessage(if (register) "正在注册…" else "正在加入…")
        lifecycleScope.launch {
            val r = withContext(Dispatchers.IO) {
                if (register) QiPairing.register(server, code) else QiPairing.join(server, code)
            }
            when (r) {
                is QiPairing.Outcome.Ok -> {
                    QiSync.save(r.key)
                    setMessage("")
                }
                is QiPairing.Outcome.Fail -> setMessage(r.message)
            }
            refresh()
        }
    }

    private fun startInvite() {
        val code = QiSync.startInvite() ?: run {
            setMessage("需要先连上服务器才能添加设备。")
            return
        }
        val host = QiSync.server?.let { android.net.Uri.parse(it).host } ?: ""
        inviteHost.text = "服务器地址  $host"
        inviteCode.text = "${code.take(3)} ${code.takeLast(3)}"
        timer?.cancel()
        timer = object : CountDownTimer(300_000, 1000) {
            override fun onTick(left: Long) {
                val s = left / 1000
                inviteTimer.text = "${s / 60}:${String.format(java.util.Locale.ROOT, "%02d", s % 60)} 内有效，请保持此页面打开"
            }

            override fun onFinish() = stopInvite()
        }.start()
        setMessage("")
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
        const val FLYPY = "rime_frost_double_pinyin_flypy"
        const val QUANPIN = "rime_frost"
        private val stateFile get() = File(DataManager.userDataDir, "qi_schema.txt")

        fun currentScheme(): String = runCatching { stateFile.readText().trim().split(" ").first() }.getOrNull()
            ?.takeIf { it == FLYPY || it == QUANPIN } ?: FLYPY

        fun requestScheme(id: String) {
            stateFile.writeText("$id ui-${System.currentTimeMillis()}\n")
        }
    }
}
