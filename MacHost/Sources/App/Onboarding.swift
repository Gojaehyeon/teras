import SwiftUI

/// First-run walkthrough: the three permissions Teras needs and the Android
/// setup that has no permission prompt of its own.
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var step = 0

    private var steps: [OnboardingStep] {
        [
            OnboardingStep(
                title: L("onboarding.welcomeTitle"),
                body: L("onboarding.welcomeBody"),
                symbol: "sparkles",
                isSatisfied: true,
                actionTitle: nil,
                action: nil),
            OnboardingStep(
                title: L("permission.screenRecording"),
                body: L("permission.screenRecordingHelp"),
                symbol: "rectangle.on.rectangle",
                isSatisfied: model.permissions.hasScreenRecording,
                actionTitle: L("permission.grant"),
                action: { model.permissions.requestScreenRecording() }),
            OnboardingStep(
                title: L("permission.accessibility"),
                body: L("permission.accessibilityHelp"),
                symbol: "hand.tap",
                isSatisfied: model.permissions.hasAccessibility,
                actionTitle: L("permission.grant"),
                action: { model.permissions.requestAccessibility() }),
            OnboardingStep(
                title: L("onboarding.networkTitle"),
                body: L("onboarding.networkBody"),
                symbol: "wifi",
                isSatisfied: model.sessions.isBrowsingLAN,
                actionTitle: L("permission.openSettings"),
                action: { model.permissions.openLocalNetworkSettings() }),
            OnboardingStep(
                title: L("onboarding.androidTitle"),
                body: L("permission.androidSteps"),
                symbol: "cable.connector",
                isSatisfied: model.permissions.adbPath != nil,
                actionTitle: L("permission.refresh"),
                action: { model.permissions.refresh() }),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            let current = steps[min(step, steps.count - 1)]

            HStack(spacing: 14) {
                Image(systemName: current.symbol)
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(current.title).font(.title2).bold()
                    Text(L("onboarding.stepCount", step + 1, steps.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(current.body)
                .fixedSize(horizontal: false, vertical: true)

            if current.isSatisfied, step > 0 {
                Label(L("onboarding.ready"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            Spacer()

            HStack {
                if step > 0 {
                    Button(L("onboarding.back")) { step -= 1 }
                }
                if let actionTitle = current.actionTitle, let action = current.action, !current.isSatisfied {
                    Button(actionTitle, action: action)
                        .buttonStyle(.borderedProminent)
                }
                Spacer()
                if step < steps.count - 1 {
                    Button(L("onboarding.next")) { step += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(L("onboarding.finish")) { model.closeOnboarding() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 560, height: 520)
    }
}

private struct OnboardingStep {
    var title: String
    var body: String
    var symbol: String
    var isSatisfied: Bool
    var actionTitle: String?
    var action: (() -> Void)?
}
