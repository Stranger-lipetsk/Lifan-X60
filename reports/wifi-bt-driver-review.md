# Static review: Wi-Fi and Bluetooth bring-up on EL830C-LF01

Date of review: 2026-11-01. Scope: existing repository reports and extracted firmware/boot-image evidence. No device files were read or changed during this review; no firmware was built or flashed.

## Runtime evidence supplied by the owner

- The head unit's Wi-Fi settings remain disabled/gray; scanning does not start.
- The first removable diagnostic APK showed Android `WIFI_STATE_DISABLED`, `isWifiEnabled() == false` after its 20-second check, and no scan-results event. That APK did not preserve the `setWifiEnabled(true)` return value on the final screen, so the rejection/acceptance of the framework request is not known.
- Bluetooth discovery sees the NEXPEAK NX101 Pro ELM at `00:10:CC:4F:36:03`, but stock pairing fails before a PIN prompt. The Elead query previously returned `hasSPPProfile() == false`. SPP data transfer has never been runtime-tested.

## Wi-Fi evidence in the branch

- `reports/wifi-gps.txt` and `docs/13-wifi-точка-доступа.md` identify a built-in TI `wl12xx` driver in the Linux 3.0.35 kernel. The `wl12xx_get_platform_data` kernel string is present. This proves the driver code is in the image, not that the radio registered or powered up on the vehicle.
- The report lists `/vendor/firmware/ti-connectivity/wl18xx-fw-4.bin` and `wl18xx-conf.bin`, plus `wlconf/struct.bin` and `wl18xx-conf-default.bin`. It does not establish which firmware/NVS file the active runtime requests.
- The vendor updater references `/mnt/para_fw/wl1271-nvs.bin` for calibration/MAC. The report says this file is not in `system.img` or the update package; its presence and validity on the currently running unit are unknown. Do not replace, regenerate, or delete it.
- In the extracted `init.el_imx6_solo_v2.rc`, `#load wifi/bt modules` and `#service wifi_loader /system/bin/wifi/rc.wifi start` are commented out. The file separately declares `el_wifi_enable.sh` as a disabled, one-shot service. `wpa_supplicant`, DHCP, P2P and hostapd are also declared disabled/oneshot, normally for Android framework control. The repository contains no recovered body for `el_wifi_enable.sh`; therefore the vendor enable/power sequence is an important unresolved gap.
- An older branch note (`docs/20`) says Wi-Fi is available; that is a static expectation, contradicted by the owner's current runtime observation. The latter takes precedence.

## Bluetooth evidence in the branch

- `reports/bt-release-static-audit.txt` identifies `/etc/bluetooth/bt_vendor.conf` with UART `/dev/ttymxc1` and firmware patch `bcm20710a1.hcd`. `/lib/libbluelet.so` and `/bin/blueletd` are present. The report also finds no `/lib/hw/bluetooth.default.so`.
- `reports/bt-hal.txt` finds SPP/RFCOMM symbols in the proprietary Bluelet library and an Elead Binder service with explicit SPP operations. These are static symbols/API, not proof that the stock UI accepts SPP bonds or that the ELM can exchange bytes.
- The same static audit finds `/vendor/lib/libbt-vendor.so` containing `/dev/ttyO1`, different from the UART in `bt_vendor.conf`. It may be an unused/stale AOSP vendor library; because the standard Bluetooth HAL is absent, it must not be assumed to be the active transport.
- `init.el_imx6_solo_v2.rc` contains a `# No bluetooth hardware present` comment despite `hw.bluetooth=1`; `blueletd` is separately started after the Bluetooth MAC setup property. The `ueventd` file labels `/dev/hci_tty` and `/dev/ttymxc1` for Bluetooth. These conflicting clues mean the active HCI transport/stack has not yet been proved.
- `docs/02-железо.md` groups Wi-Fi and BT as TI WiLink, while the more specific Wi-Fi report identifies TI for Wi-Fi and the BT vendor config names a Broadcom patch. Hardware identity/configuration must be reconciled before attempting a driver replacement.

## Assessment and safe next work

1. Do not rewrite/replace either driver yet. The Wi-Fi image already contains `wl12xx`; the immediate unknown is whether the runtime enable/power/firmware/NVS path completes. The UI state alone cannot distinguish those causes.
2. For Wi-Fi, the decisive read-only evidence is the result of Android's enable request plus runtime `dmesg`/`logcat` around `WifiStateMachine`, `wlan0`, `wl12xx`, firmware/NVS and `el_wifi_enable.sh`. We do not currently have a confirmed safe ADB connection to the head unit. Do not enable network ADB or connect two USB host ports.
3. For BT, the decisive evidence is the running Bluelet/HCI transport and Elead pair-failure reason. The discovered ELM and failed bond prove only inquiry works and the bond does not complete; they do not establish whether the BT UART driver or SPP code is faulty.
4. The checkout has extracted reports and the kernel image/strings, but no kernel source tree, exact `.config`, active vendor script body, or complete device-side runtime logs. A compatible driver rebuild cannot be produced reliably from strings alone. Obtain the matching vendor BSP/source and a verified restorable image before any system-level change.
5. Preserve the existing phone/HFP path and Wi-Fi calibration. Any later driver experiment must be isolated, reversible, and explicitly approved; this review made no system or firmware changes.
