package app.teras.receiver.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.teras.receiver.R
import app.teras.receiver.ReceiverUiState

/** Device name, screen behaviour, stats and paired-Mac management. */
@Composable
fun SettingsScreen(
    state: ReceiverUiState,
    onDeviceNameChange: (String) -> Unit,
    onKeepScreenOnChange: (Boolean) -> Unit,
    onShowStatsChange: (Boolean) -> Unit,
    onForgetPairedHosts: () -> Unit,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var nameDraft by remember(state.deviceName) { mutableStateOf(state.deviceName) }

    Column(
        modifier =
            modifier
                .fillMaxSize()
                .safeDrawingPadding()
                .verticalScroll(rememberScrollState())
                .padding(24.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = stringResource(R.string.settings_title),
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.SemiBold,
            )
            TextButton(onClick = onClose) { Text(stringResource(R.string.action_done)) }
        }

        Spacer(Modifier.height(24.dp))

        OutlinedTextField(
            value = nameDraft,
            onValueChange = { nameDraft = it },
            label = { Text(stringResource(R.string.settings_device_name)) },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(8.dp))
        Button(
            onClick = { onDeviceNameChange(nameDraft) },
            enabled = nameDraft.isNotBlank() && nameDraft != state.deviceName,
        ) {
            Text(stringResource(R.string.action_save))
        }

        Spacer(Modifier.height(24.dp))
        SettingRow(
            title = stringResource(R.string.settings_keep_screen_on),
            subtitle = stringResource(R.string.settings_keep_screen_on_detail),
            checked = state.keepScreenOn,
            onCheckedChange = onKeepScreenOnChange,
        )
        SettingRow(
            title = stringResource(R.string.settings_show_stats),
            subtitle = stringResource(R.string.settings_show_stats_detail),
            checked = state.showStats,
            onCheckedChange = onShowStatsChange,
        )

        Spacer(Modifier.height(24.dp))
        Text(
            text = stringResource(R.string.settings_paired_count, state.pairedHostCount),
            style = MaterialTheme.typography.bodyMedium,
        )
        Spacer(Modifier.height(8.dp))
        Button(onClick = onForgetPairedHosts, enabled = state.pairedHostCount > 0) {
            Text(stringResource(R.string.settings_forget_paired))
        }
    }
}

@Composable
private fun SettingRow(
    title: String,
    subtitle: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(text = title, style = MaterialTheme.typography.bodyLarge)
            Text(
                text = subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.65f),
            )
        }
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    }
}
