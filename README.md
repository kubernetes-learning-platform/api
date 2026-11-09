# api

> **The ASP.NET Core backend (.NET 10):** auth, sessions, the WebSocket gateway, the session event log, scenarios, and the optional AI helper.

Part of [kubernetes-learning-platform](https://github.com/kubernetes-learning-platform/docs), a live Kubernetes lab with an optional AI helper. The [docs repository](https://github.com/kubernetes-learning-platform/docs) describes the overall system.

**Owner:** Person 2 (the Scenarios and Agent libraries and `scenarios/`: Filip) · **Status:** planned layout, scaffolding lands in M1.

---

## Overview

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/api-dark.svg">
  <img src="assets/api-light.svg" width="100%" alt="Inside the api process. The browser calls the controllers over REST and the socket over WebSocket. The socket hands messages to a LiveSession, which uses the Scenarios library, the Agent library and SandboxClient. Events go to EventFanout, which appends them to Postgres and then sends them back out through the socket. The Provisioner publishes start and teardown requests to RabbitMQ, the Agent calls the LLM API, and SandboxClient talks gRPC to envmgr.">
</picture>

`api` is the backend and the only service the browser communicates with. It manages authentication, sessions, scenarios and the session event log. It does not run Kubernetes: each cluster runs in a sandbox on another machine, and `api` relays between the browser and that sandbox while recording the session.

It is a single process composed of three projects:

- **`KubernetesLearning.Api`**: authentication, sessions, the WebSocket endpoint, persistence and the work queue.
- **`KubernetesLearning.Scenarios`**: runs scenarios. It applies each step, evaluates the checks that determine whether a step is complete, and resets a step on request. It has no LLM dependency.
- **`KubernetesLearning.Agent`**: the optional helper. It sends the learner's request to an LLM and executes the typed tools the LLM calls. The LLM API key stays in this process.

| Component | Responsibility |
|---|---|
| **Controllers** | REST endpoints: sign in, start and end sessions, list scenarios, page through the event log |
| **Socket** | The WebSocket for one session. Receives terminal input and chat, and sends terminal output, cluster changes and helper responses |
| **LiveSession** | In-memory state for one running session: the sandbox connection, the scenario runner and, when used, the helper |
| **EventFanout** | Assigns each outgoing message the next sequence number, stores it in Postgres, then sends it to the browser |
| **Provisioner** | Requests a sandbox, and later its deletion, through the RabbitMQ work queue |
| **SandboxClient** | Library from `sandbox` that communicates with `envmgr`. `api` uses only its `ISandboxSession` interface |

### Message flow

1. The browser sends `TerminalInput` over the socket.
2. The `LiveSession` forwards it through `SandboxClient` to the shell in the VM.
3. The shell output returns along the same path.
4. `EventFanout` assigns it a sequence number, appends it to the event log, and sends it to every browser connected to the session.

Storing each message before sending it supports two features. A reconnecting browser requests everything after the last sequence number it received, and replay reads the same log from the beginning.

## REST controllers

| Controller | Routes | Purpose |
|---|---|---|
| `AuthController` | `POST /api/auth/login` · `POST /api/auth/logout` · `GET /api/auth/me` | Delegates to `IAuthProvider`. The mechanism is **OPEN**; the interface is fixed. |
| `SessionsController` | `POST /api/sessions` · `GET /api/sessions` · `GET /api/sessions/{id}` · `DELETE /api/sessions/{id}` | Start, list, inspect and end sessions. A start takes an optional `scenarioId`; without one you get a blank cluster. One active session per user, and one scenario per session. |
| `ScenariosController` | `GET /api/scenarios` · `GET /api/scenarios/{id}` | The scenario catalog for the home screen, with this account's progress. Goals and hints are included; the `helper` notes and `solution` are not. |
| `EventsController` | `GET /api/sessions/{id}/events?afterSeq=&limit=` | Event log pages for the timeline and replay, as protobuf `EventBatch`. |

Request and response bodies are Protobuf messages from [`contracts`](https://github.com/kubernetes-learning-platform/contracts) (`rest.proto`), serialized as proto3 JSON. Health check: `/healthz`.

## WebSocket

`GET /ws/sessions/{id}`: binary frames, each one a `ClientMessage` or `ServerMessage` from `session.proto`.

| Browser → api | api → browser (each with a per-session `seq`) |
|---|---|
| `ChatSend` · `TerminalInput` · `TerminalResize` · `ApplyManifest` · `HelperStop` · `AgentAnswer` · `ScenarioNext` · `StepReset` · `Resync{afterSeq}` | `ChatDelta` · `ChatMessage` · `ToolCallStarted` · `ToolCallFinished` · `AgentQuestion` · `HelperState` · `TopologySnapshot` · `TopologyDiff` · `ClusterEvent` · `ViewIntent` · `FaultMarked` · `FaultReverted` · `TrafficSample` · `ScenarioProgress` · `TerminalOutput` · `SessionStatus` · `Error` |

**Persist, then broadcast.** Every server message is written to the event log before it's sent, with terminal output batched (about 50 ms) first. A reconnecting browser sends `Resync{afterSeq}` and catches up from the log, and replay reads the same log.

**The learner drives.** Terminal input and `ApplyManifest` are accepted by default and refused only while the helper is acting.

## Starting a sandbox

Starts arrive in bursts and capacity is limited, so requests wait in a RabbitMQ work queue ([ADR 0002](https://github.com/kubernetes-learning-platform/docs/blob/main/adr/0002-learner-driven-scenarios-and-scale-target.md)). Only start and teardown use it; everything live streams directly.

1. `POST /api/sessions` creates a `queued` session and publishes `ProvisionRequest` with a publisher confirm. If the broker can't be reached, it returns "try again".
2. The browser sees `SessionStatus{queued, position}`. `api` computes the position from its own `queued` sessions, because RabbitMQ doesn't report it.
3. `ProvisionResult` carries the sandbox id and the `envmgr` address. `api` stores both and opens `Connect`. If the session was cancelled meanwhile, it publishes a teardown instead.
4. A dead-lettered request marks the session failed and tells the browser.
5. Ending a session publishes `TeardownRequest`, so a teardown survives a link drop.

`ISandboxProvisioner` hides all of this, so `Sandbox__Mode=Fake` needs no broker.

## Sandbox link

`api` runs on the Hetzner box, and `envmgr` runs on the Proxmox box at home. They talk gRPC over the WireGuard mesh, so the link can drop ([ADR 0001](https://github.com/kubernetes-learning-platform/docs/blob/main/adr/0001-hosting-and-harness-transport.md)).

When the `Connect` stream for a session breaks:
1. The session goes `SessionStatus{reconnecting}`, and the browser shows it.
2. In-flight agent tool calls fail with a retryable error, so the agent can retry instead of hanging.
3. `SandboxClient` redials with backoff and jitter, because every session reconnects at once. The sandbox keeps running on the Proxmox box the whole time.
4. On reattach, the harness sends a fresh `TopologySnapshot`, which replaces `TopologyCache`, and the session is live again.

Replays and the scenarios' recorded fallback sessions come from Postgres on the Hetzner box, so they still work while the Proxmox box is unreachable.

## Scenarios library

`KubernetesLearning.Scenarios` runs scenarios with no LLM dependency, so everything here works with the helper off.

| Area | Classes |
|---|---|
| Catalog | `ScenarioCatalog`, `ScenarioDefinition`: load one folder per scenario ([format](https://github.com/kubernetes-learning-platform/docs/blob/main/adr/0002-learner-driven-scenarios-and-scale-target.md)) |
| Runner | `ScenarioRunner`: sends the files to the sandbox, applies steps and faults, runs checks through the harness, handles **Next** and **Reset**, and records progress |

The first scenario lives in `scenarios/`. It moves to a `scenarios` repo once the flow is up and working.

## Agent library

`KubernetesLearning.Agent` is the optional helper. It runs the LLM loop inside the api process, and has no ASP.NET or EF Core dependency.

| Area | Classes |
|---|---|
| Loop | `AgentRunner`, one per live session that uses the helper. A turn only starts from a learner's message or answer, and `HelperStop` ends it at the next tool boundary. |
| Seams | `IAgentEventSink` (to api), `ISandboxSession` (to the sandbox, from `SandboxClient`), `ScenarioRunner` (the step's notes, and reset) |
| LLM | `ILlmClient` + one provider (**OPEN**) |
| Tools | `ToolRegistry` with execute, observe, view, fault and interaction tools. `ask_user(question, options[])` suspends the turn until the answer arrives, and `reset_step()` acts on a "reset it" answer. |
| Budget | `TokenBudget`, a hard per-session cap, plus a global limit on concurrent turns. When the budget runs out, the helper turns off and the scenario carries on. |

## Database

Postgres via EF Core + Npgsql:

```
users           (id, display_name, auth_subject, created_at)
sessions        (id, user_id, sandbox_id?, sandbox_host?, scenario_id?, repo_url?, status, tokens_used, created_at, ended_at?)
session_events  (session_id, seq, at, kind, payload bytea)   PK (session_id, seq), append-only
scenario_progress (user_id, scenario_id, step_id, status, helper_demonstrated, updated_at)   PK (user_id, scenario_id, step_id)
```

`payload` is the serialized `ServerMessage`, so replay shows exactly what the browser saw live.

## Layout

```
api/
├── src/
│   ├── KubernetesLearning.Api/      # Person 2
│   │   ├── Controllers/             # Auth, Sessions, Scenarios, Events
│   │   ├── Realtime/                # SessionSocketEndpoint, EventFanout, TopologyCache
│   │   ├── Sessions/                # SessionService, LiveSession, IdleReaper
│   │   ├── Provisioning/            # ISandboxProvisioner, RabbitMqProvisioner, fake
│   │   ├── Auth/                    # IAuthProvider + implementation
│   │   └── Persistence/             # AppDbContext, EventStore, Entities/, Migrations/
│   ├── KubernetesLearning.Scenarios/ # Filip
│   │   └── ScenarioCatalog, ScenarioDefinition, ScenarioRunner
│   └── KubernetesLearning.Agent/    # Filip
│       ├── Llm/  Tools/  Budget/
│       └── Prompts/system.md
├── scenarios/                       # the first scenario (Filip), until the `scenarios` repo exists
├── tests/                           # Api.Tests, Scenarios.Tests, Agent.Tests
├── Dockerfile
└── .github/                         # CODEOWNERS, workflows/ci.yml
```

## Configuration

Env vars only:

| Variable | Purpose |
|---|---|
| `ConnectionStrings__Db` | Postgres connection string |
| `RabbitMq__Url` | The work queue on the Hetzner box. `envmgr`'s address comes from each `ProvisionResult`. |
| `Sandbox__Mode` | `Real` or `Fake` |
| `Llm__Provider` · `Llm__ApiKey` | LLM provider and key. The key never leaves api. |
| `Agent__TokenBudget` | Per-session token cap |
| `Agent__MaxConcurrentTurns` | Global limit on concurrent helper turns |
| `Session__IdleMinutes` | Idle timeout, about 30 by default |

## Local development

No sandbox needed to start. Run Postgres and api from `platform`'s dev Compose with `Sandbox__Mode=Fake`: `FakeSandboxSession` plays a scripted cluster, and no broker is needed. Switch to `Real` once envmgr's Docker provider works.

Installing `KubernetesLearning.Contracts` and `KubernetesLearning.SandboxClient` from GitHub Packages needs a personal access token with `read:packages`. See [contracts → Installing the packages](https://github.com/kubernetes-learning-platform/contracts#installing-the-packages).

## Ownership

`.github/CODEOWNERS` assigns `src/KubernetesLearning.Agent/`, `src/KubernetesLearning.Scenarios/` and `scenarios/` to Filip and everything else to Person 2. On a free plan with private repos, it requests reviews but can't enforce them.

**Ships:** the `api` container image (multi-arch) → GHCR. It runs in Docker Compose on the Hetzner box, behind Caddy, and is only reachable over the WireGuard mesh, which is why a light auth mechanism is enough.

## Further reading

- [ARCHITECTURE §4 Services](https://github.com/kubernetes-learning-platform/docs/blob/main/ARCHITECTURE.md#4-services-and-their-entry-points) (api internals)
- [ARCHITECTURE §6 Key flows](https://github.com/kubernetes-learning-platform/docs/blob/main/ARCHITECTURE.md#6-key-flows) (including control and terminal semantics)

## License

[MIT](LICENSE)
