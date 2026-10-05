.DEFAULT_GOAL := help

.PHONY: help init up down docker-up docker-down docker-pull docker-build show-initial-password deploy

help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "Local development:"
	@echo "  init                    Pull, build and start all services"
	@echo "  up                      Start all services"
	@echo "  down                    Stop all services"
	@echo "  show-initial-password   Print the Jenkins initial admin password"
	@echo ""
	@echo "Production:"
	@echo "  deploy HOST=<ip> PORT=<port>   Deploy to remote server"

init: docker-down docker-pull docker-build docker-up

up: docker-up
down: docker-down

docker-up:
	docker compose up -d

docker-down:
	docker compose down --remove-orphans

docker-pull:
	docker compose pull

docker-build:
	docker compose build --pull

show-initial-password:
	docker compose exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword

deploy:
ifndef HOST
	$(error HOST is not set. Usage: make deploy HOST=<ip> PORT=<port>)
endif
ifndef PORT
	$(error PORT is not set. Usage: make deploy HOST=<ip> PORT=<port>)
endif
	@echo "Starting deployment to $(HOST):$(PORT)..."
	@set -e; \
	echo "Transferring files..."; \
	ssh deploy@$(HOST) -p $(PORT) 'mkdir -p jenkins && rm -rf jenkins/docker.new'; \
	scp -P $(PORT) compose-production.yml deploy@$(HOST):jenkins/compose.yml.new; \
	scp -P $(PORT) -r docker deploy@$(HOST):jenkins/docker.new; \
	echo "Deploying services..."; \
	ssh deploy@$(HOST) -p $(PORT) 'set -e; cd jenkins && { \
		rm -rf docker && mv docker.new docker; \
		docker compose -p jenkins -f compose.yml.new pull --ignore-buildable; \
		docker compose -p jenkins -f compose.yml.new build --pull; \
		mv -f compose.yml.new compose.yml; \
		docker compose -p jenkins up -d --wait --wait-timeout 300 --remove-orphans; \
	}'; \
	echo "Deployment completed successfully"
