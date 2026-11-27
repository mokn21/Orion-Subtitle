package com.orion.subtitles.tv

import kotlin.math.max
import kotlin.math.min

data class PixelRect(val left: Int, val top: Int, val width: Int, val height: Int)

object OverlayGeometry {
    enum class DisplayMode { FIT, ZOOM }

    /**
     * Maps Vision's normalized bottom-left rectangle into the TV display.
     * The video source is 16:9, matching the PS Remote Play frame geometry.
     */
    fun toScreenRect(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        screenWidth: Int,
        screenHeight: Int,
        videoAspect: Double = 16.0 / 9.0,
        mode: DisplayMode = DisplayMode.FIT
    ): PixelRect? {
        if (screenWidth <= 0 || screenHeight <= 0 || videoAspect <= 0.0) return null
        if (!listOf(x, y, width, height).all { it.isFinite() }) return null
        if (width <= 0.0 || height <= 0.0) return null

        val candidateHeight = screenWidth / videoAspect
        val videoHeight = when (mode) {
            DisplayMode.FIT -> min(screenHeight.toDouble(), candidateHeight)
            DisplayMode.ZOOM -> max(screenHeight.toDouble(), candidateHeight)
        }
        val videoWidth = videoHeight * videoAspect
        val originX = (screenWidth - videoWidth) / 2.0
        val originY = (screenHeight - videoHeight) / 2.0

        val left = originX + x.coerceIn(0.0, 1.0) * videoWidth
        // Vision coordinates start at bottom-left; Android screen coordinates start at top-left.
        val top = originY + (1.0 - (y + height).coerceIn(0.0, 1.0)) * videoHeight
        val right = originX + (x + width).coerceIn(0.0, 1.0) * videoWidth
        val bottom = originY + (1.0 - y.coerceIn(0.0, 1.0)) * videoHeight

        val l = left.toInt().coerceIn(0, screenWidth - 1)
        val t = top.toInt().coerceIn(0, screenHeight - 1)
        val r = right.toInt().coerceIn(l + 1, screenWidth)
        val b = bottom.toInt().coerceIn(t + 1, screenHeight)
        return PixelRect(l, t, r - l, b - t)
    }
}
