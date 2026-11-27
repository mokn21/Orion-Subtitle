package com.orion.subtitles.tv

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

class OverlayGeometryTest {
    @Test
    fun mapsBottomLeftVisionCoordinatesToTopLeftScreenCoordinates() {
        val rect = OverlayGeometry.toScreenRect(
            x = 0.10, y = 0.20, width = 0.30, height = 0.10,
            screenWidth = 1920, screenHeight = 1080
        )
        assertNotNull(rect)
        assertEquals(192, rect!!.left)
        assertEquals(756, rect.top)
        assertEquals(576, rect.width)
        assertEquals(108, rect.height)
    }

    @Test
    fun letterboxesVideoWhenDisplayIsWiderThanSixteenByNine() {
        val rect = OverlayGeometry.toScreenRect(
            x = 0.0, y = 0.0, width = 1.0, height = 1.0,
            screenWidth = 2560, screenHeight = 1080
        )
        assertNotNull(rect)
        assertEquals(320, rect!!.left)
        assertEquals(0, rect.top)
        assertEquals(1920, rect.width)
        assertEquals(1080, rect.height)
    }

    @Test
    fun rejectsInvalidRectangles() {
        assertEquals(null, OverlayGeometry.toScreenRect(
            x = Double.NaN, y = 0.0, width = 0.2, height = 0.2,
            screenWidth = 1920, screenHeight = 1080
        ))
    }
}
