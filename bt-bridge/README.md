# OBD Bluetooth Bridge (prototype)

A removable Android 4.4/API 19 app intended to bridge the Elead vendor SPP service to Torque's TCP/Wi-Fi adapter interface. It does **not** replace Bluetooth framework, system APKs, kernel files, or call/HFP/A2DP components.

## Data path

`Torque TCP client → 127.0.0.1:35000 → bridge → exported Elead IelBluetoothService → Nforetek SPP → ELM327`

Torque's APK uses `java.net.Socket(host, port)` for its Wi-Fi OBD transport. The bridge binds its listener only to loopback, not the car's LAN. It asks the Elead service for pairing and SPP explicitly; it never asks the service to connect HFP/A2DP.

## Build and install

The `Build OBD Bluetooth Bridge` GitHub Actions workflow builds a v1-signed API 19-compatible APK. GitHub Actions artifact storage for this repository is currently at quota, so the workflow places the small installable APK and its SHA-256 sidecar directly on the active work branch as a delivery fallback. It does not alter a firmware image. Download `bt-bridge/obd-bt-bridge.apk` from the branch, copy it to a USB drive, and install it using the head unit's file manager. The build signing key is temporary; for a future prototype update, uninstall the old bridge app before installing a newly built APK (saved Bluetooth pairing is unaffected).

## First test

1. Park the vehicle. Keep existing phone-to-head-unit pairings; this app does not remove them.
2. Plug the ELM327 into the OBD socket and enable Bluetooth on the head unit.
3. Open **OBD Bluetooth Bridge**, scan, select the ELM327, and press **Pair and start SPP bridge**. If you know the exact PIN already used to pair this ELM with the phone, enter it in the optional PIN field before starting. It remains in memory only and is submitted only for a PIN pairing request from the selected Bluetooth address; it is neither logged nor stored. Leave blank if unknown. Confirm any visible system pairing prompt only when its code is expected. The bridge never guesses a PIN and never auto-accepts passkey/consent pairing modes.
4. Wait for `SPP connected; TCP 127.0.0.1:35000 ready`.
5. In Torque set **Connection Type = WiFi**, adapter IP `127.0.0.1`, port `35000`, then connect.
6. To stop, return to the bridge and press **Stop bridge**. The app requests only SPP disconnect; saved pairing stays in place.

## Safety and limits

- The app is opt-in; no boot receiver or auto-start is present.
- The Binder transaction map is statically recovered from the published test firmware. The service's `elBTreqHasSPPProfile()` may report `false`; that advisory flag is logged but does not block the explicitly requested bond/SPP attempt. A rejected pair or SPP request is reported directly. CI can compile and sign the APK but cannot prove the running head unit accepts the call.
- Pairing still goes through the head unit's existing Bluetooth bond flow. If that flow produces no PIN/confirmation UI and fails to bond, this prototype cannot bypass the Bluetooth framework; it will report the failure and stop without touching calls or system files.
- Do not install it into `/system`, replace Elead APKs, or flash a new image for this test.
- Runtime validation on the physical head unit is still required before treating the bridge as working.
