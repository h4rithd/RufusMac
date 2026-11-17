import SwiftUI
import RufusMacKit

extension BurnMode {
    var systemImage: String {
        switch self {
        case .single: return "opticaldisc"
        case .multiboot: return "square.stack.3d.up"
        case .dd: return "doc.badge.gearshape"
        case .reclaim: return "arrow.counterclockwise"
        }
    }
}

/// Root view: header, mode switcher, contextual configuration cards, the
/// primary action, and the persistent footer — all on Liquid Glass.
struct ContentView: View {
    @State private var model = AppModel()

    private var modeItems: [GlassSegmented<BurnMode>.Item] {
        BurnMode.allCases.map { .init(value: $0, label: $0.rawValue, systemImage: $0.systemImage) }
    }

    var body: some View {
        ZStack {
            AppBackground()

            VStack(spacing: 16) {
                header
                GlassSegmented(items: modeItems, selection: $model.mode)

                ScrollView {
                    GlassEffectContainer(spacing: 14) {
                        VStack(spacing: 14) {
                            DevicePickerView(model: model)
                            if model.requiresImage {
                                BootSelectionView(model: model)
                            }
                            FormatOptionsView(model: model)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.bottom, 4)
                }

                startButton
                FooterView()
            }
            .padding(20)

            if model.isRunning {
                RunningOverlay(progress: model.progress)
            }
        }
        .animation(.smooth(duration: 0.3), value: model.mode)
        .animation(.smooth(duration: 0.3), value: model.isRunning)
        .task { await model.refreshDrives() }
        .sheet(isPresented: $model.showConfirm) {
            ConfirmationView(model: model)
        }
        .alert(
            model.resultMessage ?? "",
            isPresented: Binding(
                get: { model.resultMessage != nil },
                set: { if !$0 { model.dismissResult() } }
            )
        ) {
            Button("OK") { model.dismissResult() }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "internaldrive.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Brand.accent)
                .padding(10)
                .glassEffect(.regular.tint(Brand.accent.opacity(0.35)), in: .rect(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 1) {
                Text(Brand.name)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text(Brand.tagline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var startButton: some View {
        Button {
            model.prepare()
        } label: {
            Label(model.startTitle, systemImage: model.mode == .reclaim ? "arrow.counterclockwise" : "bolt.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.glassProminent)
        .tint(model.mode == .reclaim ? Brand.danger : Brand.accent)
        .disabled(!model.canStart)
        .keyboardShortcut(.defaultAction)
    }
}
