import SwiftUI

/// Full-window overlay shown while a privileged operation is in progress.
struct RunningOverlay: View {
    var progress: Double? = nil
    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                if let progress {
                    ProgressView(value: progress)
                        .frame(width: 260)
                    Text("Writing… \(Int(progress * 100))%")
                        .font(.headline)
                        .monospacedDigit()
                } else {
                    ProgressView().controlSize(.large)
                    Text("Working…")
                        .font(.headline)
                }
                Text("You may be prompted for your administrator password.\nPlease don't unplug the drive.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
        }
        .transition(.opacity)
    }
}
