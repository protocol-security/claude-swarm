# claude-swarm

[![CI](https://github.com/protocol-security/claude-swarm/actions/workflows/ci.yml/badge.svg)](https://github.com/protocol-security/claude-swarm/actions/workflows/ci.yml)

N coding agents in Docker, coordinating through git.
No orchestrator, no message passing.  Designed to support
multiple agent CLIs via a driver abstraction layer.

Based on the agent-team pattern from
[Building a C Compiler with Large Language Models](https://www.anthropic.com/engineering/building-c-compiler).

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- bash (5.0+), git, jq, bc
- tput (ncurses) — used by the dashboard
- Credentials for the driver(s) you use:
  `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN`,
  `OPENROUTER_API_KEY`, `MINIMAX_API_KEY`,
  `OPENAI_API_KEY` or `~/.codex/auth.json`,
  `GEMINI_API_KEY`, `KIMI_API_KEY`, `FACTORY_API_KEY`

For development: `shellcheck` for linting.

## Setup

Add as a submodule:

```bash
git submodule add https://github.com/protocol-security/claude-swarm.git tools/claude-swarm
```

Or clone standalone and run from your project directory
(with a `swarm.json` in the project root):

```bash
./path/to/claude-swarm/launch.sh start --dashboard
```

## How it works

```
Host                         /tmp (bare repos)
~/project/ ── git clone ──>  project-upstream.git (rw)
               --bare        project-mirror-*.git (ro)
                                        |
                                        | docker volumes
                                        |
                 .-----------.----------+-----------.
                 |           |          |           |
           Container 1            Container 2       ...
           /upstream  (rw)        /upstream  (rw)
           /mirrors/* (ro)        /mirrors/* (ro)
                 |                      |
                 v                      v
           /workspace/            /workspace/
           (agent-work)           (agent-work)
```

All containers mount the same bare repo. Each runs
`lib/harness.sh` which loops: reset to `origin/agent-work`,
run one agent session, push. When one agent pushes, others
see the changes on the next fetch.

## Quick start

```bash
# Create a swarmfile and launch.
SWARM_CONFIG=swarm.json ./launch.sh start --dashboard

# Or place swarm.json in your repo root and launch.
./launch.sh start --dashboard
```

See [USAGE.md](USAGE.md) for all commands, dashboard keys,
and testing.

## Configuration

Place a `swarm.json` in your repo root:

```json
{
  "prompt": "prompts/task.md",
  "setup": "scripts/setup.sh",
  "max_idle": 3,
  "driver": "claude-code",
  "providers": {
    "anthropic_oauth": {
      "kind": "anthropic",
      "oauth_token": "$CLAUDE_CODE_OAUTH_TOKEN"
    },
    "openrouter": {
      "kind": "anthropic-compatible",
      "base_url": "https://openrouter.ai/api",
      "bearer_token": "$OPENROUTER_API_KEY"
    }
  },
  "agents": [
    { "count": 2, "model": "claude-opus-4-6", "provider": "anthropic_oauth", "effort": "high" },
    { "count": 1, "model": "claude-opus-4-6", "provider": "anthropic_oauth", "context": "none" },
    { "count": 1, "model": "claude-sonnet-4-6", "provider": "anthropic_oauth", "prompt": "prompts/review.md" },
    {
      "count": 3,
      "model": "openrouter/custom",
      "provider": "openrouter"
    }
  ],
  "post_process": {
    "prompt": "prompts/review.md",
    "model": "claude-opus-4-6",
    "provider": "anthropic_oauth",
    "max_idle": 2
  }
}
```

V2 swarmfiles are fully declarative: credentials live in the
top-level `providers` map, and each agent group or
`post_process` selects one with `provider`.

**Per-group fields:** `model`, `count`, `provider`, `effort`,
`context`, `prompt`, `tag`, `driver`. Provider entries define
`kind` plus the auth/config fields that kind supports
(`api_key`, `oauth_token`, `bearer_token`, `auth_file`,
`base_url`). See [USAGE.md](USAGE.md) for the full schema,
driver/provider compatibility, context modes, per-group
prompts, and examples.

## Drivers

Agent drivers decouple the harness from any specific CLI.
Each driver implements a fixed role interface:

| Function | Description |
| --- | --- |
| `agent_name` | Human-readable name (e.g. "Claude Code") |
| `agent_default_model` | Fallback model when config omits one |
| `agent_cmd` | CLI command (e.g. "claude") |
| `agent_version` | CLI version string |
| `agent_run` | Run one session, output JSONL |
| `agent_settings` | Write agent-specific settings |
| `agent_extract_stats` | Parse session stats from log |
| `agent_detect_fatal` | Detect fatal errors from log + exit code |
| `agent_is_retriable` | Detect retriable errors (rate limits, overload) |
| `agent_activity_jq` | jq filter for activity display |
| `agent_docker_env` | Emit driver-specific env vars for the container |
| `agent_docker_auth` | Resolve driver auth/mounts for the container |
| `agent_validate_config` | Reject unsupported config/auth combinations early |
| `agent_install_cmd` | Document how the CLI is installed in Docker |

Built-in drivers: `claude-code` (default), `gemini-cli`,
`codex-cli`, `kimi-cli`, `opencode`, `droid`, `fake`
(test double). `kimi-cli`, `opencode`, and `droid` now use
the same provider model as the other drivers, with
driver-specific validation at launch time. See
[USAGE.md](USAGE.md#writing-a-new-driver) for the full interface
and guide to writing a new driver.
