# Deploying Sudoku Race

Sudoku Race deploys to a DigitalOcean droplet via Docker Compose (Postgres +
the Phoenix release). Pushing to `main` runs tests, builds + pushes the image,
then SSHes in and runs `docker compose pull && up`.

## Coexisting with residency-schedule on one droplet

This droplet also runs **residency-schedule**, which uses a different model:
bare-metal Mix release under systemd, a **host Nginx** owning ports **80/443**,
and a **host-native Postgres**. Sudoku Race is built to sit alongside it
without touching anything it owns:

| Concern | residency-schedule | sudoku_race | Isolated? |
|---|---|---|---|
| Files | `/home/deploy/residency_schedule` | `/opt/sudoku_race` | yes |
| Database | host Postgres, `residency_schedule_prod` | **containerized** Postgres, `sudoku_race_prod`, volume `sudoku_race_postgres_data` | yes — separate engine |
| App port | host `localhost:4000` | container 4000 → **`127.0.0.1:4001`** | yes |
| 80 / 443 | owned by host **Nginx** | NOT bound — proxied via that same Nginx | yes |
| Process mgr | systemd `residency_schedule` | Docker Compose | yes |

The deploy never writes outside `/opt/sudoku_race` and Docker's own
namespaces, so residency-schedule's release, DB, systemd unit, and Nginx
config are untouched.

> **Rules to keep them isolated:**
> - Use a **distinct subdomain** (e.g. `sudoku.example.com`), not residency's.
> - The compose stack must **not** publish 80/443 and must **not** reuse host
>   port 4000. It binds `127.0.0.1:4001` only.

## One-time server setup

1. **Install Docker** (residency-schedule's setup did not):
   ```bash
   curl -fsSL https://get.docker.com | sh
   ```
2. **Create the app dir + env file** (root):
   ```bash
   mkdir -p /opt/sudoku_race
   cat > /opt/sudoku_race/.env << 'EOF'
   # Docker Hub image the CI build pushes (namespace = your Docker Hub user):
   APP_IMAGE=docker.io/<dockerhub-user>/sudoku_race:latest
   POSTGRES_PASSWORD=<choose a strong password>
   DATABASE_URL=ecto://postgres:<same password>@db/sudoku_race_prod
   SECRET_KEY_BASE=<mix phx.gen.secret>
   PHX_HOST=sudoku.example.com
   POOL_SIZE=10
   EOF
   chmod 600 /opt/sudoku_race/.env
   ```
3. **Add the Nginx site** (shares the existing Nginx; routes by `server_name`):
   ```bash
   cp deploy/nginx/sudoku_race.conf /etc/nginx/sites-available/sudoku_race
   # edit YOUR_DOMAIN → your subdomain
   ln -s /etc/nginx/sites-available/sudoku_race /etc/nginx/sites-enabled/
   nginx -t && systemctl reload nginx
   certbot --nginx -d sudoku.example.com
   ```

## GitHub secrets

`DO_HOST`, `DO_USER`, `DO_SSH_KEY`, `DOCKER_REGISTRY_USER`, `DOCKER_REGISTRY_TOKEN`.
The image is pushed to **Docker Hub**: `DOCKER_REGISTRY_USER` is your Docker Hub
username and `DOCKER_REGISTRY_TOKEN` a Docker Hub access token (Account Settings
→ Security → New Access Token, read/write).
`DO_USER` needs Docker access (root, or a user in the `docker` group) and write
access to `/opt/sudoku_race` — residency's `deploy` user (sudo limited to
`systemctl … residency_schedule`) is not sufficient.

## Resource note

A second Postgres container plus Docker adds memory pressure on a 2 GB droplet.
If it's tight, point `DATABASE_URL` at the host Postgres with a **separate
database** (`createdb sudoku_race_prod`) and drop the `db` service — the two
apps still never share a database.
