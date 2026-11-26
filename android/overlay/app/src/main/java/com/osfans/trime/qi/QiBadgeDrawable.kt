package com.osfans.trime.qi

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorFilter
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.Drawable

// C2: 工具栏右侧紧凑的「双 / 全」圆角线框徽标图标，使用系统字体绘制以保证清晰且不被资源压缩移除。
class QiBadgeDrawable(
    context: Context,
    private val glyph: String,
) : Drawable() {
    private val density = context.resources.displayMetrics.density
    private val sizePx = (18f * density).toInt()

    private var tintList: ColorStateList? = null
    private var currentColor: Int = Color.BLACK

    private val strokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 1.4f * density
        strokeJoin = Paint.Join.ROUND
        color = currentColor
    }

    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        textAlign = Paint.Align.LEFT
        textSize = 11f * density
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        color = currentColor
    }

    private val box = RectF()
    private val ink = Rect()

    override fun getIntrinsicWidth(): Int = sizePx
    override fun getIntrinsicHeight(): Int = sizePx

    override fun setTint(tintColor: Int) {
        tintList = ColorStateList.valueOf(tintColor)
        updateColor(state)
    }

    override fun setTintList(tint: ColorStateList?) {
        tintList = tint
        updateColor(state)
    }

    override fun isStateful(): Boolean = tintList?.isStateful == true

    override fun onStateChange(state: IntArray): Boolean = updateColor(state)

    private fun updateColor(state: IntArray): Boolean {
        val def = tintList?.defaultColor ?: currentColor
        val c = tintList?.getColorForState(state, def) ?: currentColor
        if (c == currentColor) return false
        currentColor = c
        strokePaint.color = c
        textPaint.color = c
        invalidateSelf()
        return true
    }

    override fun draw(canvas: Canvas) {
        val b = bounds
        val side = minOf(b.width(), b.height()).toFloat()
        if (side <= 0f) return
        val half = side / 2f
        val cx = b.exactCenterX()
        val cy = b.exactCenterY()
        val inset = strokePaint.strokeWidth / 2f + 0.5f * density
        box.set(cx - half + inset, cy - half + inset, cx + half - inset, cy + half - inset)
        val r = 4.2f * density
        canvas.drawRoundRect(box, r, r, strokePaint)

        textPaint.textSize = side * 0.58f
        textPaint.getTextBounds(glyph, 0, glyph.length, ink)
        canvas.drawText(glyph, cx - ink.exactCenterX(), cy - ink.exactCenterY(), textPaint)
    }

    override fun setAlpha(alpha: Int) {
        strokePaint.alpha = alpha
        textPaint.alpha = alpha
    }

    override fun setColorFilter(colorFilter: ColorFilter?) {
        strokePaint.colorFilter = colorFilter
        textPaint.colorFilter = colorFilter
    }

    @Deprecated("Deprecated in Java")
    override fun getOpacity(): Int = PixelFormat.TRANSLUCENT
}
