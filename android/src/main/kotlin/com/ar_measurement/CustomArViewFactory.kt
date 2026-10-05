package com.ar_measurement

import android.app.Activity
import android.content.Context
import android.view.View
import android.widget.FrameLayout
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

class CustomArViewFactory(
    private val messenger: BinaryMessenger,
    private val activityProvider: () -> Activity?,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val activity = activityProvider()
        if (activity == null) {
            // Soft-fail during config-change windows instead of crashing the engine.
            return UnavailableArPlatformView(context, messenger, viewId)
        }
        return CustomArPlatformView(activity, context, messenger, viewId)
    }
}

class CustomArPlatformView(
    activity: Activity,
    context: Context,
    messenger: BinaryMessenger,
    id: Int,
) : PlatformView {
    private val measurementView = CustomArMeasurementView(activity, context, messenger, id)

    override fun getView(): View = measurementView

    override fun dispose() {
        measurementView.destroy()
    }
}

/** Placeholder when Activity is briefly unavailable (config change). */
private class UnavailableArPlatformView(
    context: Context,
    messenger: BinaryMessenger,
    viewId: Int,
) : PlatformView {
    private val view = FrameLayout(context)
    private val channel = MethodChannel(messenger, "ar_measurement/custom_$viewId")

    init {
        channel.invokeMethod("onError", "Activity unavailable for AR view")
    }

    override fun getView(): View = view

    override fun dispose() {
        channel.setMethodCallHandler(null)
    }
}
