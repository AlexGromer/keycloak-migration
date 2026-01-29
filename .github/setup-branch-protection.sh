#!/usr/bin/env bash
#
# Setup Branch Protection for keycloak-migration
# Requires: gh CLI (https://cli.github.com/)
#

set -euo pipefail

REPO="AlexGromer/keycloak-migration"
BRANCH="main"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🛡️  Setting up branch protection for $REPO"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check gh CLI
if ! command -v gh &>/dev/null; then
    echo "❌ gh CLI not found. Install from: https://cli.github.com/"
    exit 1
fi

# Check authentication
if ! gh auth status &>/dev/null; then
    echo "❌ Not authenticated. Run: gh auth login"
    exit 1
fi

echo "✓ gh CLI authenticated"
echo ""

# Enable auto-merge
echo "⚙️  Enabling auto-merge..."
gh repo edit "$REPO" --enable-auto-merge || {
    echo "⚠️  Auto-merge setting may require admin permissions"
}

# Configure branch protection
echo "⚙️  Configuring branch protection for '$BRANCH'..."

gh api "repos/$REPO/branches/$BRANCH/protection" \
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
    --field allow_deletions=false \
    > /dev/null

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Branch protection configured successfully!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Protection rules for '$BRANCH':"
echo "  ✓ Requires PR before merge"
echo "  ✓ Requires 6 CI checks to pass:"
echo "    - syntax-check"
echo "    - shellcheck"
echo "    - unit-tests"
echo "    - secrets-scan"
echo "    - security-audit"
echo "    - profile-validation"
echo "  ✓ Requires branch to be up-to-date"
echo "  ✓ Dismisses stale reviews"
echo "  ✓ Blocks force push"
echo "  ✓ Blocks deletion"
echo ""
echo "Verify at: https://github.com/$REPO/settings/branches"
echo ""

# Verify setup
echo "⚙️  Verifying configuration..."
if gh api "repos/$REPO/branches/$BRANCH/protection" &>/dev/null; then
    echo "✅ Verification passed!"
else
    echo "❌ Verification failed. Check manually at GitHub settings."
    exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎉 Setup complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
