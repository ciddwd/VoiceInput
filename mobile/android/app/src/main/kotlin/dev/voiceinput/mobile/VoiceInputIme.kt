package dev.voiceinput.mobile

import android.content.Context
import android.inputmethodservice.InputMethodService
import android.util.Log
import android.util.TypedValue
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.FrameLayout
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterTextureView
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * IME service that hosts a Flutter UI as the system keyboard.
 *
 * The Flutter engine runs the `ime_main` entrypoint (declared in
 * lib/ime_main.dart) and is cached under [ENGINE_ID] so subsequent IME
 * activations reuse the warm engine. The cache survives across
 * onCreateInputView/onFinishInput cycles, eliminating the cold-start latency.
 *
 * Bridge to Dart is via MethodChannel "voiceinput/ime":
 *   Dart -> Kotlin
 *     - commitText(text: String)            inject text into the focused editor
 *     - commitKey(name: "enter"|"tab"|"space"|"backspace")
 *     - clearAll()                          select-all + delete
 *     - switchToPreviousIme()               return to the previous IME
 *     - showImePicker()                     open the system input method chooser
 *   Kotlin -> Dart
 *     - onStartInput { packageName: String?, fieldType: String }
 *     - onFinishInput
 */
class VoiceInputIme : InputMethodService() {

    companion object {
        const val ENGINE_ID = "voiceinput.ime.engine"
        const val CHANNEL = "voiceinput/ime"
        const val TAG = "VoiceInputIme"
    }

    private var engine: FlutterEngine? = null
    private var flutterView: FlutterView? = null
    private var channel: MethodChannel? = null

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "onCreate / pid=${android.os.Process.myPid()}")
        engine = obtainEngine(this)
        Log.i(TAG, "engine obtained: $engine running=${engine?.dartExecutor?.isExecutingDart}")
        channel = MethodChannel(engine!!.dartExecutor.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                Log.d(TAG, "<- dart call: ${call.method}")
                when (call.method) {
                    "commitText" -> {
                        val text = call.argument<String>("text") ?: ""
                        Log.d(TAG, "commitText len=${text.length} ic=${currentInputConnection != null}")
                        currentInputConnection?.commitText(text, 1)
                        result.success(true)
                    }
                    "commitKey" -> {
                        val name = call.argument<String>("name")
                        Log.d(TAG, "commitKey $name")
                        when (name) {
                            "enter" -> currentInputConnection?.commitText("\n", 1)
                            "tab" -> currentInputConnection?.commitText("\t", 1)
                            "space" -> currentInputConnection?.commitText(" ", 1)
                            "backspace" -> currentInputConnection?.deleteSurroundingText(1, 0)
                        }
                        result.success(true)
                    }
                    "clearAll" -> {
                        Log.d(TAG, "clearAll")
                        currentInputConnection?.performContextMenuAction(android.R.id.selectAll)
                        currentInputConnection?.commitText("", 1)
                        result.success(true)
                    }
                    "switchToPreviousIme" -> {
                        val handled = switchToPreviousInputMethod()
                        Log.d(TAG, "switchToPreviousIme handled=$handled")
                        if (!handled) showImePicker()
                        result.success(handled)
                    }
                    "showImePicker" -> {
                        showImePicker()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    // Default InputMethodService enters fullscreen / extract mode in landscape
    // and on some OEMs even in portrait, which makes the keyboard pane render
    // as the whole screen. We never want that — this is a voice keyboard, not
    // a full-screen editor.
    override fun onEvaluateFullscreenMode(): Boolean = false
    override fun onEvaluateInputViewShown(): Boolean = true

    // Standard bottom-docked keyboard: we deliberately do NOT override
    // onComputeInsets. The default InputMethodService behaviour places our
    // fixed-height input view at the bottom, resizes the host app to sit above
    // it, and makes exactly the input-view rect touchable. The old custom
    // insets (a transparent full-screen overlay) were what caused first
    // "can't tap anything" and then "keyboard covers the whole screen" on MIUI.

    override fun onCreateInputView(): View {
        Log.i(TAG, "onCreateInputView")
        flutterView?.detachFromFlutterEngine()

        val height = TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP, 200f, resources.displayMetrics,
        ).toInt()
        val container = FrameLayout(this).apply {
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                height,
            )
        }
        // Opaque texture view — a standard keyboard paints a solid panel. The
        // old isOpaque=false was for the (removed) see-through overlay and
        // rendered as a black/grey full-screen block on some OEMs.
        val textureView = FlutterTextureView(this)
        val view = FlutterView(this, textureView)
        // Fix the FlutterView to the panel height. InputMethodService.setInputView
        // re-adds our container with MATCH_PARENT x WRAP_CONTENT, so a
        // MATCH_PARENT-height child stretches to fill the WHOLE screen — that's
        // the "keyboard is full-screen / pinned to the top" bug. A fixed height
        // makes the input view wrap to exactly the keyboard panel.
        view.layoutParams = FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            height,
        )
        flutterView = view
        view.attachToFlutterEngine(engine!!)
        container.addView(view)
        // Make the container's touch handling absolutely permissive — sometimes
        // a parent ViewGroup intercepts touches before they reach the Flutter
        // surface, leaving the user staring at unclickable buttons. Logging
        // the touchstream from both layers makes that obvious in logcat.
        container.setOnTouchListener { _, ev ->
            if (ev.action == android.view.MotionEvent.ACTION_DOWN) {
                Log.d(TAG, "container TOUCH down @ (${ev.x}, ${ev.y})")
            }
            false
        }
        view.setOnTouchListener { _, ev ->
            if (ev.action == android.view.MotionEvent.ACTION_DOWN) {
                Log.d(TAG, "flutterView TOUCH down @ (${ev.x}, ${ev.y})")
            }
            false
        }
        Log.i(TAG, "view attached height=${height}px engineRunning=${engine?.dartExecutor?.isExecutingDart}")
        return container
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        Log.i(TAG, "onStartInputView pkg=${info?.packageName} restarting=$restarting")
    }

    override fun onWindowShown() {
        super.onWindowShown()
        // Drive the embedded engine's lifecycle to RESUMED. A FlutterActivity
        // does this automatically; a hand-rolled FlutterView host must do it
        // itself. Without it the engine's AppLifecycleState stays non-resumed,
        // so SchedulerBinding.framesEnabled is false: the warm-up frame paints
        // (keyboard is visible) but setState() after a tap never schedules a new
        // frame — every key looks dead even though onTap fired. THIS is why our
        // Flutter keyboard couldn't be tapped while native keyboards (Sogou/
        // Baidu) work — they don't depend on Flutter's frame scheduling.
        engine?.lifecycleChannel?.appIsResumed()
        val w = window?.window
        Log.i(TAG, "onWindowShown decorH=${w?.decorView?.height} attrs=${w?.attributes}")
    }

    override fun onWindowHidden() {
        super.onWindowHidden()
        engine?.lifecycleChannel?.appIsInactive()
        Log.i(TAG, "onWindowHidden")
    }

    override fun onStartInput(info: EditorInfo?, restarting: Boolean) {
        super.onStartInput(info, restarting)
        channel?.invokeMethod(
            "onStartInput",
            mapOf(
                "packageName" to info?.packageName,
                "fieldType" to describeFieldType(info?.inputType ?: 0),
                "restarting" to restarting,
            ),
        )
    }

    override fun onFinishInput() {
        super.onFinishInput()
        channel?.invokeMethod("onFinishInput", null)
    }

    override fun onDestroy() {
        flutterView?.detachFromFlutterEngine()
        flutterView = null
        // Keep the engine alive in the cache so re-opening the keyboard is fast.
        // The OS reaps it when the process is killed.
        channel = null
        super.onDestroy()
    }

    private fun showImePicker() {
        val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        imm.showInputMethodPicker()
    }

    private fun describeFieldType(inputType: Int): String {
        val cls = inputType and EditorInfo.TYPE_MASK_CLASS
        return when (cls) {
            EditorInfo.TYPE_CLASS_TEXT -> "text"
            EditorInfo.TYPE_CLASS_NUMBER -> "number"
            EditorInfo.TYPE_CLASS_PHONE -> "phone"
            EditorInfo.TYPE_CLASS_DATETIME -> "datetime"
            else -> "unknown"
        }
    }
}

/** Lazily obtain or build the cached Flutter engine pointed at ime_main. */
fun obtainEngine(context: Context): FlutterEngine {
    val cache = FlutterEngineCache.getInstance()
    val existing = cache.get(VoiceInputIme.ENGINE_ID)
    if (existing != null) return existing

    val engine = FlutterEngine(context.applicationContext)
    engine.dartExecutor.executeDartEntrypoint(
        DartExecutor.DartEntrypoint(
            FlutterInjector.instance().flutterLoader().findAppBundlePath(),
            "imeMain",
        ),
    )
    cache.put(VoiceInputIme.ENGINE_ID, engine)
    return engine
}
