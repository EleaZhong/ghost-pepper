import XCTest
@testable import GhostPepper

final class ProcessingQueueTests: XCTestCase {
    func testRunsWorkSeriallyInEnqueueOrder() async {
        let queue = ProcessingQueue()
        let recorder = Recorder()

        await queue.enqueue { try? await Task.sleep(nanoseconds: 50_000_000); await recorder.append(1) }
        await queue.enqueue { await recorder.append(2) }
        await queue.enqueue { await recorder.append(3) }
        await queue.enqueue { await recorder.append(99) }  // drain marker: runs last by construction

        for _ in 0..<100 where (await recorder.values) != [1, 2, 3, 99] {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let order = await recorder.values
        XCTAssertEqual(order, [1, 2, 3, 99])
    }

    func testRecordingPathIsNotBlockedByInFlightWork() async {
        let queue = ProcessingQueue()
        let recorder = Recorder()

        await queue.enqueue { try? await Task.sleep(nanoseconds: 300_000_000); await recorder.append(1) }
        await queue.enqueue { await recorder.append(2) }
        // the second enqueue returns before the first item finishes: enqueueing never blocks
        let valuesImmediately = await recorder.values
        XCTAssertEqual(valuesImmediately, [])
    }

    private actor Recorder {
        private(set) var values: [Int] = []
        func append(_ value: Int) { values.append(value) }
    }
}
