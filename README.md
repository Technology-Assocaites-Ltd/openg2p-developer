# OpenG2P Developer Setup

Orchestration repo to bootstrap local OpenG2P development (infra in Docker; apps native or Docker images).

**Full documentation:** [https://docs.openg2p.org/tools/openg2p-developer-setup](https://docs.openg2p.org/tools/openg2p-developer-setup)

**Source:** [https://github.com/OpenG2P/openg2p-developer](https://github.com/OpenG2P/openg2p-developer)

## Quick start (Docker Farmer Registry)

```bash
git clone https://github.com/OpenG2P/openg2p-developer.git
cd openg2p-developer
cp .env.example .env
sed -i 's/^USE_EXTERNAL_REDIS=.*/USE_EXTERNAL_REDIS=false/' .env
docker login registry.gitlab.com
make sync-images
make docker-farmer-up
```

Default ports and credentials are defined in `.env.example`.

| URL | Port (default) |
| --- | -------------- |
| Staff Portal hub | http://localhost:3000 |
| Farmer Registry UI | http://localhost:3001 |
| NSR UI | http://localhost:3002 |
| Keycloak | http://localhost:8080 |

| User | Password |
| ---- | -------- |
| `staff` | `staff` |
| `alex.carter` | `pass` |
| `nina.patel` | `pass` |
| `admin` (Keycloak) | `admin` |

```bash
make help
```

## Put PBMS and the connector up

From `openg2p-developer`, with `.env` already filled in.

If the social registry is already running, leave it. Check `http://127.0.0.1:8022/ping`. When that returns 200, run:

```bash
make vsss-pbms-connector-up
```

That keeps the registry you already have. It does not stop those containers and it does not drop `vsss_registry_db`. It adds PBMS and the connector, and it only creates the pieces that are missing.

If the social registry is not running, start it first with `make docker-vsss-up`, wait until `http://127.0.0.1:8022/ping` returns 200, then run the command above. Do not run `make docker-vsss-up` again once that registry is the one you want to keep. That command stops it and resets its databases.

`make vsss-pbms-connector-up` starts PBMS Odoo, the PBMS staff API, PBMS Celery, and the registry connector, and points PBMS at `vsss_registry_db`. It does not start G2P Bridge or SPAR.

The script prints `OK` or `FAIL` for each check. Done looks like this:

```text
OK  VSSS partner http://127.0.0.1:8022/ping -> 200
OK  PBMS staff API http://127.0.0.1:8050/docs -> 200
OK  PBMS Odoo http://127.0.0.1:8069/web/login -> 200
OK  Connector http://127.0.0.1:8070/health -> 200
OK  Connector ready http://127.0.0.1:8070/health/ready -> 200
OK  PBMS celery beat is running
OK  PBMS celery worker is running
OK  connector celery worker is running
```

Open:

- PBMS Odoo at http://127.0.0.1:8069
- PBMS staff API at http://127.0.0.1:8050/docs
- Connector at http://127.0.0.1:8070/health

If a line says `FAIL`, the log for that process is under `generated/run/`.

## License

[Mozilla Public License 2.0](LICENSE)
