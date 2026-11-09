# Wi-Fi Radio Check (removable diagnostic)

Small Android 4.4/API 19 diagnostic for the Lifan head unit. It does not modify system files, drivers, calibration data, or Bluetooth settings. It does not connect to or save a Wi-Fi network and does not require internet.

On launch it only reads `WifiManager` state. The user-triggered **Check enable and scan** button asks Android to enable Wi-Fi, observes the framework state for up to 20 seconds, and requests a scan only if Android reports Wi-Fi enabled. Scan result output is a count only; SSIDs and credentials are not displayed or saved.

The report distinguishes `DISABLED`, `ENABLING`, `ENABLED`, and `UNKNOWN`, shows the initial state, preserves the return value or exception from `setWifiEnabled(true)` and `startScan()`, and says whether Android delivered a scan-results event. This is a framework-level diagnostic, not kernel `dmesg`; it cannot alone prove a driver, firmware, antenna, or NVS fault.

Build with `bash bt-diagnostics/build.sh` after Android SDK platform 34 and build-tools 34.0.0 are installed. The standalone APK has its own package ID, so it can be installed alongside the OBD bridge.
