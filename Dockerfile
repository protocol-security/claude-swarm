FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    clang \
    make \
    jq \
    sudo \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

# Claude Code refuses --dangerously-skip-permissions as root.
RUN useradd -m -s /bin/bash agent \
    && echo "agent ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/agent
USER agent

# Language toolchains are installed by SWARM_SETUP, not here.

# Comma-separated list of drivers whose CLIs should be installed.
# launch.sh derives this from the config and passes it as --build-arg.
ARG SWARM_AGENTS=claude-code

# --- Claude Code CLI (default) ---
ARG CLAUDE_CODE_VERSION=
RUN if echo ",$SWARM_AGENTS," | grep -q ",claude-code,"; then \
        curl -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh \
        && bash /tmp/claude-install.sh ${CLAUDE_CODE_VERSION:+$CLAUDE_CODE_VERSION} \
        && rm /tmp/claude-install.sh; \
    fi

# --- Kimi CLI ---
RUN if echo ",$SWARM_AGENTS," | grep -q ",kimi-cli,"; then \
        curl -LsSf https://code.kimi.com/install.sh | bash; \
    fi
ENV PATH="/home/agent/.local/bin:${PATH}"

# --- Node.js (shared by Gemini CLI, Codex CLI, OpenCode, and Droid) ---
USER root
RUN if echo ",$SWARM_AGENTS," | grep -qE ",(gemini-cli|codex-cli|opencode|droid),"; then \
        curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
        && apt-get install -y --no-install-recommends nodejs \
        && rm -rf /var/lib/apt/lists/*; \
    fi

# --- Gemini CLI ---
RUN if echo ",$SWARM_AGENTS," | grep -q ",gemini-cli,"; then \
        npm install -g @google/gemini-cli; \
    fi

# --- Codex CLI ---
RUN if echo ",$SWARM_AGENTS," | grep -q ",codex-cli,"; then \
        npm install -g @openai/codex \
        && mkdir -p /home/agent/.codex \
        && chown agent:agent /home/agent/.codex; \
    fi

# --- OpenCode ---
RUN if echo ",$SWARM_AGENTS," | grep -q ",opencode,"; then \
        npm install -g opencode-ai \
        && mkdir -p /home/agent/.config/opencode /home/agent/.local/share/opencode \
        && chown -R agent:agent /home/agent/.config/opencode /home/agent/.local/share/opencode; \
    fi

# --- Droid ---
RUN if echo ",$SWARM_AGENTS," | grep -q ",droid,"; then \
        npm install -g droid \
        && mkdir -p /home/agent/.factory \
        && chown -R agent:agent /home/agent/.factory; \
    fi
USER agent

# Trust mounted bare repos and allow file:// transport for submodules.
RUN git config --global --add safe.directory '*' \
    && git config --global protocol.file.allow always

COPY --chmod=755 lib/harness.sh /harness.sh
COPY --chmod=755 lib/signing.sh /signing.sh
COPY --chmod=755 lib/activity-filter.sh /activity-filter.sh
COPY --chmod=644 lib/agent-system-prompt.md /agent-system-prompt.md
COPY --chmod=644 VERSION /swarm-version
COPY --chmod=755 lib/drivers/ /drivers/

WORKDIR /workspace

ENTRYPOINT ["/harness.sh"]
