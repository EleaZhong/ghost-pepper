import Foundation

/// A serial async drain: work items run one at a time, in enqueue order. Dictation
/// processing (transcribe → cleanup → paste) goes through here so a new recording can
/// start while earlier clips are still processing — recording never blocks on the model.
/// Serial in-order processing also keeps paste order trivially correct and matches the
/// hardware truth: one ANE runs one inference at a time anyway.
actor ProcessingQueue {
    private var tail: Task<Void, Never> = Task {}

    func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let previous = tail
        tail = Task {
            await previous.value
            await work()
        }
    }
}
