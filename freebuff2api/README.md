# Freebuff2API component

OpenAI-compatible gateway for the Codebuff Freebuff free tier — FastAPI + httpx + SSE.

Mirror of the full stack at **github.com/marktantongco/Freebuff2API-Optimized**
(fork of kele68108/Freebuff2API-Optimized) with the production hardening applied:

| Layer | Contents |
|---|---|
| `installers/install_freebuff2api.sh` | **Unified self-contained installer** (34 embedded base64 payloads) — `install / update / uninstall / doctor / status` |
| `scripts/build_installer.py` | Regenerates the unified installer from source |
| `scripts/doctor.sh` | go/no-go validation: healthz / readyz / models / chat ×2 / admin / log hygiene / RSS |
| `scripts/backup-freebuff2api.sh` | Nightly backup of data + `.env` (mode-600, 14-day retention) |
| `deploy/` | systemd units (api + admin), backup timer, journald rotation drop-in |
| `tool/` | `get_token.py` (device-code login) + token web tool |

## The production fixes bundled here

- **R5** — jittered rate-limit retries honoring `retry_after_ms` / `reset_at` (`FREEBUFF_RETRY_JITTER`)
- **R6** — `/livez` `/readyz` `/metrics` (Prometheus), correlation IDs, full-SSE-duration timing
- **Gate fix** — `free_mode_cli_required` bypass: real Buffy CLI system-prompt extraction from the
  installed CLI binary (`freebuff2api/cli_prompt.py`), UA pinned to `provider-utils/3.0.25`,
  `x-freebuff-acting-user-id` header (`FREEBUFF_ACTING_USER_ID`)
- **Ops** — journald rotation (500M / 14d), nightly backup via systemd timer, doctor script

## Quick start

```bash
sudo bash installers/install_freebuff2api.sh            # install stack (api :20004, admin :20003)
sudo nano /var/lib/freebuff2api/repo/.env               # set FREEBUFF_TOKEN (+ FREEBUFF_ACTING_USER_ID)
sudo bash installers/install_freebuff2api.sh doctor     # go/no-go validation
```

The installer is fully self-contained — every runtime file is embedded, so it works
offline apart from Python dependency downloads (fastapi / httpx / uvicorn / dotenv).
