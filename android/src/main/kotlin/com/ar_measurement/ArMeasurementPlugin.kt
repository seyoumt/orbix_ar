package com.ar_measurement

import android.os.Handler
import android.os.Looper
import com.google.ar.core.ArCoreApk
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

class ArMeasurementPlugin : FlutterPlugin, MethodCallHandler, ActivityAware {
    private lateinit var availabilityChannel: MethodChannel
    private var activityBinding: ActivityPluginBinding? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        availabilityChannel =
            MethodChannel(binding.binaryMessenger, "ar_measurement/availability")
        availabilityChannel.setMethodCallHandler(this)

        val messenger = binding.binaryMessenger
        binding.platformViewRegistry.registerViewFactory(
            "ar_measurement/custom",
            CustomArViewFactory(messenger) { activityBinding?.activity },
        )
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "isArCoreSupported" -> checkAvailabilityWithRetry(result, attempt = 0)
            else -> result.notImplemented()
        }
    }

    private fun checkAvailabilityWithRetry(result: Result, attempt: Int) {
        val activity = activityBinding?.activity
        if (activity == null) {
            result.success(false)
            return
        }
        try {
            val availability = ArCoreApk.getInstance().checkAvailability(activity)
            if (availability.isTransient && attempt < 10) {
                mainHandler.postDelayed(
                    { checkAvailabilityWithRetry(result, attempt + 1) },
                    200L,
                )
                return
            }
            result.success(availability.isSupported)
        } catch (_: Exception) {
            result.success(false)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        availabilityChannel.setMethodCallHandler(null)
        mainHandler.removeCallbacksAndMessages(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activityBinding = binding
    }

    override fun onDetachedFromActivity() {
        activityBinding = null
    }
}
