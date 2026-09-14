import SwiftUI

struct PairingView: View {
    let pin: String
    let attemptsLeft: Int

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()

            VStack(spacing: 20) {
                Text(L.key("pairing.title"))
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.7))

                HStack(spacing: 10) {
                    ForEach(Array(pin.enumerated()), id: \.offset) { _, character in
                        Text(String(character))
                            .font(.system(size: 54, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 76)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                            )
                    }
                }
                .minimumScaleFactor(0.4)
                .padding(.horizontal, 16)

                Text(L.key("pairing.subtitle"))
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 40)

                Text(L.f("pairing.attemptsLeft", attemptsLeft))
                    .font(.footnote)
                    .foregroundStyle(attemptsLeft <= 1 ? Color.orange : Color.white.opacity(0.4))
            }
        }
        .accessibilityElement(children: .combine)
    }
}
