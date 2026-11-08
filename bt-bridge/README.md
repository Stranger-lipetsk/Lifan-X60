# OBD Bluetooth Bridge (prototype)

A removable Android 4.4/API 19 app intended to bridge the Elead vendor SPP service to Torque's TCP/Wi-Fi adapter interface. It does **not** replace Bluetooth framework, system APKs, kernel files, or call/HFP/A2DP components.

## Data path

`Torque TCP client → 127.0.0.1:35000 → bridge → exported Elead IelBluetoothService → Nforetek SPP → ELM327`

Torque's APK uses `java.net.Socket(host, port)` for its Wi-Fi OBD transport. The bridge binds its listener only to loopback, not the car's LAN. It asks the Elead service for pairing and SPP explicitly; it never asks the service to connect HFP/A2DP.

## Build and install

The `Build OBD Bluetooth Bridge` GitHub Actions workflow builds a v1-signed API 19-compatible APK and publishes it as a short-lived workflow artifact. It does not add the APK to Git or alter a firmware image. Copy the artifact to a USB drive and install it using the head unit's file manager.

## First test

1. Park the vehicle. Keep existing phone-to-head-unit pairings; this app does not remove them.
2. Plug the ELM327 into the OBD socket and enable Bluetooth on the head unit.
3. Open **OBD Bluetooth Bridge**, scan, select the ELM327, and press **Pair and start SPP bridge**. Confirm a system pairing prompt only if one appears and the code is expected. The bridge does not invent or silently enter a PIN.
4. Wait for `SPP connected; TCP 127.0.0.1:35000 ready`.
5. In Torque set **Connection Type = WiFi**, adapter IP `127.0.0.1`, port `35000`, then connect.
6. To stop, return to the bridge and press **Stop bridge**. The app requests only SPP disconnect; saved pairing stays in place.

## Safety and limits

- The app is opt-in; no boot receiver or auto-start is present.
- The Binder transaction map is statically recovered from the published test firmware. CI can compile and sign the APK but cannot prove the running head unit accepts the call.
- Pairing still goes through the head unit's existing Bluetooth bond flow. If that flow produces no PIN/confirmation UI and fails to bond, this prototype cannot bypass the Bluetooth framework; it will report the failure and stop without touching calls or system files.
- Do not install it into `/system`, replace Elead APKs, or flash a new image for this test.
- Runtime validation on the physical head unit is still required before treating the bridge as working.
