import SwiftUI
import DroidDeckKit

/// Shared spacing, typography and small components so every screen behaves the same.
enum DS {
    static let spacing: CGFloat = 12
    static let smallSpacing: CGFloat = 6
    static let sectionSpacing: CGFloat = 24
    static let cornerRadius: CGFloat = 10
    static let contentPadding: CGFloat = 20
}

extension DeviceLifecycleState {
    var tint: Color {
        switch self {
        case .running: return .green
        case .starting, .stopping: return .orange
        case .failed: return .red
        case .stopped: return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .running: return "circle.fill"
        case .starting, .stopping: return "circle.dotted"
        case .failed: return "exclamationmark.circle.fill"
        case .stopped: return "circle"
        }
    }
}

struct StatusLabel: View {
    let state: DeviceLifecycleState
    var paused = false
    /// The display was turned off because no window shows the device.
    var asleep = false

    private var label: String {
        guard state.isRunning else { return state.label }
        return paused ? "Paused" : asleep ? "Screen off" : state.label
    }

    var body: some View {
        HStack(spacing: 5) {
            if state.isBusy {
                ProgressView().controlSize(.mini)
            } else if paused && state.isRunning {
                Image(systemName: "pause.circle.fill").font(.system(size: 10)).foregroundStyle(.orange)
            } else if asleep && state.isRunning {
                Image(systemName: "moon.fill").font(.system(size: 9)).foregroundStyle(.indigo)
            } else {
                Image(systemName: state.symbol)
                    .font(.system(size: 8))
                    .foregroundStyle(state.tint)
            }
            Text(label)
                .foregroundStyle(state.isRunning ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(label)")
    }
}

struct Badge: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

/// A labeled value row.
struct InfoRow: View {
    let label: String
    let value: String
    var help: String?

    var body: some View {
        LabeledContent(label) {
            Text(value)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
        .help(help ?? "")
    }
}

struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let message: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// A notice with an icon, message and optional recovery text.
struct NoticeView: View {
    enum Kind { case info, warning, error, success }
    let kind: Kind
    let title: String
    var message: String?
    var action: (title: String, run: () -> Void)?

    private var tint: Color {
        switch kind {
        case .info: return .accentColor
        case .warning: return .orange
        case .error: return .red
        case .success: return .green
        }
    }

    private var symbol: String {
        switch kind {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .success: return "checkmark.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                if let message {
                    Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if let action {
                Button(action.title, action: action.run).controlSize(.small)
            }
        }
        .padding(10)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

extension DroidDeckError {
    var alertMessage: String {
        [recovery, detail.map { "Details:\n\($0.prefix(1200))" }].compactMap { $0 }.joined(separator: "\n\n")
    }
}

extension View {
    /// Presents `AppModel.presentedError` as an alert.
    func errorAlert(_ model: AppModel) -> some View {
        @Bindable var model = model
        return alert(model.presentedError?.message ?? "Error",
                     isPresented: Binding(get: { model.presentedError != nil }, set: { if !$0 { model.presentedError = nil } }),
                     presenting: model.presentedError) { _ in
            Button("OK") { model.presentedError = nil }
        } message: { error in
            Text(error.alertMessage)
        }
    }
}

func formatBytes(_ bytes: Int64) -> String { ByteFormat.string(bytes) }
