# Branch Protection Setup

## Automatic Setup (via GitHub CLI)

```bash
# Install gh CLI (if not installed)
# Debian/Ubuntu: sudo apt-get install gh
# Or: https://cli.github.com/

# Authenticate
gh auth login

# Configure branch protection for main
gh api repos/AlexGromer/keycloak-migration/branches/main/protection \
  --method PUT \
  --field required_status_checks[strict]=true \
  --field required_status_checks[contexts][]=syntax-check \
  --field required_status_checks[contexts][]=shellcheck \
  --field required_status_checks[contexts][]=unit-tests \
  --field required_status_checks[contexts][]=secrets-scan \
  --field required_status_checks[contexts][]=security-audit \
  --field required_status_checks[contexts][]=profile-validation \
  --field enforce_admins=false \
  --field required_pull_request_reviews[dismiss_stale_reviews]=true \
  --field required_pull_request_reviews[require_code_owner_reviews]=false \
  --field required_pull_request_reviews[required_approving_review_count]=0 \
  --field required_pull_request_reviews[require_last_push_approval]=false \
  --field restrictions=null \
  --field required_linear_history=false \
  --field allow_force_pushes=false \
  --field allow_deletions=false
```

## Manual Setup (via GitHub UI)

### Step 1: Navigate to Settings
1. Go to https://github.com/AlexGromer/keycloak-migration/settings/branches
2. Click **"Add rule"** or edit existing rule for `main`

### Step 2: Configure Protection Rules

**Branch name pattern:** `main`

**Protect matching branches:**
- ✅ **Require a pull request before merging**
  - ⚠️ Require approvals: **0** (solo developer)
  - ✅ Dismiss stale pull request approvals when new commits are pushed

- ✅ **Require status checks to pass before merging**
  - ✅ Require branches to be up to date before merging
  - **Required checks:**
    - `syntax-check`
    - `shellcheck`
    - `unit-tests`
    - `secrets-scan`
    - `security-audit`
    - `profile-validation`

- ✅ **Require conversation resolution before merging**

- ❌ **Require signed commits** (optional)

- ❌ **Require linear history** (optional)

- ✅ **Do not allow bypassing the above settings**

- ❌ **Allow force pushes** (NEVER for main)

- ❌ **Allow deletions** (NEVER for main)

### Step 3: Save Changes

Click **"Create"** or **"Save changes"**

---

## Verification

After setup, verify protection is active:

```bash
# Check protection status
gh api repos/AlexGromer/keycloak-migration/branches/main/protection | jq

# Expected output should show:
# - required_status_checks: 6 checks
# - enforce_admins: false
# - required_pull_request_reviews: enabled
```

---

## Workflow

### For Solo Development

1. **Create feature branch:**
   ```bash
   git checkout -b feature/my-feature
   ```

2. **Make changes & commit:**
   ```bash
   git add .
   git commit -m "feat: add new feature"
   ```

3. **Push to GitHub:**
   ```bash
   git push -u origin feature/my-feature
   ```

4. **Create PR:**
   ```bash
   gh pr create --title "Add new feature" --body "Description..."
   ```

5. **Wait for CI checks** (automatic)

6. **Merge PR:**
   ```bash
   # Option 1: Via CLI (auto-merge when checks pass)
   gh pr merge --auto --squash

   # Option 2: Via UI
   # Navigate to PR and click "Merge" when checks are green
   ```

### For Team Development

Same as above, but:
- **Require approvals:** Set to 1+ in branch protection
- **Code owners:** Add `CODEOWNERS` file
- **Review assignments:** Configure auto-assignment

---

## Auto-Merge Configuration

If you want PRs to auto-merge when CI passes:

### Option 1: GitHub UI
1. Go to Settings → General
2. Scroll to **"Pull Requests"**
3. ✅ Enable **"Allow auto-merge"**

### Option 2: GitHub CLI
```bash
gh repo edit AlexGromer/keycloak-migration --enable-auto-merge
```

### Usage
When creating PR:
```bash
gh pr create --title "..." --body "..." --auto-merge
```

---

## Troubleshooting

### Issue: "Required status checks not found"

**Cause:** CI workflow hasn't run yet.

**Solution:** Push a commit to trigger the workflow, then add checks to protection rules.

### Issue: "Cannot merge — branch protection rules not met"

**Cause:** One or more CI checks failed.

**Solution:**
1. Check workflow run: `gh run list`
2. View logs: `gh run view <run-id>`
3. Fix issues and push new commit

### Issue: "Cannot enable auto-merge"

**Cause:** Repository settings don't allow it.

**Solution:**
```bash
gh repo edit AlexGromer/keycloak-migration --enable-auto-merge
```

---

## References

- [GitHub Branch Protection Docs](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches)
- [GitHub CLI Protection API](https://cli.github.com/manual/gh_api)
- [Auto-Merge Documentation](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/incorporating-changes-from-a-pull-request/automatically-merging-a-pull-request)
