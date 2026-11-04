# enso.sh

The landing page for Enso. Four static files, no build step — open `index.html`
directly, or serve the directory to exercise the root-relative asset paths:

    python3 -m http.server 8000

## The download link is pinned

"Download for Mac" points at a specific release asset. It has to: GitHub's
unpinned `/releases/latest/download/<name>` needs a stable filename, and our
assets embed the version (`Enso-0.8.0.dmg`). So after cutting a release, bump
both the `href` and the version in `.meta` in `index.html`, then redeploy.

Serving a stable `Enso.dmg` asset alongside the versioned one would let the link
become evergreen.

## Deployment

Served by Caddy on `hetzner_takumi` from a checkout of this repo. The server has
a shallow, sparse clone at `/var/www/enso` that materializes only `website/`,
fetched over SSH with a read-only deploy key (`~/.ssh/enso_deploy_key`, host
alias `github.com-enso` in the server's `~/.ssh/config`; registered on the repo
as "hetzner_takumi enso.sh deploy"). Anonymous HTTPS fetches from that server
started getting 401s from GitHub in Sep 2026, so the remote must stay SSH:

    git clone --depth 1 --filter=blob:none --sparse \
      git@github.com-enso:amanfromsolan/enso.git /var/www/enso
    git -C /var/www/enso sparse-checkout set website

To ship whatever is on `main`:

    ssh hetzner_takumi enso-deploy

That script fast-forwards the checkout and nothing else. Caddy's `file_server`
reads from disk on each request, so static changes need no reload — only edits
to `/etc/caddy/Caddyfile` do.
