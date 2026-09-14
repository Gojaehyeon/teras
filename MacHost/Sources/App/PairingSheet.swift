import SwiftUI

/// Asks for the six-digit code the receiver is showing.
struct PairingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pin = ""
    @FocusState private var focused: Bool

    private var request: PINRequest? { model.activePINRequest }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let request {
                Text(L("pairing.heading", request.deviceName))
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)

                Text(L("pairing.body"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField(L("pairing.placeholder"), text: $pin)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.title2, design: .monospaced))
                    .focused($focused)
                    .onChange(of: pin) { _, newValue in
                        pin = String(newValue.filter(\.isNumber).prefix(6))
                    }
                    .onSubmit(submit)

                if request.attemptsLeft < 3 {
                    Text(L("pairing.attemptsLeft", request.attemptsLeft))
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                Spacer()

                HStack {
                    Button(L("pairing.cancel")) {
                        model.sessions.cancelPIN(for: request.id)
                    }
                    .keyboardShortcut(.cancelAction)

                    Spacer()

                    Button(L("pairing.confirm"), action: submit)
                        .keyboardShortcut(.defaultAction)
                        .disabled(pin.count != 6)
                }
            } else {
                Text(L("pairing.done"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(width: 380, height: 300)
        .onAppear { focused = true }
        .onChange(of: request?.id) { _, _ in pin = "" }
    }

    private func submit() {
        guard let request, pin.count == 6 else { return }
        model.sessions.submitPIN(pin, for: request.id)
        pin = ""
    }
}
