# 🤖 AI System Handoff & Deployment Instructions
## Secure Double-Proxy AI Wrapper & Triage Ecosystem

### 🎯 Objective for the AI Agent
You are tasked with reproducing, deploying, and validating the **Kiro / OWL / Hermes / Clash Proxy Stack** on this host computer. The stack abstracts regional network blocking, handles AWS Q OIDC authorization fallback states, and encapsulates network requests safely via terminal wrappers, preventing global proxy pollution.

Follow this exact structural playbook to provision the workspace.

---

## 🔎 1. Workspace Pre-Flight Diagnostics
Before touching or executing any scripts, perform forensic checks on the host to assess the network context:

1. **Check Clash Core (mihomo)**: Verify that Clash is active and listening on **port `7890`**:
   ```bash
   ss -tulpn | grep ":7890 "
   ```
2. **Check Port Conflicts**: Ensure ports `60000` (OWL Forward Proxy) and `8333` (Kiro Gateway) are completely clear:
   ```bash
   ss -tulpn | grep -E ":60000 |:8333 "
   ```
3. **Verify Git & GitHub CLI auth status**:
   ```bash
   git --version && gh auth status
   ```

---

## 🛠️ 2. Core Deployment Sequence

### Step 1: Clone the Replication Suite
Fetch the files from the replication repository:
```bash
git clone https://github.com/marktantongco/kiro-proxy-ecosystem.git ~/Documents/kiro-proxy-ecosystem
cd ~/Documents/kiro-proxy-ecosystem
```

### Step 2: System Installation & Compilations
1. **OWL Forwarding Proxy & Credentials CLI Setup**:
   Execute the core deduplicated installer. It builds the proxy defense logic at `~/.owl-agent` and sets up `kiro-cli` binary links from AWS S3, checking dynamic linkers (`ld-linux` repairs):
   ```bash
   chmod +x installers/install_owl_agent.sh
   ./installers/install_owl_agent.sh
   ```
2. **Kiro Gateway Translation Setup**:
   Execute the gateway installer to configure python translation servers at `~/Documents/proxy/kiro-gateway` and prepare `opencode.jsonc` entries:
   ```bash
   chmod +x installers/install_kiro_owl_agent.sh
   ./installers/install_kiro_owl_agent.sh
   ```

### Step 3: Deploys Systemd User Units
Configure the background daemons so they survive restarts and run cleanly in the user namespace:
```bash
mkdir -p ~/.config/systemd/user/
cp systemd/kiro-gateway.service ~/.config/systemd/user/
cp systemd/owl-forward-proxy.service ~/.config/systemd/user/

systemctl --user daemon-reload
systemctl --user enable --now owl-forward-proxy.service kiro-gateway.service
```

### Step 4: Provision Terminal Wrappers
Install the dynamic privilege wrappers. These isolate the proxy environment within the lifecycle of the commands:
```bash
mkdir -p ~/.local/bin
cp scripts/hermes_wrapper.sh ~/.local/bin/hermes
cp scripts/kiro_gateway_wrapper.sh ~/.local/bin/kiro-gateway
chmod +x ~/.local/bin/hermes ~/.local/bin/kiro-gateway
```
*Verify that `~/.local/bin` is in the user's `PATH`. If not, append it in `.bashrc`.*

---

## 🩺 3. Auto-Triage & Self-Healing Execution
Run the diagnostic and self-healing triage script:
```bash
chmod +x scripts/validate_ecosystem.sh
./scripts/validate_ecosystem.sh
```
**Triage Objectives Met by the Script:**
* Detects and warns about lowercase variable pollution (e.g., dead port `2080`).
* Kills manual background proxy processes on ports `8333` and `60000` to prevent collisions.
* Aligns systemd user units to a running state.
* Performs a live end-to-end active ping check (HTTP tunnel through OWL `60000` -> Clash `7890` -> Outside).

---

## 🔑 4. Credentials Authentication & Maintenance
If the terminal returns **403 Forbidden** or **502 Bad Gateway** errors:
1. The AWS monthly free limits have been hit. The stack automatically defaults to its **13 pre-cached fallback models** to prevent runtime crashes.
2. **To Restore Active Models**: Open the AWS Builder ID Console, register a fresh free ID, and log in:
   ```bash
   kiro-cli login
   ```
3. Restart the background gateway service to apply the new tokens:
   ```bash
   systemctl --user restart kiro-gateway.service
   ```

---

## 🚫 5. Critical Guidelines for AI Agent
* **Strict Wrapper Encapsulation**: **NEVER** export global proxy variables in the system shell. Always run standalone agents via `hermes [args]` or `kiro-cli [args]` wrappers to keep environment variables isolated.
* **Upstream Clash Priority**: Always ensure `UPSTREAM_PROXY=http://127.0.0.1:7890` is bound in the OWL systemd service to route regional traffic reliably.
* **Non-interactive Execution**: When writing automation or installation scripts for the host, always append `--yes` or `-y` to commands to prevent blocking on headless agents.
