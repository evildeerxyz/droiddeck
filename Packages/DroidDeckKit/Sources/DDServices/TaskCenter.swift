import Foundation
import Observation
import DDCore
import DDPlatform
import DDPersistence

/// Visible, cancellable long-running operations with an operation history.
@MainActor
@Observable
public final class TaskCenter {
    public enum Status: Equatable, Sendable {
        case running
        case succeeded
        case failed(String)
        case cancelled

        public var isFinished: Bool { self != .running }
    }

    public struct TrackedTask: Identifiable, Equatable, Sendable {
        public let id: UUID
        public var title: String
        public var deviceName: String?
        public var status: Status
        public var progress: Double?
        public var detail: String?
        public var startedAt: Date
        public var finishedAt: Date?
        public var cancellable: Bool
        public var error: DroidDeckError?
    }

    public private(set) var tasks: [TrackedTask] = []
    public private(set) var history: [OperationRecord] = []
    private var handles: [UUID: Task<Void, Never>] = [:]
    private let historyStore: OperationHistoryStore

    public init(historyStore: OperationHistoryStore) {
        self.historyStore = historyStore
        Task { [weak self] in
            let loaded = await historyStore.load()
            self?.history = loaded
        }
    }

    public var activeTasks: [TrackedTask] { tasks.filter { !$0.status.isFinished } }

    /// Reports progress from any isolation domain.
    public struct Reporter: Sendable {
        let id: UUID
        let center: TaskCenter

        public func update(progress: Double? = nil, detail: String? = nil) {
            Task { @MainActor in center.update(id: id, progress: progress, detail: detail) }
        }
    }

    @discardableResult
    public func run(_ title: String, device: String? = nil, cancellable: Bool = true,
                    operation: @escaping @Sendable (Reporter) async throws -> Void) -> UUID {
        let id = UUID()
        tasks.insert(TrackedTask(id: id, title: title, deviceName: device, status: .running, progress: nil, detail: nil,
                                 startedAt: Date(), finishedAt: nil, cancellable: cancellable, error: nil), at: 0)
        let reporter = Reporter(id: id, center: self)
        handles[id] = Task { [weak self] in
            do {
                try await operation(reporter)
                self?.finish(id: id, status: .succeeded, error: nil)
            } catch is CancellationError {
                self?.finish(id: id, status: .cancelled, error: nil)
            } catch let error as DroidDeckError where error.kind == .cancelled {
                self?.finish(id: id, status: .cancelled, error: nil)
            } catch let error as DroidDeckError {
                self?.finish(id: id, status: .failed(error.message), error: error)
            } catch {
                let wrapped = DroidDeckError(.toolFailed, Redactor.redact(String(describing: error)))
                self?.finish(id: id, status: .failed(wrapped.message), error: wrapped)
            }
        }
        return id
    }

    /// Runs and awaits an operation while still tracking it.
    public func perform<T: Sendable>(_ title: String, device: String? = nil,
                                     operation: @escaping @Sendable (Reporter) async throws -> T) async throws -> T {
        let id = UUID()
        tasks.insert(TrackedTask(id: id, title: title, deviceName: device, status: .running, progress: nil, detail: nil,
                                 startedAt: Date(), finishedAt: nil, cancellable: false, error: nil), at: 0)
        do {
            let value = try await operation(Reporter(id: id, center: self))
            finish(id: id, status: .succeeded, error: nil)
            return value
        } catch let error as DroidDeckError {
            finish(id: id, status: error.kind == .cancelled ? .cancelled : .failed(error.message), error: error)
            throw error
        } catch {
            finish(id: id, status: .failed(Redactor.redact(String(describing: error))), error: nil)
            throw error
        }
    }

    public func cancel(_ id: UUID) {
        handles[id]?.cancel()
    }

    public func clearFinished() {
        tasks.removeAll { $0.status.isFinished }
    }

    fileprivate func update(id: UUID, progress: Double?, detail: String?) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        if let progress { tasks[index].progress = min(max(progress, 0), 1) }
        if let detail { tasks[index].detail = detail }
    }

    private func finish(id: UUID, status: Status, error: DroidDeckError?) {
        handles[id] = nil
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].status = status
        tasks[index].finishedAt = Date()
        tasks[index].error = error
        if status == .succeeded { tasks[index].progress = 1 }
        let task = tasks[index]
        let outcome: OperationRecord.Outcome
        let message: String?
        switch status {
        case .succeeded: outcome = .succeeded; message = nil
        case .cancelled: outcome = .cancelled; message = nil
        case .failed(let text): outcome = .failed; message = text
        case .running: return
        }
        let record = OperationRecord(title: task.title, deviceName: task.deviceName, startedAt: task.startedAt,
                                     finishedAt: Date(), outcome: outcome, message: message)
        history.insert(record, at: 0)
        if history.count > 500 { history.removeLast(history.count - 500) }
        let store = historyStore
        Task { await store.append(record) }
        switch status {
        case .failed(let text): log.error("task", "\(task.title) failed: \(text)\(error?.detail.map { " — \($0.prefix(500))" } ?? "")")
        default: log.info("task", "\(task.title): \(outcome.rawValue)")
        }
        // Successful tasks disappear from the active list after a short delay.
        if status == .succeeded {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                self?.tasks.removeAll { $0.id == id }
            }
        }
    }
}
