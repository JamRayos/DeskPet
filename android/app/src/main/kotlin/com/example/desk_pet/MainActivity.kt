package com.example.desk_pet   // <-- change to your app's package name

import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "deskpet/blocker")
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    // Is the accessibility service connected (i.e. permission granted)?
                    "enabled" -> result.success(BlockerService.instance != null)

                    "openSettings" -> {
                        startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(null)
                    }

                    // Launchable apps: [{name, package}, ...]
                    "apps" -> {
                        val pm = packageManager
                        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                        val list = pm.queryIntentActivities(intent, 0)
                            .map { mapOf("package" to it.activityInfo.packageName,
                                         "name" to it.loadLabel(pm).toString()) }
                            .filter { it["package"] != packageName }
                            .distinctBy { it["package"] }
                            .sortedBy { it["name"]!!.lowercase() }
                        result.success(list)
                    }

                    "block" -> {
                        BlockerState.packages = (call.argument<List<String>>("packages") ?: emptyList()).toSet()
                        BlockerState.messages = call.argument<List<String>>("messages") ?: emptyList()
                        BlockerState.until = call.argument<Number>("until")?.toLong() ?: 0L
                        result.success(null)
                    }

                    "unblock" -> {
                        BlockerState.packages = emptySet()
                        BlockerState.until = 0L
                        BlockerService.instance?.hide()
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }
    }
}