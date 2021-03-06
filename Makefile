.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

DEPLOY_ENV_MAX_LENGTH=12
DEPLOY_ENV_VALID_LENGTH=$(shell if [ $$(printf "%s" $(DEPLOY_ENV) | wc -c) -gt $(DEPLOY_ENV_MAX_LENGTH) ]; then echo ""; else echo "OK"; fi)
DEPLOY_ENV_VALID_CHARS=$(shell if echo $(DEPLOY_ENV) | grep -q '^[a-zA-Z0-9-]*$$'; then echo "OK"; else echo ""; fi)
YAMLLINT=yamllint
SHELLCHECK=shellcheck
VAGRANT_SSH_KEY_NAME=${DEPLOY_ENV}-vagrant-bootstrap-concourse

check-env-vars:
	$(if ${DEPLOY_ENV},,$(error Must pass DEPLOY_ENV=<name>))
	$(if ${DEPLOY_ENV_VALID_LENGTH},,$(error Sorry, DEPLOY_ENV ($(DEPLOY_ENV)) has a max length of $(DEPLOY_ENV_MAX_LENGTH), otherwise derived names will be too long))
	$(if ${DEPLOY_ENV_VALID_CHARS},,$(error Sorry, DEPLOY_ENV ($(DEPLOY_ENV)) must use only alphanumeric chars and hyphens, otherwise derived names will be malformatted))

.PHONY: test
test: spec lint_yaml lint_terraform lint_shellcheck lint_concourse lint_ruby ## Run linting tests

.PHONY: spec
spec:
	cd concourse/scripts &&\
		go test
	cd manifests/shared &&\
		bundle exec rspec
	cd manifests/bosh-manifest &&\
		bundle exec rspec
	cd manifests/runtime-config &&\
		bundle exec rspec
	cd manifests/concourse-manifest &&\
		bundle exec rspec

lint_yaml:
	find . -name '*.yml' -not -path '*/vendor/*' | xargs $(YAMLLINT) -c yamllint.yml

GPG = $(shell command -v gpg2 || command -v gpg)

.PHONY: list_merge_keys
list_merge_keys: ## List all GPG keys allowed to sign merge commits.
	$(if $(GPG),,$(error "gpg2 or gpg not found in PATH"))
	@for key in $$(cat .gpg-id); do \
		printf "$${key}: "; \
		if [ "$$($(GPG) --version | awk 'NR==1 { split($$3,version,"."); print version[1]}')" = "2" ]; then \
			$(GPG) --list-keys --with-colons $$key 2> /dev/null | awk -F: '/^uid/ {found = 1; print $$10; exit} END {if (found != 1) {print "*** not found in local keychain ***"}}'; \
		else \
			$(GPG) --list-keys --with-colons $$key 2> /dev/null | awk -F: '/^pub/ {found = 1; print $$10} END {if (found != 1) {print "*** not found in local keychain ***"}}'; \
		fi;\
	done

lint_terraform:
	$(eval export TF_VAR_system_dns_zone_name=service.com)
	$(eval export TF_VAR_apps_dns_zone_name=apps.com)
	find terraform -mindepth 1 -maxdepth 1 -type d -print0 | xargs -0 -n 1 -t terraform graph > /dev/null
	@if [ "$$(terraform fmt -write=false terraform)" != "" ] ; then \
		echo "Use 'terraform fmt' to fix HCL formatting:"; \
		terraform fmt -write=false -diff=true terraform ; \
		exit 1; \
	fi

lint_shellcheck:
	find . -name '*.sh' -not -path '*/vendor/*' | xargs $(SHELLCHECK)

lint_concourse:
	cd .. && SHELLCHECK_OPTS="-e SC1091" python paas-bootstrap/concourse/scripts/pipecleaner.py --fatal-warnings paas-bootstrap/concourse/pipelines/*.yml

lint_ruby:
	bundle exec govuk-lint-ruby

.PHONY: globals
PASSWORD_STORE_DIR?=${HOME}/.paas-pass
globals:
	$(eval export AWS_DEFAULT_REGION=eu-west-1)
	$(eval export PASSWORD_STORE_DIR=${PASSWORD_STORE_DIR})
	$(eval export DATADOG_PASSWORD_STORE_DIR?=${HOME}/.paas-pass)
	$(eval export GITHUB_PASSWORD_STORE_DIR?=${HOME}/.paas-pass)
	@true

## Environments

.PHONY: dev
dev: globals check-env-vars ## Set Environment to DEV
	$(eval export SYSTEM_DNS_ZONE_NAME=${DEPLOY_ENV}.dev.cloudpipeline.digital)
	$(eval export AWS_ACCOUNT=dev)
	$(eval export ENABLE_DESTROY=true)
	$(eval export ENABLE_DATADOG ?= false)
	$(eval export ENABLE_GITHUB ?= false)
	$(eval export CONCOURSE_AUTH_DURATION=48h)
	$(eval export SKIP_COMMIT_VERIFICATION=true)

.PHONY: ci
ci: globals check-env-vars ## Set Environment to CI
	$(eval export SYSTEM_DNS_ZONE_NAME=${DEPLOY_ENV}.ci.cloudpipeline.digital)
	$(eval export AWS_ACCOUNT=ci)
	$(eval export ENABLE_DATADOG=true)
	$(eval export ENABLE_GITHUB=true)

.PHONY: staging
staging: globals check-env-vars ## Set Environment to Staging
	$(eval export SYSTEM_DNS_ZONE_NAME=staging.cloudpipeline.digital)
	$(eval export AWS_ACCOUNT=staging)
	$(eval export ENABLE_DATADOG=true)
	$(eval export ENABLE_GITHUB=true)

.PHONY: prod
prod: globals check-env-vars ## Set Environment to Production
	$(eval export SYSTEM_DNS_ZONE_NAME=cloud.service.gov.uk)
	$(eval export AWS_ACCOUNT=prod)
	$(eval export ENABLE_DATADOG=true)
	$(eval export ENABLE_GITHUB=true)

## Concourse profiles

.PHONY: build-concourse
build-concourse: ## Setup profiles for deploying a build concourse
	$(eval export BOSH_INSTANCE_PROFILE=bosh-director-build)
	$(eval export CONCOURSE_TYPE=build-concourse)
	$(eval export CONCOURSE_HOSTNAME=concourse)
	$(eval export CONCOURSE_INSTANCE_TYPE=m4.large)
	$(eval export CONCOURSE_INSTANCE_PROFILE=concourse-build)
	$(eval export ENABLE_COLLECTD_ADDON=false)
	$(eval export ENABLE_SYSLOG_ADDON=false)
	@true

.PHONY: deployer-concourse
deployer-concourse: ## Setup profiles for deploying a paas-cf deployer concourse
	$(eval export BOSH_INSTANCE_PROFILE=bosh-director-cf)
	$(eval export CONCOURSE_TYPE=deployer-concourse)
	$(eval export CONCOURSE_HOSTNAME=deployer)
	$(eval export CONCOURSE_INSTANCE_TYPE=m4.xlarge)
	$(eval export CONCOURSE_INSTANCE_PROFILE=deployer-concourse)
	$(eval export ENABLE_COLLECTD_ADDON=true)
	$(eval export ENABLE_SYSLOG_ADDON=true)
	@true

## Actions

.PHONY: pipelines
pipelines:
	$(eval export TARGET_CONCOURSE=${CONCOURSE_TYPE})
	$(if ${TARGET_CONCOURSE},,$(error Must set CONCOURSE_TYPE=deployer-concourse|build-concourse. This can be done with the relevant make target.))
	$$("./concourse/scripts/environment.sh") && \
                ./concourse/scripts/pipelines.sh

.PHONY: bootstrap
bootstrap: ## Start bootstrap
	$(if ${BOSH_INSTANCE_PROFILE},,$(error Must pass BOSH_INSTANCE_PROFILE=<name>))
	$(if ${CONCOURSE_HOSTNAME},,$(error Must pass CONCOURSE_HOSTNAME=<name>))
	$(if ${CONCOURSE_INSTANCE_TYPE},,$(error Must pass CONCOURSE_INSTANCE_TYPE=<name>))
	$(if ${CONCOURSE_INSTANCE_PROFILE},,$(error Must pass CONCOURSE_INSTANCE_PROFILE=<name>))
	$(eval export VAGRANT_SSH_KEY_NAME=$(VAGRANT_SSH_KEY_NAME))
	$(eval export TARGET_CONCOURSE=bootstrap)
	vagrant/deploy.sh

.PHONY: bootstrap-destroy
bootstrap-destroy: ## Destroy bootstrap
	$(eval export VAGRANT_SSH_KEY_NAME=$(VAGRANT_SSH_KEY_NAME))
	$(eval export TARGET_CONCOURSE=bootstrap)
	./vagrant/destroy.sh

.PHONY: showenv
showenv: ## Display environment information
	$(eval export TARGET_CONCOURSE=bootstrap)
	@concourse/scripts/environment.sh
	@echo export CONCOURSE_IP=$$(aws ec2 describe-instances \
		--filters 'Name=tag:Name,Values=concourse/*' "Name=key-name,Values=${DEPLOY_ENV}_concourse_key_pair" \
		--query 'Reservations[].Instances[].PublicIpAddress' --output text)
	@echo export BOOTSTRAP_CONCOURSE_IP=$$(aws ec2 describe-instances \
		--filters 'Name=tag:Name,Values=*concourse' "Name=key-name,Values=${VAGRANT_SSH_KEY_NAME}" \
                --query 'Reservations[].Instances[].PublicIpAddress' --output text)

.PHONY: bosh-cli
bosh-cli:
	@./scripts/bosh-cli.sh

.PHONY: ssh_bosh
ssh_bosh: check-env-vars ## SSH to the bosh server
	@./scripts/ssh_bosh.sh

ssh_concourse: check-env-vars ## SSH to the concourse server. Set SSH_CMD to pass a command to execute.
	@./concourse/scripts/ssh.sh ssh ${SSH_CMD}

ssh_bootstrap_concourse: check-env-vars ## SSH to the bootstrap concourse server
	@cd vagrant ; vagrant ssh -- -i ../${VAGRANT_SSH_KEY_NAME}

tunnel: check-env-vars ## SSH tunnel to internal IPs
	$(if ${TUNNEL},,$(error Must pass TUNNEL=SRC_PORT:HOST:DST_PORT))
	@./concourse/scripts/ssh.sh tunnel ${TUNNEL}

stop-tunnel: check-env-vars ## Stop SSH tunnel
	@./concourse/scripts/ssh.sh tunnel stop

.PHONY: upload-datadog-secrets
upload-datadog-secrets: check-env-vars ## Decrypt and upload Datadog credentials to S3
	$(if ${AWS_ACCOUNT},,$(error Must set environment to ci/staging/prod))
	$(if ${DATADOG_PASSWORD_STORE_DIR},,$(error Must pass DATADOG_PASSWORD_STORE_DIR=<path_to_password_store>))
	$(if $(wildcard ${DATADOG_PASSWORD_STORE_DIR}),,$(error Password store ${DATADOG_PASSWORD_STORE_DIR} does not exist))
	@scripts/manage-datadog-secrets.sh upload

.PHONY: upload-github-oauth
upload-github-oauth: check-env-vars ## Decrypt and upload github OAuth credentials to S3
	$(if ${AWS_ACCOUNT},,$(error Must set environment to dev/ci/staging/prod))
	$(if ${GITHUB_PASSWORD_STORE_DIR},,$(error Must pass GITHUB_PASSWORD_STORE_DIR=<path_to_password_store>))
	$(if $(wildcard ${GITHUB_PASSWORD_STORE_DIR}),,$(error Password store ${GITHUB_PASSWORD_STORE_DIR} does not exist))
	@scripts/manage-github-secrets.sh upload

merge_pr: ## Merge a PR. Must specify number in a PR=<number> form.
	$(if ${PR},,$(error Must pass PR=<number>))
	bundle exec github_merge_sign --pr ${PR}
