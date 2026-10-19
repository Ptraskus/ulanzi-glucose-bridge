# Privacy

Ulanzi Libre Bridge processes glucose readings locally to display them on an Ulanzi TC001. It has no telemetry, advertising, project account or project-operated server.

## Data accessed

The app accesses the reading, trend and timestamp from the configured Nightscout or JSON source; the configured service addresses and credentials; and operational state needed for diagnostics and to reduce duplicate alarms.

The bridge communicates with the glucose source and TC001 selected by the user. Those services, the network and the installed firmware have their own behavior and privacy policies.

During device preparation, clicking the corresponding button opens documentation or a flashing page on the official AWTRIX NG domain. The browser and website may record ordinary access information. The bridge does not receive the Wi-Fi password entered in the clock's own portal, does not request Abbott/LibreLinkUp credentials, and does not send such information to this project.

## Local storage

| Path | Purpose |
| --- | --- |
| `.env` | Addresses and configuration. Although secrets are separated, this file remains private. |
| `.secrets/vault.json` | Credentials protected by Windows DPAPI for the same Windows user. |
| `.runtime/` | Operational state and rotating logs. |
| `.config-history/` | Valid configuration snapshots for recovery. |
| `.updates/` | Installers downloaded after an explicit update action. |

These files are excluded from public source and release packages. Uninstalling normally preserves them. Copying a vault to another Windows account or computer does not make its credentials usable there.

Theme and initial language preferences are stored in `%LOCALAPPDATA%\Ulanzi Libre Bridge\ui-preferences.json`. This file contains no readings, thresholds, addresses or credentials. The saved application configuration can also contain the selected language and glucose unit.

Valid recovery snapshots can contain a vault still encrypted with DPAPI. When configuration is invalid, quarantine records only file presence, hashes and the error code; it does not copy the problematic `.env` or vault.

## Logs and diagnostic reports

Persistent logs remove credentials, sensitive addresses and glucose readings by default. Exported diagnostics are sanitized again and declare that readings have been omitted. Addresses are reduced to categories such as local network or internet. Exported state excludes the glucose value, trend, high/low classification and reading timestamps.

An export can still contain configured thresholds, software/system versions, connection states and log timestamps. Redaction cannot guarantee removal of every possible unexpected value; review the file before sharing it. Terminal diagnostic commands can print glucose data and should also be reviewed before sharing output.

## Updates

Update checking is disabled until the distributor configures a manifest URL, channel and expected publisher. These values are pinned locally and are not accepted from the remote feed itself. When used, checking contacts that HTTPS URL, and downloading an installer requires the corresponding user action. The hosting service may record ordinary access information, including IP address and time.

## Control and deletion

You can stop the app and remove local configuration and data. Standard uninstallation keeps user data to avoid accidental loss; inspect the remaining installation folder and UI-preferences folder before deliberately deleting them. No project account or cloud deletion request is needed.

Future features that introduce telemetry, automatic background checks or new data destinations must update this policy before distribution and obtain consent when applicable.
