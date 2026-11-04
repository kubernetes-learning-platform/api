# api

> **The ASP.NET Core backend (.NET 10):** auth, sessions, the WebSocket gateway, the session event log, and the AI agent loop.

Part of [**kubernetes-learning-platform**](https://github.com/kubernetes-learning-platform/docs), an AI tutor with a live Kubernetes lab. Start at the [docs hub](https://github.com/kubernetes-learning-platform/docs) for the big picture.

**Owner:** Person 2 (the Agent library and `lessons/`: Filip) · **Status:** planned layout, scaffolding lands in M1.

---

## 🌐 REST controllers

| Controller | Routes | Purpose |
|---|---|---|
| `AuthController` | `POST /api/auth/login` · `POST /api/auth/logout` · `GET /api/auth/me` | Delegates to `IAuthProvider`. The mechanism is **OPEN**; the interface is fixed. |
| `SessionsController` | `POST /api/sessions` · `GET /api/sessions` · `GET /api/sessions/{id}` · `DELETE /api/sessions/{id}` | Start, list, inspect and end sessions. One active session per user. |
| `LessonsController` | `GET /api/lessons` · `GET /api/lessons/{id}` | The curated lesson catalog for the home screen. |
| `EventsController` | `GET /api/sessions/{id}/events?afterSeq=&limit=` | Event log pages for the timeline and replay, as protobuf `EventBatch`. |

Request and response bodies are Protobuf messages from [`contracts`](https://github.com/kubernetes-learning-platform/contracts) (`rest.proto`), serialized as proto3 JSON. Health check: `/healthz`.

## 💬 WebSocket

`GET /ws/sessions/{id}`: binary frames, each one a `ClientMessage` or `ServerMessage` from `session.proto`.

| Browser → api | api → browser (each with a per-session `seq`) |
|---|---|
| `ChatSend` · `TerminalInput` · `TerminalResize` · `ApplyManifest` · `ControlTake` · `ControlRelease` · `AgentPause` · `AgentResume` · `Resync{afterSeq}` | `ChatDelta` · `ChatMessage` · `ToolCallStarted` · `ToolCallFinished` · `TopologySnapshot` · `TopologyDiff` · `ClusterEvent` · `ViewIntent` · `FaultMarked` · `FaultReverted` · `TrafficSample` · `LessonProgress` · `TerminalOutput` · `ControlState` · `SessionStatus` · `Error` |

**Persist, then broadcast.** Every server message is written to the event log before it's sent. A reconnecting browser sends `Resync{afterSeq}` and catches up from the log, and replay reads the same log.

## 🔗 Sandbox link

`api` runs on the Hetzner box, and `envmgr` runs on the Proxmox box at home. They talk gRPC over the WireGuard mesh, so the link can drop ([ADR 0001](https://github.com/kubernetes-learning-platform/docs/blob/main/adr/0001-hosting-and-harness-transport.md)).

When the `Connect` stream for a session breaks:
1. The session goes `SessionStatus{reconnecting}`, and the browser shows it.
2. In-flight agent tool calls fail with a retryable error, so the agent can retry instead of hanging.
3. `SandboxClient` redials with backoff. The sandbox keeps running on the Proxmox box the whole time.
4. On reattach, the harness sends a fresh `TopologySnapshot`, which replaces `TopologyCache`, and the session is live again.

Replays and the lessons' recorded fallback sessions come from Postgres on the Hetzner box, so they still work while the Proxmox box is unreachable.

## 🧠 Agent library

`KubernetesLearning.Agent` runs the LLM loop inside the api process. It has no ASP.NET or EF Core dependency.

| Area | Classes |
|---|---|
| Loop | `AgentRunner`, one per live session. Pauses at the next tool boundary when the user takes control. |
| Seams | `IAgentEventSink` (to api), `ISandboxSession` (to the sandbox, from `SandboxClient`) |
| LLM | `ILlmClient` + one provider (**OPEN**) |
| Tools | `ToolRegistry` with execute, observe, view, fault and handover tools |
| Budget | `TokenBudget`, a hard per-session cap |
| Lessons | `LessonCatalog`, `LessonDefinition`, `CheckpointEvaluator`, which checks each lesson step against the live cluster |

## 🗄️ Database

Postgres via EF Core + Npgsql:

```
users           (id, display_name, auth_subject, created_at)
sessions        (id, user_id, sandbox_id, lesson_id?, repo_url?, status, tokens_used, created_at, ended_at?)
session_events  (session_id, seq, at, kind, payload bytea)   PK (session_id, seq), append-only
```

`payload` is the serialized `ServerMessage`, so replay shows exactly what the browser saw live.

## 📁 Layout

```
api/
├── src/
│   ├── KubernetesLearning.Api/      # Person 2
│   │   ├── Controllers/             # Auth, Sessions, Lessons, Events
│   │   ├── Realtime/                # SessionSocketEndpoint, EventFanout, TopologyCache
│   │   ├── Sessions/                # SessionService, LiveSession, ControlLock, IdleReaper
│   │   ├── Auth/                    # IAuthProvider + implementation
│   │   └── Persistence/             # AppDbContext, EventStore, Entities/, Migrations/
│   └── KubernetesLearning.Agent/    # Filip
│       ├── Llm/  Tools/  Budget/  Lessons/
│       └── Prompts/system.md
├── lessons/                         # curated lesson YAML (Filip)
├── tests/                           # Api.Tests, Agent.Tests
├── Dockerfile
└── .github/                         # CODEOWNERS, workflows/ci.yml
```

## ⚙️ Configuration

Env vars only:

| Variable | Purpose |
|---|---|
| `ConnectionStrings__Db` | Postgres connection string |
| `EnvManager__Address` | envmgr's gRPC address on the WireGuard mesh, e.g. `http://10.66.0.2:7070` |
| `Sandbox__Mode` | `Real` or `Fake` |
| `Llm__Provider` · `Llm__ApiKey` | LLM provider and key. The key never leaves api. |
| `Agent__TokenBudget` | Per-session token cap |
| `Session__IdleMinutes` | Idle timeout, about 30 by default |

## 🛠️ Local development

No sandbox needed to start. Run Postgres and api from `platform`'s dev Compose with `Sandbox__Mode=Fake`: `FakeSandboxSession` plays a scripted cluster. Switch to `Real` once envmgr's Docker provider works.

Installing `KubernetesLearning.Contracts` and `KubernetesLearning.SandboxClient` from GitHub Packages needs a personal access token with `read:packages`. See [contracts → Installing the packages](https://github.com/kubernetes-learning-platform/contracts#-installing-the-packages).

## 👥 Ownership

`.github/CODEOWNERS` assigns `src/KubernetesLearning.Agent/` and `lessons/` to Filip and everything else to Person 2. On a free plan with private repos, it requests reviews but can't enforce them.

**Ships:** the `api` container image (multi-arch) → GHCR. It runs in Docker Compose on the Hetzner box, behind Caddy, and is only reachable over the WireGuard mesh, which is why a light auth mechanism is enough.

## 📚 More

- [ARCHITECTURE §4 Services](https://github.com/kubernetes-learning-platform/docs/blob/main/ARCHITECTURE.md#4-services-and-their-entry-points) (api internals)
- [ARCHITECTURE §6 Key flows](https://github.com/kubernetes-learning-platform/docs/blob/main/ARCHITECTURE.md#6-key-flows) (including control and terminal semantics)

## 📄 License

[MIT](LICENSE)
