package com.ar_measurement

import android.app.Activity
import android.content.Context
import android.view.View
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

class SceneviewArViewFactory(
    private val messenger: BinaryMessenger,
    private val activityProvider: () -> Activity?,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val activity = activityProvider()
            ?: throw IllegalStateException("Activity required for SceneView AR view")
        return SceneviewArPlatformView(activity, context, messenger, viewId)
    }
}

class SceneviewArPlatformView(
    activity: Activity,
    context: Context,
    messenger: BinaryMessenger,
    id: Int,
) : PlatformView {
    private val measurementView = SceneviewArMeasurementView(activity, context, messenger, id)

    override fun getView(): View = measurementView

    override fun dispose() {
        measurementView.destroy()
    }
}
