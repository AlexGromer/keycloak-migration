# Security Policy

## Supported Versions

We release patches for security vulnerabilities in the following versions:

| Version | Supported          |
| ------- | ------------------ |
| 3.0.x   | :white_check_mark: |
| < 3.0   | :x:                |

## Reporting a Vulnerability

**Please DO NOT report security vulnerabilities through public GitHub issues.**

Instead, please report them via one of the following methods:

### 1. GitHub Security Advisories (Preferred)

1. Go to https://github.com/AlexGromer/keycloak-migration/security/advisories
2. Click "New draft security advisory"
3. Fill in the details
4. Submit privately

### 2. Email

Send an email to: **alexei.pape@yandex.ru**

**Subject:** `[SECURITY] Keycloak Migration - [Brief Description]`

**Include:**
- Type of vulnerability
- Full path to source file(s) related to the vulnerability
- Location of the affected code (tag/branch/commit)
- Step-by-step instructions to reproduce the issue
- Proof-of-concept or exploit code (if possible)
- Impact of the issue (what an attacker can achieve)

### Response Timeline

- **24 hours:** Initial acknowledgment
- **7 days:** Detailed response with assessment
- **30 days:** Fix release (if confirmed)

## Security Best Practices

### For Users

**1. Environment Variables for Secrets**
```bash
# ✅ GOOD - Use environment variables
export KC_DB_PASSWORD="secret"
export PROFILE_DB_CREDENTIALS_SOURCE="env"

# ❌ BAD - Never hardcode in YAML
database:
  password: "hardcoded_secret"  # DON'T DO THIS
```

**2. Use Vault or Kubernetes Secrets**
```yaml
database:
  credentials_source: vault  # or "secret" for K8s
  vault_path: secret/keycloak/db
```

**3. Run Pre-flight Checks**
```bash
# Pre-flight automatically scans for secrets
./scripts/migrate_keycloak_v3.sh migrate --profile my-profile
# Includes gitleaks/trufflehog scan
```

**4. Airgap Mode for Sensitive Environments**
```bash
# Validate all artifacts before migration
./scripts/migrate_keycloak_v3.sh migrate --profile prod --airgap
```

**5. Enable Audit Logging**
```bash
export AUDIT_ENABLED=true
export AUDIT_LOG_FILE=/var/log/keycloak-migration/audit.jsonl
```

### For Contributors

**1. Never Commit Secrets**
- Review `.gitignore` before committing
- Use pre-commit hooks (gitleaks)
- CI automatically scans for secrets

**2. Validate Input**
```bash
# Validate database type
if ! db_validate_type "$input"; then
    log_error "Invalid database type: $input"
    exit 1
fi
```

**3. Use Parameterized Commands**
```bash
# ✅ GOOD - Parameterized
psql -U "$PROFILE_DB_USER" -d "$PROFILE_DB_NAME" -c "SELECT 1"

# ❌ BAD - SQL injection risk
psql -c "SELECT * FROM users WHERE name = '$user_input'"
```

**4. Sanitize File Paths**
```bash
# Prevent path traversal
backup_file=$(realpath "$1")
if [[ "$backup_file" != "$WORK_DIR"* ]]; then
    log_error "Backup file must be in WORK_DIR"
    exit 1
fi
```

## Security Features

### Built-in Protection

**1. Secrets Detection (CI)**
- Gitleaks scan on every PR
- Blocks merge if secrets found
- Scans: API keys, tokens, credentials, private keys

**2. .gitignore Coverage**
- Automatically excludes: `.env`, `*.key`, `*.pem`, `credentials.json`
- CI verifies .gitignore patterns
- See [.gitignore](.gitignore) for full list

**3. Credential Sources**
```yaml
database:
  credentials_source: env    # Environment variables
  # OR
  credentials_source: file   # .pgpass, .my.cnf
  # OR
  credentials_source: secret # Kubernetes secret
  # OR
  credentials_source: vault  # HashiCorp Vault
```

**4. Audit Logging**
```json
{"ts":"2026-01-29T21:15:00Z","level":"INFO","event":"migration_start","msg":"Migration started","host":"kali","user":"admin","profile":"prod"}
```

**5. Pre-flight Security Checks**
- Secrets scan before migration
- Database connectivity validation
- Java version verification
- Network reachability (for non-airgap)

## Known Security Considerations

### 1. Database Credentials

**Risk:** Database passwords exposed in process list or logs.

**Mitigation:**
- Use `.pgpass`, `.my.cnf`, or Kubernetes secrets
- Never pass passwords via command-line arguments
- Audit logs sanitize sensitive data

### 2. Backup Files

**Risk:** Unencrypted database dumps contain sensitive data.

**Mitigation:**
```bash
# Encrypt backups
pg_dump keycloak | gpg --encrypt --recipient admin@example.com > backup.dump.gpg

# Restore
gpg --decrypt backup.dump.gpg | psql keycloak
```

### 3. Migration State Files

**Risk:** State files may contain sensitive metadata.

**Mitigation:**
- State files excluded from git (`.migration_state` in `.gitignore`)
- Stored in `WORK_DIR` with restricted permissions (600)

### 4. Container Image Secrets

**Risk:** Secrets baked into container images.

**Mitigation:**
- Use Kubernetes secrets or Docker secrets
- Never include credentials in Dockerfile
- Use multi-stage builds for sensitive data

## Disclosure Policy

We follow **coordinated disclosure**:

1. **Day 0:** Vulnerability reported privately
2. **Day 1:** Acknowledgment sent to reporter
3. **Day 7:** Assessment and severity classification
4. **Day 30:** Patch released (if confirmed)
5. **Day 31:** Public disclosure via GitHub Security Advisory

## Security Updates

Subscribe to security advisories:

1. Go to https://github.com/AlexGromer/keycloak-migration
2. Click "Watch" → "Custom" → "Security alerts"

Or watch this repository for releases.

## Hall of Fame

We recognize security researchers who responsibly disclose vulnerabilities:

<!-- To be populated with contributors -->

---

**Last Updated:** 2026-01-29
**Version:** 3.0.0
