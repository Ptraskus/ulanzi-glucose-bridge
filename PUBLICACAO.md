# Building and publishing releases

This guide is for maintainers. Source code can be public before a signed installer is available. A local build is not evidence that installation was validated on a clean computer or that its publisher is trusted.

## Source publication

Review both `git diff --cached` and `git diff --cached --name-only` before pushing. Keep `.env`, vaults, logs, configuration history, backups, downloaded tools, generated presentations and screenshots out of Git. Only the reviewed `.env.example` belongs in public source. `.gitignore` cannot protect files already tracked.

Use a public author name and GitHub's `noreply` email for commits. Check document metadata and screenshots for personal paths before publishing exports. Keep private vulnerability reporting enabled as described in [SECURITY.md](SECURITY.md).

## Package guarantees and limits

`release/package-files.txt` is a literal allowlist. New files are never automatically included. The builder rejects local data directories and unexpected JSON; the only locale JSON files allowed are `locales/en.json` and `locales/pt-BR.json`. Portable Node.js requires an explicit archive and matching SHA-256, and its major version must be at least 22. Neither runtime nor signing material is downloaded automatically.

Payload and artifact checksums are generated. The installer runs per user without administrator privileges, uses English by default with Portuguese available, and offers optional desktop/startup shortcuts. Initial installer language is saved only if no application configuration or language preference exists. Installing again preserves local configuration and credentials. Normal uninstall removes program files and preserves user data.

The bundled runtime includes only `node.exe` and the original Node.js `LICENSE`. The application needs no npm packages at runtime; npm and Corepack are intentionally excluded from end-user packages.

The packaging script enforces requested signature checks. A successful unsigned local build is intended for internal validation; do not represent it as a signed or trusted public installer. Checksums alone do not authenticate the publisher.

The wizard links to AWTRIX's official flasher; it does not redistribute firmware. Review the firmware project's own license separately before any proposed redistribution or commercial use.

## Prerequisites

- Windows with PowerShell 5.1.
- [Inno Setup](https://jrsoftware.org/isinfo.php) 6 or 7 to compile the installer; the builder prefers version 7 when present.
- A Windows x64 Node.js 22+ archive from [official Node.js distributions](https://nodejs.org/dist/), with its SHA-256 from that release's official `SHASUMS256.txt`. Use a currently supported LTS release and verify signed checksums according to Node.js guidance.
- For public installers, a valid code-signing certificate with its private key and a working timestamp service. Keep signing material outside the repository.

## Build an internal validation package

Update `package.json`, review the allowlist, and run `npm.cmd run check` and `npm.cmd test` on Windows first.

```powershell
$releaseVersion = (Get-Content .\package.json -Raw | ConvertFrom-Json).version
$nodeHash = 'REPLACE_WITH_THE_OFFICIAL_64_CHARACTER_SHA256'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-release.ps1 `
    -Version $releaseVersion `
    -IncludePortableNode `
    -NodeArchivePath C:\ReleaseInputs\node-v24.x.x-win-x64.zip `
    -NodeArchiveSha256 $nodeHash `
    -RequireInstaller
```

Use the real archive filename and checksum. Output goes to `release\artifacts\<version>`; staging is removed afterward. Existing output is not overwritten unless `-Force` is explicitly provided. `-SkipInstaller` creates only a ZIP. An internal prerelease suffix can use `-AllowVersionMismatch`; public version numbers should match `package.json`.

## Sign a public installer

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-release.ps1 `
    -Version $releaseVersion `
    -IncludePortableNode `
    -NodeArchivePath C:\ReleaseInputs\node-v24.x.x-win-x64.zip `
    -NodeArchiveSha256 $nodeHash `
    -RequireInstaller `
    -RequireSignature `
    -CertificateThumbprint 'REPLACE_WITH_YOUR_CERTIFICATE_THUMBPRINT' `
    -ReleaseNotes 'Public summary of this release'
```

For a PFX, open a dedicated PowerShell session with `powershell.exe -NoProfile -ExecutionPolicy Bypass`, then invoke `scripts/build-release.ps1` directly within that session. Use `-CertificatePfxPath` outside the repository and provide `-CertificatePfxPassword` as a `SecureString`, obtained with `Read-Host -AsSecureString`. Do not pass a SecureString across the `-File` command line, put passwords in arguments, or commit keys/certificates. The execution-policy option applies only to this process; do not change system-wide policy.

`-RequireSignature` signs the payload's PowerShell scripts and installer and requires Authenticode status `Valid`. Keep timestamping enabled. The ZIP does not receive Authenticode; signed scripts remain signed inside it, and its hash appears in `SHA256SUMS.txt`. Confirm the publisher, trust chain and timestamp separately on a clean test machine.

In CI, use protected secrets and an approved release environment, restrict temporary key access and remove temporary signing material afterward. Do not add credentials to source files or logs.

## Validate before publishing

Use a clean Windows x64 virtual machine and a standard user. Do not run installation smoke tests against a developer's real app data.

1. Verify artifact hashes and the installer's Authenticode publisher, chain and timestamp.
2. Install without a global Node.js and confirm the bundled runtime works.
3. Test first launch, English and Portuguese setup, language persistence, both glucose units, connection tests and cancellation. Check that alarms begin disabled.
4. Physically confirm clock display and sound using an appropriate test device; automated tests cannot prove hardware behavior.
5. Test startup and desktop shortcuts, duplicate launches, repair, upgrade, and uninstall/reinstall with existing settings. Confirm local data and credentials are preserved.
6. Test source ZIP extraction and a missing/old Node.js: the launcher must provide an actionable error.
7. Check signed installer warnings and installation under the supported Windows versions. Inspect the final ZIP for unexpected personal files or metadata.

The advanced `scripts/install-local.ps1` installs only a prepared package containing `checksums.sha256`, not a raw GitHub source ZIP. It supports `-ExpectedPackageSha256`, `-Repair`, `-NoShellIntegration` and an explicit installation path inside the current user's LocalAppData Programs folder. For isolated automated checks, redirect the child process's `LOCALAPPDATA` to staging and use `-NoShellIntegration`; never redirect the real user's data or invoke their installation's uninstaller.

## Publish and enable updates

Publish only reviewed artifacts from the matching version folder, their `SHA256SUMS.txt` and accurate release notes. Do not upload local configuration, caches, old internal artifacts or unsigned installers described as signed releases. Keep the README honest about which downloadable artifacts actually exist.

The app's update channel remains disabled unless configured. To generate an update feed, add both `-UpdateManifestUrl` and `-UpdateInstallerUrl` using permanent real HTTPS addresses and enable `-RequireSignature`. The installer URL must end in `Ulanzi-Libre-Bridge-Setup-<version>.exe`; the manifest URL must end in `update-manifest.json`. Example domains, temporary query URLs and incomplete pins are rejected.

The builder pins the channel, feed URL and expected publisher into the packaged defaults, then produces `update-manifest.json`. Existing installations keep their settings and may need an explicit migration. Verify HTTPS, hash, signed publisher and version before announcing the channel. Publishing a GitHub repository alone does not enable updates.
