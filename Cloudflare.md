# Deploying hobo.gsquared.app

The docs site is built from this repo by Cloudflare Workers Builds and served as a Worker with
static assets only. This file is at the repo root, outside `docs/` and `site/`, so the site build
never publishes it.

## Worker settings

In the Cloudflare dashboard, **Workers & Pages → Create → Import a repository**, then pick
`hobo-vm/hobo`.

| Setting | Value |
| --- | --- |
| Project name | `hobo-site` (must match `name` in `site/wrangler.jsonc`) |
| Production branch | `main` |
| Root directory | `site` |
| Build command | `npm ci && npm run build` |
| Deploy command | `npx wrangler deploy` |
| Non-production branch deploy command | `npx wrangler versions upload` |

- Node comes from `site/.nvmrc` (24).
- `npm run build` runs the README check first (as `make readme-check` does), so a README that's out of date with
  `docs/features` fails the deploy.
- `site/wrangler.jsonc` serves `site/dist` as static assets, with Starlight's 404 page.

## Build watch paths

**Settings → Build → Build watch paths**, so commits that touch only code don't rebuild the site:

- Include: `docs/*`, `site/*`, `assets/*`
- Exclude: `docs/design.md`

`assets/*` is there because the site uses the logo and icon from it.

## Custom domain

**Settings → Domains & Routes → Add → Custom domain**: `hobo.gsquared.app`. The `gsquared.app`
zone must be on the same Cloudflare account; Cloudflare adds the DNS record and certificate.

## Later

- Once signed builds ship, the home page's download button links to the latest GitHub Release:
  `https://github.com/hobo-vm/hobo/releases/latest`.
- The repo stays private until the first release and Homebrew tap ship; Workers Builds reads it
  through the Cloudflare GitHub app, which needs access to the `hobo-vm` organization.
