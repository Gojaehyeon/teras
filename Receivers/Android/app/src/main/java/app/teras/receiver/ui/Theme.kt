package app.teras.receiver.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

private val TerasBlue = Color(0xFF3E7BFA)
private val TerasBlueDark = Color(0xFF2A5FD0)

private val DarkColors =
    darkColorScheme(
        primary = TerasBlue,
        onPrimary = Color.White,
        background = Color(0xFF101216),
        surface = Color(0xFF181B21),
        onBackground = Color(0xFFE8EAED),
        onSurface = Color(0xFFE8EAED),
    )

private val LightColors =
    lightColorScheme(
        primary = TerasBlueDark,
        onPrimary = Color.White,
        background = Color(0xFFF6F7F9),
        surface = Color.White,
    )

@Composable
fun TerasTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    MaterialTheme(
        colorScheme = if (darkTheme) DarkColors else LightColors,
        typography = Typography(),
        content = content,
    )
}
