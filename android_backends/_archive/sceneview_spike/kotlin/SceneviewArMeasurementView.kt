package com.ar_measurement

import android.app.Activity
import android.content.Context
import android.graphics.Color
import android.view.MotionEvent
import android.widget.FrameLayout
import androidx.lifecycle.LifecycleOwner
import com.google.ar.core.Config
import com.google.ar.core.Plane
import com.google.ar.core.TrackingState
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.sceneview.ar.ARSceneView
import io.github.sceneview.ar.arcore.getUpdatedPlanes
import io.github.sceneview.math.Position
import io.github.sceneview.node.CylinderNode
import io.github.sceneview.node.Node
import io.github.sceneview.node.SphereNode
import kotlin.math.sqrt

/**
 * SceneView / ARSceneView measurement host (spike 3A).
 * Hybrid Composition-friendly: SceneView owns Filament/GL.
 */
class SceneviewArMeasurementView(
    private val activity: Activity,
    context: Context,
    messenger: BinaryMessenger,
    viewId: Int,
) : FrameLayout(context), MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "ar_measurement/sceneview_$viewId")
    private val nodesById = LinkedHashMap<String, Node>()
    private var planeEmitCounter = 0

    private val sceneView: ARSceneView = ARSceneView(context).apply {
        val owner = activity as? LifecycleOwner
        if (owner != null) {
            lifecycle = owner.lifecycle
        }
        planeRenderer.isEnabled = true
        configureSession { _, config ->
            config.planeFindingMode = Config.PlaneFindingMode.HORIZONTAL_AND_VERTICAL
            config.lightEstimationMode = Config.LightEstimationMode.DISABLED
            config.instantPlacementMode = Config.InstantPlacementMode.DISABLED
            config.depthMode = Config.DepthMode.DISABLED
        }
        onSessionUpdated = { _, frame ->
            planeEmitCounter++
            if (planeEmitCounter % 30 == 0) {
                frame.getUpdatedPlanes()
                    .firstOrNull { it.trackingState == TrackingState.TRACKING }
                    ?.let { plane ->
                        val center = plane.centerPose.translation
                        val id = "${center[0]}_${center[1]}_${center[2]}"
                        post {
                            channel.invokeMethod(
                                "onPlane",
                                mapOf(
                                    "id" to id,
                                    "extentX" to plane.extentX.toDouble(),
                                    "extentZ" to plane.extentZ.toDouble(),
                                    "alignment" to if (plane.type == Plane.Type.VERTICAL) {
                                        "vertical"
                                    } else {
                                        "horizontal"
                                    },
                                ),
                            )
                        }
                    }
            }
        }
        onTouchEvent = { event, _ ->
            if (event.action == MotionEvent.ACTION_UP) {
                handleTap(event.x, event.y)
            }
            true
        }
        onSessionFailed = { exception ->
            post {
                channel.invokeMethod("onError", exception.message ?: "AR session failed")
            }
        }
    }

    init {
        channel.setMethodCallHandler(this)
        addView(
            sceneView,
            LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT),
        )
        keepScreenOn = true
    }

    private fun handleTap(x: Float, y: Float) {
        val hit = sceneView.hitTestAR(
            xPx = x,
            yPx = y,
            planeTypes = setOf(
                Plane.Type.HORIZONTAL_UPWARD_FACING,
                Plane.Type.HORIZONTAL_DOWNWARD_FACING,
                Plane.Type.VERTICAL,
            ),
            planePoseInPolygon = true,
        ) ?: sceneView.hitTestAR(
            xPx = x,
            yPx = y,
            planeTypes = setOf(
                Plane.Type.HORIZONTAL_UPWARD_FACING,
                Plane.Type.HORIZONTAL_DOWNWARD_FACING,
                Plane.Type.VERTICAL,
            ),
            planePoseInPolygon = false,
        ) ?: return

        val t = hit.hitPose.translation
        channel.invokeMethod(
            "onTap",
            mapOf("x" to t[0].toDouble(), "y" to t[1].toDouble(), "z" to t[2].toDouble()),
        )
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "addMarker" -> {
                val id = call.argument<String>("id")!!
                val x = call.argument<Double>("x")!!.toFloat()
                val y = call.argument<Double>("y")!!.toFloat()
                val z = call.argument<Double>("z")!!.toFloat()
                post { addMarker(id, x, y, z) }
                result.success(null)
            }
            "addLine" -> {
                val id = call.argument<String>("id")!!
                post {
                    addLine(
                        id,
                        call.argument<Double>("x0")!!.toFloat(),
                        call.argument<Double>("y0")!!.toFloat(),
                        call.argument<Double>("z0")!!.toFloat(),
                        call.argument<Double>("x1")!!.toFloat(),
                        call.argument<Double>("y1")!!.toFloat(),
                        call.argument<Double>("z1")!!.toFloat(),
                    )
                }
                result.success(null)
            }
            "remove" -> {
                val id = call.argument<String>("id")!!
                post { removeNode(id) }
                result.success(null)
            }
            "clear" -> {
                post { clearNodes() }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun addMarker(id: String, x: Float, y: Float, z: Float) {
        removeNode(id)
        val material = sceneView.materialLoader.createColorInstance(
            Color.rgb(77, 153, 255),
            metallic = 0f,
            roughness = 1f,
        )
        val node = SphereNode(
            engine = sceneView.engine,
            radius = 0.015f,
            materialInstance = material,
        ).apply {
            position = Position(x = x, y = y, z = z)
        }
        sceneView.addChildNode(node)
        nodesById[id] = node
    }

    private fun addLine(
        id: String,
        x0: Float,
        y0: Float,
        z0: Float,
        x1: Float,
        y1: Float,
        z1: Float,
    ) {
        removeNode(id)
        val dx = x1 - x0
        val dy = y1 - y0
        val dz = z1 - z0
        val length = sqrt(dx * dx + dy * dy + dz * dz).coerceAtLeast(0.001f)
        val material = sceneView.materialLoader.createColorInstance(
            Color.rgb(255, 230, 50),
            metallic = 0f,
            roughness = 1f,
        )
        val node = CylinderNode(
            engine = sceneView.engine,
            radius = 0.004f,
            height = length,
            materialInstance = material,
        ).apply {
            position = Position(
                x = (x0 + x1) / 2f,
                y = (y0 + y1) / 2f,
                z = (z0 + z1) / 2f,
            )
            // Orient cylinder (local +Y) toward the segment end.
            lookAt(Position(x = x1, y = y1, z = z1))
        }
        sceneView.addChildNode(node)
        nodesById[id] = node
    }

    private fun removeNode(id: String) {
        val node = nodesById.remove(id) ?: return
        sceneView.removeChildNode(node)
        node.destroy()
    }

    private fun clearNodes() {
        for (id in nodesById.keys.toList()) {
            removeNode(id)
        }
    }

    fun destroy() {
        channel.setMethodCallHandler(null)
        clearNodes()
        sceneView.destroy()
    }
}
