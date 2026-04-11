FROM node:24-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    openssh-client \
    curl \
    unzip \
    jq \
    procps \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# chezmoi
RUN sh -c "$(curl -fsLS get.chezmoi.io)" -- -b /usr/local/bin

# Bun (required by Telegram Channels plugin)
ENV BUN_INSTALL="/usr/local/bun"
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/usr/local/bun/bin:$PATH"

# Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code && npm cache clean --force

# kubectl
RUN curl -fsSL "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
    -o /usr/local/bin/kubectl && chmod +x /usr/local/bin/kubectl

# flux CLI
RUN curl -fsSL https://fluxcd.io/install.sh | bash

# gh CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    -o /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && apt-get install -y gh && rm -rf /var/lib/apt/lists/*

# Create user matching worker-node UID
RUN groupadd -g 1000 akhozya && \
    useradd -u 1000 -g 1000 -m -s /bin/bash akhozya

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER akhozya
WORKDIR /home/akhozya

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
