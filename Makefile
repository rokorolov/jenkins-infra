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
	@echo "Starting Jenkins deployment..."
	@set -e; \
	echo "Transferring files..."; \
	scp -P $(PORT) compose-production.yml deploy@$(HOST):jenkins/compose.yml.new; \
	scp -P $(PORT) -r docker deploy@$(HOST):jenkins/docker.new; \
	echo "Configuring and deploying..."; \
	ssh deploy@$(HOST) -p $(PORT) 'set -e; cd jenkins && { \
		mv -f compose.yml.new compose.yml; \
		rm -rf docker && mv docker.new docker; \
		echo "COMPOSE_PROJECT_NAME=jenkins" > .env; \
		echo "Stopping existing services..."; \
		docker compose down --remove-orphans; \
		echo "Pulling latest images..."; \
		docker compose pull; \
		echo "Building images..."; \
		docker compose build --pull; \
		echo "Starting services..."; \
		docker compose up -d; \
		echo "Services started successfully"; \
	}'
	@echo "Jenkins deployment completed successfully"
