# Hints — Challenge 3: The Shadow Pipeline Overlord

**Hint 1 (least revealing):**
The deploy pipeline uses OpenID Connect, not a stored AWS key — so there's no credential to steal.
But the pipeline still has to decide *when* it's allowed to run with its privileged identity.
Look closely at what triggers it.

**Hint 2:**
Check the repository's branch protection settings, not just its files. Protecting the branch
everyone can see (`main`) isn't the same as protecting every branch the CI pipeline actually
trusts.

**Hint 3 (most revealing, still no flag):**
The deploy workflow triggers on pushes to `deploy/*`. If that pattern isn't covered by any branch
protection rule, and you have Write access to the repo, you can push directly to a branch matching
it. Once the pipeline runs, its job log is visible to you in the Actions tab — read it carefully.
