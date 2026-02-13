.PHONY: help lint tf-init tf-plan tf-apply tf-destroy tf-output ansible-ping ansible-run ansible-check ansible-cluster ansible-samba bootstrap status pods apps vault-edit vault-view argocd-pw

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ========================
# Linting
# ========================
lint: ## Run all linters (pre-commit)
	pre-commit run --all-files

# ========================
# Terraform
# ========================
tf-init: ## Terraform init
	cd terraform && terraform init

tf-plan: ## Terraform plan
	cd terraform && terraform plan

tf-apply: ## Terraform apply
	cd terraform && terraform apply

tf-destroy: ## Terraform destroy (CAREFUL!)
	cd terraform && terraform destroy

tf-output: ## Show Terraform outputs
	cd terraform && terraform output

# ========================
# Ansible
# ========================
ansible-ping: ## Ping all hosts
	cd ansible && ansible all -m ping

ansible-run: ## Run full site playbook
	cd ansible && ansible-playbook playbooks/site.yml

ansible-check: ## Dry-run full site playbook
	cd ansible && ansible-playbook playbooks/site.yml --check --diff

ansible-cluster: ## Run k3s cluster playbook only
	cd ansible && ansible-playbook playbooks/cluster.yml

ansible-samba: ## Run Samba AD role only
	cd ansible && ansible-playbook playbooks/site.yml --start-at-task="Install Samba AD DC packages"

# ========================
# Secrets
# ========================
vault-edit: ## Edit Ansible Vault secrets
	cd ansible && EDITOR="$${EDITOR:-vi}" ansible-vault edit inventory/group_vars/all/vault.yml

vault-view: ## View Ansible Vault secrets
	cd ansible && ansible-vault view inventory/group_vars/all/vault.yml

# ========================
# Kubernetes Bootstrap
# ========================
bootstrap: ## Bootstrap k8s services (one-time)
	chmod +x scripts/bootstrap-argocd.sh
	./scripts/bootstrap-argocd.sh

# ========================
# Kubernetes Status
# ========================
status: ## Full cluster status
	@echo "=== Nodes ==="
	@kubectl get nodes -o wide
	@echo ""
	@echo "=== Unhealthy Pods ==="
	@kubectl get pods -A --field-selector 'status.phase!=Running,status.phase!=Succeeded' 2>/dev/null || echo "All pods healthy"
	@echo ""
	@echo "=== PostgreSQL ==="
	@kubectl get cluster -n infrastructure 2>/dev/null || echo "No PostgreSQL clusters"
	@echo ""
	@echo "=== Resource Usage ==="
	@kubectl top nodes 2>/dev/null || echo "metrics-server not installed"

pods: ## List all pods
	kubectl get pods -A

apps: ## ArgoCD application status
	kubectl get applications -n argocd

argocd-pw: ## Show ArgoCD admin password
	@kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo
