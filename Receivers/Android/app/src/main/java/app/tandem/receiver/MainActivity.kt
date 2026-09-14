package app.tandem.receiver

import android.content.res.Configuration
import android.os.Bundle
import android.view.KeyEvent
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.collectAsState
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import app.tandem.receiver.ui.DisplayScreen
import app.tandem.receiver.ui.DisplayView
import app.tandem.receiver.ui.IdleScreen
import app.tandem.receiver.ui.SettingsScreen
import app.tandem.receiver.ui.TandemTheme

/**
 * The single screen of the receiver.
 *
 * `configChanges` in the manifest keeps this activity alive through rotation so
 * the listening socket and the decoder survive; the host is told about the new
 * geometry with DEVICE_CONFIG instead (PROTOCOL.md §5.2).
 */
class MainActivity : ComponentActivity() {
    private val viewModel: ReceiverViewModel by viewModels()
    private var displayView: DisplayView? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)

        setContent {
            val state by viewModel.state.collectAsState()
            var showSettings by remember { mutableStateOf(false) }
            val streaming = state.phase == ReceiverPhase.STREAMING

            // Window flags are a side effect: doing this in the composition
            // body would touch the window on every recomposition.
            SideEffect {
                applyWindowFlags(
                    keepScreenOn = state.keepScreenOn,
                    immersive = streaming && !showSettings,
                )
            }

            TandemTheme {
                when {
                    showSettings ->
                        SettingsScreen(
                            state = state,
                            onDeviceNameChange = viewModel.controller::setDeviceName,
                            onKeepScreenOnChange = viewModel.controller::setKeepScreenOn,
                            onShowStatsChange = viewModel.controller::setShowStats,
                            onForgetPairedHosts = viewModel.controller::forgetPairedHosts,
                            onClose = { showSettings = false },
                        )

                    streaming ->
                        DisplayScreen(
                            state = state,
                            inputSink = viewModel.controller.inputSink,
                            onSurfaceChanged = viewModel.controller::attachSurface,
                            onTripleTap = viewModel.controller::toggleShowStats,
                            onViewCreated = { displayView = it },
                            onViewReleased = { if (displayView === it) displayView = null },
                        )

                    else ->
                        IdleScreen(
                            state = state,
                            onOpenSettings = { showSettings = true },
                        )
                }
            }
        }
    }

    override fun onStart() {
        super.onStart()
        viewModel.controller.refreshSettingsState()
        viewModel.start()
    }

    override fun onStop() {
        // The receiver is only useful with the screen on and the app in front;
        // releasing the port here also frees it for a fresh session on return.
        displayView?.resetInput()
        viewModel.stop()
        super.onStop()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        viewModel.controller.refreshNetwork()
        // Post so the new metrics are in place before they are measured.
        window.decorView.post { viewModel.controller.onDeviceConfigurationChanged() }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (viewModel.state.value.phase == ReceiverPhase.STREAMING) {
            displayView?.let { view ->
                if (view.dispatchHardwareKey(event)) return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    private fun applyWindowFlags(keepScreenOn: Boolean, immersive: Boolean) {
        if (keepScreenOn) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }

        val controller = WindowCompat.getInsetsController(window, window.decorView)
        if (immersive) {
            controller.systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            controller.hide(WindowInsetsCompat.Type.systemBars())
        } else {
            controller.show(WindowInsetsCompat.Type.systemBars())
        }
    }
}
