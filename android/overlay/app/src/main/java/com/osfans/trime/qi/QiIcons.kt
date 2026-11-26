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
        )
    }

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        strokeWidth = 1.5f
        strokeJoin = Paint.Join.ROUND
        strokeCap = Paint.Cap.ROUND
    }

    fun has(name: String) = name in shapes

    fun draw(canvas: Canvas, name: String, cx: Float, cy: Float, size: Float, color: Int) {
        val parts = shapes[name] ?: return
        paint.color = color
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
