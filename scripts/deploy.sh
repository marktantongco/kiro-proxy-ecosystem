#!/bin/bash
# 🦉 Kiro Proxy Ecosystem — Deploy Script
# Compiles the site, commits, pushes to master, and triggers GitHub Pages.
set -euo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${CYAN}➜${NC} $1"; }
ok()    { echo -e "${GREEN}✓${NC} $1"; }
err()   { echo -e "${RED}✗${NC} $1"; }

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

# 1. Ensure we're on master
info "Checking branch..."
BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$BRANCH" != "master" ]; then
    err "Not on master branch (current: $BRANCH). Switch to master first."
    exit 1
fi

# 2. Compile site (embeds all scripts into index.html / mobile.html)
info "Compiling site..."
python3 compile_site.py

# 3. Stage everything
info "Staging changes..."
git add -A

# 4. Show what's changed
echo ""
echo "  Changed files:"
git diff --cached --name-only | sed 's/^/    /'
echo ""

# 5. Commit
if git diff --cached --quiet; then
    info "Nothing to commit — working tree clean."
else
    read -p "  Commit message: " msg
    if [ -z "$msg" ]; then
        msg="chore: site update $(date +%Y-%m-%d)"
    fi
    git commit -m "$msg"
    ok "Committed."
fi

# 6. Push to GitHub (triggers GitHub Pages auto-deploy)
info "Pushing to origin/master..."
git push origin master
ok "Pushed. GitHub Pages deploying..."

# 7. Show deploy URL
echo ""
echo "  🌐 https://marktantongco.github.io/kiro-proxy-ecosystem/"
echo "  📱 https://marktantongco.github.io/kiro-proxy-ecosystem/mobile.html"
echo ""
info "Check deploy status: gh api repos/marktantongco/kiro-proxy-ecosystem/pages --jq '.status'"
