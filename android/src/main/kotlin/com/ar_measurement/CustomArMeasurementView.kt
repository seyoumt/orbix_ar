package com.ar_measurement

import android.app.Activity
import android.content.Context
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import android.opengl.Matrix
import android.os.Build
import android.view.MotionEvent
import android.view.WindowManager
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import com.google.ar.core.Anchor
import com.google.ar.core.ArCoreApk
import com.google.ar.core.Config
import com.google.ar.core.Frame
import com.google.ar.core.Plane
import com.google.ar.core.Pose
import com.google.ar.core.Session
import com.google.ar.core.TrackingState
import com.google.ar.core.exceptions.CameraNotAvailableException
import com.google.ar.core.exceptions.SessionPausedException
import com.google.ar.core.exceptions.UnavailableException
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10

/**
 * Thin ARCore + GLES measurement view (hello_ar-inspired).
 * Owns the GL context on the GLSurfaceView thread so Hybrid Composition stays viable.
 *
 * Session API calls are synchronized; [Session.update] runs only from [onDrawFrame].
 * Markers/lines use ARCore [Anchor]s so poses stay fixed as tracking refines.
 */
class CustomArMeasurementView(
    private val activity: Activity,
    context: Context,
    messenger: BinaryMessenger,
    viewId: Int,
) : GLSurfaceView(context), GLSurfaceView.Renderer, MethodChannel.MethodCallHandler {

    private data class LineAnchors(val start: Anchor, val end: Anchor)

    private val channel = MethodChannel(messenger, "ar_measurement/custom_$viewId")
    private val sessionLock = Any()
    private var session: Session? = null
    private var installRequested = false
    private val markers = ConcurrentHashMap<String, Anchor>()
    private val lines = ConcurrentHashMap<String, LineAnchors>()
    /**
     * Plane-hit anchor from the latest tap. Consumed by [addMarker] only when the
     * requested point is near the hit (so a complete-flow start marker does not
     * steal the end-tap anchor).
     */
    private var pendingHitAnchor: Anchor? = null
    /** Held briefly when a `pending_*` marker is removed so complete can reclaim it. */
    private var recycledPendingAnchor: Anchor? = null
    private var markerProgram = 0
    private var cameraProgram = 0
    private var positionHandle = 0
    private var colorHandle = 0
    private var mvpHandle = 0
    private var cameraTextureId = -1
    private var boundCameraTextureId = -1
    private var cameraPositionHandle = 0
    private var cameraTexCoordHandle = 0
    private var cameraTextureUniform = 0
    private var displayRotation = 0
    private var viewportWidth = 1
    private var viewportHeight = 1
    private val projectionMatrix = FloatArray(16)
    private val viewMatrix = FloatArray(16)
    private val mvpMatrix = FloatArray(16)
    private val destroyed = AtomicBoolean(false)
    private val pendingTap = AtomicReference<FloatArray?>(null)
    /** One-shot: first TRACKING plane → Dart coaching can end. */
    private val trackingReadyEmitted = AtomicBoolean(false)
    /** Dart-requested thermal idle pause; Activity resume must not fight it. */
    private val idlePaused = AtomicBoolean(false)

    // Instance-local UV / geometry scratch (not shared across views).
    private val quadCoordsBuffer: FloatBuffer = directFloatBuffer(
        floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f),
    )
    private val quadTexCoordsBuffer: FloatBuffer = directFloatBuffer(
        floatArrayOf(0f, 1f, 1f, 1f, 0f, 0f, 1f, 0f),
    )
    private val texCoordsBuffer: FloatBuffer = directFloatBuffer(
        floatArrayOf(0f, 1f, 1f, 1f, 0f, 0f, 1f, 0f),
    )
    private val lineScratch = directFloatBuffer(FloatArray(6))
    private val sphereScratch = directFloatBuffer(FloatArray(72)) // 24 verts * 3

    private val lifecycleObserver = object : DefaultLifecycleObserver {
        override fun onResume(owner: LifecycleOwner) {
            if (idlePaused.get()) return
            this@CustomArMeasurementView.onResume()
        }

        override fun onPause(owner: LifecycleOwner) {
            this@CustomArMeasurementView.onPause()
        }
    }

    init {
        channel.setMethodCallHandler(this)
        setEGLContextClientVersion(2)
        // RGB888 + 16-bit depth so marker depth testing works.
        setEGLConfigChooser(8, 8, 8, 8, 16, 0)
        preserveEGLContextOnPause = true
        setRenderer(this)
        renderMode = RENDERMODE_CONTINUOUSLY
        keepScreenOn = true
        (activity as? LifecycleOwner)?.lifecycle?.addObserver(lifecycleObserver)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "addMarker" -> {
                val id = call.argument<String>("id")
                val x = call.argument<Double>("x")
                val y = call.argument<Double>("y")
                val z = call.argument<Double>("z")
                if (id == null || x == null || y == null || z == null) {
                    result.error("bad_args", "addMarker requires id,x,y,z", null)
                    return
                }
                val ok = synchronized(sessionLock) {
                    addMarkerLocked(id, x.toFloat(), y.toFloat(), z.toFloat())
                }
                if (ok) {
                    result.success(null)
                } else {
                    result.error("no_session", "AR session not ready for anchor", null)
                }
            }
            "addLine" -> {
                val id = call.argument<String>("id")
                val x0 = call.argument<Double>("x0")
                val y0 = call.argument<Double>("y0")
                val z0 = call.argument<Double>("z0")
                val x1 = call.argument<Double>("x1")
                val y1 = call.argument<Double>("y1")
                val z1 = call.argument<Double>("z1")
                if (id == null || x0 == null || y0 == null || z0 == null ||
                    x1 == null || y1 == null || z1 == null
                ) {
                    result.error("bad_args", "addLine requires id,x0,y0,z0,x1,y1,z1", null)
                    return
                }
                val ok = synchronized(sessionLock) {
                    addLineLocked(
                        id,
                        x0.toFloat(), y0.toFloat(), z0.toFloat(),
                        x1.toFloat(), y1.toFloat(), z1.toFloat(),
                    )
                }
                if (ok) {
                    result.success(null)
                } else {
                    result.error("no_session", "AR session not ready for anchor", null)
                }
            }
            "remove" -> {
                val id = call.argument<String>("id")
                if (id == null) {
                    result.error("bad_args", "remove requires id", null)
                    return
                }
                synchronized(sessionLock) {
                    removeVisualLocked(id)
                }
                result.success(null)
            }
            "clear" -> {
                synchronized(sessionLock) {
                    clearAnchorsLocked()
                }
                result.success(null)
            }
            "pauseTracking" -> {
                pauseTrackingForIdle()
                result.success(null)
            }
            "resumeTracking" -> {
                resumeTrackingFromIdle()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun pauseTrackingForIdle() {
        if (destroyed.get()) return
        if (!idlePaused.compareAndSet(false, true)) return
        keepScreenOn = false
        onPause()
    }

    private fun resumeTrackingFromIdle() {
        if (destroyed.get()) return
        idlePaused.set(false)
        trackingReadyEmitted.set(false)
        keepScreenOn = true
        onResume()
    }

    private fun addMarkerLocked(id: String, x: Float, y: Float, z: Float): Boolean {
        val session = session ?: return false
        removeMarkerLocked(id)
        val anchor = takeMatchingAnchorLocked(x, y, z)
            ?: try {
                session.createAnchor(Pose.makeTranslation(x, y, z))
            } catch (_: Exception) {
                return false
            }
        markers[id] = anchor
        return true
    }

    /** Prefer plane-hit, then a recycled pending marker, else null. */
    private fun takeMatchingAnchorLocked(x: Float, y: Float, z: Float): Anchor? {
        val fromHit = pendingHitAnchor
        if (fromHit != null && poseNear(fromHit, x, y, z)) {
            pendingHitAnchor = null
            return fromHit
        }
        val recycled = recycledPendingAnchor
        if (recycled != null && poseNear(recycled, x, y, z)) {
            recycledPendingAnchor = null
            return recycled
        }
        return null
    }

    private fun poseNear(anchor: Anchor, x: Float, y: Float, z: Float, epsMeters: Float = 0.04f): Boolean {
        return try {
            if (anchor.trackingState == TrackingState.STOPPED) return false
            val t = anchor.pose.translation
            val dx = t[0] - x
            val dy = t[1] - y
            val dz = t[2] - z
            dx * dx + dy * dy + dz * dz <= epsMeters * epsMeters
        } catch (_: Exception) {
            false
        }
    }

    private fun addLineLocked(
        id: String,
        x0: Float,
        y0: Float,
        z0: Float,
        x1: Float,
        y1: Float,
        z1: Float,
    ): Boolean {
        val session = session ?: return false
        removeLineLocked(id)
        var start: Anchor? = null
        return try {
            start = session.createAnchor(Pose.makeTranslation(x0, y0, z0))
            val end = session.createAnchor(Pose.makeTranslation(x1, y1, z1))
            lines[id] = LineAnchors(start!!, end)
            true
        } catch (_: Exception) {
            start?.let { detachQuietly(it) }
            false
        }
    }

    private fun removeVisualLocked(id: String) {
        removeMarkerLocked(id)
        removeLineLocked(id)
    }

    private fun removeMarkerLocked(id: String) {
        val removed = markers.remove(id) ?: return
        // Keep pending-tap anchors so completing a pair can reclaim the start hit.
        if (id.startsWith("pending_")) {
            recycledPendingAnchor?.let { detachQuietly(it) }
            recycledPendingAnchor = removed
        } else {
            detachQuietly(removed)
        }
    }

    private fun removeLineLocked(id: String) {
        lines.remove(id)?.let {
            detachQuietly(it.start)
            detachQuietly(it.end)
        }
    }

    private fun clearAnchorsLocked() {
        for (anchor in markers.values) {
            detachQuietly(anchor)
        }
        markers.clear()
        for (line in lines.values) {
            detachQuietly(line.start)
            detachQuietly(line.end)
        }
        lines.clear()
        pendingHitAnchor?.let { detachQuietly(it) }
        pendingHitAnchor = null
        recycledPendingAnchor?.let { detachQuietly(it) }
        recycledPendingAnchor = null
        // Allow a new session to re-emit coaching ready after clearVisuals.
        trackingReadyEmitted.set(false)
    }

    private fun detachQuietly(anchor: Anchor) {
        try {
            anchor.detach()
        } catch (_: Exception) {
        }
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (event.action == MotionEvent.ACTION_UP) {
            // Capture coords before MotionEvent may be recycled.
            pendingTap.set(floatArrayOf(event.x, event.y))
        }
        return true
    }

    /** Hit-test against [frame] only — never calls [Session.update]. */
    private fun hitTest(frame: Frame, x: Float, y: Float) {
        if (frame.camera.trackingState != TrackingState.TRACKING) return
        val hits = frame.hitTest(x, y)
        for (hit in hits) {
            val trackable = hit.trackable
            if (trackable is Plane &&
                trackable.trackingState == TrackingState.TRACKING &&
                trackable.isPoseInPolygon(hit.hitPose)
            ) {
                synchronized(sessionLock) {
                    pendingHitAnchor?.let { detachQuietly(it) }
                    pendingHitAnchor = try {
                        hit.createAnchor()
                    } catch (_: Exception) {
                        null
                    }
                }
                emitTap(hit.hitPose.translation)
                return
            }
        }
    }

    private fun emitTap(t: FloatArray) {
        activity.runOnUiThread {
            if (destroyed.get()) return@runOnUiThread
            channel.invokeMethod(
                "onTap",
                mapOf("x" to t[0].toDouble(), "y" to t[1].toDouble(), "z" to t[2].toDouble()),
            )
        }
    }

    private fun emitTrackingReady() {
        activity.runOnUiThread {
            if (destroyed.get()) return@runOnUiThread
            channel.invokeMethod("onTrackingReady", null)
        }
    }

    private fun emitError(message: String) {
        activity.runOnUiThread {
            if (destroyed.get()) return@runOnUiThread
            channel.invokeMethod("onError", message)
        }
    }

    private fun maybeEmitTrackingReady(frame: Frame) {
        if (trackingReadyEmitted.get()) return
        if (frame.camera.trackingState != TrackingState.TRACKING) return
        val planes = frame.getUpdatedTrackables(Plane::class.java)
        var hasTrackingPlane = false
        for (plane in planes) {
            if (plane.trackingState == TrackingState.TRACKING) {
                hasTrackingPlane = true
                break
            }
        }
        // updatedTrackables can miss already-known planes; also scan all.
        if (!hasTrackingPlane) {
            val session = synchronized(sessionLock) { session } ?: return
            try {
                for (plane in session.getAllTrackables(Plane::class.java)) {
                    if (plane.trackingState == TrackingState.TRACKING) {
                        hasTrackingPlane = true
                        break
                    }
                }
            } catch (_: Exception) {
                return
            }
        }
        if (hasTrackingPlane && trackingReadyEmitted.compareAndSet(false, true)) {
            emitTrackingReady()
        }
    }

    override fun onResume() {
        if (destroyed.get() || idlePaused.get()) return
        super.onResume()
        synchronized(sessionLock) {
            ensureSessionLocked()
            try {
                session?.resume()
            } catch (e: CameraNotAvailableException) {
                closeSessionLocked()
                emitError("Camera not available: ${e.message}")
            }
        }
    }

    override fun onPause() {
        synchronized(sessionLock) {
            try {
                session?.pause()
            } catch (_: Exception) {
            }
        }
        super.onPause()
    }

    fun destroy() {
        if (!destroyed.compareAndSet(false, true)) return
        (activity as? LifecycleOwner)?.lifecycle?.removeObserver(lifecycleObserver)
        channel.setMethodCallHandler(null)
        keepScreenOn = false
        onPause()
        queueEvent {
            synchronized(sessionLock) {
                closeSessionLocked()
            }
            deleteGlResources()
        }
    }

    private fun closeSessionLocked() {
        clearAnchorsLocked()
        try {
            session?.close()
        } catch (_: Exception) {
        }
        session = null
        boundCameraTextureId = -1
    }

    private fun deleteGlResources() {
        if (cameraTextureId >= 0) {
            GLES20.glDeleteTextures(1, intArrayOf(cameraTextureId), 0)
            cameraTextureId = -1
        }
        if (cameraProgram != 0) {
            GLES20.glDeleteProgram(cameraProgram)
            cameraProgram = 0
        }
        if (markerProgram != 0) {
            GLES20.glDeleteProgram(markerProgram)
            markerProgram = 0
        }
    }

    private fun ensureSessionLocked() {
        if (session != null || destroyed.get()) return
        try {
            when (ArCoreApk.getInstance().requestInstall(activity, !installRequested)) {
                ArCoreApk.InstallStatus.INSTALL_REQUESTED -> {
                    installRequested = true
                    emitError("ARCore install or update required")
                    return
                }
                ArCoreApk.InstallStatus.INSTALLED -> {}
            }
            val newSession = Session(activity)
            val config = Config(newSession)
            config.updateMode = Config.UpdateMode.LATEST_CAMERA_IMAGE
            config.planeFindingMode = Config.PlaneFindingMode.HORIZONTAL_AND_VERTICAL
            config.lightEstimationMode = Config.LightEstimationMode.DISABLED
            config.instantPlacementMode = Config.InstantPlacementMode.DISABLED
            newSession.configure(config)
            session = newSession
            if (cameraTextureId >= 0) {
                newSession.setCameraTextureName(cameraTextureId)
                boundCameraTextureId = cameraTextureId
            }
            newSession.setDisplayGeometry(displayRotation, viewportWidth, viewportHeight)
        } catch (e: UnavailableException) {
            closeSessionLocked()
            emitError("ARCore unavailable: ${e.message}")
        } catch (e: Exception) {
            closeSessionLocked()
            emitError("Failed to create AR session: ${e.message}")
        }
    }

    override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        if (destroyed.get()) return
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        cameraTextureId = textures[0]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, cameraTextureId)
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_WRAP_S,
            GLES20.GL_CLAMP_TO_EDGE,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_WRAP_T,
            GLES20.GL_CLAMP_TO_EDGE,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_MIN_FILTER,
            GLES20.GL_LINEAR,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_MAG_FILTER,
            GLES20.GL_LINEAR,
        )

        cameraProgram = createProgram(CAMERA_VERTEX, CAMERA_FRAGMENT)
        if (cameraProgram == 0) {
            emitError("Failed to compile camera shaders")
            return
        }
        cameraPositionHandle = GLES20.glGetAttribLocation(cameraProgram, "a_Position")
        cameraTexCoordHandle = GLES20.glGetAttribLocation(cameraProgram, "a_TexCoord")
        cameraTextureUniform = GLES20.glGetUniformLocation(cameraProgram, "u_Texture")

        markerProgram = createProgram(VERTEX_SHADER, FRAGMENT_SHADER)
        if (markerProgram == 0) {
            emitError("Failed to compile marker shaders")
            return
        }
        positionHandle = GLES20.glGetAttribLocation(markerProgram, "a_Position")
        colorHandle = GLES20.glGetUniformLocation(markerProgram, "u_Color")
        mvpHandle = GLES20.glGetUniformLocation(markerProgram, "u_MVP")

        synchronized(sessionLock) {
            session?.let {
                it.setCameraTextureName(cameraTextureId)
                boundCameraTextureId = cameraTextureId
            }
        }
    }

    override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
        if (destroyed.get()) return
        viewportWidth = width.coerceAtLeast(1)
        viewportHeight = height.coerceAtLeast(1)
        GLES20.glViewport(0, 0, viewportWidth, viewportHeight)
        displayRotation = currentDisplayRotation()
        synchronized(sessionLock) {
            session?.setDisplayGeometry(displayRotation, viewportWidth, viewportHeight)
        }
    }

    override fun onDrawFrame(gl: GL10?) {
        if (destroyed.get() || idlePaused.get()) return
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT or GLES20.GL_DEPTH_BUFFER_BIT)
        val frame: Frame
        synchronized(sessionLock) {
            if (idlePaused.get()) return
            val session = session ?: return
            try {
                if (cameraTextureId >= 0 && cameraTextureId != boundCameraTextureId) {
                    session.setCameraTextureName(cameraTextureId)
                    boundCameraTextureId = cameraTextureId
                }
                frame = session.update()
            } catch (_: SessionPausedException) {
                // Expected during idle pause / Activity pause races — not an error.
                return
            } catch (e: CameraNotAvailableException) {
                if (idlePaused.get()) return
                closeSessionLocked()
                emitError("Camera not available: ${e.message ?: "unknown"}")
                return
            } catch (e: Exception) {
                if (idlePaused.get()) return
                emitError("AR frame update failed: ${e.message ?: e.javaClass.simpleName}")
                return
            }
        }

        // Process queued tap against this frame only (no second update).
        pendingTap.getAndSet(null)?.let { tap ->
            hitTest(frame, tap[0], tap[1])
        }

        maybeEmitTrackingReady(frame)

        quadTexCoordsBuffer.position(0)
        texCoordsBuffer.position(0)
        frame.transformDisplayUvCoords(quadTexCoordsBuffer, texCoordsBuffer)
        texCoordsBuffer.position(0)
        drawCameraBackground()

        val camera = frame.camera
        if (camera.trackingState != TrackingState.TRACKING) return

        camera.getViewMatrix(viewMatrix, 0)
        camera.getProjectionMatrix(projectionMatrix, 0, 0.1f, 100f)
        Matrix.multiplyMM(mvpMatrix, 0, projectionMatrix, 0, viewMatrix, 0)

        GLES20.glUseProgram(markerProgram)
        GLES20.glEnable(GLES20.GL_DEPTH_TEST)
        GLES20.glUniformMatrix4fv(mvpHandle, 1, false, mvpMatrix, 0)

        GLES20.glUniform4f(colorHandle, 0.3f, 0.6f, 1f, 1f)
        val markerSnapshot: List<Anchor>
        val lineSnapshot: List<LineAnchors>
        synchronized(sessionLock) {
            markerSnapshot = markers.values.toList()
            lineSnapshot = lines.values.toList()
        }
        for (anchor in markerSnapshot) {
            translationOrNull(anchor)?.let { t ->
                drawSphereApprox(t[0], t[1], t[2], 0.015f)
            }
        }
        GLES20.glUniform4f(colorHandle, 1f, 1f, 0.2f, 1f)
        GLES20.glLineWidth(6f)
        for (line in lineSnapshot) {
            val a = translationOrNull(line.start) ?: continue
            val b = translationOrNull(line.end) ?: continue
            drawLine(a[0], a[1], a[2], b[0], b[1], b[2])
        }
    }

    private fun translationOrNull(anchor: Anchor): FloatArray? {
        return try {
            if (anchor.trackingState == TrackingState.STOPPED) null
            else anchor.pose.translation
        } catch (_: Exception) {
            null
        }
    }

    private fun drawCameraBackground() {
        if (cameraProgram == 0 || cameraTextureId < 0) return
        GLES20.glDisable(GLES20.GL_DEPTH_TEST)
        GLES20.glUseProgram(cameraProgram)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, cameraTextureId)
        if (cameraTextureUniform >= 0) {
            GLES20.glUniform1i(cameraTextureUniform, 0)
        }
        GLES20.glEnableVertexAttribArray(cameraPositionHandle)
        GLES20.glVertexAttribPointer(
            cameraPositionHandle,
            2,
            GLES20.GL_FLOAT,
            false,
            0,
            quadCoordsBuffer,
        )
        GLES20.glEnableVertexAttribArray(cameraTexCoordHandle)
        GLES20.glVertexAttribPointer(
            cameraTexCoordHandle,
            2,
            GLES20.GL_FLOAT,
            false,
            0,
            texCoordsBuffer,
        )
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GLES20.glDisableVertexAttribArray(cameraPositionHandle)
        GLES20.glDisableVertexAttribArray(cameraTexCoordHandle)
        GLES20.glEnable(GLES20.GL_DEPTH_TEST)
    }

    private fun drawLine(x0: Float, y0: Float, z0: Float, x1: Float, y1: Float, z1: Float) {
        lineScratch.clear()
        lineScratch.put(x0).put(y0).put(z0).put(x1).put(y1).put(z1)
        lineScratch.position(0)
        GLES20.glEnableVertexAttribArray(positionHandle)
        GLES20.glVertexAttribPointer(positionHandle, 3, GLES20.GL_FLOAT, false, 0, lineScratch)
        GLES20.glDrawArrays(GLES20.GL_LINES, 0, 2)
        GLES20.glDisableVertexAttribArray(positionHandle)
    }

    private fun drawSphereApprox(cx: Float, cy: Float, cz: Float, r: Float) {
        val v = floatArrayOf(
            cx, cy + r, cz, cx + r, cy, cz, cx, cy, cz + r,
            cx, cy + r, cz, cx, cy, cz + r, cx - r, cy, cz,
            cx, cy + r, cz, cx - r, cy, cz, cx, cy, cz - r,
            cx, cy + r, cz, cx, cy, cz - r, cx + r, cy, cz,
            cx, cy - r, cz, cx + r, cy, cz, cx, cy, cz + r,
            cx, cy - r, cz, cx, cy, cz + r, cx - r, cy, cz,
            cx, cy - r, cz, cx - r, cy, cz, cx, cy, cz - r,
            cx, cy - r, cz, cx, cy, cz - r, cx + r, cy, cz,
        )
        sphereScratch.clear()
        sphereScratch.put(v)
        sphereScratch.position(0)
        GLES20.glEnableVertexAttribArray(positionHandle)
        GLES20.glVertexAttribPointer(positionHandle, 3, GLES20.GL_FLOAT, false, 0, sphereScratch)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLES, 0, v.size / 3)
        GLES20.glDisableVertexAttribArray(positionHandle)
    }

    private fun createProgram(vertex: String, fragment: String): Int {
        val vs = loadShader(GLES20.GL_VERTEX_SHADER, vertex) ?: return 0
        val fs = loadShader(GLES20.GL_FRAGMENT_SHADER, fragment) ?: return 0
        val program = GLES20.glCreateProgram()
        GLES20.glAttachShader(program, vs)
        GLES20.glAttachShader(program, fs)
        GLES20.glLinkProgram(program)
        val linkStatus = IntArray(1)
        GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, linkStatus, 0)
        if (linkStatus[0] == 0) {
            GLES20.glDeleteProgram(program)
            return 0
        }
        return program
    }

    private fun loadShader(type: Int, code: String): Int? {
        val shader = GLES20.glCreateShader(type)
        GLES20.glShaderSource(shader, code)
        GLES20.glCompileShader(shader)
        val compiled = IntArray(1)
        GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, compiled, 0)
        if (compiled[0] == 0) {
            GLES20.glDeleteShader(shader)
            return null
        }
        return shader
    }

    private fun currentDisplayRotation(): Int {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            activity.display?.rotation
                ?: activity.getSystemService(WindowManager::class.java).defaultDisplay.rotation
        } else {
            @Suppress("DEPRECATION")
            activity.windowManager.defaultDisplay.rotation
        }
    }

    companion object {
        private fun directFloatBuffer(values: FloatArray): FloatBuffer {
            val bb = ByteBuffer.allocateDirect(values.size * 4).order(ByteOrder.nativeOrder())
            val fb = bb.asFloatBuffer()
            fb.put(values)
            fb.position(0)
            return fb
        }

        private const val CAMERA_VERTEX = """
            attribute vec4 a_Position;
            attribute vec2 a_TexCoord;
            varying vec2 v_TexCoord;
            void main() {
              gl_Position = a_Position;
              v_TexCoord = a_TexCoord;
            }
        """
        private const val CAMERA_FRAGMENT = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 v_TexCoord;
            uniform samplerExternalOES u_Texture;
            void main() {
              gl_FragColor = texture2D(u_Texture, v_TexCoord);
            }
        """
        private const val VERTEX_SHADER = """
            uniform mat4 u_MVP;
            attribute vec4 a_Position;
            void main() {
              gl_Position = u_MVP * a_Position;
            }
        """
        private const val FRAGMENT_SHADER = """
            precision mediump float;
            uniform vec4 u_Color;
            void main() {
              gl_FragColor = u_Color;
            }
        """
    }
}
