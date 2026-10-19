# Nightscout connection guide

Ulanzi Glucose Bridge reads an existing Nightscout instance. It does not create a server, install an uploader, authenticate with a CGM manufacturer's cloud, or connect directly to a glucose sensor. The CGM brand is not used to select or reject readings.

## Before setup

Confirm that your Nightscout site already receives current readings and that its timestamps match the source. Use the final HTTPS base URL, without `/api/v1`, query parameters or credentials. `https://glucose.example.org` is only an example, not a service provided by this project.

Use a read-only access token for the bridge when available. Nightscout documents access control and token setup in its [security guide](https://nightscout.github.io/nightscout/security/) and [administration tools](https://nightscout.github.io/nightscout/admin_tools/). A token limits access according to the permissions assigned by your server; keep it private.

The bridge also supports a Nightscout `API_SECRET`, sent as a hash in the API header. Prefer the least privilege needed for reading. Configure credentials through the local setup wizard so Windows DPAPI protects the saved value.

## Configure the bridge

1. Open `Start.cmd`, then select **Set up now**, or open `Configure.cmd` directly.
2. Choose **Nightscout** as the glucose source.
3. Enter the HTTPS base URL and the selected authentication method.
4. Enter the token or secret in the protected credential field, then test the source.
5. Test the TC001 connection. Leave sensor-expiry estimation off unless you want it and have reliable sensor-start events and the correct model-specific duration.
6. Review language, glucose unit and other preferences before saving.

For a terminal check that reads the source without sending to the clock:

```powershell
.\iniciar.cmd --once --dry-run
```

This can print a glucose reading in your terminal. Do not share its output without checking for private information. The source must return a fresh timestamp; a successful connection is not enough to confirm that an uploader is working.

## Source requirements

Remote sources require HTTPS. HTTP is accepted only on the same computer through a loopback address. Source requests do not follow redirects, so configure the final address. Fix certificate problems at the source instead of disabling certificate validation.

The bridge requests `/api/v1/entries/sgv.json?count=1`. It needs a numeric `sgv` value in mg/dL and a valid reading timestamp; Nightscout's standard `direction` field supplies the trend. It does not require any particular `device` value or manufacturer-specific metadata. The configured display unit can still be mg/dL or mmol/L.

Sensor-expiry estimation is a separate, optional feature. When enabled with `SENSOR_LIFETIME_DAYS` greater than zero, it uses the latest Nightscout `Sensor Start` or `Sensor Change` event and the duration you select. Zero disables the estimate and the event queries. Fractional durations are accepted, up to 365 days; choose the value for your actual sensor and avoid assuming a duration from another model. This is an estimate, not manufacturer-reported sensor status.

Some uploaders do not send treatment events, as the [Nightscout documentation explains](https://nightscout.github.io/nightscout/discover/#add-a-treatment-careportal). Ordinary glucose display only needs access to glucose entries; reading treatments is needed for the optional estimate. Without a suitable event or permission to read it, the bridge cannot derive an expected sensor end date; timestamp and stale-reading checks remain active.

## Choosing an uploader or hosting service

An uploader and a Nightscout host are separate components with their own support, costs, terms and privacy practices. The bridge does not provide or maintain them. Nightscout receives data through integrations for different CGMs; consult its [uploader guide](https://nightscout.github.io/uploader/setup/) and [setup documentation](https://nightscout.github.io/nightscout/) for your equipment and region before changing a working setup. This bridge supports the resulting API format; compatibility with every physical CGM/uploader combination has not been verified. Do not replace or disable official sensor alarms as part of configuring this display.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Authentication fails | Token permissions, selected authentication type and server access settings. |
| Redirect rejected | Use the final HTTPS base URL directly. |
| Connected but NO DATA | Latest source timestamp, uploader operation and maximum reading age. |
| Sensor-change estimate unavailable | Whether estimation is enabled, presence and date of the sensor-start event, and configured duration. Glucose display works without an estimate. |

Never post your site address, access tokens, API secret, `.env` or vault in a public issue. Use the app's sanitized diagnostics and review the export first.
