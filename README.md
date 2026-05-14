# Jenkins

Self-hosted Jenkins CI/CD server running in Docker with Nginx reverse proxy, TLS via Let's Encrypt, and Ansible provisioning.

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
   ▼
Docker DinD (2376/TLS)
   │  Isolated Docker daemon for pipeline builds
   ▼
Docker Registry Mirror (optional)
```

Jenkins communicates with a Docker-in-Docker sidecar over TLS. The Nginx config and SSL certificates are managed by Ansible and mounted into the container from the host — they are not part of the deployed application files.

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
| Ansible 2.10+ | Server provisioning (control node only) |
| `ansible.posix` collection | Required by the swap role (control node only) |
| SSH access to the server | Provisioning and deployment |
| A domain pointed at the server | TLS certificate issuance |

Install the required Ansible collection:

```bash
ansible-galaxy collection install ansible.posix
```

## Project structure

```
.
├── compose.yml                      # Development stack (port 8000)
├── compose-production.yml           # Production stack (ports 80/443)
├── Makefile                         # Local dev and deploy commands
├── docker/
│   ├── common/jenkins/
│   │   ├── Dockerfile               # Jenkins LTS + Docker CLI + plugins
│   │   └── plugins.txt              # Installed Jenkins plugins
│   └── development/nginx/conf.d/    # Dev Nginx config (no TLS)
└── provisioning/
    ├── Makefile                     # Provisioning commands
    ├── requirements.yml             # Ansible Galaxy role versions
    ├── hosts.yml.dist               # Inventory template — copy to hosts.yml
    ├── server.yml                   # Main provisioning playbook
    ├── certbot.yml                  # SSL certificate playbook
    ├── authorize.yml                # SSH key authorization playbook
    ├── upgrade.yml                  # System upgrade playbook
    └── roles/
        ├── swap/                    # Configures swap space
        ├── docker/                  # Installs Docker Engine
        ├── docker-cache/            # Configures Docker registry mirror
        └── jenkins/                 # Deploy user, DinD prune cron, Nginx config
```

## Local development

```bash
make init                    # Pull images, build Jenkins, start all services
make up                      # Start services
make down                    # Stop services
make show-initial-password   # Print Jenkins initial admin password
```

Jenkins is available at `http://localhost:8000`.

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
| `ansible_python_interpreter` | Path to Python 3 on the server (e.g. `/usr/bin/python3`). Used by Ansible to execute modules remotely — prevents interpreter auto-discovery warnings when multiple Python versions are installed. |
| `jenkins_domain` | Domain name pointing to the server |
| `certbot_admin_email` | Email for Let's Encrypt notifications |
| `cache_registry` | Docker registry mirror URL (optional, leave empty to disable) |

### 2. Provision the server

Installs swap, Docker Engine, Docker registry mirror, creates the `deploy` user, and renders the Nginx config.

```bash
cd provisioning && make server
```

### 3. Authorize your SSH key for deployments

The playbook reads your public key from `~/.ssh/id_rsa.pub`. If you use a different key type (e.g. `id_ed25519`), update the `key` path in `provisioning/authorize.yml` before running.

```bash
cd provisioning && make authorize
```

### 4. Issue SSL certificate

```bash
cd provisioning && make certbot
```

### 5. Deploy Jenkins

Run from the project root. Transfers compose and Docker config to the server, then starts the stack.

```bash
make deploy HOST=<server-ip> PORT=<ssh-port>
```

Jenkins is available at `https://<jenkins_domain>`.

Retrieve the initial admin password:

```bash
cd provisioning && make show-initial-password
```

## Day-2 operations

### Upgrade system packages

```bash
cd provisioning && make upgrade
```

### Renew SSL certificate

Certbot renewal runs automatically via cron on the server. To trigger manually:

```bash
cd provisioning && make certbot
```

### Update Ansible Galaxy roles

Bump the version in `provisioning/requirements.yml`, then re-run:

```bash
cd provisioning && make server
```

### Update Docker image versions

Pin the new versions in `compose.yml` and `compose-production.yml`, then redeploy:

```bash
make deploy HOST=<server-ip> PORT=<ssh-port>
```

### Add a Jenkins plugin

Add the plugin ID to `docker/common/jenkins/plugins.txt`, then rebuild and redeploy:

```bash
make deploy HOST=<server-ip> PORT=<ssh-port>
```

Plugin IDs can be found on [plugins.jenkins.io](https://plugins.jenkins.io).

## Jenkins plugins

Plugins are defined in `docker/common/jenkins/plugins.txt` and installed at image build time.

| Plugin | Purpose |
|---|---|
| `pipeline-stage-view` | Pipeline visualization in the classic UI |
| `pipeline-github` | GitHub integration for pipelines |
