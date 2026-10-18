import XCTest
@testable import TaskProcessor

// MARK: - Test helpers

private enum StudentWorkerError: Error {
    case boom
}

/// Blocks a worker until the test releases its job ID.
private actor JobGate {
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<String> = []
    private var waitingObservers: [String: [CheckedContinuation<Void, Never>]] = [:]

    func wait(for id: String) async {
        if released.remove(id) != nil {
            return
        }
        await withCheckedContinuation { continuation in
            waiters[id] = continuation
            for observer in waitingObservers.removeValue(forKey: id) ?? [] {
                observer.resume()
            }
        }
    }

    func waitUntilWaiting(for id: String) async {
        if waiters[id] != nil {
            return
        }
        await withCheckedContinuation { continuation in
            waitingObservers[id, default: []].append(continuation)
        }
    }

    func release(_ id: String) {
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.resume()
        } else {
            released.insert(id)
        }
    }
}

/// Records which jobs started and finished, and the peak number of active workers.
private actor WorkerProbe {
    private(set) var started: [String] = []
    private(set) var finished: [String] = []
    private(set) var maximumActive = 0
    private var active = 0
    private var finishObservers: [String: [CheckedContinuation<Void, Never>]] = [:]

    func begin(_ id: String) {
        started.append(id)
        active += 1
        maximumActive = max(maximumActive, active)
    }

    func end(_ id: String) {
        active -= 1
        finished.append(id)
        for observer in finishObservers.removeValue(forKey: id) ?? [] {
            observer.resume()
        }
    }

    func waitUntilFinished(_ id: String) async {
        if finished.contains(id) {
            return
        }
        await withCheckedContinuation { continuation in
            finishObservers[id, default: []].append(continuation)
        }
    }
}

/// Records every (job, attempt) call made by a retry worker.
private actor AttemptLog {
    private(set) var calls: [String] = []

    func record(_ id: String, _ attempt: Int) {
        calls.append("\(id)#\(attempt)")
    }
}

// MARK: - Tests

@MainActor
final class TaskProcessorStudentTests: XCTestCase {

    // MARK: Configuration and input validation

    func testNegativeMaximumConcurrencyIsRejected() {
        XCTAssertThrowsError(try TaskProcessor(maximumConcurrency: -3)) { error in
            XCTAssertEqual(error as? TaskProcessorError, .nonPositiveMaximumConcurrency)
        }
    }

    func testFirstRepeatedIDThrowsBeforeAnyWorkerStarts() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 4)
        let probe = WorkerProbe()
        // "a" repeats at index 2, before "b" repeats at index 3.
        let jobs = ["a", "b", "a", "b"].map { Job(id: $0, input: 1) }

        do {
            _ = try await processor.process(jobs) { job in
                await probe.begin(job.id)
                return job.input
            }
            XCTFail("Expected duplicateID")
        } catch {
            XCTAssertEqual(error as? TaskProcessorError, .duplicateID("a"))
        }

        let started = await probe.started
        XCTAssertEqual(started, [])
    }

    // MARK: Bounded scheduling

    func testConcurrencyLimitIsRespectedAndFreedSlotStartsNextJobInOrder() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let gate = JobGate()
        let probe = WorkerProbe()
        let jobs = ["a", "b", "c", "d"].map { Job(id: $0, input: 1) }

        let processing = Task {
            try await processor.process(jobs) { job in
                await probe.begin(job.id)
                await gate.wait(for: job.id)
                await probe.end(job.id)
                return job.input
            }
        }

        await gate.waitUntilWaiting(for: "a")
        await gate.waitUntilWaiting(for: "b")
        var started = await probe.started
        XCTAssertEqual(started, ["a", "b"])

        // Freeing one slot starts exactly the next unstarted job.
        await gate.release("a")
        await gate.waitUntilWaiting(for: "c")
        started = await probe.started
        XCTAssertEqual(started, ["a", "b", "c"])

        await gate.release("b")
        await gate.waitUntilWaiting(for: "d")
        await gate.release("c")
        await gate.release("d")

        let results = try await processing.value
        XCTAssertEqual(results.map(\.id), ["a", "b", "c", "d"])
        let maximumActive = await probe.maximumActive
        XCTAssertEqual(maximumActive, 2)
    }

    // MARK: Stable result ordering

    func testResultsKeepInputOrderWhenJobsFinishInReverse() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 3)
        let gate = JobGate()
        let probe = WorkerProbe()
        let jobs = [
            Job(id: "a", input: 1),
            Job(id: "b", input: 2),
            Job(id: "c", input: 3)
        ]

        let processing = Task {
            try await processor.process(jobs) { job in
                await probe.begin(job.id)
                await gate.wait(for: job.id)
                await probe.end(job.id)
                return job.input * 100
            }
        }

        for id in ["a", "b", "c"] {
            await gate.waitUntilWaiting(for: id)
        }
        for id in ["c", "b", "a"] {
            await gate.release(id)
            await probe.waitUntilFinished(id)
        }

        let results = try await processing.value
        let finishOrder = await probe.finished
        XCTAssertEqual(finishOrder, ["c", "b", "a"])
        XCTAssertEqual(results, [
            JobResult(id: "a", outcome: .succeeded(100)),
            JobResult(id: "b", outcome: .succeeded(200)),
            JobResult(id: "c", outcome: .succeeded(300))
        ])
    }

    // MARK: Outcome handling

    func testMixedOutcomesMapCorrectlyAndOtherJobsContinue() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let jobs = [
            Job(id: "ok", input: 5),
            Job(id: "fails", input: 0),
            Job(id: "cancels", input: 0),
            Job(id: "ok-after", input: 7)
        ]

        let results = try await processor.process(jobs) { job in
            switch job.id {
            case "fails":
                throw StudentWorkerError.boom
            case "cancels":
                throw CancellationError()
            default:
                return job.input * 2
            }
        }

        XCTAssertEqual(results, [
            JobResult(id: "ok", outcome: .succeeded(10)),
            JobResult(id: "fails", outcome: .failed),
            JobResult(id: "cancels", outcome: .cancelled),
            JobResult(id: "ok-after", outcome: .succeeded(14))
        ])
    }

    // MARK: Cooperative cancellation

    func testCallerCancellationStopsQueuedJobsFromStarting() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let gate = JobGate()
        let probe = WorkerProbe()
        let jobs = ["a", "b", "c"].map { Job(id: $0, input: 1) }

        let processing = Task {
            try await processor.process(jobs) { job in
                await probe.begin(job.id)
                await gate.wait(for: job.id)
                await probe.end(job.id)
                try Task.checkCancellation()   // cooperative worker
                return job.input
            }
        }

        await gate.waitUntilWaiting(for: "a")
        processing.cancel()
        await gate.release("a")

        let results = try await processing.value
        XCTAssertEqual(results, [
            JobResult(id: "a", outcome: .cancelled),
            JobResult(id: "b", outcome: .cancelled),
            JobResult(id: "c", outcome: .cancelled)
        ])
        let started = await probe.started
        XCTAssertEqual(started, ["a"])
    }

    func testJobCompletedBeforeCancellationKeepsItsResult() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let gate = JobGate()
        let probe = WorkerProbe()
        let jobs = [
            Job(id: "a", input: 4),
            Job(id: "b", input: 5),
            Job(id: "c", input: 6)
        ]

        let processing = Task {
            try await processor.process(jobs) { job in
                await probe.begin(job.id)
                await gate.wait(for: job.id)
                await probe.end(job.id)
                try Task.checkCancellation()
                return job.input
            }
        }

        await gate.waitUntilWaiting(for: "a")
        await gate.release("a")
        // With limit 1, "b" only starts after "a" has completed and been recorded.
        await gate.waitUntilWaiting(for: "b")
        processing.cancel()
        await gate.release("b")

        let results = try await processing.value
        XCTAssertEqual(results, [
            JobResult(id: "a", outcome: .succeeded(4)),
            JobResult(id: "b", outcome: .cancelled),
            JobResult(id: "c", outcome: .cancelled)
        ])
        let started = await probe.started
        XCTAssertEqual(started, ["a", "b"])
    }

    // MARK: Bonus: retry policy

    func testRetryPolicyRejectsNonPositiveAttempts() {
        for attempts in [0, -1] {
            XCTAssertThrowsError(try RetryPolicy(maximumAttempts: attempts)) { error in
                XCTAssertEqual(error as? RetryPolicyError, .nonPositiveMaximumAttempts)
            }
        }
    }

    func testRetryRecoversBeforeTheLimitWithExactAttemptNumbers() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let log = AttemptLog()

        let results = try await processor.process(
            [Job(id: "a", input: 1)],
            retryPolicy: try RetryPolicy(maximumAttempts: 5)
        ) { job, attempt in
            await log.record(job.id, attempt)
            if attempt < 3 {
                throw StudentWorkerError.boom
            }
            return attempt * 10
        }

        XCTAssertEqual(results, [JobResult(id: "a", outcome: .succeeded(30))])
        let calls = await log.calls
        XCTAssertEqual(calls, ["a#1", "a#2", "a#3"])
    }

    func testRetryStopsAtFinalAttemptAndReportsFailed() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let log = AttemptLog()

        let results = try await processor.process(
            [Job(id: "a", input: 1)],
            retryPolicy: try RetryPolicy(maximumAttempts: 3)
        ) { job, attempt in
            await log.record(job.id, attempt)
            throw StudentWorkerError.boom
        }

        XCTAssertEqual(results, [JobResult(id: "a", outcome: .failed)])
        let calls = await log.calls
        XCTAssertEqual(calls, ["a#1", "a#2", "a#3"])
    }

    func testCancellationErrorIsNeverRetried() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let log = AttemptLog()

        let results = try await processor.process(
            [Job(id: "a", input: 1)],
            retryPolicy: try RetryPolicy(maximumAttempts: 3)
        ) { job, attempt in
            await log.record(job.id, attempt)
            throw CancellationError()
        }

        XCTAssertEqual(results, [JobResult(id: "a", outcome: .cancelled)])
        let calls = await log.calls
        XCTAssertEqual(calls, ["a#1"])
    }

    func testRetriesStayInsideTheJobsSlotAndKeepInputOrder() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let log = AttemptLog()
        let jobs = [Job(id: "a", input: 1), Job(id: "b", input: 2)]

        let results = try await processor.process(
            jobs,
            retryPolicy: try RetryPolicy(maximumAttempts: 2)
        ) { job, attempt in
            await log.record(job.id, attempt)
            if job.id == "a" && attempt == 1 {
                throw StudentWorkerError.boom
            }
            return job.input
        }

        // With one slot, "b" cannot start until all of "a"'s attempts are done.
        let calls = await log.calls
        XCTAssertEqual(calls, ["a#1", "a#2", "b#1"])
        XCTAssertEqual(results, [
            JobResult(id: "a", outcome: .succeeded(1)),
            JobResult(id: "b", outcome: .succeeded(2))
        ])
    }
}
