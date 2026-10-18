public struct Job: Sendable, Equatable {
    public let id: String
    public let input: Int

    public init(id: String, input: Int) {
        self.id = id
        self.input = input
    }
}

public enum JobOutcome: Sendable, Equatable {
    case succeeded(Int)
    case failed
    case cancelled
}

public struct JobResult: Sendable, Equatable {
    public let id: String
    public let outcome: JobOutcome

    public init(id: String, outcome: JobOutcome) {
        self.id = id
        self.outcome = outcome
    }
}

public enum TaskProcessorError: Error, Equatable {
    case nonPositiveMaximumConcurrency
    case duplicateID(String)
}

public actor TaskProcessor {
    private let maximumConcurrency: Int

    public init(maximumConcurrency: Int) throws {
        guard maximumConcurrency > 0 else {
            throw TaskProcessorError.nonPositiveMaximumConcurrency
        }
        self.maximumConcurrency = maximumConcurrency
    }

    public func process(
        _ jobs: [Job],
        worker: @escaping @Sendable (Job) async throws -> Int
    ) async throws -> [JobResult] {
        var seenIDs = Set<String>()
        for job in jobs {
            if seenIDs.contains(job.id) {
                throw TaskProcessorError.duplicateID(job.id)
            }
            seenIDs.insert(job.id)
        }

        var outcomes = [JobOutcome?](repeating: nil, count: jobs.count)
        let limit = maximumConcurrency

        await withTaskGroup(of: (index: Int, outcome: JobOutcome).self) { group in
            var nextIndex = 0
            var running = 0

            while true {
                if Task.isCancelled {
                    group.cancelAll()
                } else {
                    while running < limit && nextIndex < jobs.count {
                        let index = nextIndex
                        let job = jobs[index]
                        group.addTask {
                            let outcome = await Self.outcome(of: job, using: worker)
                            return (index: index, outcome: outcome)
                        }
                        nextIndex += 1
                        running += 1
                    }
                }

                guard let finished = await group.next() else {
                    break
                }
                running -= 1
                outcomes[finished.index] = finished.outcome
            }
        }

        return jobs.indices.map { index in
            JobResult(id: jobs[index].id, outcome: outcomes[index] ?? .cancelled)
        }
    }


    private static func outcome(
        of job: Job,
        using worker: @Sendable (Job) async throws -> Int
    ) async -> JobOutcome {
        do {
            return .succeeded(try await worker(job))
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed
        }
    }
}



public struct RetryPolicy: Sendable, Equatable {
    public let maximumAttempts: Int

    public init(maximumAttempts: Int) throws {
        guard maximumAttempts > 0 else {
            throw RetryPolicyError.nonPositiveMaximumAttempts
        }
        self.maximumAttempts = maximumAttempts
    }
}

public enum RetryPolicyError: Error, Equatable {
    case nonPositiveMaximumAttempts
}

public extension TaskProcessor {
    func process(
        _ jobs: [Job],
        retryPolicy: RetryPolicy,
        worker: @escaping @Sendable (Job, Int) async throws -> Int
    ) async throws -> [JobResult] {
        let maximumAttempts = retryPolicy.maximumAttempts

        return try await process(jobs) { job in
            var attempt = 1
            while true {
                do {
                    return try await worker(job, attempt)
                } catch let cancellation as CancellationError {
                    throw cancellation                 // never retried
                } catch {

                    if attempt >= maximumAttempts || Task.isCancelled {
                        throw error
                    }
                    attempt += 1
                }
            }
        }
    }
}
