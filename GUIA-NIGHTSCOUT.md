# Nightscout connection guide

Ulanzi Libre Bridge reads an existing Nightscout instance. It does not create a server, install an uploader, authenticate with Abbott/LibreLinkUp, or connect directly to a glucose sensor.

## Before setup

Confirm that your Nightscout site already receives current readings and that its timestamps match the source. Use the final HTTPS base URL, without `/api/v1`, query parameters or credentials. `https://glucose.example.org` is only an example, not a service provided by this project.

Use a read-only access token for the bridge when available. Nightscout documents access control and token setup in its [security guide](https://nightscout.github.io/nightscout/security/) and [administration tools](https://nightscout.github.io/nightscout/admin_tools/). A token limits access according to the permissions assigned by your server; keep it private.

The bridge also supports a Nightscout `API_SECRET`, sent as a hash in the API header. Prefer the least privilege needed for reading. Configure credentials through the local setup wizard so Windows DPAPI protects the saved value.

## Configure the bridge

1. Open `Start.cmd`, then select **Set up now**, or open `Configure.cmd` directly.
2. Choose **Nightscout** as the glucose source.
3. Enter the HTTPS base URL and the selected authentication method.
4. Enter the token or secret in the protected credential field, then test the source.
5. Select the correct sensor duration and test the TC001 connection.
6. Review language, glucose unit and other preferences before saving.

For a terminal check that reads the source without sending to the clock:

```powershell
.\iniciar.cmd --once --dry-run
```

This can print a glucose reading in your terminal. Do not share its output without checking for private information. The source must return a fresh timestamp; a successful connection is not enough to confirm that an uploader is working.

## Source requirements

Remote sources require HTTPS. HTTP is accepted only on the same computer through a loopback address. Source requests do not follow redirects, so configure the final address. Fix certificate problems at the source instead of disabling certificate validation.

Sensor expiry uses the latest Nightscout `Sensor Start` or `Sensor Change` event and the duration you select. If those events are absent, the bridge can show stale data but cannot reliably derive the sensor's expected end date.

## Choosing an uploader or hosting service

An uploader and a Nightscout host are separate components with their own support, costs, terms and privacy practices. The bridge does not provide or maintain them. Review the [Nightscout setup documentation](https://nightscout.github.io/nightscout/) for your equipment and region before changing a working setup. Do not replace or disable official sensor alarms as part of configuring this display.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Authentication fails | Token permissions, selected authentication type and server access settings. |
| Redirect rejected | Use the final HTTPS base URL directly. |
| Connected but NO DATA | Latest source timestamp, uploader operation and maximum reading age. |
| Sensor-change status unavailable | Presence and date of the sensor-start event and configured duration. |

Never post your site address, access tokens, API secret, `.env` or vault in a public issue. Use the app's sanitized diagnostics and review the export first.
