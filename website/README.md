# enso.sh

The landing page for Enso. Four static files, no build step — open `index.html`
directly, or serve the directory to exercise the root-relative asset paths:

    python3 -m http.server 8000

## Deployment

Served by Caddy on `hetzner_takumi` from a checkout of this repo. The server has
a shallow, sparse clone at `/var/www/enso` that materializes only `website/`:

    git clone --depth 1 --filter=blob:none --sparse \
      https://github.com/amanfromsolan/enso.git /var/www/enso
    git -C /var/www/enso sparse-checkout set website

To ship whatever is on `main`:

    ssh hetzner_takumi enso-deploy

That script fast-forwards the checkout and nothing else. Caddy's `file_server`
reads from disk on each request, so static changes need no reload — only edits
to `/etc/caddy/Caddyfile` do.
