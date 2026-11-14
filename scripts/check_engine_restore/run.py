#!/usr/bin/env python3
"""Restore one pinned tab in Chromium, temporarily in WebKit, then in Chromium again."""
import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import signal
import subprocess
import sys
import tempfile
import time
import uuid

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
FIXTURE = "<!doctype html><meta charset=utf-8><title>Arch offline restore</title><p>Local renderer sentinel</p>"


def make_probe(root, frameworks, bundle_id):
    products = Path(subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=ROOT, text=True).strip())
    libraries = ["Browsing", "ARCHEngineChromium", "ARCHEngineWebKit"]
    if any(not (products / f"lib{name}.a").is_file() for name in libraries):
        sys.exit("Build the debug library products with swift build in this checkout first.")
    contents = root / "RestoreCheck.app/Contents"
    executable = contents / "MacOS/RestoreCheck"
    executable.parent.mkdir(parents=True)

    # SwiftPM exports these three static products with their transitive dependencies.
    # Give their Swift interfaces access to the bridge through its public header.
    (root / "CEFBridge.h").symlink_to(ROOT / "Packages/ARCHKit/Sources/CEFBridge/include/CEFBridge.h")
    module_map = root / "module.modulemap"
    module_map.write_text('module CEFBridge { umbrella header "CEFBridge.h"\n export * }\n')
    subprocess.run(["swiftc", "-swift-version", "5", "-target", f"{platform.machine()}-apple-macos14.0",
                    "-I", products, "-L", products, "-Xcc", f"-fmodule-map-file={module_map}",
                    HERE / "main.swift", *[f"-l{name}" for name in libraries],
                    "-lbsm", "-lsqlite3", "-lc++", "-framework", "IOSurface", "-o", executable], check=True)
    subprocess.run(["ditto", frameworks, contents / "Frameworks"], check=True)
    with (contents / "Info.plist").open("wb") as file:
        plistlib.dump(dict(CFBundleExecutable=executable.name, CFBundleName="Arch Engine Restore Check",
                           CFBundlePackageType="APPL", CFBundleIdentifier=bundle_id, LSBackgroundOnly=True), file)
    subprocess.run(["codesign", "--force", "--sign", "-", contents.parent], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", contents.parent], check=True)
    return executable


def run_phase(executable, root, bundle_id, phase, interrupt):
    home = str(root / "home")
    env = dict(PATH=os.defpath, HOME=home, CFFIXED_USER_HOME=home, TMPDIR=str(root / "temp") + "/",
               LANG="en_US.UTF-8", ARCH_RESTORE_BUNDLE=bundle_id, ARCH_RESTORE_PHASE=str(phase),
               ARCH_RESTORE_INTERRUPT="1" if interrupt else "0")
    args = [executable, "--use-mock-keychain", "--disable-background-networking", "--disable-component-update",
            "--disable-sync", "--disable-domain-reliability", "--no-pings", "--host-resolver-rules=MAP * ~NOTFOUND",
            "--proxy-server=http://127.0.0.1:9"]
    process = subprocess.Popen(args, cwd=root, env=env, start_new_session=True)
    result_file = root / f"result-{phase}.json"
    try:
        if interrupt and phase == 2:
            deadline = time.monotonic() + 40
            while not result_file.is_file():
                if process.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError("No scheduled-save checkpoint from the temporary WebKit process.")
                time.sleep(0.05)
            ready = json.loads(result_file.read_text())
            if ready != {"checkpoint": "rename-saved", "id": (root / "first-id").read_text(), "active": "webKit"}:
                raise RuntimeError("Unexpected scheduled-save checkpoint.")
            os.killpg(process.pid, signal.SIGKILL)
            if process.wait(timeout=10) != -signal.SIGKILL:
                raise RuntimeError("The checkpointed process did not exit from SIGKILL.")
            print(f"Phase 2 · {ready['id']} · WebKit · killed after scheduled rename save, before quit", flush=True)
            return ready
        status = process.wait(timeout=40)
    except BaseException:
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        raise
    if status:
        sys.exit(f"Engine restore phase {phase} failed (exit {status}).")
    return json.loads(result_file.read_text())


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     epilog="Build this checkout with swift build and ./scripts/bundle_app.sh first.")
    parser.add_argument("--app", type=Path, default=ROOT / "build/Arch.app",
                        help="a bundled Arch.app built from this checkout (default: build/Arch.app)")
    parser.add_argument("--interrupt", action="store_true",
                        help="kill the second launch after its scheduled rename save and verify recovery on the third")
    options = parser.parse_args()
    app = options.app.resolve()
    frameworks = app / "Contents/Frameworks"
    if not (frameworks / "Arch Helper.app/Contents/MacOS/Arch Helper").is_file():
        parser.error("missing CEF helpers; run swift build and ./scripts/bundle_app.sh, or supply --app")

    with tempfile.TemporaryDirectory(prefix="arch-engine-restore-") as scratch:
        root = Path(scratch).resolve()
        for subdir in ["temp", "profile", "home/Library/Application Support", "home/Library/Caches",
                       "home/Library/Preferences", "home/Library/WebKit"]:
            (root / subdir).mkdir(parents=True)
        # The first launch creates a named Chromium profile through the alias; the third opens that existing profile.
        (root / "profile-alias").symlink_to(root / "profile", target_is_directory=True)
        (root / "session-key").write_bytes(os.urandom(32))
        (root / "fixture.html").write_text(FIXTURE, encoding="utf-8")
        bundle_id = "xyz.taeyoon.arch.engine-restore-check." + uuid.uuid4().hex
        executable = make_probe(root, frameworks, bundle_id)
        results = [run_phase(executable, root, bundle_id, phase, options.interrupt) for phase in (1, 2, 3)]
        if len({row["id"] for row in results}) != 1 or [row["active"] for row in results] != ["chromium", "webKit", "chromium"]:
            sys.exit("The three launches did not restore the same tab with the expected renderers.")
        print(f"Verified pinned tab {results[0]['id']} across three launches. The saved engine stayed Chromium.")
        if options.interrupt:
            print("The third launch restored the committed rename after SIGKILL. Edits awaiting a save are outside this check.")


if __name__ == "__main__":
    main()
