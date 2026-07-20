# Contributing to Keycloak Migration Tool

Thank you for your interest in contributing! This document outlines the development workflow and standards.

---

## 🚀 Quick Start

1. **Fork the repository**
   ```bash
   gh repo fork AlexGromer/keycloak-migration --clone
   cd keycloak-migration
   ```

2. **Create a feature branch**
   ```bash
   git checkout -b feature/your-feature-name
   ```

3. **Make changes**
   - Write code following the standards below
   - Add tests for new functionality
   - Update documentation if needed

4. **Test locally**
   ```bash
   # Run all tests
   ./tests/run_all_tests.sh

   # Syntax check
   find scripts/ tests/ -name "*.sh" -exec bash -n {} \;

   # ShellCheck (optional but recommended)
   shellcheck scripts/**/*.sh tests/*.sh
   ```

5. **Commit & push**
   ```bash
   git add .
   git commit -m "feat: add new feature"
   git push -u origin feature/your-feature-name
   ```

6. **Create Pull Request**
   ```bash
   gh pr create --title "Add new feature" --body "Description of changes"
   ```

7. **Wait for CI checks** (automatic)
   - ✅ Syntax check
   - ✅ ShellCheck linting
   - ✅ Unit tests (137 tests)
   - ✅ Secrets scan
   - ✅ Security audit
   - ✅ Profile validation

8. **Address review feedback** (if any)

9. **Merge** (when CI passes and approved)

---

## 📋 Development Standards

### Code Style

**Bash Scripts:**
- Use `set -euo pipefail` at the top of every script
- 4-space indentation (no tabs)
- Function names: `lowercase_with_underscores()`
- Variables: `UPPERCASE_FOR_GLOBALS`, `lowercase_for_locals`
- Always quote variables: `"$var"` not `$var`
- Use `[[ ]]` for conditionals, not `[ ]`

**Good Example:**
```bash
#!/usr/bin/env bash
set -euo pipefail

# Global configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

my_function() {
    local input="$1"
    local result=""

    if [[ "$input" == "test" ]]; then
        result="success"
    fi

    echo "$result"
}

main() {
    local output
    output=$(my_function "test")
    echo "Result: $output"
}

main "$@"
```

### Arithmetic Operations

**CRITICAL:** Under `set -e`, avoid `((var++))` when `var=0`:

```bash
# ❌ BAD (will exit when counter=0)
((counter++))

# ✅ GOOD
counter=$((counter + 1))
```

### Testing

**All new features MUST include tests.**

1. **Create test file:**
   ```bash
   cp tests/test_framework.sh tests/test_new_feature.sh
   ```

2. **Write test cases:**
   ```bash
   describe "New Feature Tests"

   test_feature_basic() {
       local result
       result=$(my_new_function "input")
       assert_equals "expected" "$result" "Basic test"
   }

   test_feature_edge_case() {
       local result
       result=$(my_new_function "")
       assert_empty "$result" "Empty input handling"
   }
   ```

3. **Add to test runner:**
   ```bash
   # In tests/run_all_tests.sh, add:
   run_suite "test_new_feature"
   ```

4. **Verify:**
   ```bash
   ./tests/run_all_tests.sh
   # Expected: ALL TESTS PASSED
   ```

### Documentation

**Update relevant docs when changing:**
- **README.md** — User-facing features
- **ARCHITECTURE.md** — architectural decisions (add an ADR)
- **CONTRIBUTING.md** — Development workflow changes
- **Inline comments** — Complex logic

### Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <description>

[optional body]

[optional footer]
```

**Types:**
- `feat:` — New feature
- `fix:` — Bug fix
- `docs:` — Documentation only
- `test:` — Tests only
- `refactor:` — Code refactoring
- `perf:` — Performance improvement
- `chore:` — Maintenance (deps, CI, etc.)

**Examples:**
```bash
feat(database): add Oracle 23c support
fix(migration): resolve checkpoint resume bug
docs(readme): update installation instructions
test(adapter): add MariaDB connection tests
refactor(profile): extract YAML parsing to function
```

---

## 🔒 Security

### Pre-Commit Checks (Automatic)

1. **Secrets Detection**
   - Gitleaks scans every commit
   - Never commit: `.env`, `*.key`, `credentials.json`, etc.

2. **.gitignore Verification**
   - Ensure `.claude/` is always excluded
   - See `.gitignore` for full list

3. **Profile Validation**
   - No hardcoded passwords in YAML profiles
   - Use `credentials_source: env` or `vault`

### Reporting Security Issues

**DO NOT open public issues for security vulnerabilities.**

Instead:
- Email: [security contact]
- Or create private security advisory on GitHub

---

## 🧪 CI Pipeline

Every PR triggers these checks:

```
┌─────────────────────────────────────────────────────────┐
│  1. Syntax Check    — bash -n for all scripts          │
│  2. ShellCheck      — Linting with shellcheck           │
│  3. Unit Tests      — 137 tests, 100% pass required     │
│  4. Secrets Scan    — Gitleaks for leaked credentials   │
│  5. Security Audit  — .gitignore + hardcoded secrets    │
│  6. Profile Validation — YAML lint + load test          │
└─────────────────────────────────────────────────────────┘
```

**All checks MUST pass before merge.**

View logs:
```bash
gh run list
gh run view <run-id>
```

---

## 🌿 Branch Protection

The `main` branch is protected:

- ✅ Requires PR (no direct push)
- ✅ Requires all CI checks to pass
- ✅ Requires up-to-date branch
- ❌ No force push
- ❌ No deletion

See [.github/BRANCH_PROTECTION.md](.github/BRANCH_PROTECTION.md) for setup details.

---

## 📂 Project Structure

```
keycloak-migration/
├── scripts/
│   ├── migrate_keycloak_v3.sh      # Main script
│   ├── config_wizard.sh            # Interactive config
│   └── lib/                        # Adapter modules
│       ├── database_adapter.sh     # DB abstraction
│       ├── deployment_adapter.sh   # Deploy abstraction
│       ├── profile_manager.sh      # YAML handling
│       ├── distribution_handler.sh # Artifact management
│       ├── keycloak_discovery.sh   # Auto-discovery
│       └── audit_logger.sh         # Audit logging
│
├── profiles/                       # YAML configs
├── tests/                          # Unit tests (137 tests)
├── .github/
│   ├── workflows/ci.yml            # CI pipeline
│   └── BRANCH_PROTECTION.md        # Setup guide
│
├── README.md                       # User documentation
├── CONTRIBUTING.md                 # This file
└── ARCHITECTURE.md                 # ADRs + change log
```

---

## 🐛 Debugging

### Test Failures

```bash
# Run specific test file
./tests/test_database_adapter.sh

# Enable debug mode
VERBOSE=true ./tests/run_all_tests.sh

# Check specific assertion
grep "assert_equals" tests/test_database_adapter.sh
```

### CI Failures

1. **View workflow run:**
   ```bash
   gh run list --workflow=ci.yml
   gh run view <run-id>
   ```

2. **Download logs:**
   ```bash
   gh run download <run-id>
   ```

3. **Re-run failed jobs:**
   ```bash
   gh run rerun <run-id> --failed
   ```

### ShellCheck Warnings

```bash
# Suppress specific warnings (use sparingly)
# shellcheck disable=SC2086
command_with_intentional_word_splitting $var

# Ignore file-wide
# shellcheck disable=SC1091
source ./lib/not_found_by_shellcheck.sh
```

---

## 🎯 Common Tasks

### Add New Database Support

1. **Update `database_adapter.sh`:**
   ```bash
   DB_ADAPTERS["newdb"]="New Database"
   DB_DEFAULT_PORTS["newdb"]=5000
   JDBC_PREFIXES["newdb"]="jdbc:newdb:"

   db_backup_newdb() { ... }
   db_restore_newdb() { ... }
   ```

2. **Add tests:**
   ```bash
   # In tests/test_database_adapter.sh
   test_newdb_validation() { ... }
   test_newdb_jdbc_url() { ... }
   ```

3. **Update docs:**
   - README.md — Add to supported databases
   - ARCHITECTURE.md — add an ADR for the decision

### Add New Deployment Mode

Similar to database, but in `deployment_adapter.sh`.

### Add New Migration Strategy

Implement in `migrate_keycloak_v3.sh`:
```bash
migrate_new_strategy() {
    local version="$1"
    # Implementation...
}
```

---

## 📞 Getting Help

- **Issues:** https://github.com/AlexGromer/keycloak-migration/issues
- **Discussions:** https://github.com/AlexGromer/keycloak-migration/discussions
- **Documentation:** [README.md](README.md), [ARCHITECTURE.md](ARCHITECTURE.md), [QUICKSTART.md](QUICKSTART.md)

---

## 🏆 Recognition

Contributors will be:
- Listed in release notes
- Mentioned in CHANGELOG.md
- Added to contributors section (if desired)

Thank you for contributing! 🚀
