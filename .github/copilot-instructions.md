# Copilot instructions: api

This repo is the ASP.NET Core backend (.NET 10) of kubernetes-learning-platform, an AI tutor with a live Kubernetes lab. It contains `KubernetesLearning.Api` (auth, sessions, WebSocket gateway, event log) and `KubernetesLearning.Agent` (the LLM loop and tools). The full design is in the `docs` repo (ARCHITECTURE.md §4.1, §6).

## Shape
- 4 controllers: `Auth`, `Sessions`, `Lessons`, `Events`. Plus a WebSocket endpoint `/ws/sessions/{id}` that carries binary Protobuf `ClientMessage` / `ServerMessage`, and `/healthz`.
- Message types come from the `KubernetesLearning.Contracts` package. Never hand-write duplicate DTOs. The sandbox is reached only through `ISandboxSession` from `KubernetesLearning.SandboxClient`.
- Postgres via EF Core + Npgsql. Tables `users`, `sessions`, `session_events`.

## When reviewing, focus on
- **Persist, then broadcast.** Every `ServerMessage` gets the next per-session `seq` and is written to `session_events` **before** it's sent to any socket. Flag any send path that skips `EventStore`. `session_events` is append-only: no updates or deletes.
- **Control lock.** One driver at a time. While the user holds control, the agent may only use observe and view tools: no exec, no faults, no manifest apply. Terminal input and `ApplyManifest` are only accepted from the controller.
- **The agent can't fake state.** The topology the browser sees comes only from the sandbox's snapshot/diff stream. The agent emits `ViewIntent`s (focus, highlight, annotate) but never topology.
- **Agent library boundaries.** `KubernetesLearning.Agent` has no ASP.NET Core or EF Core dependency. It talks to api through `IAgentEventSink` and to the sandbox through `ISandboxSession`.
- **Secrets.** The LLM API key lives only in api config. It's never logged, never returned to clients, never sent to the sandbox.
- **Limits.** One active session per user. The token budget is enforced per session. Idle sessions are reaped.
- **Async correctness.** No sync-over-async, `CancellationToken`s passed through, no unbounded per-connection buffers, WebSocket close handled.
- **Sandbox link drops.** envmgr is on another machine across the WireGuard mesh. A dropped `Connect` stream sets `SessionStatus{reconnecting}`, fails in-flight tool calls with a retryable error, and reconnects with backoff. The fresh snapshot after reattach replaces `TopologyCache`. Flag code that ends the session or hangs a tool call when the link drops.
- **Schema changes** come with an EF Core migration.
- Config is env vars only (`ConnectionStrings__Db`, `EnvManager__Address`, `Sandbox__Mode`, `Llm__Provider`, `Llm__ApiKey`, `Agent__TokenBudget`, `Session__IdleMinutes`).

## Ownership
`src/KubernetesLearning.Agent/` and `lessons/` belong to Filip. Everything else belongs to Person 2.

## Project-wide rules
- PR titles are Conventional Commits (`feat: short description`), one line, at most 72 characters, no trailing period.
- Files are UTF-8 with LF line endings.

## Don't
- Don't comment on formatting that `dotnet format` or `.editorconfig` handles.
- Keep reviews short. Skip praise and summaries of the diff.
