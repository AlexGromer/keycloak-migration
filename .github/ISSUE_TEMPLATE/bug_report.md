---
name: Bug Report
about: Create a report to help us improve
title: '[BUG] '
labels: bug
assignees: ''

---

## Bug Description
A clear and concise description of the bug.

## To Reproduce
Steps to reproduce the behavior:
1. Run command: `./scripts/migrate_keycloak_v3.sh migrate --profile ...`
2. At step: '...'
3. See error: '...'

## Expected Behavior
What you expected to happen.

## Actual Behavior
What actually happened.

## Environment
**Profile Configuration:**
```yaml
# Paste relevant parts of your YAML profile
```

**System Information:**
- OS: [e.g., Ubuntu 22.04, Debian 12, RHEL 8]
- Bash version: [e.g., 5.1.16]
- Keycloak versions: [e.g., 16.1.1 → 26.0.7]
- Database: [e.g., PostgreSQL 14.5]
- Deployment: [e.g., Kubernetes 1.28, Docker Compose]

**Deployment Mode:**
- [ ] Standalone
- [ ] Docker
- [ ] Docker Compose
- [ ] Kubernetes
- [ ] Deckhouse

**Migration Strategy:**
- [ ] In-place
- [ ] Rolling update
- [ ] Blue-green

## Logs
<details>
<summary>Error Logs</summary>

```
Paste relevant log output here
```
</details>

<details>
<summary>Audit Log (if applicable)</summary>

```json
Paste relevant audit log entries
```
</details>

## Screenshots
If applicable, add screenshots to help explain the problem.

## Additional Context
Add any other context about the problem here.

## Checklist
- [ ] I have checked existing issues for duplicates
- [ ] I have included all requested information
- [ ] I have sanitized logs (removed secrets/credentials)
- [ ] I am using the latest version (3.0.0)
