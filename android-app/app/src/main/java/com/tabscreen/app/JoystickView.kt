package com.tabscreen.app

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.View

class JoystickView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : View(context, attrs, defStyleAttr) {

    private var baseRadius = 0f
    private var knobRadius = 0f
    private var centerX = 0f
    private var centerY = 0f
    private var knobX = 0f
    private var knobY = 0f

    var onMoveListener: ((normalizedX: Float, normalizedY: Float) -> Unit)? = null
    var onReleaseListener: (() -> Unit)? = null

    private val basePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#441A1A24")
        style = Paint.Style.FILL
    }
    private val baseBorderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#665A5A72")
        style = Paint.Style.STROKE
        strokeWidth = 3f
    }
    private val crosshairPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#33FFFFFF")
        style = Paint.Style.STROKE
        strokeWidth = 2f
    }
    private val knobPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#0A84FF")
        style = Paint.Style.FILL
    }
    private val knobBorderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#CCFFFFFF")
        style = Paint.Style.STROKE
        strokeWidth = 2.5f
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        centerX = w / 2f
        centerY = h / 2f
        knobX = centerX
        knobY = centerY
        baseRadius = kotlin.math.min(w, h) / 2f - 8f
        knobRadius = baseRadius * 0.40f
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        canvas.drawCircle(centerX, centerY, baseRadius, basePaint)
        canvas.drawCircle(centerX, centerY, baseRadius, baseBorderPaint)

        canvas.drawLine(centerX - baseRadius * 0.45f, centerY, centerX + baseRadius * 0.45f, centerY, crosshairPaint)
        canvas.drawLine(centerX, centerY - baseRadius * 0.45f, centerX, centerY + baseRadius * 0.45f, crosshairPaint)

        canvas.drawCircle(knobX, knobY, knobRadius, knobPaint)
        canvas.drawCircle(knobX, knobY, knobRadius, knobBorderPaint)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_MOVE -> {
                val dx = event.x - centerX
                val dy = event.y - centerY
                val dist = kotlin.math.hypot(dx.toDouble(), dy.toDouble()).toFloat()
                val maxDist = (baseRadius - knobRadius).coerceAtLeast(1f)

                if (dist <= maxDist) {
                    knobX = event.x
                    knobY = event.y
                } else {
                    knobX = centerX + (dx / dist) * maxDist
                    knobY = centerY + (dy / dist) * maxDist
                }

                val normX = ((knobX - centerX) / maxDist).coerceIn(-1f, 1f)
                val normY = ((knobY - centerY) / maxDist).coerceIn(-1f, 1f)
                onMoveListener?.invoke(normX, normY)
                invalidate()
                return true
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                knobX = centerX
                knobY = centerY
                onReleaseListener?.invoke()
                invalidate()
                return true
            }
        }
        return super.onTouchEvent(event)
    }
}
