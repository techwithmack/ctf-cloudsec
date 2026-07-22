# Learning Objectives — Challenge 1: The Flawed Blueprint

After completing this challenge, players should understand:

1. **Public bucket policies are a common, high-impact misconfiguration.** A single
   `aws_s3_bucket_policy` with `Principal: "*"` and `s3:GetObject` grants read access to anyone on
   the internet, regardless of any "public access block" settings that were *also* explicitly
   disabled to allow it — as happened here.
2. **Public access blocks exist specifically to prevent this class of mistake.** S3's
   `block_public_policy` / `restrict_public_buckets` settings default to blocking exactly this
   misconfiguration; they have to be deliberately turned off (as in this challenge's Terraform) for
   a public-read policy to take effect at all.
3. **"Temporary" backups and forgotten artifacts are a real attack surface.** Config files pushed
   during migrations, incident response, or one-off scripts often contain credentials or secrets
   and are rarely cleaned up once the immediate need passes.
4. **IaC scanning / CSPM catches this before it ships.** This exact misconfiguration — a public
   read policy plus disabled access blocks — is a standard rule in infrastructure-as-code scanners
   and cloud security posture management tools. Had this Terraform been scanned pre-deployment, the
   issue would have been flagged before the bucket (and the flag) ever went live.
5. **Basic cloud CLI enumeration is a core skill.** Unauthenticated `aws s3 ls` /
   `aws s3 cp --no-sign-request` against a public bucket requires no exploit — just knowing where
   to look and how the tooling works.
