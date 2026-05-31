# 🦉 Kiro / OWL / Hermes / Clash Proxy Stack - Replication Suite

---

### 🌐 Connected Portals & Integrations
* **Interactive Web Platform (Desktop)**: 🔗 [Ecosystem Desktop Console](https://marktantongco.github.io/kiro-proxy-ecosystem/index.html) — *The live operational dashboard, procedural walkthroughs, and secure code/script downloader.*
* **Mobile Interactive Console**: 🔗 [Ecosystem Mobile Console](https://marktantongco.github.io/kiro-proxy-ecosystem/mobile.html) — *High-contrast Neo-Brutalist mobile dashboard designed with stark Red-Black-Yellow UI elements for extreme outdoor visibility during triage.*
* **AWS Builder ID Portal**: 🔗 [AWS SSO Console](https://builderid.us-east-1.console.aws.amazon.com) — *Builder ID endpoint for Kiro token refresh sequences.*
* **Upstream Geo-Routing (Mihomo Core)**: 🔗 [Mihomo Core GitHub](https://github.com/MetaCubeX/mihomo) — *The core routing backbone listening on port `7890`.*
* **Webshare Proxy Backbone**: 🔗 [Webshare Dashboard](https://www.webshare.io/) — *Provider backbone for rotating IP definitions.*
* **Anthropic SDK Integration**: 🔗 [Anthropic API Documentation](https://docs.anthropic.com/) — *API standard mapped inside `kiro-gateway` translation pipelines.*

> [!NOTE]
> **Mobile Redirection Protocol**: The main entrypoint ([`index.html`](https://marktantongco.github.io/kiro-proxy-ecosystem/index.html)) automatically detects mobile viewports and redirects to the Neo-Brutalist [`mobile.html`](https://marktantongco.github.io/kiro-proxy-ecosystem/mobile.html) console. Users can override this behavior by loading the site with `?desktop=true` or by clicking the *Desktop Suite* button on the mobile UI.

---

Welcome to the comprehensive, self-healing **AI Wrapper and Secure Proxy Replication Suite**. This repository contains every script, wrapper launcher, systemd unit, config map, and utility required to reproduce a completely operational regional-bypass proxy stack for OpenCode, standalone local agents (e.g., Hermes), and parallel research pipelines.

---

## 📐 1. Advanced 8-Node Ecosystem Architecture

Our network stack encapsulates local HTTP traffic and routes it dynamically through a double-proxy tunnel to secure regional endpoints. Below is the complete architectural layout of all 8 nodes, spanning provisioning, validation, client wrappers, IDE MCP servers, translation layers, and weighted geo-routers:

```
                  [ 1. PROVISIONING ENGINE ]
                  (install_owl_agent.sh)
                      │             │
                      ▼ (deploys)   ▼ (deploys)
   [ 3. STANDALONE HERMES ]         [ 8. KIRO GATEWAY (Port 8333) ] ◄──┐
   (Isolated CLI wrapper)           (translates Anthropic/OIDC)         │
              │                                 │                       │ (MCP search)
              ▼ (enforces HTTP_PROXY)           ▼ (routes requests)     │
   [ 4. OWL DEFENSE PROXY (Port 60000) ] ◄──────┘                       │
              │             ▲                                           │
              │             │ (validates throughput)                    │
              │     [ 2. CONCURRENCY HARNESS ]               [ 7. RESILIENT MCP ]
              │     (test_parallel_research.py)              (owl_resilient_mcp.py)
              │                                                         ▲
              ▼ (forwards UPSTREAM_PROXY)                               │ (indexes)
   [ 5. CLASH ROUTER CORE (Port 7890) ]                                 │
   (Mihomo weighted geo-routing)                             [ 6. OPENCODE WORKSPACE ]
              │                                              (IDE Settings Map)
              ▼
      [ OUTSIDE WORLD (WAN) ]
```

---

## 📁 2. Unified File Directory & Relationships

This replication suite is organized logically into specific functional directories. Below is the catalog of files and how they work in harmony:

### ⚙️ Core Wrappers & Scripts (`/scripts`)
* **[`validate_ecosystem.sh`](./scripts/validate_ecosystem.sh)**: The automated self-healing diagnostic suite. Detects lowercase variable pollution, kills manual port bindings on `8333` and `60000` to prevent collisions, verifies systemd services, and runs an end-to-end active ping.
* **[`diagnose_opencode.sh`](./scripts/diagnose_opencode.sh)**: Automated self-healing diagnostic tool. Evaluates core system listener ports, resolves terminal Unix domain socket mismatches, and tests direct-connect proxy bypass rules.
* **[`patch_owl_proxy.sh`](./scripts/patch_owl_proxy.sh)**: Installs the Clash upstream routing overrides inside your active python OWL installations, unsets conflicting environmental routes, and restores fallback definitions.
* **[`install.sh`](./scripts/install.sh)**: Base system compilation and binary fetcher script.
* **[`hermes_wrapper.sh`](./scripts/hermes_wrapper.sh)**: Launcher wrapper (deploys to `~/.local/bin/hermes`). Isolates `HTTP_PROXY` within the agent command lifecycle and delegates systemd checks to the correct standard user when running under root.
* **[`agy_wrapper.sh`](./scripts/agy_wrapper.sh)**: Antigravity secure proxy wrapper launcher (deploys to `~/.local/bin/agy`). Ensures active proxy connection and intercepts environmental variable scopes dynamically before delegating to `agy.real`.
* **[`kiro_gateway_wrapper.sh`](./scripts/kiro_gateway_wrapper.sh)**: Standard Kiro terminal launcher.

### 🛠️ Dedicated Installers (`/installers`)
* **[`install_owl_agent.sh`](./installers/install_owl_agent.sh)**: *Deduplicated Core Installer.* Custom-built to download `kiro-cli` native binaries from AWS S3, repair dynamic linkers (`ld-linux`), initialize credentials pools, and provision the OWL proxy defense stack at `~/.owl-agent` with robust retry pipelines.
* **[`install_kiro_owl_agent.sh`](./installers/install_kiro_owl_agent.sh)**: Dedicated installer script for cloning and provisioning the `kiro-gateway` python service, setting up its virtual environment, and configuring parameters in `opencode.jsonc`.

### 🧠 MCP Integration (`/mcp`)
* **[`owl_resilient_mcp.py`](./mcp/owl_resilient_mcp.py)**: The premium Model Context Protocol (MCP) server bridge. Translates OpenCode semantic searches and indexes local Obsidian vaults directly through our proxy stack.

### 🧪 Integration Tests (`/tests`)
* **[`test_parallel_research.py`](./tests/test_parallel_research.py)**: Operational pipeline test suite to verify that concurrent model requests run securely through the double-proxy environment without triggering rate limits or leakage.

### 📝 Config Maps & Daemons (`/configs` & `/systemd`)
* **[`ai-instructions-handover.md`](./configs/ai-instructions-handover.md)**: *Handover Playbook.* Standard system manual designed specifically for external AI coding agents to parse, configure, connect, deploy, and maintain the proxy stack.
* **[`handoff-antigravity-autoapproval.md`](./configs/handoff-antigravity-autoapproval.md)**: Dynamic agent auto-approval security ruleset.
* **[`README_PROXY_ARCHITECTURE.md`](./configs/README_PROXY_ARCHITECTURE.md)**: Comprehensive proxy bypass routing architecture manual for NVIDIA NIM and OpenCode Zen model providers.
* **[`kiro-gateway.service`](./systemd/kiro-gateway.service)**: Systemd user-service unit mapping for running Kiro background API translators.
* **[`owl-forward-proxy.service`](./systemd/owl-forward-proxy.service)**: Systemd user-service unit mapping for running OWL forward proxies.

---

## 🚀 3. Step-by-Step Station Replication Guide

To reproduce this exact operational environment on another machine, execute these steps:

### Step 1: Upstream Routing Setup
Ensure Clash (`mihomo` or equivalent) is installed, running, and listening on **port `7890`**.

### Step 2: Running the Installers
1. Run the core installer script to deploy credentials, libc links, and Core OWL agents:
   ```bash
   chmod +x installers/install_owl_agent.sh
   ./installers/install_owl_agent.sh
   ```
2. Provision Kiro gateway translation engines:
   ```bash
   chmod +x installers/install_kiro_owl_agent.sh
   ./installers/install_kiro_owl_agent.sh
   ```
3. Verify systemd units are correctly installed:
   ```bash
   cp systemd/*.service ~/.config/systemd/user/
   systemctl --user daemon-reload
   systemctl --user enable --now owl-forward-proxy.service kiro-gateway.service
   ```

### Step 3: Local Binaries & Wrappers
Copy the terminal wrappers to your local bin path:
```bash
cp scripts/hermes_wrapper.sh ~/.local/bin/hermes
cp scripts/kiro_gateway_wrapper.sh ~/.local/bin/kiro-gateway
chmod +x ~/.local/bin/hermes ~/.local/bin/kiro-gateway
```

### Step 4: Run Diagnostic Self-Healing
Run the diagnostic check to automatically clean up environment variables, check systemd statuses, and test connections:
```bash
chmod +x scripts/validate_ecosystem.sh
./scripts/validate_ecosystem.sh
```

---

## 🩺 4. Active Connection Maintenance

If your model calls return **403 Forbidden** or **502 Bad Gateway** errors, your AWS monthly free limits have likely been hit. The gateway automatically defaults to its **13 pre-cached models**. To restore active live models:
1. Log in with a fresh free AWS Builder ID.
2. Authenticate the CLI:
   ```bash
   kiro-cli login
   ```
3. Restart the background daemon:
   ```bash
   systemctl --user restart kiro-gateway.service
   ```

---

## 🛠️ 5. Recent Ecosystem Updates & Schema Patching

### May 30, 2026: OpenCode Stack Recovery & Schema Alignment
* **The Launch Issue**: The `opencode` environment tmux session was crashing immediately with exit code `[exited]` upon launching. Raw binary checks revealed a configuration schema failure: `[cause]: SchemaError: Missing key at ["command"]["heavy"]["template"]` and `["command"]["light"]["template"]`.
* **The Resolution**: Updated the main OpenCode config `~/.config/opencode/opencode.jsonc` to explicitly define `"template"` keys alongside the existing `"prompt"` fields. This completely cures the validator parse engine and restores pristine launcher functionality.
* **Redundancy Pruning**: Moved redundant legacy installers (e.g. `scripts/install.sh`, `scripts/owl_agent_installer_v4.sh`) from `/home/x1` and nested workspace paths into `/home/x1/Documents/proxy_backups/` to eliminate script conflicts.
* **Resilient MCP Bridging**: Fully configured the `owl-resilient-http` MCP server into OpenCode settings to ensure high-uptime failover translation of semantic searches.
* **Ecosystem Integrity**: Integrated advanced user-level systemd process verification inside `validate_ecosystem.sh` to resolve process tracking false-positives under UID mapping limits.

### May 31, 2026 (Late): Kiro-Gateway Proxy Bypass Fix & SSL Error Resolution
* **Kiro Backend Unreachable (SSL_ERROR_SYSCALL)**: The Kiro Gateway's connection to `q.us-east-1.amazonaws.com` was failing because the OWL forward proxy routed it through Mihomo/Clash, which caused TLS handshake drops after establishing the CONNECT tunnel. Traffic timed out with 0 upstream models loaded.
* **The Resolution**: Added `*.amazonaws.com` and `*.kiro.dev` to the OWL forward proxy's direct-connect bypass list in both the TCP tunnel (`connect_upstream`) and HTTP handler (`handle_http`) routines. These domains now bypass Mihomo entirely and connect directly, restoring the Kiro gateway's ability to authenticate with Amazon Q and load its full 9-model catalog (auto-kiro, claude-haiku-4.5, claude-sonnet-4, claude-sonnet-4.5, deepseek-3.2, glm-5, minimax-m2.1, minimax-m2.5, qwen3-coder-next).
* **Documentation Updated**: Proxy architecture guide (`configs/README_PROXY_ARCHITECTURE.md`) updated with the new bypass entries and technical explanation of the SSL_ERROR_SYSCALL root cause.

### May 31, 2026: Installer Upgrades, Self-Healing Diagnostics & Alias Integration
* **Advanced Proxy Defense (v3.2)**: Upgraded `install_owl_agent.sh` to provision the robust `proxy_defense_fixed_v3.py` script containing weighted proxy selection, per-domain rate limiting, a domain circuit breaker, and automatic multi-provider credentials/auth injection.
* **Inline Diagnostics Suite**: Integrated the secure `diagnose_opencode.sh` self-healing script inline inside the core OWL-Agent installer (`install_owl_agent.sh`), deploying it natively to `~/.owl-agent/diagnose_opencode.sh`.
* **Dynamic Shortcut Integration**: Added an automated script hook inside `install_owl_agent.sh` that dynamically appends the `owl-check` shell alias to the user's `~/.bashrc`, enabling single-command system state queries.
* **Troubleshooting Orchestration**: Patched the unified `install_kiro_owl_agent.sh` script to output automated diagnostic guidance referencing the `owl-check` suite in its final installation summary.

---

---

## 🚢 6. Deploy & Release

This site auto-deploys to **GitHub Pages** from the `master` branch root.

### Quick Deploy
```bash
# Compile site, commit, and push in one step:
bash scripts/deploy.sh
```

### Manual Steps
```bash
# 1. Compile (embeds all script contents into index.html / mobile.html)
python3 compile_site.py

# 2. Commit and push (triggers auto-deploy)
git add -A
git commit -m "feat: description"
git push origin master
```

### GitHub Actions
A CI workflow (`.github/workflows/deploy.yml`) also compiles and deploys automatically on every push to `master`. You can also trigger it manually from the Actions tab.

### URLs
- **Desktop Console**: https://marktantongco.github.io/kiro-proxy-ecosystem/
- **Mobile Console**: https://marktantongco.github.io/kiro-proxy-ecosystem/mobile.html

---

*Maintained under GitHub Pages for marktantongco.*

