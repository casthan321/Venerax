"""Reproducible Windows archive and installer builder for Venera Community."""

from __future__ import annotations

import hashlib
import os
import platform
import re
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent
WINDOWS_DIR = PROJECT_ROOT / "windows"
BUILD_DIR = PROJECT_ROOT / "build" / "windows"
TRANSLATION_URL = (
    "https://raw.githubusercontent.com/"
    "kira-96/Inno-Setup-Chinese-Simplified-Translation/"
    "6da09d23e14443d4cf8f07b1c5fd821bfe459788/"
    "ChineseSimplified.isl"
)
TRANSLATION_SHA256 = "869e43e7c7b8d20c7e4397c8e98f7d1b7cf0528803acdf019ad350143ec85469"

_IMAGE_FILE_MACHINE_NAMES = {
    0x014C: "x86",
    0x8664: "x64",
    0xAA64: "arm64",
}


def _read_version() -> str:
    pubspec = (PROJECT_ROOT / "pubspec.yaml").read_text(encoding="utf-8")
    match = re.search(r"^version:\s*([^+\s]+)(?:\+\S+)?\s*$", pubspec, re.MULTILINE)
    if match is None:
        raise RuntimeError("Could not read the application version from pubspec.yaml")
    return match.group(1)


def _run(*args: str) -> None:
    executable = shutil.which(args[0])
    if executable is None:
        raise RuntimeError(f"Required build tool was not found: {args[0]}")
    command = [executable, *args[1:]]
    if Path(executable).suffix.lower() in {".bat", ".cmd"}:
        command = [
            os.environ.get("COMSPEC", "cmd.exe"),
            "/d",
            "/c",
            "call",
            *command,
        ]
    subprocess.run(command, cwd=str(PROJECT_ROOT), check=True)


def _native_windows_architecture() -> str:
    """Return the native Windows architecture, including under emulation."""
    if sys.platform != "win32":
        return f"{sys.platform}/{platform.machine() or 'unknown'}"

    try:
        import ctypes

        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        is_wow64_process2 = kernel32.IsWow64Process2
        is_wow64_process2.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_ushort),
            ctypes.POINTER(ctypes.c_ushort),
        ]
        is_wow64_process2.restype = ctypes.c_bool
        kernel32.GetCurrentProcess.restype = ctypes.c_void_p
        process_machine = ctypes.c_ushort()
        native_machine = ctypes.c_ushort()
        if is_wow64_process2(
            kernel32.GetCurrentProcess(),
            ctypes.byref(process_machine),
            ctypes.byref(native_machine),
        ):
            return _IMAGE_FILE_MACHINE_NAMES.get(
                native_machine.value,
                f"windows-machine-0x{native_machine.value:04x}",
            )
    except (AttributeError, OSError):
        pass

    reported = (
        os.environ.get("PROCESSOR_ARCHITEW6432")
        or os.environ.get("PROCESSOR_ARCHITECTURE")
        or platform.machine()
        or "unknown"
    )
    normalized = reported.strip().lower().replace("-", "").replace("_", "")
    return {"amd64": "x64", "aarch64": "arm64"}.get(normalized, normalized)


def _require_supported_host(architecture: str) -> None:
    if architecture != "arm64":
        return
    native_architecture = _native_windows_architecture()
    if sys.platform != "win32" or native_architecture != "arm64":
        raise RuntimeError(
            "ARM64 Windows packages require a native ARM64 Windows host; "
            f"detected {native_architecture}. This Flutter SDK cannot "
            "cross-compile Windows with --target-platform."
        )


def _release_dir(architecture: str) -> Path:
    return BUILD_DIR / architecture / "runner" / "Release"


def _package_paths(architecture: str, version: str) -> tuple[Path, Path]:
    archive = BUILD_DIR / f"Venera-Community-{version}-windows-{architecture}.zip"
    installer = BUILD_DIR / (
        f"Venera-Community-{version}-windows-{architecture}-installer.exe"
    )
    return archive, installer


def _remove_previous_packages(architecture: str, version: str) -> None:
    resolved_build_dir = BUILD_DIR.resolve()
    for package in _package_paths(architecture, version):
        if package.resolve().parent != resolved_build_dir:
            raise RuntimeError(f"Unsafe Windows package path: {package}")
        package.unlink(missing_ok=True)


def _remove_previous_flutter_output(architecture: str) -> None:
    release_dir = _release_dir(architecture)
    resolved_build_dir = BUILD_DIR.resolve()
    resolved_release_dir = release_dir.resolve()
    if resolved_build_dir not in resolved_release_dir.parents:
        raise RuntimeError(f"Unsafe Flutter output path: {release_dir}")
    if release_dir.exists():
        shutil.rmtree(release_dir)


def _validate_fresh_flutter_output(
    architecture: str,
    build_started_ns: int,
) -> Path:
    release_dir = _release_dir(architecture)
    executable = release_dir / "venera.exe"
    data_dir = release_dir / "data"
    if not executable.is_file() or not data_dir.is_dir():
        raise RuntimeError(f"Incomplete Flutter Windows output: {release_dir}")
    stale_paths = [
        path
        for path in (executable, data_dir)
        if path.stat().st_mtime_ns < build_started_ns
    ]
    if stale_paths:
        stale = ", ".join(str(path) for path in stale_paths)
        raise RuntimeError(f"Flutter Windows output was not freshly built: {stale}")
    return release_dir


def _validate_fresh_file(path: Path, started_ns: int, label: str) -> None:
    if (
        not path.is_file()
        or path.stat().st_size <= 0
        or path.stat().st_mtime_ns < started_ns
    ):
        raise RuntimeError(f"{label} was not freshly generated: {path}")


def _ensure_translation() -> Path:
    destination = BUILD_DIR / "ChineseSimplified.isl"
    if destination.is_file():
        content = destination.read_bytes()
        if hashlib.sha256(content).hexdigest() == TRANSLATION_SHA256:
            return destination

    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(TRANSLATION_URL, timeout=30) as response:
        content = response.read()
    if hashlib.sha256(content).hexdigest() != TRANSLATION_SHA256:
        raise RuntimeError("The Inno Setup translation checksum is invalid")
    destination.write_bytes(content)
    return destination


def _find_inno_compiler() -> str:
    executable = shutil.which("iscc")
    if executable:
        return executable
    candidates = (
        Path("C:/Program Files (x86)/Inno Setup 6/ISCC.exe"),
        Path("C:/Program Files/Inno Setup 6/ISCC.exe"),
    )
    for candidate in candidates:
        if candidate.is_file():
            return str(candidate)
    raise RuntimeError("Inno Setup 6 was not found (ISCC.exe)")


def _render_installer_script(architecture: str, version: str) -> Path:
    template_name = "build.iss" if architecture == "x64" else "build_arm64.iss"
    template = (WINDOWS_DIR / template_name).read_text(encoding="utf-8")
    translation = _ensure_translation()
    rendered = (
        template.replace("{{version}}", version)
        .replace("{{root_path}}", str(PROJECT_ROOT))
        .replace("{{translation_path}}", str(translation))
    )
    destination = BUILD_DIR / f"installer-{architecture}.iss"
    destination.write_text(rendered, encoding="utf-8")
    return destination


def _create_archive(architecture: str, version: str) -> Path:
    release_dir = _release_dir(architecture)
    executable = release_dir / "venera.exe"
    data_dir = release_dir / "data"
    if not executable.is_file() or not data_dir.is_dir():
        raise RuntimeError(f"Incomplete Flutter Windows output: {release_dir}")
    archive_base = BUILD_DIR / (
        f"Venera-Community-{version}-windows-{architecture}"
    )
    archive = Path(f"{archive_base}.zip")
    archive.unlink(missing_ok=True)
    shutil.make_archive(str(archive_base), "zip", root_dir=str(release_dir))
    return archive


def build(architecture: str) -> None:
    if architecture not in {"x64", "arm64"}:
        raise ValueError(f"Unsupported Windows architecture: {architecture}")

    _require_supported_host(architecture)
    version = _read_version()
    _remove_previous_packages(architecture, version)
    _remove_previous_flutter_output(architecture)
    build_started_ns = time.time_ns()
    _run("flutter", "build", "windows", "--release")
    _validate_fresh_flutter_output(architecture, build_started_ns)

    archive_started_ns = time.time_ns()
    archive = _create_archive(architecture, version)
    _validate_fresh_file(archive, archive_started_ns, "Windows archive")

    script = _render_installer_script(architecture, version)
    _, installer = _package_paths(architecture, version)
    try:
        installer_started_ns = time.time_ns()
        _run(_find_inno_compiler(), str(script))
        _validate_fresh_file(
            installer,
            installer_started_ns,
            "Windows installer",
        )
    finally:
        script.unlink(missing_ok=True)


if __name__ == "__main__":
    build("x64")
