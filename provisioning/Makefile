.DEFAULT_GOAL := help

.PHONY: help build preflight status logs requirements server authorize upgrade show-initial-password

help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "  build                          Build the provisioning toolbox Docker image"
	@echo "  preflight                      Verify inventory variables, SSH connectivity, disk space, and DNS"
	@echo "  status                         Show live server status: containers, disk, firewall, TLS, Jenkins health"
	@echo "  logs                           Show last 200 lines of Jenkins, Caddy and DinD logs (override: LINES=500)"
	@echo "  requirements                   Install Ansible Galaxy collections (local Ansible only)"
	@echo "  server                         Provision the server (SSH hardening, firewall, swap, docker, Caddy config)"
	@echo "  authorize                      Authorize SSH keys for the deploy user"
	@echo "  upgrade                        Upgrade and clean APT packages (reboot only with REBOOT=true)"
	@echo "  show-initial-password          Print the Jenkins initial admin password"

build:
	docker build -t jenkins-provision .

preflight:
	ansible-playbook preflight.yml -i hosts.yml

status:
	ansible-playbook status.yml -i hosts.yml

logs:
	ansible-playbook logs.yml -i hosts.yml $(if $(LINES),-e "lines=$(LINES)",)

requirements:
	ansible-galaxy install -r requirements.yml

server: requirements
	ansible-playbook server.yml -i hosts.yml

authorize:
	ansible-playbook authorize.yml -i hosts.yml

upgrade:
	ansible-playbook upgrade.yml -i hosts.yml $(if $(REBOOT),-e "reboot=$(REBOOT)",)

show-initial-password:
	ansible -i hosts.yml manager -m shell -a 'cd /home/deploy/jenkins && docker compose -p jenkins exec -T jenkins cat /var/jenkins_home/secrets/initialAdminPassword'
