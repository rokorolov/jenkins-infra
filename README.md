# Jenkins

Self-hosted Jenkins CI/CD server running in Docker with a Docker-in-Docker sidecar, Nginx reverse proxy, TLS via Let's Encrypt, and Ansible provisioning.

## Architecture

```
Internet
   │
   ▼
Nginx (80/443)
   │  TLS termination, HTTP→HTTPS redirect
   ▼
Jenkins (8080)
   │  Docker CLI + Buildx + Compose
   │
   ├── tcp://docker:2376 (TLS) ──────────▶ Docker DinD
   │                                         Isolated daemon for pipeline builds
   │                                         daemon.json ← host: /etc/docker/dind-daemon.json
   │
   ├── (optional) registry mirror ────────▶ Docker Registry Mirror
   │                                         Configured via cache_registry variable
   │
   └── SSH ───────────────────────────────▶ Build agent(s)
                                             Separate host(s); runs pipeline steps
                                             instead of the built-in (controller) node
```

Jenkins communicates with a Docker-in-Docker sidecar over mutual TLS on port 2376. Certificates are generated automatically by the DinD container and shared via a named volume. The Nginx config and SSL certificates are managed by Ansible and mounted into the container from the host — they are not part of the deployed application files.

Build agents are separate hosts, provisioned by Ansible and connected over SSH, so pipeline code never executes inside the controller's own JVM/container — see [Set up a build agent](#set-up-a-build-agent-optional).

## Prerequisites

### Supported operating systems

| Layer | Supported OS |
|---|---|
| Remote server | Ubuntu 24.04 LTS (Noble) |
| Control node (provisioning + deploy) | Linux, macOS |
| Local development (Docker only) | Linux, macOS, Windows |

### Required tools

| Tool | Purpose |
|---|---|
| Docker + Docker Compose plugin | Local development and production runtime |
| Ansible 2.12+ | Server provisioning (control node only) |
| `ansible.posix` collection | Required by the swap role — installed via `make requirements` |
| SSH access to the server | Provisioning and deployment |
| A domain name pointed at the server | TLS certificate issuance |

## Project structure

```
.
├── compose.yml                      # Development stack (port 8000)
├── compose-production.yml           # Production stack (ports 80/443)
├── Makefile                         # Local dev and deploy commands
├── docker/
│   ├── common/jenkins/
│   │   ├── Dockerfile               # Jenkins LTS + Docker CLI + Buildx + Compose + plugins
│   │   └── plugins.txt              # Jenkins plugins installed at image build time
│   └── development/nginx/conf.d/    # Dev Nginx config (no TLS, proxies to port 8080)
└── provisioning/
    ├── Makefile                     # Provisioning commands
    ├── requirements.yml             # Ansible Galaxy collections and role versions
    ├── hosts.yml.dist               # Inventory template — copy to hosts.yml and fill in values
    ├── server.yml                   # Main provisioning playbook
    ├── certbot.yml                  # SSL certificate playbook
    ├── authorize.yml                # SSH key authorization playbook
    ├── upgrade.yml                  # System upgrade playbook
    └── roles/
        ├── swap/                    # Creates a swapfile (auto-sized: 2× RAM if ≤1 GB, else 2 GB)
        ├── docker/                  # Installs Docker Engine + daily host prune cron (1 am, >72 h)
        ├── docker-cache/            # Writes dind-daemon.json to configure a registry mirror
        ├── jenkins/                 # Creates deploy user, adds DinD prune cron, renders Nginx config
        └── agent/                   # Creates jenkins agent user, generates and authorizes the controller's SSH key
```

## Local development

```bash
make init                    # Pull images, build Jenkins image, start all services
make up                      # Start services
make down                    # Stop services
make show-initial-password   # Print the Jenkins initial admin password
```

| Service | URL |
|---|---|
| Jenkins (via Nginx) | `http://localhost:8000` |

Jenkins is also reachable directly on port 8080 if you bypass Nginx, but the compose setup does not expose that port — use the Nginx address.

### Getting the initial admin password

On first start, Jenkins generates a one-time password and writes it to:

```
/var/jenkins_home/secrets/initialAdminPassword
```

Print it with:

```bash
make show-initial-password
```

### Docker-in-Docker in development

The `docker` service in `compose.yml` runs a Docker-in-Docker daemon. Jenkins connects to it via the `DOCKER_HOST=tcp://docker:2376` environment variable. TLS certificates are generated automatically on first start and shared with Jenkins via the `docker-certs` volume.

Pipeline jobs that run `docker build`, `docker push`, or `docker compose` commands execute inside this isolated daemon — they do not touch the host Docker socket.

## Production deployment

### 1. Configure inventory

```bash
cp provisioning/hosts.yml.dist provisioning/hosts.yml
```

Edit `provisioning/hosts.yml` and fill in your values:

| Variable | Description |
|---|---|
| `ansible_host` | Server IP address |
| `ansible_port` | SSH port |
| `ansible_python_interpreter` | Path to Python 3 on the server (e.g. `/usr/bin/python3`). Prevents interpreter auto-discovery warnings when multiple Python versions are installed. |
| `jenkins_domain` | Domain name pointing to the server (e.g. `jenkins.example.com`) |
| `certbot_admin_email` | Email address for Let's Encrypt expiry notifications |
| `cache_registry` | Docker registry mirror URL (e.g. `https://cache-registry.example.com`). Configure this if you run the companion [docker-registry](https://github.com/rokorolov/docker-registry) project. Leave empty (`""`) to disable mirroring. |

`provisioning/hosts.yml` is listed in `.gitignore` — it must never be committed.

The `agent` group is optional — only fill it in if you want [distributed builds](#set-up-a-build-agent-optional). It needs no variables beyond the standard `ansible_*` connection settings; the agent role handles the rest.

### 2. Provision the server

Installs swap space, Docker Engine, configures the DinD daemon registry mirror, creates the `deploy` system user, and renders the Nginx config template to `/etc/jenkins/nginx/` on the server.

```bash
cd provisioning && make server
```

This requires root SSH access to the server. After this step you can lock down the `root` account if your security policy requires it.

### 3. Authorize your SSH key for deployments

Copies your public key (`~/.ssh/id_rsa.pub`) to the `deploy` user's `authorized_keys`. If you use a different key type (e.g. `id_ed25519`), update the `key` path in `provisioning/authorize.yml` before running.

```bash
cd provisioning && make authorize
```

### 4. Issue SSL certificate

The playbook uses the webroot method. If port 80 is not yet occupied, it temporarily starts an Apache container to serve the ACME challenge, then removes it when the certificate is issued.

```bash
cd provisioning && make certbot
```

### 5. Deploy

Run from the project root. Atomically transfers the compose file and Docker build context to the server, then starts the stack.

```bash
make deploy HOST=<server-ip> PORT=<ssh-port>
```

The compose file is staged as `compose.yml.new` and the `docker/` directory as `docker.new`. Both are renamed atomically only after a successful transfer, so an interrupted transfer cannot leave the server in a broken state.

Jenkins is available at `https://<jenkins_domain>` once the stack is running.

Retrieve the initial admin password from the production instance:

```bash
cd provisioning && make show-initial-password
```

### 6. Set up a build agent (optional)

By default Jenkins runs pipeline steps on the built-in node — the controller itself — which Jenkins flags as a security risk: pipeline code gets access to the controller's JVM, credentials store, and admin API. This step moves build execution to a separate, dedicated host connected over SSH.

Add an `agent` host to `provisioning/hosts.yml` (see `provisioning/hosts.yml.dist` for the shape), then provision it:

```bash
cd provisioning && make server
```

This installs Docker, Java, and Git on the agent host, creates a `jenkins` system user, and generates an SSH keypair at `provisioning/files/agent_rsa` (gitignored) that's authorized on the agent for that user. Re-running `make server` is safe — the keypair is only generated once and reused for any additional agent hosts.

Register the node in Jenkins (one-time, via the UI — this mirrors the manual first-login setup above and needs no extra plugin surface beyond `ssh-slaves`, already in `plugins.txt`):

1. **Manage Jenkins → Credentials → System → Global credentials → Add Credentials.** Kind: *SSH Username with private key*. Username: `jenkins`. Private key: paste the contents of `provisioning/files/agent_rsa`.
2. **Manage Jenkins → Nodes → New Node.** Type: *Permanent Agent*.
   - Remote root directory: `/home/jenkins/agent`
   - Labels: e.g. `linux docker`
   - Launch method: *Launch agents via SSH* — Host: the agent's IP, Credentials: the one from step 1, Host Key Verification Strategy: *Manually trusted key Verification Strategy*
3. **Manage Jenkins → Nodes → Built-In Node → Configure.** Set **Number of executors** to `0`. This is what actually stops jobs from scheduling on the controller — adding an agent alone doesn't do it.

## Using Jenkins

### First login

1. Open `https://<jenkins_domain>` in a browser.
2. Paste the initial admin password (see above).
3. Choose **Install suggested plugins** or **Select plugins to install** (the plugins pre-installed in `plugins.txt` will already be available after the image build, so only install extras here).
4. Create the first admin user and complete the wizard.

### Plugin management

Plugins are baked into the Docker image via `docker/common/jenkins/plugins.txt` and installed at build time by `jenkins-plugin-cli`. To add or update plugins:

1. Add or update the plugin ID in `docker/common/jenkins/plugins.txt`. Plugin IDs are listed on [plugins.jenkins.io](https://plugins.jenkins.io).
2. Rebuild and redeploy:

```bash
make deploy HOST=<server-ip> PORT=<ssh-port>
```

### Connecting pipeline jobs to the Docker registry mirror

If you set `cache_registry` in the inventory, the DinD daemon is configured to pull through the mirror automatically — no pipeline code changes are needed. All `docker pull` calls inside Jenkins pipelines will use the mirror transparently.

## Day-2 operations

### Upgrade system packages

```bash
cd provisioning && make upgrade
```

### Renew SSL certificate

Certbot renewal runs automatically via cron on the server. To trigger a manual renewal:

```bash
cd provisioning && make certbot
```

### Update Nginx configuration

The Nginx config is managed by Ansible. After editing `jenkins_domain` or the template at `provisioning/roles/jenkins/templates/nginx.conf.j2`, re-provision to push the change:

```bash
cd provisioning && make server
```

Then reload Nginx inside the running container:

```bash
ssh deploy@<server-ip> -p <port> 'cd jenkins && docker compose exec nginx nginx -s reload'
```

### Update Docker image versions

Images are pinned to `major.minor.patch` (Nginx also includes the Alpine OS version) so updates are always explicit and reproducible. Find the new tags on Docker Hub, update both `compose.yml` and `compose-production.yml`, then redeploy:

```bash
make deploy HOST=<server-ip> PORT=<ssh-port>
```

| Image | Tag strategy | Rationale |
|---|---|---|
| `nginx` | `1.30.3-alpine3.23` | Stable branch (`1.30.x`; even minor = stable, odd minor = mainline). Pin the Alpine OS version to prevent a silent base-image change on the next pull. |
| `docker` | `29.6.1-dind` | Pin to `major.minor.patch` for full reproducibility. |
| `jenkins/jenkins` | `2.555.3-jdk21` | LTS release, pinned to `major.minor.patch-jdkN`. Avoid the floating `lts-jdk21` tag — it changes silently on every LTS release. |

The Jenkins image tag is set in `docker/common/jenkins/Dockerfile`.

### Add or update Jenkins plugins

Add or update the plugin ID in `docker/common/jenkins/plugins.txt`, then rebuild and redeploy:

```bash
make deploy HOST=<server-ip> PORT=<ssh-port>
```

### Update Ansible Galaxy roles

Bump the version in `provisioning/requirements.yml`, then re-run server provisioning:

```bash
cd provisioning && make server
```

### DinD pruning cron

The `jenkins` Ansible role installs a daily cron job on the server (runs at **02:00**) that prunes the Docker-in-Docker daemon's storage:

```
docker compose exec docker docker system prune -af --filter until=360h
```

This removes all images, containers, networks, and build cache inside the DinD daemon that have not been used in the last **15 days** (360 hours). It runs inside the DinD container — it does not affect the host Docker daemon.

The host Docker daemon has its own separate prune cron (installed by the `docker` role, runs at **01:00**, threshold **72 hours**) that cleans up the host's own storage.

## Security notes

- **TLS:** Jenkins is served over TLS 1.2/1.3 only. HSTS with a two-year max-age is enforced. OCSP stapling is enabled.
- **DinD privilege:** The `docker` container runs with `--privileged`. This is required for Docker-in-Docker. The DinD container is not exposed to the host network — Jenkins connects to it over the internal Compose network via TLS.
- **Deploy user:** The `deploy` system user has no password (`!` in `/etc/shadow`) and belongs to the `docker` group. SSH access is via authorized key only. Root SSH can be disabled after provisioning.
- **Nginx config:** The config is managed by Ansible and mounted read-only (`/etc/jenkins/nginx:/etc/nginx/conf.d:ro`). It is not part of the deployed application files and cannot be overwritten by a deploy.
- **Credentials:** `provisioning/hosts.yml` is listed in `.gitignore`. Never commit it — it contains the server IP, SSH port, and domain name.
