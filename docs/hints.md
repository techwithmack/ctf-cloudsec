# Hints — Challenge 1: The Flawed Blueprint

**Hint 1 (least revealing):**
The developer portal at the entry point isn't the whole story — developers sometimes leave notes
for themselves that they forget aren't visible to everyone. Try looking at what the page actually
sends you, not just what it renders.

**Hint 2:**
View the page's source (not just the rendered page) — look for an HTML comment. It references a
cloud storage location. Once you have that, think about what unauthenticated tooling exists for
listing and downloading from that kind of storage.

**Hint 3 (most revealing, still no flag):**
The storage bucket referenced in the comment allows public reads with no credentials — use
`aws s3 ls <bucket> --no-sign-request` to see what's inside, then pull down the one file you find
and read through it carefully for anything that looks like a leftover debug value.
