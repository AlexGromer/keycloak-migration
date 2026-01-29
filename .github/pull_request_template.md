# Pull Request

## Description
Brief description of what this PR does.

Fixes #(issue number)

## Type of Change
- [ ] Bug fix (non-breaking change which fixes an issue)
- [ ] New feature (non-breaking change which adds functionality)
- [ ] Breaking change (fix or feature that would cause existing functionality to not work as expected)
- [ ] Documentation update
- [ ] Refactoring (no functional changes)
- [ ] Test coverage improvement

## Changes Made
List the key changes in this PR:
-
-
-

## Testing
Describe how you tested this change:

**Test commands:**
```bash
# Example test commands
./tests/run_all_tests.sh
./scripts/migrate_keycloak_v3.sh plan --profile test-profile
```

**Test results:**
- [ ] All existing tests pass (137/137)
- [ ] New tests added for new functionality
- [ ] Manual testing completed

**Test environment:**
- OS: [e.g., Ubuntu 22.04]
- Bash: [e.g., 5.1.16]
- Deployment: [e.g., Docker Compose]
- Database: [e.g., PostgreSQL 14]

## Screenshots (if applicable)
Add screenshots for UI changes or workflow demonstrations.

## Checklist
**Code Quality:**
- [ ] Code follows the style guidelines (see CONTRIBUTING.md)
- [ ] Self-review of code completed
- [ ] Code is commented where necessary
- [ ] No debug/console statements left in code
- [ ] Variables use proper naming conventions

**Testing:**
- [ ] All tests pass (`./tests/run_all_tests.sh`)
- [ ] New tests added for new functionality
- [ ] Test coverage ≥ 80% for new code
- [ ] Edge cases considered and tested

**Documentation:**
- [ ] README.md updated (if user-facing changes)
- [ ] CHANGELOG.md updated
- [ ] Code comments added for complex logic
- [ ] Examples updated (if applicable)

**Security:**
- [ ] No secrets/credentials in code
- [ ] Input validation added where needed
- [ ] No SQL injection vulnerabilities
- [ ] No command injection vulnerabilities
- [ ] Secrets scan passed (Gitleaks)

**Git:**
- [ ] Commit messages follow conventional commits format
- [ ] Branch is up-to-date with main
- [ ] No merge conflicts
- [ ] Commits are atomic (one logical change per commit)

**CI/CD:**
- [ ] All CI checks pass (6/6)
- [ ] ShellCheck warnings addressed
- [ ] Profile validation passes

## Breaking Changes
If this PR introduces breaking changes, describe them and provide migration instructions:

**Migration Guide:**
```bash
# Example migration steps
```

## Additional Notes
Any additional information, context, or notes for reviewers.

## Reviewer Checklist (for maintainers)
- [ ] Code review completed
- [ ] Tests reviewed and adequate
- [ ] Documentation reviewed
- [ ] Security considerations reviewed
- [ ] Performance impact considered
- [ ] Backward compatibility verified
