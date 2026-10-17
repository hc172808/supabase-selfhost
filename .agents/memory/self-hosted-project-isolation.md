---
name: Self-hosted project isolation
description: The user's chosen deployment layout for multiple self-hosted Supabase projects.
---

Run each independent self-hosted Supabase project in its own Proxmox CT, with a distinct hostname and isolated data and credentials.

**Why:** The user chose one CT per project on 2026-10-17 because self-hosted Studio does not provide multi-project management.

**How to apply:** For every additional instance, create a new CT and Cloudflare Tunnel hostname/origin. Do not attempt to add multiple projects to the same self-hosted Studio instance.
