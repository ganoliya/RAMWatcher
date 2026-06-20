import SwiftUI

/// A custom in-content modal card for confirming a kill, standing in for
/// the system `.confirmationDialog`/`.alert`. See `AppModel.pendingConfirmation`
/// for why those can't be used inside `MenuBarExtra(.window)`.
struct ConfirmationOverlay: View {
    @EnvironmentObject private var model: AppModel
    let pending: PendingKill

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .onTapGesture { model.cancelPendingKill() }

            VStack(spacing: 14) {
                Text("Confirm Action")
                    .font(.headline)
                Text(pending.message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Cancel") {
                        model.cancelPendingKill()
                    }
                    .keyboardShortcut(.cancelAction)

                    Button(pending.confirmButtonLabel) {
                        Task { await model.confirmPendingKill() }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(maxWidth: 280)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
