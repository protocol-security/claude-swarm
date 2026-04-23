# Usage

## Quick start

```bash
# Create a swarmfile and launch.
SWARM_CONFIG=swarm.json ./launch.sh start --dashboard
```

All configuration lives in the swarmfile (JSON).  Place a
`swarm.json` in your repo root or point to it with `SWARM_CONFIG`.

## Commands

```bash
./launch.sh start [--dashboard]   # Launch agents.
./launch.sh stop                  # Stop all agents.
./launch.sh status                # Show containers.
./launch.sh logs N                # Tail agent N logs.
./launch.sh wait                  # Block, harvest, post-process.
./launch.sh post-process          # Run post-process agent.
```

## Environment variables

Credentials stay as env vars (not in shell history).

| Variable | Default | Description |
|----------|---------|-------------|
| `ANTHROPIC_API_KEY` | | Anthropic API key. Commonly referenced from a provider as `"api_key": "$ANTHROPIC_API_KEY"`. |
| `CLAUDE_CODE_OAUTH_TOKEN` | | Anthropic OAuth token via `claude setup-token`. Commonly referenced as `"oauth_token": "$CLAUDE_CODE_OAUTH_TOKEN"`. |
| `OPENROUTER_API_KEY` | | Bearer token for Anthropic-compatible OpenRouter providers. |
| `MINIMAX_API_KEY` | | API key for Anthropic-compatible MiniMax providers. |
| `OPENAI_API_KEY` | | OpenAI API key. Commonly referenced from `openai` providers. |
| `CODEX_AUTH_JSON` | `~/.codex/auth.json` | Optional path for a Codex/OpenAI auth file used via provider `"auth_file"`. |
| `GEMINI_API_KEY` | | Google API key for `gemini` providers. |
| `KIMI_API_KEY` | | Kimi API key for `kimi` providers. |
| `FACTORY_API_KEY` | | Factory API key for `factory` providers. |
| `SWARM_CONFIG` | | Path to swarmfile (or place `swarm.json` in repo root). |
| `SWARM_TITLE` | | Dashboard title override. |
| `SWARM_SKIP_DEP_CHECK` | | Set to `1` to silence dependency version warnings. |
| `SWARM_ACTIVITY_TIMEOUT` | `0` | Seconds of logfile silence before the in-container watchdog SIGTERMs the agent CLI's process group.  `0` disables.  See [Activity watchdog](#activity-watchdog). |
| `SWARM_ACTIVITY_POLL` | `10` | Watchdog mtime-poll interval, in seconds.  Rarely needs tuning. |
| `SWARM_WATCHDOG_GRACE` | `10` | Grace window between watchdog SIGTERM and SIGKILL.  Rarely needs tuning. |

Use bare `$VAR` references in the swarmfile's top-level
`providers` map to pull secrets from the host environment
without hardcoding them.

## Config file fields

Top-level provider entries in `swarm.json`:

| Field | Values | Notes |
|-------|--------|-------|
| `kind` | `none`, `anthropic`, `anthropic-compatible`, `openai`, `openai-compatible`, `gemini`, `kimi`, `factory` | Required. |
| `api_key` | key or `$VAR` | Supported by `anthropic`, `anthropic-compatible`, `openai`, `openai-compatible`, `gemini`, `kimi`, `factory`. |
| `oauth_token` | token or `$VAR` | Supported by `anthropic` only. |
| `bearer_token` | token or `$VAR` | Supported by `anthropic-compatible` and `openai-compatible`. |
| `auth_file` | path or `$VAR` | Supported by `anthropic`, `anthropic-compatible`, `openai`, and `openai-compatible`. |
| `base_url` | URL | Supported by `anthropic-compatible`, `openai-compatible`, and optional for `kimi`. |

Per-group fields in the `agents` array:

| Field | Values | Notes |
|-------|--------|-------|
| `model` | model name | Required. |
| `count` | integer | Number of agents in this group. |
| `provider` | provider name | Required. Must reference a top-level provider entry. |
| `effort` | string | Reasoning depth (see below). |
| `context` | `full`, `slim`, `none` | How much of `.claude/` to keep (default: `full`). |
| `prompt` | file path | Per-group prompt override (default: top-level). |
| `tag` | string or `$VAR` | Label for grouping runs (default: top-level). |
| `driver` | driver name | Agent driver override (default: top-level or `claude-code`). |

**Effort values** are driver-dependent:

- Claude Code: `low`, `medium`, `high`, `max` (Opus only).
- Codex CLI: `none`, `minimal`, `low`, `medium`, `high`, `xhigh`.
- Kimi CLI: empty leaves default behavior; `none`/`off` disables thinking; any other non-empty value enables thinking.
- OpenCode: passed through verbatim as `--variant`.
- Droid: written to `~/.factory/settings.local.json` as `reasoningEffort` and also passed to `droid exec -r`.
- Gemini CLI: ignored.

Top-level fields: `prompt`, `setup`, `max_idle` (default: `3`),
`max_retry_wait`, `driver`, `providers`, `inject_git_rules`,
`git_user` (`name`, `email`, `signing_key`),
`claude_code_version`, `title`, `tag`, `pricing`,
`docker_args`, `post_process`.

### Retry on rate limits

Set `max_retry_wait` (seconds) to have agents retry with
exponential backoff when rate-limited instead of exiting:

```json
{ "max_retry_wait": 25200 }
```

Default is `0` (no retry -- exit immediately on fatal errors).
The backoff starts at 30 s, doubles each attempt, and caps at
30 min per sleep.  When the cumulative wait exceeds
`max_retry_wait`, the agent exits.  This also covers transient
network failures.

### Activity watchdog

Some CLIs (observed on `codex-cli`, occasionally `claude-code`)
can deadlock mid-request -- the process stays alive but stops
emitting output, so the harness's post-`wait` process-group
kill never fires and the container sits idle until an operator
notices and runs `docker stop`.  Setting
`SWARM_ACTIVITY_TIMEOUT` to a positive integer enables a
watchdog inside `_run_reaped` that polls the CLI's logfile
mtime; if the mtime doesn't advance for that many seconds the
watchdog SIGTERMs the CLI's process group, then SIGKILLs after
`SWARM_WATCHDOG_GRACE` seconds if the group hasn't exited.
Default is `0` (disabled); 300-600 is a sensible starting point
for production swarms:

```bash
SWARM_ACTIVITY_TIMEOUT=600 ./launch.sh start --dashboard
```

The watchdog's kill decision is written to the CLI's stderr
file (`/workspace/*.log.err` inside the container, visible via
`docker logs`) so an operator investigating an agent that
exited early can tell a watchdog-killed exit from a
crashed-on-its-own exit.  `SWARM_ACTIVITY_POLL` (default 10 s)
tunes how often the watchdog checks mtime;
`SWARM_WATCHDOG_GRACE` (default 10 s) tunes the SIGTERM→SIGKILL
gap.  Both rarely need adjustment outside the test suite.

### Extra Docker arguments

Pass arbitrary flags to every `docker run` invocation via the
top-level `docker_args` array.  Each element is one shell token:

```json
{
  "docker_args": [
    "-v", "/var/run/docker.sock:/var/run/docker.sock",
    "--privileged"
  ]
}
```

This is useful for mounting the host Docker socket, adding
devices or capabilities, setting network modes, or passing any
other flags that the harness does not manage natively.

Docker's `-e` flag accepts two forms: `-e VAR=value` passes a
literal value, and `-e VAR` (no `=value`) inherits `VAR` from the
caller's environment at `launch.sh start` time, omitting it
entirely when unset.  This lets you parameterize a single
swarmfile with host env without templating:

```json
{
  "setup": "scripts/setup.sh",
  "docker_args": ["-e", "TARGET_REPO", "-e", "TARGET_REV"]
}
```

```bash
TARGET_REPO=git@github.com:org/repo.git TARGET_REV=abc123 \
    ./launch.sh start
```

### Setup hook

The `setup` script runs once at container startup as root, via
`sudo -E bash <setup>`, so the full container environment crosses
the `sudo` boundary into the script.  Any variable passed through
`docker_args -e` (plus the swarm's own env like `AGENT_ID`,
`SWARM_MODEL`, `MAX_IDLE`, ...) is visible inside `setup.sh`.
Default Debian sudoers would otherwise strip everything except
`PATH` via `env_reset`, so `-E` is what makes the example above
work end-to-end.

After `setup.sh` returns, the harness reclaims ownership of
`/workspace` so subsequent agent runs can modify the tree as the
non-root `agent` user.

### Commit signing

Set `git_user.signing_key` to an SSH private-key path on the
host to sign every commit agents and post-processors make.
Accepts a literal path, a bare `$VAR` reference (expanded from
the host environment), or a path starting with `~/` (expanded
to `$HOME` before mounting):

```json
{
  "git_user": {
    "name": "swarm-agent",
    "email": "agent@swarm.local",
    "signing_key": "~/.ssh/swarm-agent-signing"
  }
}
```

The key is bind-mounted read-only into each container at
`/etc/swarm/signing_key`, and git inside the container is
configured with:

```
gpg.format      = ssh
user.signingkey = /etc/swarm/signing_key
commit.gpgsign  = true
```

When `signing_key` is absent -- or resolves to empty via an
unset `$VAR` -- signing is explicitly disabled inside the
container (`commit.gpgsign = false`), overriding anything that
might otherwise leak in from the image or a mounted config.

The host key file must exist at `launch.sh start` time;
otherwise launch fails with `ERROR: signing key not found`.
The container image ships `openssh-client` for the
`ssh-keygen -Y sign` that git invokes.

## Dashboard

```bash
./dashboard.sh
```

Per-agent model, auth source, status, cost, tokens, cache,
turns, throughput, and duration.  Updates every 3s.  The
header shows a compact model summary on a single line.

| Key | Action |
|-----|--------|
| `q` | Quit. |
| `1`-`9` | Logs for agent N. |
| `h` | Harvest results. |
| `s` | Stop numbered agents (not post-process). |
| `p` | Post-process. |

## Activity streaming

Agent activity streams to Docker logs in real time. Press
`[1-9]` in the dashboard (or `./launch.sh logs N`) to see
what an agent is doing:

```
12:34:56 harness[1] session start at=abc123
12:35:01   agent[1] Read src/main.ts
12:35:03   agent[1] Edit src/main.ts
12:35:08   agent[1] Shell: npm test
12:35:12   agent[1] Shell: git add -A && git commit -m "fix tests"
12:35:15   agent[1] Shell: git push origin agent-work
12:35:18 harness[1] session end cost=$0.12 in=800 out=644 turns=6 time=19s
```

The filter (`lib/activity-filter.sh`) parses stream-json
events from the agent CLI and prints one line per tool call
or thinking block.  The timestamp and agent ID are colored
in ANSI yellow (matching git's commit-hash color) for
readability.

Thinking/reasoning content appears as `Think: <summary>`
when the model produces it.  Whether thinking is emitted
depends on the model and configuration: Claude Code requires
extended thinking to be enabled, and Gemini CLI emits thought
events only for models that support them.

On Opus 4.7 and later the Anthropic API default for
`thinking.display` is `"omitted"`: the `thinking` field is
empty and the full reasoning is returned encrypted in the
`signature` field.  To restore summaries the client has to
explicitly send `thinking: {"display": "summarized"}` on
each Messages API request.

The claude-code driver writes `"showThinkingSummaries": true`
into the workspace's `.claude/settings.local.json` as a
forward-compatible opt-in.  As of Claude Code 2.1.111 the
CLI does not yet plumb that setting through to headless
(`-p --output-format stream-json`) requests for Opus 4.7, so
on today's releases this opt-in is effectively a no-op for
our pipeline.  The setting is retained so that a future
Claude Code release which wires it to the Messages API will
restore summaries automatically with no further swarm change.

While the client-side opt-in is missing, the activity filter
classifies the otherwise-blank blocks to keep the dashboard
informative:

- `Think: [encrypted]` — `thinking` empty, `signature` present.
  This is the expected Opus 4.7 `display:"omitted"` payload;
  the full reasoning exists server-side but is unavailable
  to the client.
- `Think: [empty]` — `thinking` empty and `signature` empty.
  Anomalous: neither summary nor encrypted reasoning; useful
  diagnostic that something upstream is off.

Blank `Think:` lines no longer reach the dashboard.  On
Opus 4.6 and earlier, summaries were the default and continue
to render as `Think: <summary>` unchanged.

## Testing

```bash
./tests/test.sh --help               # All options.
./tests/test.sh --unit               # Unit tests only.
./tests/test.sh                      # Single smoke test.
./tests/test.sh --all                # Full matrix.
./tests/test.sh --config swarm.json  # Custom config.
./tests/test.sh --no-inject          # Explicit git prompt.
./tests/test.sh --oauth              # OAuth-only smoke test.
```

Flags combine: `./tests/test.sh --config f.json --no-inject`.

The test harness uses its own built-in prompt (counting +
reasoning) regardless of config. The reasoning step exercises
adaptive thinking at different effort levels.

Unit tests (no Docker or API key):

```bash
./tests/test.sh --unit         # All unit tests.
./tests/test_activity_filter.sh  # Activity stream parsing.
./tests/test_config.sh         # Config parsing.
./tests/test_costs.sh          # Cost aggregation.
./tests/test_dashboard.sh      # Dashboard rendering.
./tests/test_drivers.sh        # Agent driver interface.
./tests/test_format.sh         # Formatting helpers.
./tests/test_harness.sh        # Stat extraction.
./tests/test_harvest.sh        # Harvest git ops.
./tests/test_launch.sh         # Launch logic.
```

## Post-processing

Add to `swarm.json`:

```json
{
  "post_process": {
    "prompt": "prompts/review.md",
    "model": "claude-opus-4-6",
    "provider": "anthropic_oauth",
    "effort": "low",
    "max_idle": 2
  }
}
```

Trigger via `[p]` in the dashboard, `./launch.sh post-process`,
or automatically via `./launch.sh wait`.

The post-process agent clones the same bare repo, sees all
commits on `agent-work`, runs its prompt, and pushes.

`post_process` accepts the same routing fields as agent groups:
`provider`, `effort`, `tag`, `driver`, and `max_idle`.
`provider` is required whenever `post_process` is configured.
`max_idle` controls how many consecutive sessions with no
commits before the post-processor exits. When omitted it
inherits the top-level `max_idle` (default: `3`).

## Context modes

Motivated by [Evaluating AGENTS.md](https://arxiv.org/abs/2602.11988)
(Gloaguen et al.), which found that repository-level context files
can reduce agent success rates while increasing inference cost by
over 20%. This feature enables A/B comparisons within a single
swarm.

Control how much of `.claude/` each agent group sees:

| Mode | Behavior |
|------|----------|
| `full` | Keep `.claude/` as-is (default). |
| `slim` | Keep only `.claude/CLAUDE.md`, strip agents/skills. |
| `none` | Remove entire `.claude/` directory (bare agent). |

Set per group in `swarm.json`:

```json
{
  "providers": {
    "anthropic_oauth": {
      "kind": "anthropic",
      "oauth_token": "$CLAUDE_CODE_OAUTH_TOKEN"
    }
  },
  "agents": [
    { "count": 2, "model": "claude-opus-4-6", "provider": "anthropic_oauth" },
    { "count": 1, "model": "claude-opus-4-6", "provider": "anthropic_oauth", "context": "none" }
  ]
}
```

Bare agents do exploratory work unconstrained by repo context
while other agents use skills and rules for structured output.
Non-default modes appear in the dashboard Ctx column and in
commit trailers (`> Ctx: bare`, `> Ctx: slim`).

## Per-group prompts

Each agent group can run a different prompt file:

```json
{
  "prompt": "tasks/hunt.md",
  "providers": {
    "anthropic_oauth": {
      "kind": "anthropic",
      "oauth_token": "$CLAUDE_CODE_OAUTH_TOKEN"
    }
  },
  "agents": [
    { "count": 2, "model": "claude-opus-4-6", "provider": "anthropic_oauth" },
    { "count": 1, "model": "claude-sonnet-4-6",
      "provider": "anthropic_oauth",
      "prompt": "tasks/review.md" }
  ]
}
```

Groups without `prompt` inherit the top-level value.  When every
group specifies its own prompt, the top-level `prompt` can be
omitted entirely:

```json
{
  "providers": {
    "anthropic_oauth": {
      "kind": "anthropic",
      "oauth_token": "$CLAUDE_CODE_OAUTH_TOKEN"
    }
  },
  "agents": [
    { "count": 2, "model": "claude-opus-4-6",
      "provider": "anthropic_oauth",
      "prompt": "tasks/hunt.md" },
    { "count": 1, "model": "claude-sonnet-4-6",
      "provider": "anthropic_oauth",
      "prompt": "tasks/review.md" }
  ]
}
```

Combined with context modes, this enables divergent exploration:
hunting agents run one prompt with full skills, a reconciliation
agent runs a different prompt to validate and normalize findings.

## Providers

Swarm v2 removed per-agent `auth`, `api_key`, `auth_token`,
and `base_url`. All credentials now live in the top-level
`providers` map, and each agent or post-processor selects one
with `provider`.

Example:

```json
{
  "providers": {
    "anthropic_oauth": {
      "kind": "anthropic",
      "oauth_token": "$CLAUDE_CODE_OAUTH_TOKEN"
    },
    "openai_key": {
      "kind": "openai",
      "api_key": "$OPENAI_API_KEY"
    },
    "openrouter": {
      "kind": "anthropic-compatible",
      "base_url": "https://openrouter.ai/api",
      "bearer_token": "$OPENROUTER_API_KEY"
    }
  },
  "agents": [
    { "count": 1, "model": "claude-opus-4-6", "provider": "anthropic_oauth" },
    { "count": 1, "model": "gpt-5.4", "driver": "codex-cli", "provider": "openai_key" },
    { "count": 1, "model": "openai/gpt-5.4", "provider": "openrouter" }
  ]
}
```

Driver/provider compatibility:

| Driver | Supported provider kinds | Notes |
|---|---|---|
| `claude-code` | `anthropic`, `anthropic-compatible` | `anthropic` accepts `api_key` or `oauth_token`; `anthropic-compatible` accepts `api_key` or `bearer_token` plus `base_url`. |
| `codex-cli` | `openai` | Uses `api_key` or `auth_file`. |
| `gemini-cli` | `gemini` | Requires `api_key`. |
| `kimi-cli` | `kimi` | Requires `api_key`; optional `base_url`. |
| `opencode` | `anthropic`, `anthropic-compatible`, `openai`, `openai-compatible`, `gemini`, `kimi` | Generates native OpenCode config/auth files inside the container. |
| `droid` | `factory` | Requires `api_key`. |
| `fake` | `none` | Test driver only. |

Provider examples:

```json
{
  "providers": {
    "anthropic_oauth": {
      "kind": "anthropic",
      "oauth_token": "$CLAUDE_CODE_OAUTH_TOKEN"
    },
    "anthropic_key": {
      "kind": "anthropic",
      "api_key": "$ANTHROPIC_API_KEY"
    },
    "openrouter": {
      "kind": "anthropic-compatible",
      "base_url": "https://openrouter.ai/api",
      "bearer_token": "$OPENROUTER_API_KEY"
    },
    "codex_auth_file": {
      "kind": "openai",
      "auth_file": "~/.codex/auth.json"
    },
    "kimi_prod": {
      "kind": "kimi",
      "api_key": "$KIMI_API_KEY",
      "base_url": "https://api.kimi.com/coding/v1"
    },
    "factory_prod": {
      "kind": "factory",
      "api_key": "$FACTORY_API_KEY"
    }
  }
}
```

Validation happens before any container starts. Launch fails if:

- a group references a missing provider
- a provider kind is unknown
- a provider mixes incompatible auth fields
- a provider/driver combination is unsupported
- an `auth_file` path does not exist

The dashboard **Auth** column reflects the concrete credential
path used for the session: `key`, `oauth`, `token`, `file`, or
`none`.

## Git coordination

Agents receive git rules (commit/push/rebase) via a system
prompt appendix. Your task prompt only needs to describe the
work.

Disable with `"inject_git_rules": false` in the swarmfile.

## Cost tracking

```bash
./costs.sh          # Table.
./costs.sh --json   # JSON.
```

Stats collected per session inside each container
(`agent_logs/stats_agent_*.tsv`), read on demand.

Dashboard columns:

- **Auth** — credential source: `key` (API key), `oauth`
  (Anthropic OAuth), `token` (Bearer / OpenRouter-style),
  `file` (mounted auth file), or `none`.
- **Ctx** — context mode: `bare` (no `.claude/`), `slim`
  (only `CLAUDE.md`), or blank for full context.
- **Cost** — cumulative API cost in USD.
- **In/Out** — input and output tokens.
- **Cache** — prompt cache read tokens. Higher means the API
  is reusing cached context instead of reprocessing it,
  reducing cost and latency. Cache creation tokens (the
  one-time cost of populating the cache) are recorded in
  the TSV but not shown separately.
- **Turns** — number of assistant turns across all sessions.
- **Tok/s** — output tokens per second of API time.
- **Time** — cumulative wall-clock duration.

## Drivers

Agent drivers decouple the harness from any specific CLI tool.
Each driver (`lib/drivers/<name>.sh`) implements a fixed role
interface so the harness can run, monitor, and parse stats from
any supported agent.

Built-in drivers:

| Driver | CLI | Default |
|--------|-----|---------|
| `claude-code` | `claude` | Yes |
| `gemini-cli` | `gemini` | |
| `codex-cli` | `codex` | |
| `kimi-cli` | `kimi` | |
| `opencode` | `opencode` | |
| `droid` | `droid` | |
| `fake` | (none) | Test double for unit testing |

Set the driver globally in `swarm.json`:

```json
{
  "driver": "claude-code",
  "providers": {
    "anthropic_oauth": {
      "kind": "anthropic",
      "oauth_token": "$CLAUDE_CODE_OAUTH_TOKEN"
    }
  }
}
```

Or per agent group:

```json
{
  "providers": {
    "anthropic_oauth": {
      "kind": "anthropic",
      "oauth_token": "$CLAUDE_CODE_OAUTH_TOKEN"
    }
  },
  "agents": [
    { "count": 2, "model": "claude-opus-4-6", "provider": "anthropic_oauth" },
    { "count": 1, "model": "other-model", "provider": "anthropic_oauth", "driver": "other-driver" }
  ]
}
```

Per-agent drivers inherit the top-level `driver` field, which
defaults to `claude-code`.

### Pinning Claude Code version

By default the Docker image installs the latest Claude Code CLI.
To pin a specific version, set `claude_code_version` in the
swarmfile:

```json
{ "claude_code_version": "1.0.30" }
```

### Writing a new driver

Create `lib/drivers/<name>.sh` implementing these functions:

```bash
agent_default_model()   # Fallback model when none configured
agent_name()            # Human-readable name for commit trailers
agent_cmd()             # CLI command name
agent_version()         # Print version string to stdout
agent_run()             # Run one session (model, prompt, logfile, append_file)
agent_settings()        # Write agent config files into workspace
agent_extract_stats()   # Parse stats from log file (TSV output)
agent_detect_fatal()    # Detect fatal errors from log + exit code
agent_is_retriable()    # Detect retriable errors (rate limits, overload)
agent_activity_jq()     # Return jq filter for activity streaming
agent_docker_env()      # Print -e flags for agent-specific env vars
agent_docker_auth()     # Resolve credentials, emit Docker -e flags
agent_validate_config() # Reject unsupported config/auth combinations
agent_install_cmd()     # Print install commands (documentation only)
```

The Dockerfile hardcodes install steps for built-in drivers.
New drivers require corresponding Dockerfile changes.

See `lib/drivers/claude-code.sh` for the reference implementation
and `lib/drivers/fake.sh` for a minimal test double.

### Dry-run with the fake driver

Use the `fake` driver to validate setup scripts, prompt paths, and
config without spending tokens or requiring API keys.  Create a
swarmfile that sets `"driver": "fake"`:

```json
{
  "prompt": "your-prompt.md",
  "setup": "your-setup.sh",
  "driver": "fake",
  "providers": {
    "fake_provider": {
      "kind": "none"
    }
  },
  "agents": [
    { "count": 1, "model": "fake", "provider": "fake_provider" }
  ]
}
```

Then run it:

```bash
SWARM_CONFIG=dry-run.json ./launch.sh start --dashboard
```

The fake driver runs the full harness loop — cloning, setup script
execution, git hooks — but replaces the agent session with a
synthetic JSONL stream that completes instantly.  This catches
path errors, missing dependencies, and config issues before any
real agent run.

Clean up afterwards:

```bash
PROJECT=$(basename $(pwd))
docker rm -f ${PROJECT}-agent-1 2>/dev/null
rm -rf /tmp/${PROJECT}-upstream.git
```

## Cleanup

After a swarm run, the following artifacts remain on disk:

| Artifact | Path |
|----------|------|
| Bare repo | `/tmp/<project>-upstream.git` |
| Submodule mirrors | `/tmp/<project>-mirror-*.git` |
| Agent containers | `<project>-agent-N` |
| State file | `/tmp/<project>-swarm.env` |
Remove everything for a fresh start:

```bash
PROJECT=$(basename $(pwd))
docker rm -f $(docker ps -aq --filter "name=${PROJECT}-agent-") 2>/dev/null
rm -rf /tmp/${PROJECT}-upstream.git /tmp/${PROJECT}-mirror-*.git
rm -f  /tmp/${PROJECT}-swarm.env
```

## Verify image

```bash
docker run --rm --entrypoint bash \
    -e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY" \
    $(basename $(pwd))-agent \
    -c 'claude --dangerously-skip-permissions \
        -p "What model are you? Reply with model id only." \
        --model claude-opus-4-6 2>&1'
```
