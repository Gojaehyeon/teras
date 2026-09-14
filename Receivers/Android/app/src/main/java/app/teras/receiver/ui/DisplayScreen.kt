package app.teras.receiver.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import app.teras.receiver.R
import app.teras.receiver.ReceiverUiState
import app.teras.receiver.input.InputSink
import android.view.Surface

/**
 * The streaming screen: the decoded picture edge to edge, with an optional
 * stats readout. A triple tap anywhere toggles the readout.
 */
@Composable
fun DisplayScreen(
    state: ReceiverUiState,
    inputSink: InputSink,
    onSurfaceChanged: (Surface?) -> Unit,
    onTripleTap: () -> Unit,
    onViewCreated: (DisplayView) -> Unit,
    onViewReleased: (DisplayView) -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(modifier = modifier.fillMaxSize().background(Color.Black)) {
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { context ->
                DisplayView(context).also { view ->
                    view.onSurfaceChanged = onSurfaceChanged
                    view.onTripleTap = onTripleTap
                    onViewCreated(view)
                }
            },
            update = { view ->
                view.sink = inputSink
                state.streamConfig?.let { view.setVideoSize(it.wPx, it.hPx) }
            },
            onRelease = { view ->
                view.sink = null
                view.resetInput()
                view.onSurfaceChanged = null
                view.onTripleTap = null
                onViewReleased(view)
            },
        )

        if (state.showStats) {
            StatsOverlay(state, modifier = Modifier.align(Alignment.TopStart))
        }
    }
}

@Composable
private fun StatsOverlay(state: ReceiverUiState, modifier: Modifier = Modifier) {
    val stats = state.stats
    val config = state.streamConfig
    val text =
        buildString {
            if (config != null) {
                append(config.codec.uppercase())
                append(' ')
                append(config.wPx)
                append('x')
                append(config.hPx)
                append('@')
                append(config.fps)
                append('\n')
            }
            if (stats != null) {
                append(stringResource(R.string.stats_fps, format1(stats.fpsDecoded)))
                append("  ")
                append(stringResource(R.string.stats_dropped, format1(stats.fpsDropped)))
                append('\n')
                append(stringResource(R.string.stats_decode, format1(stats.decodeMsP50)))
                append("  ")
                append(stringResource(R.string.stats_rtt, format1(stats.rttMs)))
                append('\n')
                append(stringResource(R.string.stats_e2e, format1(stats.e2eMsP50)))
                append("  ")
                append(stringResource(R.string.stats_queued, stats.queued))
            } else {
                append(stringResource(R.string.stats_waiting))
            }
            if (state.encrypted) {
                append('\n')
                append(stringResource(R.string.stats_encrypted))
            }
        }

    Text(
        text = text,
        color = Color(0xFFB9F6CA),
        fontFamily = FontFamily.Monospace,
        style = MaterialTheme.typography.labelMedium,
        modifier =
            modifier
                .safeDrawingPadding()
                .padding(12.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(Color(0xCC000000))
                .padding(horizontal = 10.dp, vertical = 8.dp),
    )
}

private fun format1(value: Double): String = String.format("%.1f", value)
