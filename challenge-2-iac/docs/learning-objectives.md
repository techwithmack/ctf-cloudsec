# Learning Objectives — Challenge 2: The Shadow Pipeline Overlord

After completing this challenge, players should understand:

1. **OIDC federation removes static credentials but doesn't remove the trust boundary.**
   Replacing long-lived AWS access keys in CI with OIDC-based role assumption is a real security
   improvement — but the resulting IAM trust policy is only as safe as the *conditions* scoping it.
   If the condition matches a ref pattern (`refs/heads/deploy/*`), anything that can push a
   matching ref inherits the role, full stop.
2. **Branch protection is a completeness problem, not a checkbox.** Protecting `main` is not the
   same as protecting every branch a privileged pipeline trusts. A single unprotected branch
   pattern that a CI trigger treats as authoritative is enough to undo an otherwise
   well-scoped IAM trust policy.
3. **CI job logs are a legitimate exfiltration channel.** A player doesn't need an out-of-band
   channel to exfiltrate a secret from a privileged job — if they can trigger the job and view its
   logs (which they inherently can, since they authored the triggering commit), printing a secret
   to stdout is sufficient. This is exactly how several real-world CI supply-chain incidents played
   out.
4. **Least privilege on the assumed role limits blast radius even when the trust policy is
   defeated.** The role in this challenge can only read one Secrets Manager secret — nothing else.
   Even a fully successful exploitation of the branch-protection gap doesn't grant broader account
   access, which is what a real-world "assume role, then what?" damage assessment should look like.
5. **The CI runner host itself should hold no cloud privilege.** All AWS access in this challenge
   flows through the job's OIDC token exchange, never through credentials or an instance role
   attached to the runner host. Compromising the runner host directly (rather than the pipeline
   logic) gains an attacker nothing on its own.
