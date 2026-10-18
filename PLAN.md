# Implementation Plan

Complete this before implementation and update it when the plan changes.

## Approach

- **Validation first.** `init` rejects `maximumConcurrency <= 0`. `process` scans job IDs
  left to right with a `Set` and throws `.duplicateID` for the first repeated ID
  before any worker is started.
- **Bounded scheduling.** Use a `TaskGroup`. Start jobs left to right until
  `maximumConcurrency` are running, then wait for one to finish (`group.next()`)
  and start the next unstarted job in its slot.
- **Indexed results.** Keep one result slot per input job (`[JobOutcome?]`).
  Each child task returns its index, so results are stored by position and the
  output keeps input order no matter which job finishes first.
- **Outcomes.** Worker value → `.succeeded(value)`, `CancellationError` → `.cancelled`,
  any other error → `.failed`. One failed job does not stop the others.
- **Cancellation.** Before starting any new job, check `Task.isCancelled`. If the caller
  cancelled, cancel the running children, start nothing new, wait for running jobs,
  and mark every never-started job as `.cancelled`.
- **Bonus retry.** Same scheduler, but each job runs its attempts in a loop inside its
  own child task (attempts 1...maximumAttempts), so a retry never takes an extra slot.

## Milestones

- [ ] Validate configuration and all job IDs before starting work.
- [ ] Schedule jobs within the concurrency limit and preserve input order.
- [ ] Map success, ordinary errors, and cancellation outcomes.
- [ ] Handle caller cancellation and never-started jobs.
- [ ] Add at least six distinct student-authored tests and run `swift test`.
- [ ] Optional: `RetryPolicy` extension with its own tests.

## Risks and checks

| Risk | Check |
| --- | --- |
| A worker starts before a duplicate ID is found. | Test: IDs `a, b, a, b` throw `.duplicateID("a")` and the worker is never called. |
| More than `maximumConcurrency` workers run at once. | Test with a probe actor that records the maximum number of active workers while a `Gate` keeps them blocked. |
| A free slot is not reused, or jobs start out of order. | Gate test with limit 1: finishing the first job starts the second, not the third. |
| Results come back in completion order. | Gate test: later jobs finish first, result IDs still match input order. |
| `CancellationError` is reported as `.failed`. | Test mixing success, ordinary error and `CancellationError` in one call. |
| Queued jobs still start after the caller cancels. | Test: limit 1, first job blocked, cancel the `process` task; the rest are `.cancelled` and never started. |
| Retry uses extra slots or retries cancellation. | Bonus tests count attempts per job, check `CancellationError` is tried once, and check the active-job maximum. |
| A retry starts after the caller cancelled. | Decision: when the caller cancelled, no new attempt is started and the last ordinary error gives `.failed`. |
| Flaky timing-based tests. | Use `Gate` and probes only, no sleeps or elapsed-time checks. |

Out of scope by contract: workers that ignore cancellation, timeouts, and overlapping
`process` calls on one processor.

