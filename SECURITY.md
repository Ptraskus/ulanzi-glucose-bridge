# Security policy

## Supported versions

Only the latest stable version receives security fixes. Obtain releases from this repository and verify the checksums supplied with that version. A SHA-256 checksum verifies integrity against the value you trust; it does not itself identify the publisher. Public installer distribution additionally requires verified Authenticode signing as described in [PUBLICACAO.md](PUBLICACAO.md).

## Reporting a vulnerability

Use the [private GitHub vulnerability reporting form](https://github.com/Ptraskus/ulanzi-glucose-bridge/security/advisories/new). Include the affected version, a reproducible description using fictitious data, impact and a proposed fix if available.

Never publish tokens, passwords, private addresses, glucose readings or diagnostic files in a public security issue. If private reporting is unavailable, do not replace it with public sensitive details. The project aims to acknowledge reports within five business days; remediation and coordinated disclosure depend on severity and maintainer availability.

## Priority scope

- Exposure of Nightscout or AWTRIX credentials.
- Inclusion of personal configuration, vaults, logs, recovery snapshots, updates, backups or diagnostics in a public package.
- Code execution without consent during updates or installation.
- Firmware changes without explicit confirmation, outside the official allowed page, or with automatic serial-port selection.
- Acceptance of packages with invalid hashes or required signatures.
- Sending readings or telemetry to destinations not configured by the user.

General issues that do not involve security can use the [public issue tracker](https://github.com/Ptraskus/ulanzi-glucose-bridge/issues), after removing personal data and secrets. Review the [privacy policy](PRIVACY.md) before sharing diagnostic exports.
