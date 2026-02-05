# rbrun

Deploy apps to bare-metal Kubernetes. One YAML file, zero DevOps.

rbrun provisions servers, installs K3s, builds your Docker image, and deploys it — all from a single `rbrun.yaml` config.

## Install

```bash
gem install rbrun
```

## Quick start

```bash
# Deploy to production
rbrun release deploy -c rbrun.yaml -f . -e .env

# Check status
rbrun release status -c rbrun.yaml

# View logs
rbrun release logs -c rbrun.yaml

# SSH into the server
rbrun release ssh -c rbrun.yaml

# Run a command in a pod
rbrun release exec "rails console" -c rbrun.yaml

# Connect to PostgreSQL
rbrun release sql -c rbrun.yaml

# Tear everything down
rbrun release destroy -c rbrun.yaml
```

## Sandboxes

Ephemeral environments spun up from a branch. Each gets its own server and unique URL.

```bash
rbrun sandbox deploy -c rbrun.yaml -f . -e .env
rbrun sandbox logs --slug abc123 -c rbrun.yaml
rbrun sandbox destroy --slug abc123 -c rbrun.yaml
```

## Configuration

Everything is defined in a single `rbrun.yaml`. Environment variables are interpolated with `${VAR_NAME}` syntax — use a `.env` file or export them.

---

### Minimal — single server

The simplest config. One server runs everything: your app, database, workers.

```yaml
target: production

compute:
  provider: hetzner
  api_key: ${HETZNER_API_TOKEN}
  ssh_key_path: ~/.ssh/id_rsa
  server: cpx21                     # Single server mode — one box does it all

cloudflare:
  api_token: ${CLOUDFLARE_API_TOKEN}
  account_id: ${CLOUDFLARE_ACCOUNT_ID}
  domain: example.com

databases:
  postgres: ~                       # Uses postgres:16-alpine by default

app:
  processes:
    web:
      command: bin/rails server
      port: 3000
      subdomain: www                # Accessible at www.example.com

setup:
  - bin/rails db:prepare

env:
  RAILS_ENV: production
  SECRET_KEY_BASE: ${SECRET_KEY_BASE}
```

---

### Multi-server — separate concerns

Split compute into named server groups. Pin processes, databases, and services to specific groups with `runs_on`.

```yaml
target: production

compute:
  provider: hetzner
  api_key: ${HETZNER_API_TOKEN}
  ssh_key_path: ~/.ssh/id_rsa
  servers:                          # Multi-server mode
    app:
      type: cpx21                   # 3 vCPU, 4GB RAM
      count: 2                      # Two app servers
    worker:
      type: cpx21
    db:
      type: cpx31                   # 4 vCPU, 8GB RAM — more headroom for pg

cloudflare:
  api_token: ${CLOUDFLARE_API_TOKEN}
  account_id: ${CLOUDFLARE_ACCOUNT_ID}
  domain: example.com

databases:
  postgres:
    image: pgvector/pgvector:pg17   # Custom image
    runs_on: db                     # Pinned to db server group

services:
  redis:
    image: redis:7-alpine
    runs_on: app                    # Co-located with app processes

app:
  dockerfile: Dockerfile
  processes:
    web:
      command: "./bin/thrust ./bin/rails server"
      port: 80
      subdomain: myapp              # myapp.example.com
      replicas: 2                   # 2 pods across app servers
      runs_on:
        - app
    worker:
      command: bin/jobs
      replicas: 2
      runs_on:
        - worker                    # Isolated on worker servers

setup:
  - bin/rails db:prepare

env:
  RAILS_ENV: production
  SECRET_KEY_BASE: ${SECRET_KEY_BASE}
```

---

### Scale up/down by changing the config

rbrun reconciles declaratively. Change `count` or add/remove groups, redeploy, and it converges:

```yaml
# Scale app servers from 2 to 5 — just change the number and redeploy
servers:
  app:
    type: cpx21
    count: 5        # Was 2. rbrun creates app-3, app-4, app-5, joins them to K3s.
```

```yaml
# Scale down — rbrun drains pods, removes K3s nodes, deletes servers
servers:
  app:
    type: cpx21
    count: 1        # Was 5. rbrun drains app-5 through app-2, deletes them from Hetzner.
```

Redeploying with the same config is a no-op for infrastructure. Only the app image rolls out.

---

## Config reference

### `target`

```yaml
target: production    # or staging, sandbox
```

Controls naming prefix and firewall rules. Defaults to `production`.

### `compute`

| Key | Required | Default | Description |
|-----|----------|---------|-------------|
| `provider` | yes | — | `hetzner` or `scaleway` |
| `api_key` | yes | — | Provider API token |
| `ssh_key_path` | yes | — | Path to SSH private key |
| `location` | no | `ash` (Hetzner) | Datacenter location |
| `image` | no | `ubuntu-22.04` | Base OS image |
| `server` | * | — | Single-server mode: instance type (e.g. `cpx21`) |
| `servers` | * | — | Multi-server mode: named groups (see below) |

\* Exactly one of `server` or `servers` is required.

#### `compute.servers.<group>`

| Key | Required | Default | Description |
|-----|----------|---------|-------------|
| `type` | yes | — | Instance type (e.g. `cpx11`, `cpx21`, `cpx31`) |
| `count` | no | `1` | Number of servers in this group |

The first server of the first group is the K3s master node.

### `cloudflare`

Required when any process or service has a `subdomain`.

| Key | Required | Default | Description |
|-----|----------|---------|-------------|
| `api_token` | yes | — | Cloudflare API token |
| `account_id` | yes | — | Cloudflare account ID |
| `domain` | yes | — | Root domain (e.g. `example.com`) |

### `databases`

Supported types: `postgres`, `sqlite`.

```yaml
databases:
  postgres:
    image: pgvector/pgvector:pg17   # Optional, default: postgres:16-alpine
    runs_on: db                     # Optional, multi-server only
```

When postgres is configured, these env vars are auto-injected into app pods:
`DATABASE_URL`, `POSTGRES_HOST`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`, `POSTGRES_PORT`.

### `services`

Sidecar services deployed alongside your app. Each requires an image.

```yaml
services:
  redis:
    image: redis:7-alpine
    runs_on: app                    # Optional, multi-server only
  meilisearch:
    image: getmeili/meilisearch:v1.6
    subdomain: search               # search.example.com
    runs_on: app
    env:
      MEILI_MASTER_KEY: ${MEILI_KEY}
```

Service URLs are auto-injected: `REDIS_URL`, `MEILISEARCH_URL`, etc.

### `app`

| Key | Required | Default | Description |
|-----|----------|---------|-------------|
| `dockerfile` | no | `Dockerfile` | Path to Dockerfile |

#### `app.processes.<name>`

| Key | Required | Default | Description |
|-----|----------|---------|-------------|
| `command` | no | — | Container entrypoint args |
| `port` | no | — | Container port (enables readiness probe + K8s Service) |
| `subdomain` | no | — | Public subdomain via Cloudflare tunnel + ingress |
| `replicas` | no | `2` | Number of pods. Processes with a subdomain require >= 2 |
| `runs_on` | no | — | List of server groups (multi-server only) |

Processes with a `subdomain` must have at least 2 replicas to ensure zero-downtime rolling deploys.

### `claude`

Optional. Enables Claude-powered features.

```yaml
claude:
  auth_token: ${ANTHROPIC_API_KEY}
```

### `setup`

Commands run inside the app container on deploy (e.g. migrations).

```yaml
setup:
  - bin/rails db:prepare
  - bin/rails assets:precompile
```

### `env`

Environment variables injected into all app process pods as a Kubernetes Secret.

```yaml
env:
  RAILS_ENV: production
  SECRET_KEY_BASE: ${SECRET_KEY_BASE}
```

Supports `${VAR}` interpolation from the `.env` file passed with `-e`.

---

## How it works

1. **Provision** — creates/reconciles servers, firewall, private network on Hetzner
2. **K3s** — installs K3s on the master, joins workers, labels nodes by server group
3. **Tunnel** — sets up a Cloudflare tunnel for HTTPS ingress
4. **Build** — clones your repo on the server, builds the Docker image, pushes to in-cluster registry
5. **Deploy** — generates K8s manifests (Deployments, Services, Ingress, Secrets) and applies them
6. **Rollout** — waits for all deployments to be healthy

On subsequent deploys with the same infrastructure config, steps 1-3 are idempotent no-ops. Only the image build + rollout runs.

---

## Hetzner server types

| Type | vCPU | RAM | Disk | Use case |
|------|------|-----|------|----------|
| `cpx11` | 2 | 2GB | 40GB | Workers, small services |
| `cpx21` | 3 | 4GB | 80GB | General purpose, web apps |
| `cpx31` | 4 | 8GB | 160GB | Databases, memory-heavy workloads |
| `cpx41` | 8 | 16GB | 240GB | Large databases, high-traffic apps |
| `cpx51` | 16 | 32GB | 360GB | Heavy compute |

Locations: `ash` (Ashburn), `hil` (Hillsboro), `fsn1` (Falkenstein), `nbg1` (Nuremberg), `hel1` (Helsinki).
