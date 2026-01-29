# Ansible Integration

Automate Keycloak migrations across multiple servers using Ansible.

## 📁 Structure

```
ansible/
├── keycloak-migration.yml           # Main playbook
├── inventory/
│   └── hosts.yml                    # Inventory example
└── roles/
    └── keycloak_migration/
        └── tasks/
            └── main.yml             # Migration tasks
```

## 🚀 Quick Start

### 1. Install Ansible

```bash
# Debian/Ubuntu
sudo apt-get install ansible

# RHEL/CentOS
sudo yum install ansible

# Or via pip
pip install ansible
```

### 2. Configure Inventory

Edit `inventory/hosts.yml`:

```yaml
keycloak_servers:
  hosts:
    keycloak-prod:
      ansible_host: 192.168.1.10
      ansible_user: root
      keycloak_migration_profile: kubernetes-cluster-production
      keycloak_db_password: "{{ vault_db_password }}"
```

### 3. Store Secrets in Vault

```bash
# Create vault file
ansible-vault create inventory/vault.yml

# Add secrets:
vault_keycloak_prod_db_password: "your_password_here"
vault_keycloak_staging_db_password: "staging_password"
```

### 4. Run Playbook

```bash
# Dry-run first
ansible-playbook keycloak-migration.yml \
  -i inventory/hosts.yml \
  --ask-vault-pass \
  --check

# Actual migration
ansible-playbook keycloak-migration.yml \
  -i inventory/hosts.yml \
  --ask-vault-pass

# Specific host
ansible-playbook keycloak-migration.yml \
  -i inventory/hosts.yml \
  --limit keycloak-prod-1 \
  --ask-vault-pass
```

## 📋 Playbook Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `migration_tool_repo` | GitHub URL | Migration tool repository |
| `migration_tool_version` | `v3.0.0` | Version tag to use |
| `migration_tool_path` | `/opt/keycloak-migration` | Installation path |
| `migration_profile` | `standalone-postgresql` | Profile name |
| `skip_preflight` | `false` | Skip pre-flight checks |
| `airgap_mode` | `false` | Enable airgap mode |
| `auto_rollback` | `true` | Auto-rollback on failure |
| `dry_run` | `false` | Dry-run mode |

## 🔐 Security Best Practices

### Use Ansible Vault

```bash
# Create vault
ansible-vault create secrets.yml

# Edit vault
ansible-vault edit secrets.yml

# View vault
ansible-vault view secrets.yml
```

### Encrypt Sensitive Variables

```yaml
# In vault.yml
vault_db_password: "supersecret"

# In hosts.yml
keycloak_db_password: "{{ vault_db_password }}"
```

### SSH Key Authentication

```bash
# Generate SSH key
ssh-keygen -t ed25519 -C "ansible@keycloak"

# Copy to servers
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@192.168.1.10
```

## 📊 Advanced Usage

### Multi-Environment Deployments

```bash
# Production
ansible-playbook keycloak-migration.yml \
  -i inventory/production.yml \
  --ask-vault-pass

# Staging
ansible-playbook keycloak-migration.yml \
  -i inventory/staging.yml \
  --ask-vault-pass
```

### Rolling Updates

```yaml
# In playbook
- hosts: keycloak_servers
  serial: 1  # One host at a time
  max_fail_percentage: 0  # Abort on first failure
```

### Custom Profiles via Variables

```yaml
# In inventory
keycloak-server:
  vars:
    migration_profile_config:
      database:
        type: postgresql
        host: "{{ db_host }}"
        port: 5432
      keycloak:
        deployment_mode: kubernetes
```

## 🛠️ Troubleshooting

### Check Ansible Connection

```bash
ansible keycloak_servers -i inventory/hosts.yml -m ping --ask-vault-pass
```

### Verbose Output

```bash
ansible-playbook keycloak-migration.yml -vvv
```

### Dry-Run Mode

```bash
ansible-playbook keycloak-migration.yml --check --diff
```

### View Audit Logs

```bash
# Logs are fetched to local ./logs/ directory
cat logs/keycloak-prod-1_migration_audit.jsonl | jq
```

## 📚 Examples

### Example 1: Single Server Migration

```bash
ansible-playbook keycloak-migration.yml \
  -i inventory/hosts.yml \
  --limit keycloak-prod-1 \
  --ask-vault-pass
```

### Example 2: Staging First, Then Production

```bash
# Step 1: Test on staging
ansible-playbook keycloak-migration.yml \
  -i inventory/hosts.yml \
  --limit keycloak-staging \
  --ask-vault-pass

# Step 2: If successful, run on production
ansible-playbook keycloak-migration.yml \
  -i inventory/hosts.yml \
  --limit keycloak-prod-* \
  --ask-vault-pass
```

### Example 3: Airgap Migration

```bash
# First, download artifacts to Ansible controller
./scripts/migrate_keycloak_v3.sh download --profile my-profile

# Then, copy to target servers via Ansible
ansible-playbook keycloak-migration.yml \
  -i inventory/hosts.yml \
  -e "airgap_mode=true" \
  --ask-vault-pass
```

## 🔗 Integration with CI/CD

### GitLab CI Example

```yaml
stages:
  - migrate

migrate-keycloak:
  stage: migrate
  image: ansible/ansible:latest
  script:
    - echo "$ANSIBLE_VAULT_PASSWORD" > .vault_pass
    - ansible-playbook keycloak-migration.yml
        -i inventory/production.yml
        --vault-password-file .vault_pass
  only:
    - tags
  when: manual
```

### GitHub Actions Example

```yaml
name: Keycloak Migration

on:
  workflow_dispatch:
    inputs:
      environment:
        description: 'Environment (staging/production)'
        required: true

jobs:
  migrate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install Ansible
        run: pip install ansible

      - name: Run migration
        env:
          ANSIBLE_VAULT_PASSWORD: ${{ secrets.VAULT_PASSWORD }}
        run: |
          echo "$ANSIBLE_VAULT_PASSWORD" > .vault_pass
          ansible-playbook keycloak-migration.yml \
            -i inventory/${{ github.event.inputs.environment }}.yml \
            --vault-password-file .vault_pass
```

## 📖 References

- [Ansible Documentation](https://docs.ansible.com/)
- [Ansible Vault](https://docs.ansible.com/ansible/latest/user_guide/vault.html)
- [Ansible Best Practices](https://docs.ansible.com/ansible/latest/user_guide/playbooks_best_practices.html)
