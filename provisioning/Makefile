.DEFAULT_GOAL := help

.PHONY: help requirements server authorize certbot upgrade show-initial-password

help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "  requirements            Install Ansible Galaxy roles"
	@echo "  server                  Provision the server (swap, docker, jenkins)"
	@echo "  authorize               Authorize SSH keys"
	@echo "  certbot                 Install Certbot and issue SSL certificates"
	@echo "  upgrade                 Upgrade and clean APT packages on the server"
	@echo "  show-initial-password   Print the Jenkins initial admin password"

requirements:
	ansible-galaxy install -r requirements.yml

server: requirements
	ansible-playbook server.yml -i hosts.yml

authorize:
	ansible-playbook authorize.yml -i hosts.yml

certbot: requirements
	ansible-playbook certbot.yml -i hosts.yml

upgrade:
	ansible-playbook upgrade.yml -i hosts.yml

show-initial-password:
	ansible -i hosts.yml manager -m shell -a 'cd /home/deploy/jenkins && docker compose exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword'
