package com.internalhrms.hrms

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * FragmentActivity is required for BiometricPrompt. Registers the
 * `hrms/device_key` channel used for hardware-attested punch signing.
 */
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val deviceKey = DeviceKeyChannel(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hrms/device_key")
            .setMethodCallHandler(deviceKey::handle)
    }
}
