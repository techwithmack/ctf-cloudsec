# Challenge 1: The Flawed Blueprint

**Category:** Cloud Infrastructure / Storage
**Difficulty:** Low
**Estimated Solve Time:** 20 minutes
**Hosting Model:** Sponsor Hosted (Aikido)
**Player Isolation:** True — each team receives its own isolated set of cloud resources

## Scenario

Aikido's platform team pushed a "quick backup" of some production configuration to cloud storage
during an infrastructure migration — and never cleaned it up. The internal developer portal that
was supposed to reference it temporarily is still live, and it still points at the forgotten
bucket.

You've been given access to the internal developer portal. Somewhere in this environment is a
piece of production configuration that should never have left a private network. Find it.

## Objective

Enumerate the environment, locate the exposed cloud storage bucket, and retrieve the flag from the
forgotten backup file inside it.

## Flag Format

```
FLAG-{32 hexadecimal characters}
```
