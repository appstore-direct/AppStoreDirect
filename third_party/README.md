# Vendored dependencies

## ipatool

* Source: https://github.com/majd/ipatool
* Commit: `a53550f9c42cb4126d683e861139288b293c04ea` (2026-08-29)
* Licence: MIT — see `ipatool/LICENSE`

Pinned to a commit rather than a release tag because the SAP signer
(`internal/sap/`) that current App Store authentication requires landed after the
most recent tag. Vendored rather than fetched so builds are reproducible and so the
exact Apple-protocol revision in use is auditable.

Only `pkg/appstore`, `pkg/http` and `internal/sap` are used. The cobra CLI in
`cmd/` and the keyring in `pkg/keychain` are not — see docs/ARCHITECTURE.md §6.

To update: replace this directory, re-run `go build ./...` in `bridge/`, and
re-test authentication end to end. Treat every update as a protocol change.
