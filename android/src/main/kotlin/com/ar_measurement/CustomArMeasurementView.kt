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
    /** One-shot: look-around scan complete → Dart coaching can end. */
    private val trackingReadyEmitted = AtomicBoolean(false)
    /** Dart-requested thermal idle pause; Activity resume must not fight it. */
    private val idlePaused = AtomicBoolean(false)
    /** When true, run center hit-test and draw the oriented aim reticle. */
    private val aimingEnabled = AtomicBoolean(false)
    private val aimHasHit = AtomicBoolean(false)
    private var aimPose: Pose? = null
    /** Keep last good aim briefly so Place does not flicker on brief misses. */
    private var aimMissSinceMs = 0L
    /** Rubber-band measure preview start (world); null when inactive. */
    private var previewStart: FloatArray? = null
    private var lastPreviewDistanceCm = -1
    private val yawBuckets = BooleanArray(YAW_BUCKET_COUNT)
    private var scanStartedElapsedMs = -1L
    private var lastScanProgressEmit = -1
    private val ringScratch = directFloatBuffer(FloatArray(99)) // 33 verts * 3 floats
    /** Shared mesh scratch for UV spheres, disks, and plane outlines. */
    private val meshScratch = directFloatBuffer(FloatArray(2400))
    private val pointScratch = FloatArray(3)
    private val worldScratch = FloatArray(3)
    private val worldScratchB = FloatArray(3)

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
            "setAimingEnabled" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                aimingEnabled.set(enabled)
                if (!enabled) {
                    clearAimHit(force = true)
                }
                result.success(null)
            }
            "hitTestCenter" -> {
                val pose = synchronized(sessionLock) { aimPose }
                if (pose == null) {
                    result.success(null)
                    return
                }
                val t = pose.translation
                // Create the placement anchor only on Place — not every aim frame.
                synchronized(sessionLock) {
                    pendingHitAnchor?.let { detachQuietly(it) }
                    pendingHitAnchor = try {
                        session?.createAnchor(pose)
                    } catch (_: Exception) {
                        null
                    }
                }
                result.success(
                    mapOf(
                        "x" to t[0].toDouble(),
                        "y" to t[1].toDouble(),
                        "z" to t[2].toDouble(),
                    ),
                )
            }
            "setMeasurePreviewStart" -> {
                val x = call.argument<Double>("x")
                val y = call.argument<Double>("y")
                val z = call.argument<Double>("z")
                val cleared = synchronized(sessionLock) {
                    previewStart = if (x == null || y == null || z == null) {
                        null
                    } else {
                        floatArrayOf(x.toFloat(), y.toFloat(), z.toFloat())
                    }
                    previewStart == null
                }
                if (cleared) {
                    lastPreviewDistanceCm = -1
                    emitPreviewDistance(null)
                }
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
        resetScanState()
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
        aimPose = null
        previewStart = null
        lastPreviewDistanceCm = -1
        if (aimHasHit.getAndSet(false)) {
            emitAimChanged(false)
        }
        emitPreviewDistance(null)
        // Allow a new session to re-emit coaching ready after clearVisuals.
        trackingReadyEmitted.set(false)
        resetScanState()
    }

    private fun detachQuietly(anchor: Anchor) {
        try {
            anchor.detach()
        } catch (_: Exception) {
        }
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        // Placement is via center reticle + Place button — ignore taps.
        return true
    }

    /**
     * Center-screen plane hit for the aim reticle.
     * Only updates [aimPose] for drawing — anchors are created on Place.
     * Never calls [Session.update].
     *
     * Priority: in-polygon → in-extents → any Plane hit from hitTest (infinite
     * plane beyond the mapped patch) → raycast onto the best tracked plane.
     * Farther aim often misses the small mapped polygon; without the later
     * steps the reticle disappears a few meters out.
     */
    private fun updateCenterAim(frame: Frame) {
        if (!aimingEnabled.get()) return
        if (frame.camera.trackingState != TrackingState.TRACKING) {
            clearAimHit(force = true)
            return
        }
        val cx = viewportWidth * 0.5f
        val cy = viewportHeight * 0.5f
        val hits = frame.hitTest(cx, cy)
        var extentFallback: Pose? = null
        var infinitePlaneFallback: Pose? = null
        for (hit in hits) {
            val trackable = hit.trackable
            if (trackable !is Plane || trackable.trackingState != TrackingState.TRACKING) {
                continue
            }
            if (trackable.subsumedBy != null) continue
            if (trackable.isPoseInPolygon(hit.hitPose)) {
                acceptAimPose(hit.hitPose)
                return
            }
            if (extentFallback == null && trackable.isPoseInExtents(hit.hitPose)) {
                extentFallback = hit.hitPose
            }
            // ARCore still returns Plane hits outside the mapped polygon/extents.
            if (infinitePlaneFallback == null && hit.distance in AIM_MIN_DISTANCE..AIM_MAX_DISTANCE) {
                infinitePlaneFallback = hit.hitPose
            }
        }
        if (extentFallback != null) {
            acceptAimPose(extentFallback)
            return
        }
        if (infinitePlaneFallback != null) {
            acceptAimPose(infinitePlaneFallback)
            return
        }
        raycastBestPlane(frame)?.let {
            acceptAimPose(it)
            return
        }
        clearAimHit(force = false)
    }

    /**
     * Intersect the camera forward ray with the largest tracked plane (expanded
     * extents). Used when [Frame.hitTest] returns no usable Plane hit.
     */
    private fun raycastBestPlane(frame: Frame): Pose? {
        val session = synchronized(sessionLock) { session } ?: return null
        val camPose = frame.camera.pose
        val origin = camPose.translation
        pointScratch[0] = 0f
        pointScratch[1] = 0f
        pointScratch[2] = -1f
        camPose.rotateVector(pointScratch, 0, worldScratch, 0)
        val fx = worldScratch[0]
        val fy = worldScratch[1]
        val fz = worldScratch[2]

        var bestPose: Pose? = null
        var bestScore = -1f
        try {
            for (plane in session.getAllTrackables(Plane::class.java)) {
                if (plane.trackingState != TrackingState.TRACKING) continue
                if (plane.subsumedBy != null) continue
                val center = plane.centerPose
                pointScratch[0] = 0f
                pointScratch[1] = 1f
                pointScratch[2] = 0f
                center.rotateVector(pointScratch, 0, worldScratchB, 0)
                val nx = worldScratchB[0]
                val ny = worldScratchB[1]
                val nz = worldScratchB[2]
                val denom = fx * nx + fy * ny + fz * nz
                if (kotlin.math.abs(denom) < 1e-4f) continue
                val pp = center.translation
                val t =
                    ((pp[0] - origin[0]) * nx +
                        (pp[1] - origin[1]) * ny +
                        (pp[2] - origin[2]) * nz) / denom
                if (t < AIM_MIN_DISTANCE || t > AIM_MAX_DISTANCE) continue

                val hx = origin[0] + fx * t
                val hy = origin[1] + fy * t
                val hz = origin[2] + fz * t
                // Keep hits within expanded extents so we don't place on the sky.
                pointScratch[0] = hx
                pointScratch[1] = hy
                pointScratch[2] = hz
                val inv = center.inverse()
                inv.transformPoint(pointScratch, 0, worldScratchB, 0)
                val expand = AIM_EXTENT_EXPAND
                if (kotlin.math.abs(worldScratchB[0]) > plane.extentX * expand) continue
                if (kotlin.math.abs(worldScratchB[2]) > plane.extentZ * expand) continue

                val area = plane.extentX * plane.extentZ
                // Prefer large nearby planes.
                val score = area / (0.5f + t)
                if (score > bestScore) {
                    bestScore = score
                    bestPose = Pose(
                        floatArrayOf(hx, hy, hz),
                        center.rotationQuaternion,
                    )
                }
            }
        } catch (_: Exception) {
            return null
        }
        return bestPose
    }

    private fun acceptAimPose(pose: Pose) {
        synchronized(sessionLock) {
            aimPose = pose
        }
        aimMissSinceMs = 0L
        if (!aimHasHit.getAndSet(true)) {
            emitAimChanged(true)
        }
    }

    private fun clearAimHit(force: Boolean) {
        val now = android.os.SystemClock.elapsedRealtime()
        if (!force) {
            if (aimMissSinceMs == 0L) {
                aimMissSinceMs = now
            }
            if (now - aimMissSinceMs < AIM_HOLD_MS) {
                // Keep last pose / Place enabled through brief gaps.
                return
            }
        }
        aimMissSinceMs = 0L
        synchronized(sessionLock) {
            aimPose = null
        }
        if (aimHasHit.getAndSet(false)) {
            emitAimChanged(false)
        }
    }

    private fun emitAimChanged(hasHit: Boolean) {
        activity.runOnUiThread {
            if (destroyed.get()) return@runOnUiThread
            channel.invokeMethod("onAimChanged", hasHit)
        }
    }

    private fun emitTrackingReady() {
        activity.runOnUiThread {
            if (destroyed.get()) return@runOnUiThread
            channel.invokeMethod("onTrackingReady", null)
        }
    }

    private fun emitScanProgress(progress: Float) {
        val pct = (progress.coerceIn(0f, 1f) * 100f).toInt()
        if (pct == lastScanProgressEmit) return
        lastScanProgressEmit = pct
        activity.runOnUiThread {
            if (destroyed.get()) return@runOnUiThread
            channel.invokeMethod("onScanProgress", progress.toDouble())
        }
    }

    private fun emitPreviewDistance(meters: Double?) {
        activity.runOnUiThread {
            if (destroyed.get()) return@runOnUiThread
            channel.invokeMethod("onPreviewDistance", meters)
        }
    }

    private fun emitError(message: String) {
        activity.runOnUiThread {
            if (destroyed.get()) return@runOnUiThread
            channel.invokeMethod("onError", message)
        }
    }

    private fun resetScanState() {
        scanStartedElapsedMs = -1L
        lastScanProgressEmit = -1
        yawBuckets.fill(false)
        aimMissSinceMs = 0L
    }

    /**
     * Look-around gate: time + camera yaw coverage + plane area/count.
     * Avoids unlocking on the first tiny plane patch.
     */
    private fun maybeEmitTrackingReady(frame: Frame) {
        if (trackingReadyEmitted.get()) return
        if (frame.camera.trackingState != TrackingState.TRACKING) return

        val session = synchronized(sessionLock) { session } ?: return
        var planeCount = 0
        var maxArea = 0f
        try {
            for (plane in session.getAllTrackables(Plane::class.java)) {
                if (plane.trackingState != TrackingState.TRACKING) continue
                planeCount++
                val area = plane.extentX * plane.extentZ
                if (area > maxArea) maxArea = area
            }
        } catch (_: Exception) {
            return
        }
        if (planeCount == 0) {
            emitScanProgress(0f)
            return
        }

        val now = android.os.SystemClock.elapsedRealtime()
        if (scanStartedElapsedMs < 0L) {
            scanStartedElapsedMs = now
        }
        val elapsed = now - scanStartedElapsedMs

        // Sample camera look direction into yaw buckets ("look around").
        try {
            val zAxis = frame.camera.pose.zAxis
            val yaw = kotlin.math.atan2(zAxis[0], zAxis[2])
            val norm = ((yaw + Math.PI) / (2.0 * Math.PI))
            val bucket = (norm * YAW_BUCKET_COUNT).toInt().coerceIn(0, YAW_BUCKET_COUNT - 1)
            yawBuckets[bucket] = true
        } catch (_: Exception) {
        }
        var filledBuckets = 0
        for (b in yawBuckets) if (b) filledBuckets++

        val timeScore = (elapsed.toFloat() / SCAN_MIN_MS).coerceIn(0f, 1f)
        val lookScore = (filledBuckets.toFloat() / SCAN_MIN_YAW_BUCKETS).coerceIn(0f, 1f)
        val areaScore = if (planeCount >= SCAN_MIN_PLANES) {
            1f
        } else {
            (maxArea / SCAN_MIN_PLANE_AREA).coerceIn(0f, 1f)
        }
        val progress = minOf(timeScore, lookScore, areaScore)
        emitScanProgress(progress)

        val ready = elapsed >= SCAN_MIN_MS &&
            filledBuckets >= SCAN_MIN_YAW_BUCKETS &&
            (maxArea >= SCAN_MIN_PLANE_AREA || planeCount >= SCAN_MIN_PLANES)
        if (ready && trackingReadyEmitted.compareAndSet(false, true)) {
            emitScanProgress(1f)
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
            config.focusMode = Config.FocusMode.AUTO
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
        val activeSession: Session
        synchronized(sessionLock) {
            if (idlePaused.get()) return
            val session = session ?: return
            try {
                // Flagships often change rotation/geometry; keep ARCore display in sync.
                val rot = currentDisplayRotation()
                if (rot != displayRotation) {
                    displayRotation = rot
                    session.setDisplayGeometry(displayRotation, viewportWidth, viewportHeight)
                }
                if (cameraTextureId >= 0 && cameraTextureId != boundCameraTextureId) {
                    session.setCameraTextureName(cameraTextureId)
                    boundCameraTextureId = cameraTextureId
                }
                frame = session.update()
                activeSession = session
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

        maybeEmitTrackingReady(frame)
        updateCenterAim(frame)

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
        GLES20.glEnable(GLES20.GL_BLEND)
        GLES20.glBlendFunc(GLES20.GL_SRC_ALPHA, GLES20.GL_ONE_MINUS_SRC_ALPHA)
        GLES20.glUniformMatrix4fv(mvpHandle, 1, false, mvpMatrix, 0)

        val poseForAim: Pose?
        val previewFrom: FloatArray?
        val markerSnapshot: List<Anchor>
        val lineSnapshot: List<LineAnchors>
        synchronized(sessionLock) {
            poseForAim = aimPose
            previewFrom = previewStart?.clone()
            markerSnapshot = markers.values.toList()
            lineSnapshot = lines.values.toList()
        }

        // Soft plane outlines for scan/measure coaching.
        drawTrackedPlaneHints(activeSession)

        // Rubber-band preview: start → current aim (pose only, no anchors).
        if (previewFrom != null && poseForAim != null) {
            val aimT = poseForAim.translation
            GLES20.glUniform4f(colorHandle, 1f, 0.84f, 0.2f, 0.55f)
            GLES20.glLineWidth(5f)
            drawDashedLine(
                previewFrom[0], previewFrom[1], previewFrom[2],
                aimT[0], aimT[1], aimT[2],
            )
            maybeEmitPreviewDistance(previewFrom, aimT)
        } else if (lastPreviewDistanceCm >= 0) {
            lastPreviewDistanceCm = -1
            emitPreviewDistance(null)
        }

        // Oriented aim reticle (lies on the hit plane).
        if (aimingEnabled.get() && poseForAim != null) {
            drawElegantReticle(poseForAim)
        }

        // Placed markers: white rim + gold core (smooth UV spheres).
        for (anchor in markerSnapshot) {
            translationOrNull(anchor)?.let { t ->
                GLES20.glUniform4f(colorHandle, 1f, 1f, 1f, 1f)
                drawUvSphere(t[0], t[1], t[2], 0.014f)
                GLES20.glUniform4f(colorHandle, 0.96f, 0.77f, 0.09f, 1f)
                drawUvSphere(t[0], t[1], t[2], 0.009f)
            }
        }
        // Committed segments.
        GLES20.glUniform4f(colorHandle, 0.96f, 0.77f, 0.09f, 1f)
        GLES20.glLineWidth(6f)
        for (line in lineSnapshot) {
            val a = translationOrNull(line.start) ?: continue
            val b = translationOrNull(line.end) ?: continue
            drawLine(a[0], a[1], a[2], b[0], b[1], b[2])
        }

        GLES20.glDisable(GLES20.GL_BLEND)
    }

    private fun maybeEmitPreviewDistance(start: FloatArray, end: FloatArray) {
        val dx = end[0] - start[0]
        val dy = end[1] - start[1]
        val dz = end[2] - start[2]
        val meters = kotlin.math.sqrt(dx * dx + dy * dy + dz * dz).toDouble()
        val cm = (meters * 100.0).toInt()
        if (cm == lastPreviewDistanceCm) return
        lastPreviewDistanceCm = cm
        emitPreviewDistance(meters)
    }

    private fun drawElegantReticle(pose: Pose) {
        // Soft filled outer disk
        GLES20.glUniform4f(colorHandle, 1f, 1f, 1f, 0.22f)
        drawOrientedDisk(pose, 0.062f)
        // White outer ring
        GLES20.glUniform4f(colorHandle, 1f, 1f, 1f, 0.92f)
        GLES20.glLineWidth(3f)
        drawOrientedRing(pose, 0.058f)
        // Gold inner ring
        GLES20.glUniform4f(colorHandle, 0.96f, 0.77f, 0.09f, 1f)
        GLES20.glLineWidth(3.5f)
        drawOrientedRing(pose, 0.028f)
        // Center pip
        val t = pose.translation
        GLES20.glUniform4f(colorHandle, 0.96f, 0.77f, 0.09f, 1f)
        drawUvSphere(t[0], t[1], t[2], 0.007f)
        // Tick marks (cross) in the plane
        GLES20.glUniform4f(colorHandle, 1f, 1f, 1f, 0.9f)
        GLES20.glLineWidth(2.5f)
        drawOrientedTicks(pose, 0.034f, 0.05f)
    }

    private fun drawOrientedTicks(pose: Pose, inner: Float, outer: Float) {
        val dirs = arrayOf(
            floatArrayOf(1f, 0f, 0f),
            floatArrayOf(-1f, 0f, 0f),
            floatArrayOf(0f, 0f, 1f),
            floatArrayOf(0f, 0f, -1f),
        )
        for (d in dirs) {
            pointScratch[0] = d[0] * inner
            pointScratch[1] = 0.001f
            pointScratch[2] = d[2] * inner
            pose.transformPoint(pointScratch, 0, worldScratch, 0)
            pointScratch[0] = d[0] * outer
            pointScratch[2] = d[2] * outer
            pose.transformPoint(pointScratch, 0, worldScratchB, 0)
            drawLine(
                worldScratch[0], worldScratch[1], worldScratch[2],
                worldScratchB[0], worldScratchB[1], worldScratchB[2],
            )
        }
    }

    private fun drawDashedLine(
        x0: Float, y0: Float, z0: Float,
        x1: Float, y1: Float, z1: Float,
    ) {
        val dx = x1 - x0
        val dy = y1 - y0
        val dz = z1 - z0
        val len = kotlin.math.sqrt(dx * dx + dy * dy + dz * dz)
        if (len < 0.01f) return
        val ux = dx / len
        val uy = dy / len
        val uz = dz / len
        val dash = 0.025f
        var t = 0f
        while (t < len) {
            val t1 = (t + dash).coerceAtMost(len)
            drawLine(
                x0 + ux * t, y0 + uy * t, z0 + uz * t,
                x0 + ux * t1, y0 + uy * t1, z0 + uz * t1,
            )
            t += dash * 2f
        }
    }

    /** Low-alpha plane polygons + extent cross for coaching feedback. */
    private fun drawTrackedPlaneHints(session: Session) {
        GLES20.glUniform4f(colorHandle, 1f, 1f, 1f, 0.16f)
        GLES20.glLineWidth(1.5f)
        try {
            for (plane in session.getAllTrackables(Plane::class.java)) {
                if (plane.trackingState != TrackingState.TRACKING) continue
                if (plane.subsumedBy != null) continue
                drawPlaneOutline(plane)
            }
        } catch (_: Exception) {
            // Session may be mid-teardown.
        }
    }

    private fun drawPlaneOutline(plane: Plane) {
        val pose = plane.centerPose
        val poly = plane.polygon ?: return
        poly.rewind()
        val verts = poly.remaining() / 2
        if (verts < 3) return
        val count = verts.coerceAtMost(64)
        meshScratch.clear()
        pointScratch[1] = 0.002f
        for (i in 0 until count) {
            pointScratch[0] = poly.get(i * 2)
            pointScratch[2] = poly.get(i * 2 + 1)
            pose.transformPoint(pointScratch, 0, worldScratch, 0)
            meshScratch.put(worldScratch[0]).put(worldScratch[1]).put(worldScratch[2])
        }
        meshScratch.position(0)
        GLES20.glEnableVertexAttribArray(positionHandle)
        GLES20.glVertexAttribPointer(positionHandle, 3, GLES20.GL_FLOAT, false, 0, meshScratch)
        GLES20.glDrawArrays(GLES20.GL_LINE_LOOP, 0, count)
        GLES20.glDisableVertexAttribArray(positionHandle)

        // Light extent cross through plane center.
        val hx = plane.extentX * 0.45f
        val hz = plane.extentZ * 0.45f
        pointScratch[0] = -hx
        pointScratch[1] = 0.002f
        pointScratch[2] = 0f
        pose.transformPoint(pointScratch, 0, worldScratch, 0)
        pointScratch[0] = hx
        pose.transformPoint(pointScratch, 0, worldScratchB, 0)
        drawLine(
            worldScratch[0], worldScratch[1], worldScratch[2],
            worldScratchB[0], worldScratchB[1], worldScratchB[2],
        )
        pointScratch[0] = 0f
        pointScratch[2] = -hz
        pose.transformPoint(pointScratch, 0, worldScratch, 0)
        pointScratch[2] = hz
        pose.transformPoint(pointScratch, 0, worldScratchB, 0)
        drawLine(
            worldScratch[0], worldScratch[1], worldScratch[2],
            worldScratchB[0], worldScratchB[1], worldScratchB[2],
        )
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

    /** Ring in the local XZ plane of [pose] (Y ≈ surface normal for plane hits). */
    private fun drawOrientedRing(pose: Pose, radius: Float) {
        val segments = 32
        ringScratch.clear()
        for (i in 0..segments) {
            val angle = (i.toFloat() / segments) * (Math.PI * 2.0).toFloat()
            pointScratch[0] = kotlin.math.cos(angle) * radius
            pointScratch[1] = 0.001f
            pointScratch[2] = kotlin.math.sin(angle) * radius
            pose.transformPoint(pointScratch, 0, worldScratch, 0)
            ringScratch.put(worldScratch[0]).put(worldScratch[1]).put(worldScratch[2])
        }
        ringScratch.position(0)
        GLES20.glEnableVertexAttribArray(positionHandle)
        GLES20.glVertexAttribPointer(positionHandle, 3, GLES20.GL_FLOAT, false, 0, ringScratch)
        GLES20.glDrawArrays(GLES20.GL_LINE_LOOP, 0, segments + 1)
        GLES20.glDisableVertexAttribArray(positionHandle)
    }

    /** Filled disk in the local XZ plane of [pose]. */
    private fun drawOrientedDisk(pose: Pose, radius: Float) {
        val segments = 32
        meshScratch.clear()
        pointScratch[0] = 0f
        pointScratch[1] = 0.001f
        pointScratch[2] = 0f
        pose.transformPoint(pointScratch, 0, worldScratch, 0)
        meshScratch.put(worldScratch[0]).put(worldScratch[1]).put(worldScratch[2])
        for (i in 0..segments) {
            val angle = (i.toFloat() / segments) * (Math.PI * 2.0).toFloat()
            pointScratch[0] = kotlin.math.cos(angle) * radius
            pointScratch[1] = 0.001f
            pointScratch[2] = kotlin.math.sin(angle) * radius
            pose.transformPoint(pointScratch, 0, worldScratch, 0)
            meshScratch.put(worldScratch[0]).put(worldScratch[1]).put(worldScratch[2])
        }
        meshScratch.position(0)
        GLES20.glEnableVertexAttribArray(positionHandle)
        GLES20.glVertexAttribPointer(positionHandle, 3, GLES20.GL_FLOAT, false, 0, meshScratch)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_FAN, 0, segments + 2)
        GLES20.glDisableVertexAttribArray(positionHandle)
    }

    /** Smooth UV sphere (replaces faceted octahedron markers). */
    private fun drawUvSphere(cx: Float, cy: Float, cz: Float, r: Float) {
        val stacks = 8
        val slices = 12
        meshScratch.clear()
        var vertCount = 0
        for (i in 0 until stacks) {
            val lat0 = (Math.PI * (-0.5 + i.toDouble() / stacks)).toFloat()
            val lat1 = (Math.PI * (-0.5 + (i + 1).toDouble() / stacks)).toFloat()
            val y0 = kotlin.math.sin(lat0)
            val y1 = kotlin.math.sin(lat1)
            val rr0 = kotlin.math.cos(lat0)
            val rr1 = kotlin.math.cos(lat1)
            for (j in 0 until slices) {
                val lng0 = (2.0 * Math.PI * j / slices).toFloat()
                val lng1 = (2.0 * Math.PI * (j + 1) / slices).toFloat()
                val x00 = kotlin.math.cos(lng0) * rr0
                val z00 = kotlin.math.sin(lng0) * rr0
                val x01 = kotlin.math.cos(lng1) * rr0
                val z01 = kotlin.math.sin(lng1) * rr0
                val x10 = kotlin.math.cos(lng0) * rr1
                val z10 = kotlin.math.sin(lng0) * rr1
                val x11 = kotlin.math.cos(lng1) * rr1
                val z11 = kotlin.math.sin(lng1) * rr1
                meshScratch
                    .put(cx + x00 * r).put(cy + y0 * r).put(cz + z00 * r)
                    .put(cx + x10 * r).put(cy + y1 * r).put(cz + z10 * r)
                    .put(cx + x11 * r).put(cy + y1 * r).put(cz + z11 * r)
                    .put(cx + x00 * r).put(cy + y0 * r).put(cz + z00 * r)
                    .put(cx + x11 * r).put(cy + y1 * r).put(cz + z11 * r)
                    .put(cx + x01 * r).put(cy + y0 * r).put(cz + z01 * r)
                vertCount += 6
            }
        }
        meshScratch.position(0)
        GLES20.glEnableVertexAttribArray(positionHandle)
        GLES20.glVertexAttribPointer(positionHandle, 3, GLES20.GL_FLOAT, false, 0, meshScratch)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLES, 0, vertCount)
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

        /** Hold last aim pose through brief center-ray misses. */
        private const val AIM_HOLD_MS = 700L
        /** Ignore absurdly close / far aim hits (meters). */
        private const val AIM_MIN_DISTANCE = 0.08f
        private const val AIM_MAX_DISTANCE = 12f
        /** Allow aim beyond mapped plane extents (mapped patch grows slowly). */
        private const val AIM_EXTENT_EXPAND = 3.5f
        /** Look-around scan: minimum time after first plane. */
        private const val SCAN_MIN_MS = 2500L
        private const val YAW_BUCKET_COUNT = 8
        /** Distinct look directions required (of [YAW_BUCKET_COUNT]). */
        private const val SCAN_MIN_YAW_BUCKETS = 3
        /** ~0.5m × 0.5m plane, or at least [SCAN_MIN_PLANES] planes. */
        private const val SCAN_MIN_PLANE_AREA = 0.25f
        private const val SCAN_MIN_PLANES = 2

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
