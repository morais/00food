# Contributing to 00Food

Thanks for helping improve 00Food. Keep pull requests focused, explain the
user-visible effect, and include tests for backend behavior changes.

## Local setup

The backend requires Node.js 22 or newer:

```sh
cd server
npm ci
npm run typecheck
npm test
```

For iOS work, copy `ios/project.yml.sample` to the gitignored
`ios/project.yml`, set your own Apple identifiers, run `xcodegen`, and build
with Xcode 27 or newer. See `ios/README.md` and `server/README.md`.

## Protect credentials and personal data

- Never commit `.dev.vars`, `.env` variants, `wrangler.toml`,
  `ios/project.yml`, `.p8` keys, signing certificates, provisioning profiles,
  or exported archives.
- Update committed `.sample` files when shared configuration changes, and keep
  their public placeholder values intact.
- Use fictional data in tests, fixtures, and screenshots. Never commit real
  food logs, photos, or Apple Health data.
- Report suspected vulnerabilities privately as described in `SECURITY.md`.

## Pull requests

Before opening a pull request:

1. Run `npm ci`, `npm run typecheck`, and `npm test` in `server/`.
2. Keep the Swift models in `ios/Sources/Models.swift` in step with the Zod
   schemas in `server/src/api.ts`.
3. Add positive and negative tests for new backend endpoints.
4. Confirm that the diff contains no credentials or developer-specific Apple
   identifiers.

The 00Food name and artwork are not covered by the MIT License; a fork that
ships its own app needs its own name and icon (see `docs/brand/LICENSE`).
