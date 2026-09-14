package app.tandem.receiver

import android.app.Application
import androidx.lifecycle.AndroidViewModel

/** Keeps one [ReceiverController] alive across configuration changes. */
class ReceiverViewModel(application: Application) : AndroidViewModel(application) {
    val controller = ReceiverController(application)

    val state = controller.state

    fun start() = controller.start()

    fun stop() = controller.stop()

    override fun onCleared() {
        controller.stop()
        super.onCleared()
    }
}
