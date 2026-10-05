# Jenkins

Self-hosted Jenkins CI/CD server running in Docker with a Docker-in-Docker sidecar, Caddy reverse proxy with automatic TLS via Let's Encrypt, and Ansible provisioning.

## Contents

- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Getting Started](#getting-started)
- [Using Jenkins](#using-jenkins)
- [Security notes](#security-notes)
- [Custom SSH port](#custom-ssh-port)
- [Day-2 operations](#day-2-operations)
- [Local development](#local-development)
- [Project structure](#project-structure)

## Architecture

```
Internet
   │
   ▼
Caddy (80/443)
   │  Automatic TLS, HTTP→HTTPS redirect
   ▼
Jenkins (8080)
   │  Docker CLI + Buildx + Compose
   │
   ├── tcp://docker:2376 (TLS) ──────────▶ Docker DinD
   │                                         Isolated daemon for pipeline builds
   │                                         daemon.json ← host: /etc/docker/dind-daemon.json
   │
   └── (optional) registry mirror ────────▶ Docker Registry Mirror
                                             Configured via cache_registry variable
```

Jenkins communicates with a Docker-in-Docker sidecar over mutual TLS on port 2376. Certificates are generated automatically by the DinD container and shared via a named volume. The Caddyfile is rendered by Ansible and mounted into the container from the host - it is not part of the deployed application files. Caddy obtains and renews TLS certificates itself and stores them in the `caddy-data` volume.

## Prerequisites

### Server requirements

| Resource | Minimum | Recommended |
|---|---|---|
| CPU | 1 vCPU | 2 vCPU |
| RAM | 2 GB | 4 GB |
| Disk free on `/` | 10 GB | 40 GB |
| Network | 1 public IP, ports 80 and 443 open | - |

Jenkins itself needs about 1 GB of RAM; the rest goes to pipeline builds inside the DinD daemon. Disk usage grows with Jenkins build history and with the images and build cache that pipelines leave in DinD - see [DinD pruning cron](#dind-pruning-cron).

### Supported operating systems

| Layer | Supported OS |
|---|---|
| Remote server | Ubuntu 24.04 LTS (Noble) |
| Control node (provisioning + deploy) | Linux, macOS |
| Local development (Docker only) | Linux, macOS, Windows |

### Required tools

| Tool | Purpose |
|---|---|
| Docker + Docker Compose plugin | Local development, production runtime, and provisioning toolbox |
| GNU Make | Makefile convenience targets (`make deploy`, `make up`, etc.) |
| SSH client (`ssh`, `scp`, `ssh-copy-id`) | Deployment |
| SSH access to the server | Provisioning and deployment |
| A DNS record pointed at the server | TLS certificate issuance |

Ansible and its Galaxy collections are bundled in the toolbox Docker image - nothing else needs to be installed locally.

## Getting Started

> Run every command from the project root. Provisioning commands start with `cd provisioning &&` - return to the project root (`cd ..`) before the next step.
>
> Step **2** (Install your SSH key) is optional - skip it if your VPS provider installed your SSH key at server creation time. Step **6** (Authorize deploy user) is always required: `make deploy` connects as the `deploy` user, which has no key until this step.

### 0. Build the provisioning toolbox

All provisioning commands run inside a Docker container that bundles Ansible, Galaxy collections, and all other dependencies. Build the image once before running any of the steps below:

```bash
cd provisioning && make build
```

All subsequent provisioning commands use the `./provision` wrapper, which runs `make` inside the container with the correct volume mounts and SSH agent forwarding:

```bash
cd provisioning
./provision make <target>
```

### 1. Configure inventory

```bash
cp provisioning/hosts.yml.dist provisioning/hosts.yml
```

Edit `provisioning/hosts.yml` and fill in your values. Connection settings go on the host; the other variables go under `all.vars`:

| Variable | Description |
|---|---|
| `ansible_host` | Server IP address |
| `ansible_port` | SSH port (default: `22`). If your server uses a non-default SSH port, set it here - every provisioning command connects on this port and the firewall allows it. |
| `ansible_python_interpreter` | Path to Python 3 on the server (e.g. `/usr/bin/python3`). Prevents interpreter auto-discovery warnings when multiple Python versions are installed. |
| `jenkins_domain` | Domain name pointing to the server (e.g. `jenkins.example.com`) |
| `acme_email` | Email address for the Let's Encrypt account and expiry notifications |
| `cache_registry` | Docker registry mirror URL (e.g. `https://cache-registry.example.com`). Configure this if you run the companion [docker-registry](https://github.com/rokorolov/docker-registry) project. Leave empty (`""`) to disable mirroring. |
| `ssh_hardening` | Disable SSH password logins (default: `true`). Set to `false` if you need password logins - see [Security notes](#security-notes) |

`jenkins_domain` must resolve to the server before the first deploy - Caddy requests the certificate when it starts. `provisioning/hosts.yml` is listed in `.gitignore` - it must never be committed.

### 2. Install your SSH key on the server

> **Skip this step if your VPS provider already installed your SSH key at creation time** - most providers offer this during the server setup wizard. Only needed when your server was provisioned with password-only root access.

Run on your machine, not in the toolbox. `ssh-copy-id` ships with OpenSSH, asks for the root password once, and appends your public key to `/root/.ssh/authorized_keys`:

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub -p <ssh-port> root@<server-ip>
```

Use the public key you normally log in with (`id_ed25519.pub`, `id_ecdsa.pub`, or `id_rsa.pub`). After this step, all provisioning commands use key-based authentication, and step 5 disables SSH password logins entirely (unless you set `ssh_hardening: false`).

> **Want a non-default SSH port?** Change it now, before step 5 enables the firewall - see [Custom SSH port](#custom-ssh-port).

### 3. Run preflight checks

Validates that all required inventory variables are set, SSH connectivity works, the server has at least 10 GB free on `/`, and `jenkins_domain` resolves to the server. Run this before any other provisioning step - it catches the most common configuration mistakes upfront.

```bash
cd provisioning && ./provision make preflight
```

### 4. Upgrade the server

Update all system packages before installing anything. This ensures a clean security baseline and avoids Docker being installed on top of stale package lists.

```bash
cd provisioning && ./provision make upgrade
```

If the upgrade needs a reboot (for example after a kernel update), the playbook says so. On a fresh server, reboot right away:

```bash
cd provisioning && ./provision make upgrade REBOOT=true
```

### 5. Provision the server

Disables SSH password logins, enables unattended security updates, configures the UFW firewall, installs swap space and Docker Engine, configures the DinD daemon registry mirror, creates the `deploy` system user, and renders the Caddyfile to `/etc/jenkins/caddy/` on the server.

```bash
cd provisioning && ./provision make server
```

This requires root SSH access with your key. SSH password logins stay enabled only if `ssh_hardening` is `false` (see [Security notes](#security-notes)). UFW is enabled with a default-deny incoming policy, allowing only SSH (on the port configured in `hosts.yml`), HTTP (80), and HTTPS (443, TCP and UDP for HTTP/3).

### 6. Authorize your SSH key for deployments

Copies your public key to the `deploy` user's `authorized_keys`. The playbook detects your key type automatically, checking for `id_ed25519`, `id_ecdsa`, and `id_rsa` in that order.

```bash
cd provisioning && ./provision make authorize
```

### 7. Deploy

Run from the project root. Transfers the compose file and Docker build context to the server, builds the Jenkins image, then starts the stack.

```bash
make deploy HOST=<server-ip> PORT=<ssh-port>
```

The compose file is staged as `compose.yml.new` and the `docker/` directory as `docker.new`. Images are pulled and built with the new files while the current stack keeps running; `compose.yml` is replaced only after the build succeeds, and `up -d` then recreates only the containers that changed. A failed transfer, pull, or build leaves the running stack untouched.

The deploy waits up to 5 minutes for every service to report healthy and fails if one does not, so a broken deploy is never reported as successful. Jenkins is then available at `https://<jenkins_domain>`.

Retrieve the initial admin password from the production instance:

```bash
cd provisioning && ./provision make show-initial-password
```

## Using Jenkins

### First login

1. Open `https://<jenkins_domain>` in a browser.
2. Paste the initial admin password (see above).
3. Choose **Install suggested plugins** or **Select plugins to install** (the plugins pre-installed in `plugins.txt` will already be available after the image build, so only install extras here).
4. Create the first admin user and complete the wizard.

### Plugin management

Plugins are baked into the Docker image via `docker/common/jenkins/plugins.txt` and installed at build time by `jenkins-plugin-cli`, together with their dependencies. To add a plugin to the image:

1. Add the plugin ID to `docker/common/jenkins/plugins.txt`. Plugin IDs are listed on [plugins.jenkins.io](https://plugins.jenkins.io).
2. Rebuild and redeploy:

```bash
make deploy HOST=<server-ip> PORT=<ssh-port>
```

Plugins can also be installed and updated in **Manage Jenkins → Plugins**. They are stored in the `jenkins-data` volume and survive redeploys: the image never downgrades a plugin that was updated in the UI. Removing a plugin from `plugins.txt` does not uninstall it from a running Jenkins - uninstall it in the UI.

### Connecting pipeline jobs to the Docker registry mirror

If you set `cache_registry` in the inventory, the DinD daemon is configured to pull through the mirror automatically - no pipeline code changes are needed. Docker uses registry mirrors only for Docker Hub images; pulls from other registries (for example `ghcr.io`) go directly to that registry.

## Security notes

- **SSH:** `make server` disables SSH password logins (`PasswordAuthentication no`, `KbdInteractiveAuthentication no`) and limits root to key logins (`PermitRootLogin prohibit-password`). The settings live in `/etc/ssh/sshd_config.d/01-hardening.conf`, which sorts before cloud-init's `50-cloud-init.conf` because sshd uses the first value it reads for these options. The file is validated with `sshd -t` before it is installed, and the run fails if `sshd -T` still reports password logins. Set `ssh_hardening: false` in `hosts.yml` to keep password logins; the next `make server` removes the file again.
- **Security updates:** `make server` enables `unattended-upgrades` with the distribution's default origins. Security fixes are installed daily; the Docker repository is not included and the server is never rebooted automatically.
- **Firewall:** UFW is configured with a default-deny incoming policy; only SSH, HTTP, and HTTPS are open. Ports published by Docker bypass UFW, so never publish Jenkins (8080) or the DinD daemon (2376) in `compose-production.yml`.
- **TLS:** Caddy serves TLS 1.2/1.3 only and issues and renews certificates automatically. HSTS with a two-year max-age is enforced.
- **DinD privilege:** The `docker` container runs with `--privileged`. This is required for Docker-in-Docker. The DinD container is not exposed to the host network - Jenkins connects to it over the internal Compose network via TLS.
- **Deploy user:** The `deploy` system user has no password (`!` in `/etc/shadow`) and belongs to the `docker` group. SSH access is via authorized key only.
- **Caddy config:** The Caddyfile is managed by Ansible and mounted read-only (`/etc/jenkins/caddy:/etc/caddy:ro`). It is not part of the deployed application files and cannot be overwritten by a deploy.
- **Credentials:** `provisioning/hosts.yml` is listed in `.gitignore`. Never commit it - it contains the server IP, SSH port, and domain name.
- **SSH host key checking:** The provisioning toolbox runs Ansible inside a Docker container where `~/.ssh` is mounted read-only and owned by the host user. SSH refuses config files it does not own, so `ansible.cfg` sets `host_key_checking = False` and `-F /dev/null` to skip the SSH config file entirely. Provisioning commands therefore do not verify the server's host key against a known-hosts file. The risk is low for a server you own and provisioned yourself, but a compromised DNS or network MITM would not be detected. Provision over a trusted network.

## Custom SSH port

Moving SSH off port 22 cuts down automated scanning and brute-force noise in the auth logs. It is not a substitute for key-based authentication and a firewall.

Pick the path that matches your server:

- [Fresh server](#fresh-server) - before `make server` has run (recommended: the firewall is not active yet)
- [Already provisioned server](#already-provisioned-server) - UFW is active, so open the new port first
- [At server creation with cloud-init](#at-server-creation-with-cloud-init) - set the port before you ever log in

### Fresh server

Change the port **before** `make server`. UFW is still inactive at that point, so a mistake cannot lock you out at the firewall, and `make server` then enables UFW with only the new port allowed - port 22 is never opened.

1. Log in on the current port and **keep this session open** until step 3 succeeds:

   ```bash
   ssh -p 22 root@<server-ip>
   ```

   On the server, set the new port in a drop-in file, check it, and restart SSH:

   ```bash
   echo "Port 2222" > /etc/ssh/sshd_config.d/10-port.conf
   sshd -t
   sshd -T | grep '^port '
   systemctl daemon-reload
   if systemctl is-active --quiet ssh.socket; then
       systemctl restart ssh.socket
   else
       systemctl restart ssh
   fi
   ```

   Before restarting, check the output: `sshd -t` must print nothing, and `sshd -T | grep '^port '` must print only `port 2222` - see [Why a drop-in file](#why-a-drop-in-file) if it also shows `port 22`. Ubuntu 24.04 and later start SSH through `ssh.socket`; Debian and older Ubuntu use the `ssh` service - the `if` handles both.

2. If your VPS provider has a cloud firewall (Hetzner, AWS, DigitalOcean, and others), allow the new TCP port there. This is the most common reason a new port appears unreachable.

3. From a **new** terminal, confirm the new port works:

   ```bash
   ssh -p 2222 root@<server-ip>
   ```

   If it fails, fix it from the session you kept open, or from your provider's web console.

4. Set `ansible_port: 2222` in `provisioning/hosts.yml`, then continue with the normal steps - `./provision make preflight` confirms Ansible connects on the new port.

### Already provisioned server

UFW is active, so follow the [Fresh server](#fresh-server) steps with two additions: allow the new port before restarting SSH in step 1, and remove the old rule only after step 3 succeeds.

```bash
ufw allow 2222/tcp          # before the restart in step 1
ufw delete allow 22/tcp     # after step 3 succeeds
```

### At server creation with cloud-init

Most providers accept cloud-init user data when you create a server. This sets the port before you ever log in; then continue with step 2 of [Fresh server](#fresh-server):

```yaml
#cloud-config
write_files:
  - path: /etc/ssh/sshd_config.d/10-port.conf
    content: "Port 2222\n"
runcmd:
  - [systemctl, daemon-reload]
  - [sh, -c, "systemctl restart ssh.socket 2>/dev/null || systemctl restart ssh"]
```

### Why a drop-in file

The commands above write `/etc/ssh/sshd_config.d/10-port.conf` instead of editing `/etc/ssh/sshd_config`:

- **Package upgrades stay clean.** Files in `sshd_config.d/` are never touched by upgrades, while an edited main config triggers conffile prompts on `openssh-server` upgrades.
- **`Port` values are combined, not overridden.** Unlike most settings, sshd listens on every `Port` from every config file. If the main config still has an uncommented `Port 22` line, SSH listens on both ports. Fresh installs ship it commented out (`#Port 22`); otherwise comment it out first.
- **Single-value settings work the other way.** For options such as `PasswordAuthentication`, the first value read wins, and `sshd_config.d/` is read before the rest of the main config - so an edit to the main config can be silently overridden by a drop-in like cloud-init's `50-cloud-init.conf`. This is why `make server` names its hardening file `01-hardening.conf` (see [Security notes](#security-notes)).

## Day-2 operations

### Check server status

Shows live state of all containers, disk usage, firewall rules, TLS certificate expiry, and whether Jenkins answers at `https://<jenkins_domain>/login` - without changing anything on the server. Run this before any Day-2 operation to confirm the server is healthy.

```bash
cd provisioning && ./provision make status
```

### View container logs

Shows the last 200 lines of logs from the Jenkins, Caddy, and DinD containers.

```bash
cd provisioning && ./provision make logs

# Show more lines
cd provisioning && ./provision make logs LINES=500
```

### Upgrade system packages

```bash
cd provisioning && ./provision make upgrade
```

Security updates are already installed daily by `unattended-upgrades`; `make upgrade` applies all other package updates. If a reboot is required, the playbook reports it and leaves the server running. Reboot when convenient - every service has `restart: always`, so the stack starts again on its own, but running builds are interrupted:

```bash
cd provisioning && ./provision make upgrade REBOOT=true
```

### TLS certificates

Caddy renews certificates automatically when about a third of their lifetime remains (30 days for today's 90-day certificates), with no cron job or reload step. Check the remaining validity with `./provision make status`. Certificates live in the `jenkins_caddy-data` volume - never delete it, or Caddy has to request new certificates and may hit Let's Encrypt rate limits.

### Update Caddy configuration

The Caddyfile is managed by Ansible. After editing `jenkins_domain`, `acme_email`, or `provisioning/roles/jenkins/templates/Caddyfile.j2`, re-provision to push the change:

```bash
cd provisioning && ./provision make server
```

Caddy reloads the new config automatically - no restart needed.

### Update Docker image versions

Images are pinned to `major.minor.patch` so updates are always explicit and reproducible. Find the new tags on Docker Hub, update both `compose.yml` and `compose-production.yml`, then redeploy:

```bash
make deploy HOST=<server-ip> PORT=<ssh-port>
```

| Image | Tag strategy | Rationale |
|---|---|---|
| `caddy` | `2.11.6-alpine` | Caddy 2 stable series. |
| `docker` | `29.6.1-dind` | Pin to `major.minor.patch` for full reproducibility. |
| `jenkins/jenkins` | `2.555.3-jdk21` | LTS release, pinned to `major.minor.patch-jdkN`. Avoid the floating `lts-jdk21` tag - it changes silently on every LTS release. |

The Jenkins image tag is set in `docker/common/jenkins/Dockerfile`.

### Update Ansible Galaxy collections

Bump the version range in `provisioning/requirements.yml`, rebuild the toolbox image, then re-run server provisioning:

```bash
cd provisioning && make build && ./provision make server
```

### DinD pruning cron

The `jenkins` Ansible role installs a daily cron job on the server (runs at **02:00**) that prunes the Docker-in-Docker daemon's storage:

```
docker compose -p jenkins exec -T docker docker system prune -af --filter until=360h
```

This removes stopped containers, unused networks, unused images, and build cache inside the DinD daemon that were created more than **15 days** (360 hours) ago. Volumes are never pruned. It runs inside the DinD container - it does not affect the host Docker daemon.

The host Docker daemon has its own separate prune cron (installed by the `docker` role, runs at **01:00**, same rules with a **72-hour** cutoff) that cleans up the host's own storage.

### Manage firewall rules

UFW is configured during provisioning. To inspect or modify rules on the server:

```bash
ssh root@<server-ip> -p <ssh-port> 'ufw status numbered'
```

To allow an additional port:

```bash
ssh root@<server-ip> -p <ssh-port> 'ufw allow <port>/tcp'
```

To remove a rule by number:

```bash
ssh root@<server-ip> -p <ssh-port> 'ufw delete <rule-number>'
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
| Jenkins (via Caddy) | `http://localhost:8000` |

The compose setup does not expose Jenkins' own port 8080 - use the Caddy address.

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

Pipeline jobs that run `docker build`, `docker push`, or `docker compose` commands execute inside this isolated daemon - they do not touch the host Docker socket.

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
│   └── development/caddy/Caddyfile  # Dev Caddy config (no TLS, proxies to port 8080)
└── provisioning/
    ├── Dockerfile                   # Provisioning toolbox image
    ├── provision                    # Wrapper script - runs make inside the toolbox container
    ├── ansible.cfg                  # Ansible configuration
    ├── Makefile                     # Provisioning commands
    ├── requirements.yml             # Ansible Galaxy collection versions
    ├── hosts.yml.dist               # Inventory template - copy to hosts.yml and fill in values
    ├── preflight.yml                # Pre-provisioning validation playbook
    ├── server.yml                   # Main provisioning playbook
    ├── authorize.yml                # SSH key authorization playbook
    ├── upgrade.yml                  # System upgrade playbook (reboot only with REBOOT=true)
    ├── status.yml                   # Live server status (containers, disk, firewall, TLS, Jenkins)
    ├── logs.yml                     # Tail Jenkins, Caddy, and DinD container logs
    └── roles/
        ├── ssh-hardening/           # Disables SSH password logins via an sshd_config.d drop-in
        ├── security-updates/        # Enables daily unattended security updates
        ├── ufw/                     # Default-deny firewall: SSH, HTTP, HTTPS (TCP + UDP) only
        ├── swap/                    # Creates a swapfile (auto-sized: 2× RAM if ≤1 GB, else 2 GB)
        ├── docker/                  # Installs Docker Engine + daily host prune cron (1 am, >72 h)
        ├── docker-cache/            # Writes dind-daemon.json to configure a registry mirror
        ├── create-deploy-user/      # Creates the deploy system user
        └── jenkins/                 # Adds DinD prune cron, renders the Caddyfile
```
