# Copilot instructions: api

This repo is the ASP.NET Core backend (.NET 10) of kubernetes-learning-platform, a live Kubernetes lab with an optional AI helper. It contains `KubernetesLearning.Api` (auth, sessions, WebSocket gateway, event log, work queue), `KubernetesLearning.Scenarios` (scenarios and checks) and `KubernetesLearning.Agent` (the helper's LLM loop and tools). The full design is in the `docs` repo (ARCHITECTURE.md §4.1, §6).

## Shape
- 4 controllers: `Auth`, `Sessions`, `Scenarios`, `Events`. Plus a WebSocket endpoint `/ws/sessions/{id}` that carries binary Protobuf `ClientMessage` / `ServerMessage`, and `/healthz`.
- Message types come from the `KubernetesLearning.Contracts` package. Never hand-write duplicate DTOs. The sandbox is reached only through `ISandboxSession` from `KubernetesLearning.SandboxClient`.
- Postgres via EF Core + Npgsql. Tables `users`, `sessions`, `session_events`, `scenario_progress`. RabbitMQ only for sandbox start and teardown.

## When reviewing, focus on
- **Persist, then broadcast.** Every `ServerMessage` gets the next per-session `seq` and is written to `session_events` **before** it's sent to any socket. Flag any send path that skips `EventStore`. `session_events` is append-only: no updates or deletes. Terminal output is batched before writing.
- **The learner drives.** Terminal input and `ApplyManifest` are accepted by default and refused only while the helper is acting. A helper turn only starts from a learner's message or answer. Flag any other way to start one.
- **Scenarios need no LLM.** `KubernetesLearning.Scenarios` has no dependency on the Agent or an LLM, and checks, hints and reset must work with the helper off.
- **The helper can't fake state.** The topology the browser sees comes only from the sandbox's snapshot/diff stream. The helper emits `ViewIntent`s (focus, highlight, annotate) but never topology.
- **Agent library boundaries.** `KubernetesLearning.Agent` has no ASP.NET Core or EF Core dependency. It talks to api through `IAgentEventSink` and to the sandbox through `ISandboxSession`.
- **Secrets.** The LLM API key lives only in api config. It's never logged, never returned to clients, never sent to the sandbox.
- **Limits.** One active session per user, and one scenario per session. The token budget is enforced per session, with a global limit on concurrent helper turns. Idle sessions are reaped.
- **Work queue.** Publish with confirms and return "try again" if the broker can't be reached, because a message published while disconnected is lost. Handle redelivered results and dead letters. Only start and teardown use the queue: flag live traffic on it.
- **Async correctness.** No sync-over-async, `CancellationToken`s passed through, no unbounded per-connection buffers, WebSocket close handled.
- **Sandbox link drops.** envmgr is a separate process on the same VM and can restart. A dropped `Connect` stream sets `SessionStatus{reconnecting}`, fails in-flight tool calls with a retryable error, and reconnects with backoff and jitter. The fresh snapshot after reattach replaces `TopologyCache`. Flag code that ends the session or hangs a tool call when the link drops.
- **Schema changes** come with an EF Core migration.
- Config is env vars only (`ConnectionStrings__Db`, `RabbitMq__Url`, `Sandbox__Mode`, `Llm__Provider`, `Llm__ApiKey`, `Agent__TokenBudget`, `Agent__MaxConcurrentTurns`, `Session__IdleMinutes`).

## Ownership
`src/KubernetesLearning.Agent/`, `src/KubernetesLearning.Scenarios/` and `scenarios/` belong to Filip. Everything else belongs to Person 2.

## Project-wide rules
- PR titles are Conventional Commits (`feat: short description`), one line, at most 72 characters, no trailing period.
- Files are UTF-8 with LF line endings.

## Don't
- Don't comment on formatting that `dotnet format` or `.editorconfig` handles.
- Keep reviews short. Skip praise and summaries of the diff.
