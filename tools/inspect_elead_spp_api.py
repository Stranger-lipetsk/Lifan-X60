#!/usr/bin/env python3
"""Emit a text-only API/manifest inventory for Elead Bluetooth APKs in system.img.

Usage: python3 tools/inspect_elead_spp_api.py RELEASE.zip REPORT.txt
The extracted image/APKs are temporary and are never written into the repository.
"""
from __future__ import annotations

import hashlib
import logging
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile

# Androguard uses loguru for verbose parser diagnostics. Keep the report concise.
try:
    from loguru import logger
    logger.remove()
except Exception:
    pass
logging.disable(logging.CRITICAL)

from androguard.core.apk import APK
from androguard.core.dex import DEX

ARCHIVE_SHA256 = "4be81211994221e80e401ce712ce484b5320156902fff3707737b73e3945d17f"
SYSTEM_SHA256 = "a660f062716fd42d5a6185faec059f42675b3024304de7b81fac5d705cc88511"
MEMBER_NAMES = (
    "EL831CLF01_elBTService_2016.09.05.01.apk",
    "EL831CLF01_elBluetoothSetup_2016.12.13.01.apk",
    "EL831CLF01_elBluetoothPhone_2016.12.13.01.apk",
)
ANDROID_NS = "{http://schemas.android.com/apk/res/android}"


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def dump_from_ext4(image: Path, internal: str, output: Path) -> bool:
    result = subprocess.run(
        ["debugfs", "-R", f"dump {internal} {output}", str(image)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.returncode == 0 and output.is_file() and output.stat().st_size > 0


def format_manifest(apk: APK) -> list[str]:
    lines: list[str] = []
    xml = apk.get_android_manifest_xml()
    if xml is None:
        return ["Manifest XML: unavailable"]
    for node in xml.xpath("//*[local-name()='service']"):
        name = node.get(ANDROID_NS + "name", "")
        exported = node.get(ANDROID_NS + "exported", "(implicit)")
        permission = node.get(ANDROID_NS + "permission", "(none)")
        actions = sorted(
            set(node.xpath(".//*[local-name()='action']/@*[local-name()='name']"))
        )
        if any(token in (name + " " + " ".join(actions)).lower() for token in ("bluetooth", "nforetek", "spp", "elead")):
            lines.append(f"service {name} exported={exported} permission={permission} actions={','.join(actions) or '(none)'}")
    if not lines:
        lines.append("No Bluetooth/SPP/Elead-named services declared in manifest")
    return lines


def dex_inventory(apk: APK) -> list[str]:
    out: list[str] = []
    total_code_lines = 0
    class_markers = (
        "com/nforetek/bt/aidl/infcommandspp",
        "com/nforetek/bt/aidl/infcallbackspp",
        "com/nforetek/bt/aidl/ielbluetoothservice",
        "com/nforetek/bt/aidl/ielbluetoothservicecallback",
        "tw/com/elead/el830/elbluetooth/elbluetoothservice",
        "com/elead/bt/applicationprofiles/applicationprofiles",
    )
    code_markers = (
        "infcommandspp$stub",
        "infcommandspp$stub$proxy",
        "infcallbackspp$stub",
        "ielbluetoothservice$stub",
        "ielbluetoothservicecallback$stub",
        "elbluetoothservice$2",
        "elbluetoothservice$3",
        "elbluetoothservice$11",
        "tw/com/elead/el830/elbluetooth/elbluetoothservice;",
        "com/elead/bt/applicationprofiles/applicationprofiles;",
    )
    method_markers = (
        "spp", "btpair", "btpaired", "ontransact", "asinterface",
        "asbinder", "ondestroy", "oncreate", "onbind", "onreceive",
        "registerelbtcallback", "createbond", "profile", "access$7",
        "<init>", "initialize", "init",
    )
    for raw in apk.get_all_dex():
        dex = DEX(raw)
        for cls in dex.get_classes():
            name = cls.get_name()
            low = name.lower()
            if not any(token in low for token in class_markers):
                continue
            methods = list(cls.get_methods())
            out.append(f"CLASS {name} extends {cls.get_superclassname()}")
            for field in cls.get_fields():
                if any(token in field.get_name().lower() for token in ("profile", "spp", "bluetooth")):
                    out.append(f"  FIELD {field.get_name()} {field.get_descriptor()} [{field.get_access_flags_string()}]")
            for method in methods:
                method_name = method.get_name()
                if not any(token in method_name.lower() for token in method_markers):
                    continue
                descriptor = method.get_descriptor()
                flags = method.get_access_flags_string()
                out.append(f"  METHOD {method_name}{descriptor} [{flags}]")
                code = method.get_code()
                disassemble = any(token in low for token in code_markers)
                if code is None or not disassemble:
                    continue
                try:
                    count = 0
                    for ins in code.get_bc().get_instructions():
                        if total_code_lines >= 4000 or count >= 240:
                            out.append("    ... bytecode truncated ...")
                            break
                        output = ins.get_output()
                        out.append(f"    {ins.get_name()} {output}".rstrip())
                        total_code_lines += 1
                        count += 1
                except Exception as exc:
                    out.append(f"    (disassembly unavailable: {type(exc).__name__})")
    return out or ["No matching SPP/service DEX classes found"]


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    archive = Path(sys.argv[1])
    report = Path(sys.argv[2])
    report.parent.mkdir(parents=True, exist_ok=True)
    lines: list[str] = [
        "# Elead SPP API static inspection",
        "Scope: manifest and DEX only; no APK is installed or executed.",
        "This is reconnaissance for a removable, non-system bridge; not proof of runtime behavior.",
        f"Archive: {archive.name}",
        f"Archive SHA-256: {sha256(archive)}",
        f"Expected archive SHA-256: {ARCHIVE_SHA256}",
    ]
    if lines[-2].split(": ", 1)[1] != ARCHIVE_SHA256:
        lines.append("ERROR: release archive hash does not match the selected image; refusing to inspect.")
        report.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return 1

    with tempfile.TemporaryDirectory(prefix="elead-spp-inspect-") as temp_name:
        temp = Path(temp_name)
        image = temp / "system.img"
        with zipfile.ZipFile(archive) as zf:
            candidates = [n for n in zf.namelist() if n.endswith("system.img")]
            if not candidates:
                lines.append("ERROR: system.img is missing from ZIP")
                report.write_text("\n".join(lines) + "\n", encoding="utf-8")
                return 1
            with zf.open(candidates[0]) as src, image.open("wb") as dst:
                shutil.copyfileobj(src, dst, length=1024 * 1024)
        image_hash = sha256(image)
        lines.extend((f"system.img SHA-256: {image_hash}", f"Expected system.img SHA-256: {SYSTEM_SHA256}"))
        if image_hash != SYSTEM_SHA256:
            lines.append("ERROR: system image hash differs from the selected image; refusing to inspect.")
            report.write_text("\n".join(lines) + "\n", encoding="utf-8")
            return 1

        for member in MEMBER_NAMES:
            internal = "/app/" + member
            apk_path = temp / member
            lines.append(f"\n## {internal}")
            if not dump_from_ext4(image, internal, apk_path):
                lines.append("MISSING")
                continue
            lines.append(f"bytes={apk_path.stat().st_size} sha256={sha256(apk_path)}")
            try:
                apk = APK(str(apk_path))
                def safe_value(method_name: str) -> str:
                    try:
                        value = getattr(apk, method_name)()
                        return str(value) if value not in (None, "") else "(unset)"
                    except Exception:
                        return "(unset)"
                lines.append(
                    f"package={apk.get_package()} version={safe_value('get_androidversion_name')} "
                    f"minSdk={safe_value('get_min_sdk_version')} targetSdk={safe_value('get_target_sdk_version')}"
                )
                lines.append("Bluetooth-related permissions: " + ", ".join(p for p in apk.get_permissions() if "BLUETOOTH" in p or "NFORETEK" in p))
                lines.extend(format_manifest(apk))
                lines.append("Relevant DEX classes, method signatures, and selected bytecode:")
                lines.extend(dex_inventory(apk))
            except Exception as exc:
                lines.append(f"ERROR parsing APK: {type(exc).__name__}: {exc}")
    lines.extend((
        "",
        "## Safety boundary",
        "Do not bind to this vendor service or transmit pairing/OBD requests until service export, permission, transaction signatures, and lifecycle behavior are verified. A later bridge should be a normal removable app, must not replace Bluetooth/framework files, and must not auto-start or interfere with HFP/A2DP calls.",
    ))
    report.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
