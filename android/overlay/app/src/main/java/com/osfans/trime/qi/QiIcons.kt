package com.osfans.trime.qi

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import androidx.core.graphics.PathParser

object QiIcons {
    private const val ARROW = "M12 3.9 L4.3 12.1 H8.9 V17.6 H15.1 V12.1 H19.7 Z"
    private const val TAG = "M9.2 5.6 H19.4 A2 2 0 0 1 21.4 7.6 V16.4 A2 2 0 0 1 19.4 18.4 H9.2 L2.8 12 Z"
    private const val CROSS = "M11.8 9.4 L16.6 14.6 M16.6 9.4 L11.8 14.6"

    private val shapes: Map<String, List<Pair<Path, Boolean>>> by lazy {
        fun p(d: String, fill: Boolean) = PathParser.createPathFromPathData(d) to fill
        mapOf(
            "qi_shift" to listOf(p(ARROW, false)),
            "qi_shift_on" to listOf(p(ARROW, true)),
            "qi_shift_lock" to listOf(p(ARROW, true), p("M8.9 21 H15.1", false)),
            "qi_backspace" to listOf(p(TAG, false), p(CROSS, false)),
            "qi_back" to listOf(p("M20 12 H4.8 M11 5.8 L4.8 12 L11 18.2", false)),
            "qi_emoji" to listOf(
                p("M12 3.2 A8.8 8.8 0 1 1 11.99 3.2 Z", false),
                p("M9 9.8 H9.01 M15 9.8 H15.01", false),
                p("M8.2 14 Q12 18.2 15.8 14", false),
            ),
        )
    }

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        strokeWidth = 1.5f
        strokeJoin = Paint.Join.ROUND
        strokeCap = Paint.Cap.ROUND
    }

    fun has(name: String) = name == "qi_pad" || name in shapes

    fun draw(canvas: Canvas, name: String, cx: Float, cy: Float, size: Float, color: Int) {
        paint.color = color
        if (name == "qi_pad") {
            paint.style = Paint.Style.FILL
            paint.textAlign = Paint.Align.CENTER
            paint.textSize = size * 0.46f
            paint.typeface = android.graphics.Typeface.DEFAULT_BOLD
            canvas.drawText("12", cx, cy - size * 0.04f, paint)
            canvas.drawText("34", cx, cy + size * 0.40f, paint)
            return
        }
        val parts = shapes[name] ?: return
        canvas.save()
        canvas.translate(cx - size / 2, cy - size / 2)
        canvas.scale(size / 24f, size / 24f)
        for ((path, fill) in parts) {
            paint.style = if (fill) Paint.Style.FILL_AND_STROKE else Paint.Style.STROKE
            canvas.drawPath(path, paint)
        }
        canvas.restore()
    }
}
