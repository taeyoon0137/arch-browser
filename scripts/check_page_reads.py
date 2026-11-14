#!/usr/bin/env python3
"""Run the real WebKit and Chromium page-read checks against local fixtures."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = """<!doctype html><title>Arch page read</title>
<p>Intro text</p><input value="Field value"><textarea>Textarea value</textarea>
<div contenteditable>My draft reply</div><p>Middle text</p><div id="host"></div>
<p>Outro text</p><script>document.getElementById('host').attachShadow({mode: 'open'}).innerHTML =
    '<div contenteditable>Shadow draft</div>';</script>"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / "build/Arch.app",
                        help="an Arch.app built from this checkout (default: build/Arch.app)")
    source = parser.parse_args().app.resolve() / "Contents/Frameworks"
    if not (source / "Arch Helper.app/Contents/MacOS/Arch Helper").is_file():
        parser.error("build the app with swift build and ./scripts/bundle_app.sh first")

    webkit = subprocess.run(["swift", "test", "--filter", "WebKitReadableContentTests"], cwd=ROOT,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    print(webkit.stdout, end="", flush=True)
    webkit.check_returncode()
    # SwiftPM can exit successfully when a filter matches no tests.
    if "Suite WebKitReadableContentTests passed" not in webkit.stdout:
        sys.exit("SwiftPM did not report a passing WebKitReadableContentTests suite.")
    subprocess.run(["swift", "build", "--product", "ARCHEngineReadCheck"], cwd=ROOT, check=True)
    bin_path = subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=ROOT, text=True).strip()
    # Sign only this fixture bundle. Rendering, helper signing, and the sandbox follow the source bundle.
    with tempfile.TemporaryDirectory(prefix="arch-page-read-") as scratch:
        root = Path(scratch)
        contents = root / "Arch.app/Contents"
        (contents / "MacOS").mkdir(parents=True)
        (root / "fixture.html").write_text(FIXTURE, encoding="utf-8")
        shutil.copy2(Path(bin_path) / "ARCHEngineReadCheck", contents / "MacOS/Arch")
        subprocess.run(["ditto", source, contents / "Frameworks"], check=True)
        with (contents / "Info.plist").open("wb") as file:
            plistlib.dump(dict(CFBundleExecutable="Arch", CFBundleName="Arch", CFBundlePackageType="APPL",
                               CFBundleIdentifier="xyz.taeyoon.arch.engine-read-check", LSUIElement=True), file)
        subprocess.run(["codesign", "--force", "--sign", "-", contents.parent], check=True)
        process = subprocess.Popen([contents / "MacOS/Arch", "--use-mock-keychain"], start_new_session=True)
        try:
            status = process.wait(timeout=35)
        except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            if isinstance(error, subprocess.TimeoutExpired):
                sys.exit("Chromium did not finish the page read check within 35 seconds.")
            raise
        if status:
            sys.exit(f"Chromium page read check exited with status {status}")


if __name__ == "__main__":
    main()
