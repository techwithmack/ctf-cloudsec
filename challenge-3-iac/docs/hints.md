# Hints — Challenge 3: The Shadow Pipeline Overlord

**Hint 1 (least revealing):**
The deploy pipeline uses OpenID Connect, not a stored AWS key — so there's no credential to steal.
But the pipeline still has to decide *when* it's allowed to run with its privileged identity.
Look closely at what triggers it.

**Hint 2:**
You don't have permission to view the repo's branch protection settings directly — but you don't
need to. Try pushing to a branch other than `main` and see what the server actually allows, rather
than assuming every branch is equally protected.

**Hint 3 (most revealing, still no flag):**
The deploy workflow triggers on pushes to `deploy/*`. If that pattern isn't covered by any branch
protection rule, and you have Write access to the repo, you can push directly to a branch matching
it. Once the pipeline runs, its job log is visible to you in the Actions tab — read it carefully.
