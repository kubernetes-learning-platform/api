# api

> **The ASP.NET Core backend (.NET 10):** auth, sessions, the WebSocket gateway, the session event log, scenarios, and the optional AI helper.

Part of [kubernetes-learning-platform](https://github.com/kubernetes-learning-platform/docs), a live Kubernetes lab with an optional AI helper. The [docs repository](https://github.com/kubernetes-learning-platform/docs) describes the overall system.

**Owners:** Person 2 and Person 3, by feature (the Scenarios and Agent libraries and `scenarios/`: Filip) · **Status:** scaffolded. The three projects are empty apart from `/healthz`, and build in CI; there are no tests yet.

---

## Overview

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/api-dark.svg">
  <img src="assets/api-light.svg" width="100%" alt="Inside the api process. The browser calls the controllers over REST and the socket over WebSocket. The socket hands messages to a LiveSession, which uses the Scenarios library, the Agent library and SandboxClient. Events go to EventFanout, which appends them to Postgres and then sends them back out through the socket. The Provisioner publishes start and teardown requests to RabbitMQ, the Agent calls the LLM API, and SandboxClient talks gRPC to envmgr.">
</picture>

`api` is the backend and the only service the browser communicates with. It manages authentication, sessions, scenarios and the session event log. It does not run Kubernetes: each cluster runs in its own sandbox, managed by `envmgr`, and `api` relays between the browser and that sandbox while recording the session.

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
2. The `LiveSession` forwards it through `SandboxClient` to the shell in the sandbox.
3. The shell output returns along the same path.
4. `EventFanout` assigns it a sequence number, appends it to the event log, and sends it to every browser connected to the session.

Storing each message before sending it supports two features. A reconnecting browser requests everything after the last sequence number it received, and replay reads the same log from the beginning.

## REST controllers

| Controller | Routes | Purpose |
|---|---|---|
| `AuthController` | `POST /api/auth/login` · `POST /api/auth/logout` · `GET /api/auth/me` | Delegates to `IAuthProvider`. For now that's `NameOnlyAuthProvider`: you sign in with a display name, and the name is the account. A sturdier mechanism can replace it later (OPEN). |
| `SessionsController` | `POST /api/sessions` · `GET /api/sessions` · `GET /api/sessions/{id}` · `DELETE /api/sessions/{id}` | Start, list, inspect and end sessions. A start takes an optional `scenarioId`; without one you get a blank cluster. One active session per user, and one scenario per session. |
| `ScenariosController` | `GET /api/scenarios` · `GET /api/scenarios/{id}` | The scenario catalog for the home screen, with this account's progress. Goals and hint counts are included. Hint text arrives over the socket, and the `helper` notes and `solution` are never sent. |
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
5. Ending a session publishes `TeardownRequest`, so a teardown survives an `envmgr` restart.

`ISandboxProvisioner` hides all of this, so `Sandbox__Mode=Fake` needs no broker.

## Sandbox link

`api` runs in the stack on the course VM, and `envmgr` runs as a systemd service on the same VM ([ADR 0003](https://github.com/kubernetes-learning-platform/docs/blob/main/adr/0003-course-vm-hosting.md)). They talk gRPC on the same machine, but `envmgr` is a separate process and can restart, so the link can still drop.

When the `Connect` stream for a session breaks:
1. The session goes `SessionStatus{reconnecting}`, and the browser shows it.
2. In-flight agent tool calls fail with a retryable error, so the agent can retry instead of hanging.
3. `SandboxClient` redials with backoff and jitter, because every session reconnects at once. The sandbox keeps running the whole time.
4. On reattach, the harness sends a fresh `TopologySnapshot`, which replaces `TopologyCache`, and the session is live again.

Replays and the scenarios' recorded fallback sessions come from Postgres, so they still work when no sandbox can start.

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
│   ├── KubernetesLearning.Api/      # Person 2 and Person 3
│   │   ├── Controllers/             # Auth, Sessions, Scenarios, Events
│   │   ├── Realtime/                # SessionSocketEndpoint, EventFanout, TopologyCache
│   │   ├── Sessions/                # SessionService, LiveSession, IdleReaper
│   │   ├── Provisioning/            # ISandboxProvisioner, RabbitMqProvisioner, fake
│   │   ├── Auth/                    # IAuthProvider, NameOnlyAuthProvider
│   │   └── Persistence/             # AppDbContext, EventStore, Entities/, Migrations/
│   ├── KubernetesLearning.Scenarios/ # Filip
│   │   └── ScenarioCatalog, ScenarioDefinition, ScenarioRunner
│   └── KubernetesLearning.Agent/    # Filip
│       ├── Llm/  Tools/  Budget/
│       └── Prompts/system.md
├── scenarios/                       # the first scenario (Filip), until the `scenarios` repo exists
├── tests/                           # later: Api.Tests, Scenarios.Tests, Agent.Tests
├── KubernetesLearning.Api.slnx
├── global.json                      # SDK 10.0
├── nuget.config                     # nuget.org, plus GitHub Packages for KubernetesLearning.*
├── Directory.Packages.props         # package versions, including KubernetesLearning.Contracts
├── Directory.Build.props            # copy from platform/lint, like .editorconfig; .lint-sync records the commit
├── compose.yaml                     # local dev only: includes platform's dev Compose (Postgres, Caddy)
├── Dockerfile                       # SDK build, chiseled ASP.NET runtime, port 8080
└── .github/                         # CODEOWNERS, workflows/: ci.yml, and contracts-bump.yml and lint-sync.yml for the update bot
```

## Configuration

Env vars only:

| Variable | Purpose |
|---|---|
| `ConnectionStrings__Db` | Postgres connection string |
| `RabbitMq__Url` | The work queue in the stack. `envmgr`'s address comes from each `ProvisionResult`. |
| `Sandbox__Mode` | `Real` or `Fake` |
| `Llm__Provider` · `Llm__ApiKey` | LLM provider and key. The key never leaves api. |
| `Agent__TokenBudget` | Per-session token cap |
| `Agent__MaxConcurrentTurns` | Global limit on concurrent helper turns |
| `Session__IdleMinutes` | Idle timeout, about 30 by default |

## Packages

`KubernetesLearning.Contracts`, and later `KubernetesLearning.SandboxClient`, come from GitHub Packages, which needs a token even to read a public package. `nuget.config` maps `KubernetesLearning.*` to the organization's feed and reads the token from `GITHUB_PACKAGES_TOKEN`; everything else comes from nuget.org. Once, give the GitHub CLI the `read:packages` scope, then export the token before restoring:

```bash
gh auth refresh --hostname github.com --scopes read:packages
```

```bash
export GITHUB_PACKAGES_TOKEN="$(gh auth token)"
```

A classic personal access token with `read:packages` works too. CI passes its own `GITHUB_TOKEN`, and the image build takes the token as a build secret:

```bash
docker build --secret id=github-packages-token,env=GITHUB_PACKAGES_TOKEN --tag api .
```

The version is pinned once, in `Directory.Packages.props` (Central Package Management), and the projects reference the package without a version, so the update bot can bump it.

## Local development

Set `GITHUB_PACKAGES_TOKEN` first (see [Packages](#packages)). Build with `dotnet build -c Release` and check formatting with `dotnet format --verify-no-changes`. `dotnet run --project src/KubernetesLearning.Api` serves `/healthz` on `http://localhost:5149` (set in `Properties/launchSettings.json`, used only by `dotnet run`), and the `docker build` command under [Packages](#packages) builds the image, which listens on port 8080. There are no tests yet.

No sandbox needed. `docker compose up -d --wait` in this repo starts Postgres and Caddy: `compose.yaml` includes `platform`'s dev Compose, so clone `platform` next to this repo. It's the same stack `web` starts, and `docker compose down` stops it (`down -v` also deletes the database). `platform`'s README has the routes and `ConnectionStrings__Db`. Run api with `Sandbox__Mode=Fake`: `FakeSandboxSession` plays a scripted cluster, picked with `Sandbox__FakeScript`, and no broker is needed. Caddy serves `web` and `api` together on `http://localhost:8080`, with the same routes as production. `Real` mode comes in Milestone 2.

## Ownership

`src/KubernetesLearning.Agent/`, `src/KubernetesLearning.Scenarios/` and `scenarios/` are Filip's; everything else is shared by Person 2 and Person 3, who split the work by feature. `.github/CODEOWNERS` requests Filip's review on every PR, and merging needs one approval from anyone other than the author.

**Ships:** the `api` container image (multi-arch) → GHCR. It runs in the stack on the course VM, behind Caddy, and is only reachable over Tailscale, which is why a light auth mechanism is enough. A merge to `main` publishes an image tagged with the commit SHA, and a manual deploy picks which one runs.

## Further reading

- [ARCHITECTURE §4 Services](https://github.com/kubernetes-learning-platform/docs/blob/main/ARCHITECTURE.md#4-services-and-their-entry-points) (api internals)
- [ARCHITECTURE §6 Key flows](https://github.com/kubernetes-learning-platform/docs/blob/main/ARCHITECTURE.md#6-key-flows) (including control and terminal semantics)

## License

[MIT](LICENSE)
