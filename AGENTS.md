# AGENTS.md: api

Instructions for AI coding agents working in this repository. `CLAUDE.md` is a symlink to this file, so Claude Code reads the same instructions.

## What this repo is

The ASP.NET Core backend (.NET 10) of kubernetes-learning-platform, a live Kubernetes lab with an optional AI helper. It is the only service the browser talks to. It handles auth, sessions, scenarios and the session event log, and relays between the browser and the learner's sandbox. It does not run Kubernetes.

| Project | What it is | Owner |
|---|---|---|
| `KubernetesLearning.Api` | Auth, sessions, the WebSocket gateway, persistence, the work queue | Person 2 |
| `KubernetesLearning.Scenarios` | Scenario catalog, runner and checks. No LLM dependency | Filip |
| `KubernetesLearning.Agent` | The optional helper: LLM loop, typed tools, token budget | Filip |

Entry points: 4 controllers (`Auth`, `Sessions`, `Scenarios`, `Events`), the WebSocket endpoint `/ws/sessions/{id}` with binary Protobuf `ClientMessage` / `ServerMessage`, and `/healthz`. Postgres through EF Core and Npgsql. RabbitMQ only for sandbox start and teardown.

- **Owner:** Person 2. Filip owns `src/KubernetesLearning.Agent/`, `src/KubernetesLearning.Scenarios/` and `scenarios/`. Say so when a change touches them.
- **Status:** scaffolded (api#1). The three projects are empty apart from `/healthz`, and build; there are no tests yet.
- **Design:** `README.md` here, and ARCHITECTURE §4.1 and §6 in the `docs` repo. Where they disagree, the `docs` repo wins.

## Layout

```
api/
├── src/
│   ├── KubernetesLearning.Api/        # Controllers/, Realtime/, Sessions/, Provisioning/, Auth/, Persistence/
│   ├── KubernetesLearning.Scenarios/  # ScenarioCatalog, ScenarioDefinition, ScenarioRunner
│   └── KubernetesLearning.Agent/      # AgentRunner, Llm/, Tools/, Budget/, Prompts/
├── scenarios/                         # the first scenario, until the `scenarios` repo exists
├── tests/                             # later: Api.Tests, Scenarios.Tests, Agent.Tests
├── KubernetesLearning.Api.slnx
├── global.json                        # SDK 10.0
├── Directory.Build.props              # copy from platform/lint, like .editorconfig; .lint-sync records the commit
├── Dockerfile                         # SDK build, chiseled ASP.NET runtime, port 8080
└── .github/                           # CODEOWNERS, workflows/: ci.yml, and contracts-bump.yml and lint-sync.yml for the update bot
```

## Build and check

The solution is `KubernetesLearning.Api.slnx`, with SDK 10.0 pinned in `global.json`. Project references go `Api → Scenarios`, `Api → Agent` and `Agent → Scenarios`, never the other way. There are no tests yet. Before saying a change is done, run what CI runs:

- `dotnet format --verify-no-changes`
- `dotnet build -c Release`
- `../platform/lint/sync.sh --check .`, with `platform` at the commit in `.lint-sync`

`dotnet run --project src/KubernetesLearning.Api` listens on `http://localhost:5149`, set in `Properties/launchSettings.json`, which only `dotnet run` and IDEs read. The container listens on 8080. CI (`.github/workflows/ci.yml`) reports `ci / .NET checks` (required in the `main` ruleset) on PRs. The image is built and pushed to GHCR only on merges to `main` (platform#19, not set up yet), and the deploy smoke-tests `/healthz` on the stack (platform#15). `docker build --tag api .` builds it locally; the Dockerfile copies all of `src/`, so a new project needs no Dockerfile change. Local development needs no sandbox: run Postgres from `platform`'s dev Compose and api with `Sandbox__Mode=Fake`. Installing the `contracts` and `SandboxClient` packages from GitHub Packages needs a personal access token with `read:packages`.

**Lint configs.** `.editorconfig`, `Directory.Build.props` and `.lint-sync` are copies from `platform/lint/`: every warning is an error, `AnalysisLevel=latest-recommended`, and code style is enforced on build and by `dotnet format`. Don't edit them here; change `platform/lint/` instead, and CI fails a hand edit. Build settings for this repo go in the `.csproj` files or a nested `Directory.Build.props` that imports the root one. They were made with `lint/sync.sh --dotnet`. Projects fresh from `dotnet new` don't pass as generated: run `dotnet format` once, because the templates ship CRLF line endings and a byte order mark, then seal the template's types and add their access modifiers.

## Code rules

- **Persist, then broadcast.** Every `ServerMessage` gets the next per-session `seq` and is written to `session_events` before it is sent. `session_events` is append-only. Terminal output is batched before writing.
- **The learner drives.** Terminal input and `ApplyManifest` are accepted by default and refused only while the helper is acting. A helper turn only starts from a learner's message or answer.
- **Scenarios need no LLM.** `KubernetesLearning.Scenarios` never depends on the Agent or an LLM. Checks, hints and reset work with the helper off.
- **The helper can't fake state.** The browser's topology comes only from the sandbox's snapshot and diff stream. The helper emits `ViewIntent`s, never topology.
- **Agent boundaries.** `KubernetesLearning.Agent` has no ASP.NET Core or EF Core dependency. It talks to api through `IAgentEventSink` and to the sandbox through `ISandboxSession`.
- **Secrets.** The LLM API key lives only in api config. It is never logged, returned to clients or sent to a sandbox.
- **Limits.** One active session per user, one scenario per session, a per-session token budget, a global limit on concurrent helper turns, and an idle reaper.
- **Work queue.** Publish with confirms and return "try again" when the broker is unreachable. Handle redelivered results and dead letters. Only start and teardown use the queue.
- **Sandbox link drops.** `envmgr` can restart. A dropped `Connect` stream sets `SessionStatus{reconnecting}`, fails in-flight tool calls with a retryable error, and redials with backoff and jitter. The fresh snapshot after reattach replaces `TopologyCache`.
- **Async.** No sync-over-async, `CancellationToken`s passed through, no unbounded per-connection buffers, WebSocket close handled.
- **Schema changes** come with an EF Core migration.
- **Types and config.** Message types come from the `KubernetesLearning.Contracts` package, never hand-written DTOs. The sandbox is reached only through `ISandboxSession`. Config is env vars only; `README.md` lists them.

## Releases and dependencies

- A merge to `main` publishes the `api` image to GHCR, tagged with the commit SHA. A manual deploy picks which one runs.
- New `contracts` versions arrive as bot commits, `build(deps): bump contracts to X.Y.Z`, from `.github/workflows/contracts-bump.yml`, which calls `platform`'s update bot on `repository_dispatch`. The bot runs `platform`'s `dotnet-ci` on the commit before it pushes to `main`. If that fails, it opens a PR here instead; fix the code in that PR.
- New lint configs arrive the same way, as `chore: sync lint configs` from `.github/workflows/lint-sync.yml` after a change to `platform/lint/`. If the new rules break the build, the bot opens a PR instead; fix the code in that PR.
- When you add `KubernetesLearning.Contracts`, pin one exact version on one line, preferably once in `Directory.Packages.props` with Central Package Management, so the bot can find and bump it. See `platform`'s README, Update bot.

## Commits, branches and PRs

- **Always ask the user before creating a branch, committing or pushing.** Show the commit message when you ask.
- **Commits:** Conventional Commits only, one line: `type: short description`, lowercase, no trailing period. No body. No `Co-Authored-By` or any other attribution.
- **Types:** `feat`, `fix`, `docs`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`, `style`. Add `!` for a breaking change.
- **Branches:** use the name in the `Branch:` line of the issue being worked on. Don't make one up. `gh issue develop <number> --name <branch> --checkout` creates it linked to the issue.
- **Where changes land:** every change goes through a PR from the issue's branch. README, `AGENTS.md` and other doc updates go in the PR of the feature they describe, not in separate commits. When a change in another repo makes this repo's docs wrong, fix them in a small `docs:` PR here. Only the `docs` repo commits straight to `main`.
- **PRs:** the title follows the commit format, at most 72 characters; it becomes the squash commit on `main`. The description is one or two plain sentences, plus `Closes #<number>`. Merging needs one approval from someone other than the author, and the branch must be up to date with `main`. Filip is requested as reviewer on every PR (`.github/CODEOWNERS`), and the author is assigned automatically. Only Filip merges.
- **Public repo:** everything committed is public at once. Never commit secrets, real `.env` files or personal data; push protection only catches known token formats.

## Keep docs in sync

When a change touches this repo's design, layout, commands or conventions, update `AGENTS.md`, `README.md` and `.github/copilot-instructions.md` in the same change. If it changes a design fact, update ARCHITECTURE §4.1 in the `docs` repo too, and mention it to the user.

## Writing style

Plain, professional wording in docs and comments. No emoji, no marketing tone. Files are UTF-8 with LF line endings, following `.editorconfig`.
