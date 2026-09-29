# PulseGRPC

## Unreleased

- Add `PulseClientInterceptor`, a grpc-swift v2 client interceptor that logs every RPC attempt to Pulse as a network task: messages as JSON bodies, metadata as headers, `grpc-status`, a synthetic transaction with sizes and timing, and a failure state for non-OK statuses
- Drop request and response bodies that reach `bodySizeLimit` (8 MiB by default), so long streams don't keep every message in memory
- Requires a Pulse build with `NetworkLogger.logTaskCreated(taskId:…)` and `logTaskCompleted(taskId:…)`
