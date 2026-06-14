import os

# Define the target files, categories, and relationships
files_to_compile = [
    {
        "path": "scripts/backup_restore_proxy.sh",
        "category": "Backup & Restore",
        "relation": "Self-extracting restore installer script that recovers the systemd user units, environment wrappers, and checks runtime health."
    },
    {
        "path": "scripts/validate_ecosystem.sh",
        "category": "Triage Script",
        "relation": "Main self-healing suite. Resolves Bash read-only errors, terminates background collisions, and verifies pings."
    },
    {
        "path": "scripts/patch_owl_proxy.sh",
        "category": "Triage Script",
        "relation": "Upstream patch script. Injects Clash proxy routing definitions into your local Python packages."
    },
    {
        "path": "scripts/hermes_wrapper.sh",
        "category": "Wrapper",
        "relation": "Launcher wrapper that isolates HTTP_PROXY within standalone Hermes execution context."
    },
    {
        "path": "scripts/agy_wrapper.sh",
        "category": "Wrapper",
        "relation": "Secure proxy launcher wrapper that dynamically unsets local variable scopes before running Antigravity."
    },
    {
        "path": "scripts/kiro_gateway_wrapper.sh",
        "category": "Wrapper",
        "relation": "Wrapper script for launching the Kiro Terminal under custom environments."
    },
    {
        "path": "installers/install_kiro_owl_agent.sh",
        "category": "Installer",
        "relation": "Combination setup installer that automatically sets up local credentials databases, links, and Python wrappers."
    },
    {
        "path": "installers/install_owl_agent.sh",
        "category": "Installer",
        "relation": "Centrally provisions OWL workspaces for local Obsidian vaults, notes searches, and semantic models. Deduplicated core OWL and credentials installer."
    },
    {
        "path": "mcp/owl_resilient_mcp.py",
        "category": "MCP Server",
        "relation": "Resilient Model Context Protocol integration. Keeps semantic data searches securely routed and translated."
    },
    {
        "path": "tests/test_parallel_research.py",
        "category": "Test Suite",
        "relation": "Tests concurrent research loops, verifying double-proxy environment limits and zero-leakage routing."
    },
    {
        "path": "configs/handoff-antigravity-autoapproval.md",
        "category": "Configuration",
        "relation": "Integrates Antigravity agentic auto-approval policy mapping into local configurations."
    },
    {
        "path": "configs/ai-instructions-handover.md",
        "category": "AI Instructions",
        "relation": "The comprehensive handover instruction manual designed specifically for AI coding agents to recreate, connect, deploy, and maintain the stack."
    },
    {
        "path": "scripts/diagnose_opencode.sh",
        "category": "Triage Script",
        "relation": "Automated self-healing diagnostics check. Pinpoints active ports, Unix socket mismatches, and tests direct-connect proxy bypass rules."
    },
    {
        "path": "configs/README_PROXY_ARCHITECTURE.md",
        "category": "Documentation",
        "relation": "Comprehensive proxy bypass routing architecture manual for NVIDIA NIM, OpenCode Zen, and Kiro/AWS Q backend model providers."
    },
    {
        "path": "systemd/kiro-gateway.service",
        "category": "Systemd Service",
        "relation": "Systemd user service config for managing the Kiro API Translation Gateway service process."
    },
    {
        "path": "systemd/owl-forward-proxy.service",
        "category": "Systemd Service",
        "relation": "Systemd user service config for running and monitoring the core OWL forward proxy stack."
    }
]

base_dir = os.path.dirname(os.path.abspath(__file__))

# Read each file and construct the JS catalog manually using backtick template literals
js_entries = []
for file_meta in files_to_compile:
    full_path = os.path.join(base_dir, file_meta["path"])
    print(f"Compiling: {full_path}")
    if os.path.exists(full_path):
        with open(full_path, "r", encoding="utf-8") as f:
            code_content = f.read()
        
        # Escape backslashes, backticks, and template literal interpolation ($) in JS
        # To avoid escaping issues, we replace backslashes first, then backticks, then dollar signs.
        escaped_code = code_content.replace("\\", "\\\\").replace("`", "\\`").replace("$", "\\$")
        
        entry_str = f"""    {{
        path: "{file_meta['path']}",
        category: "{file_meta['category']}",
        relation: "{file_meta['relation']}",
        download: "https://github.com/marktantongco/kiro-proxy-ecosystem/raw/master/{file_meta['path']}",
        code: `{escaped_code}`
    }}"""
        js_entries.append(entry_str)
    else:
        print(f"Error: File {full_path} not found!")

# Join the catalog array
js_catalog_str = "const filesCatalog = [\n" + ",\n".join(js_entries) + "\n];"

# Read index.html and replace the database placeholder
index_path = os.path.join(base_dir, "index.html")
if os.path.exists(index_path):
    with open(index_path, "r", encoding="utf-8") as f:
        index_content = f.read()

    start_marker = "// === FILES_CATALOG_START ==="
    end_marker = "// === FILES_CATALOG_END ==="

    start_idx = index_content.find(start_marker)
    if start_idx != -1:
        start_replace_idx = start_idx + len(start_marker) + 1  # Include newline
        end_idx = index_content.find(end_marker, start_replace_idx)
        if end_idx != -1:
            new_index_content = index_content[:start_replace_idx] + js_catalog_str + "\n" + index_content[end_idx:]
            with open(index_path, "w", encoding="utf-8") as f:
                f.write(new_index_content)
            print("Compilation successful! index.html compiled with secure ES6 backtick literals using robust comment markers.")
        else:
            print("Error: Could not locate FILES_CATALOG_END in index.html!")
    else:
        print("Error: Could not locate FILES_CATALOG_START in index.html!")

# Read mobile.html and replace the database placeholder
mobile_path = os.path.join(base_dir, "mobile.html")
if os.path.exists(mobile_path):
    with open(mobile_path, "r", encoding="utf-8") as f:
        mobile_content = f.read()

    start_marker = "// === FILES_CATALOG_START ==="
    end_marker = "// === FILES_CATALOG_END ==="

    start_idx = mobile_content.find(start_marker)
    if start_idx != -1:
        start_replace_idx = start_idx + len(start_marker) + 1  # Include newline
        end_idx = mobile_content.find(end_marker, start_replace_idx)
        if end_idx != -1:
            new_mobile_content = mobile_content[:start_replace_idx] + js_catalog_str + "\n" + mobile_content[end_idx:]
            with open(mobile_path, "w", encoding="utf-8") as f:
                f.write(new_mobile_content)
            print("Compilation successful! mobile.html compiled with secure ES6 backtick literals using robust comment markers.")
        else:
            print("Error: Could not locate FILES_CATALOG_END in mobile.html!")
    else:
        print("Error: Could not locate FILES_CATALOG_START in mobile.html!")

