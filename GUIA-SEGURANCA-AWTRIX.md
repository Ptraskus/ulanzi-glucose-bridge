# AWTRIX network security

The bridge communicates with the TC001 over HTTP on your local network. HTTP Basic authentication can restrict access but does not encrypt passwords, configuration or glucose data in transit. A browser's HTTP warning is not a certificate problem that the bridge can fix.

## Prepare your clock

Use the official documentation for the firmware version you install: [AWTRIX NG setup](https://blueforcer.github.io/awtrix-ng/getting-started/flashing/) and [AWTRIX NG security policy](https://github.com/Blueforcer/awtrix-ng/blob/main/SECURITY.md).

Provisioning may create an open Wi-Fi access point. Configure the device in a trusted environment and use the network name shown by your own clock; names and network behavior vary by firmware. Follow the firmware's instructions for connecting to your Wi-Fi and enabling authentication. Confirm that the clock reconnects to the intended network after reboot.

Do not reuse an account password as the device password. Enter the TC001 credentials in the bridge's local setup wizard, which stores them in the Windows-protected vault. The bridge does not need the Wi-Fi password you enter into the clock's own portal.

## Limit exposure

- Keep the clock on a trusted network. If available, use an IoT network with a rule allowing the bridge computer to reach the clock.
- Do not forward the clock's HTTP port to the internet, place it in a router DMZ, or expose its configuration portal publicly.
- Confirm that authentication is enabled and that an unauthenticated request is rejected when the firmware supports it.
- Use firmware and scripts from verified sources, and review their update and security guidance.
- Keep using the official glucose app and its alarms; this display is supplementary.

The TC001 receives the display payload, not your Nightscout token. Protect both ends: the computer contains source credentials, and anyone with access to the display can see its contents.

If the firmware's provisioning or HTTP behavior does not meet your requirements, do not work around the browser warning by weakening other protections. Reconsider the network setup or firmware before sending personal data to the device.
