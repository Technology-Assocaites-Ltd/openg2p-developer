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

## Village Social Security, then PBMS

Run these in order. Wait until the check passes before the next step.

1. Start the Docker registry.

```bash
make docker-vsss-up
```

Pass: `http://127.0.0.1:8022/ping` returns 200.

2. Attach PBMS and the registry connector to that registry. This does not start a second registry.

```bash
make vsss-pbms-connector-up
```

Pass:

- VSSS partner `http://127.0.0.1:8022/ping` returns 200
- PBMS staff API `http://127.0.0.1:8050/docs` returns 200
- PBMS Odoo `http://127.0.0.1:8069/web/login` returns 200
- Connector `http://127.0.0.1:8070/health` and `http://127.0.0.1:8070/health/ready` return 200

PBMS Celery uses `vsss_registry_db`.

G2P Bridge is the next step. This command leaves it off.

## License

[Mozilla Public License 2.0](LICENSE)
