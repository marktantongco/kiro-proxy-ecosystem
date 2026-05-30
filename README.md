# 🦉 Kiro / OWL / Hermes / Clash Proxy Stack - Replication Suite

Welcome to the comprehensive, self-healing **AI Wrapper and Secure Proxy Replication Suite**. This repository contains every script, wrapper launcher, systemd unit, config map, and utility required to reproduce a completely operational regional-bypass proxy stack for OpenCode, standalone local agents (e.g., Hermes), and parallel research pipelines.

---

## 📐 1. Dynamic Ecosystem Architecture

Our network stack encapsulates local HTTP traffic and routes it dynamically through a double-proxy tunnel to secure regional endpoints without global environment pollution:

```
  [ Standalone Hermes CLI ]               [ OpenCode Editor / IDE ]
              ↓                                       ↓
     (hermes wrapper)                        (opencode.jsonc settings)
              ↓                                       ↓
   [ Explicit HTTP_PROXY ]                 [ Kiro Gateway (Port 8333) ]
              ↓                                       ↓ (Translates API)
  [ OWL Forward Proxy (Port 60000) ] ─────────────────┛
              ↓ (UPSTREAM_PROXY)
   [ Clash / mihomo (Port 7890) ]
              ↓ (Secure Geo-Routing)
        [ Outside World ]
```

---

## 📁 2. Unified File Directory & Relationships

This replication suite is organized logically into specific functional directories. Below is the catalog of files and how they work in harmony:

### ⚙️ Core Wrappers & Scripts (`/scripts`)
* **[`validate_ecosystem.sh`](./scripts/validate_ecosystem.sh)**: The automated self-healing diagnostic suite. Detects lowercase variable pollution, kills manual port bindings on `8333` and `60000` to prevent collisions, verifies systemd services, and runs an end-to-end active ping.
* **[`patch_owl_proxy.sh`](./scripts/patch_owl_proxy.sh)**: Installs the Clash upstream routing overrides inside your active python OWL installations, unsets conflicting environmental routes, and restores fallback definitions.
* **[`install.sh`](./scripts/install.sh)**: Base system compilation and binary fetcher script.
* **[`owl_agent_installer_v4.sh`](./scripts/owl_agent_installer_v4.sh)**: The standard OWL agent configuration installer.
* **[`hermes_wrapper.sh`](./scripts/hermes_wrapper.sh)**: Launcher wrapper (deploys to `~/.local/bin/hermes`). Isolates `HTTP_PROXY` within the agent command lifecycle and delegates systemd checks to the correct standard user when running under root.
* **[`kiro_gateway_wrapper.sh`](./scripts/kiro_gateway_wrapper.sh)**: Standard Kiro terminal launcher.

### 🛠️ Dedicated Installers (`/installers`)
* **[`install_kiro_owl_agent.sh`](./installers/install_kiro_owl_agent.sh)**: Fully customized combo installer script for deploying Kiro CLI credentials management alongside the OWL forwarding proxy.
* **[`ubuntu_obsidian_install_owl_agent.sh`](./installers/ubuntu_obsidian_install_owl_agent.sh)**: Obsidian-centric OWL workspace installer, setting up notes search and indexing scopes.
* **[`owl_agent_installer.sh`](./installers/owl_agent_installer.sh)**: Standard system-wide installer for compiling and starting OWL core.

### 🧠 MCP Integration (`/mcp`)
* **[`owl_resilient_mcp.py`](./mcp/owl_resilient_mcp.py)**: The premium Model Context Protocol (MCP) server bridge. Translates semantic search and tool executions, keeping queries securely encapsulated.

### 🧪 Integration Tests (`/tests`)
* **[`test_parallel_research.py`](./tests/test_parallel_research.py)**: Operational pipeline test suite to verify that concurrent model requests run securely through the double-proxy environment without triggering rate limits or leakage.

### 📝 Config Maps & Daemons (`/configs` & `/systemd`)
* **[`handoff-antigravity-autoapproval.md`](./configs/handoff-antigravity-autoapproval.md)**: Dynamic agent auto-approval security ruleset.
* **[`kiro-gateway.service`](./systemd/kiro-gateway.service)**: Systemd user-service unit mapping for running Kiro background API translators.
* **[`owl-forward-proxy.service`](./systemd/owl-forward-proxy.service)**: Systemd user-service unit mapping for running OWL forward proxies.

---

## 🚀 3. Step-by-Step Station Replication Guide

To reproduce this exact operational environment on another machine, execute these steps:

### Step 1: Upstream Routing Setup
Ensure Clash (`mihomo` or equivalent) is installed, running, and listening on **port `7890`**.

### Step 2: Running the Installers
1. Run the combo agent installer to deploy credentials and core components:
   ```bash
   chmod +x installers/install_kiro_owl_agent.sh
   ./installers/install_kiro_owl_agent.sh
   ```
2. Verify systemd units are correctly installed:
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

*Maintained under GitHub pages for marktantongco.*
