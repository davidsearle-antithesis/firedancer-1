---
name: docker_push_no_auth
description: User's Docker is already authenticated to GCP Artifact Registry — just use docker push directly without checking auth
type: feedback
---

Don't check Docker auth or try to verify credentials before pushing images. The user's environment is already configured. Just tag and push.

**Why:** User corrected me when I tried to inspect docker config and check gcloud. Their Docker is pre-authenticated.

**How to apply:** When pushing to any container registry, skip auth checks and just run `docker tag` + `docker push` directly.
