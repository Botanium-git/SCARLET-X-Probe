#!/usr/bin/env python3
"""Download a verified private SCARLET-X-Probe GitHub Actions .deb.

Read-only downloader: does not install packages or change the X app.
Requires Python 3 and dpkg-deb; GitHub fine-grained PAT with Actions:read
for the private Botanium-git/SCARLET-X-Probe repository.

The token is prompted for each invocation (not stored, not passed on command
line or written to shell history). A future keychain integration may replace
the prompt. Never paste tokens into a chat or a logged command.
"""
import getpass
import io
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile

REPO = "Botanium-git/SCARLET-X-Probe"
API = "https://api.github.com"
WORKFLOW = "build.yml"
ARTIFACT = "SCARLET-X-Probe-roothide"
PACKAGE = "com.botanium.scarletxprobe"
ARCH = "iphoneos-arm64e"
MAX_ZIP = 100 * 1024 * 1024
MAX_DEB = 70 * 1024 * 1024
DEST = pathlib.Path.home() / "Documents" / "SXProbeUpdates"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        return None


def request(url, token=None):
    p = urllib.parse.urlparse(url)
    if p.scheme != "https" or p.username or p.password:
        raise ValueError("HTTPS URL without embedded credentials required")
    if token and p.hostname != "api.github.com":
        raise ValueError("Credential must never be sent outside api.github.com")
    headers = {"User-Agent": "SCARLET-X-Probe-private-updater",
               "Accept": "application/vnd.github+json",
               "X-GitHub-Api-Version": "2022-11-28"}
    if token:
        headers["Authorization"] = "Bearer " + token
    return urllib.request.Request(url, headers=headers)


def api_json(url, token):
    with urllib.request.build_opener(NoRedirect()).open(request(url, token), timeout=25) as response:
        if response.geturl() != url:
            raise ValueError("Unexpected API redirect")
        data = response.read(2 * 1024 * 1024 + 1)
        if len(data) > 2 * 1024 * 1024:
            raise ValueError("Unexpected oversized API response")
        return json.loads(data)


def get_artifact_url(token, run_id, artifact_id):
    url = API + "/repos/" + REPO + "/actions/artifacts/" + str(artifact_id) + "/zip"
    opener = urllib.request.build_opener(NoRedirect())
    try:
        opener.open(request(url, token), timeout=25)
    except urllib.error.HTTPError as e:
        if e.code not in (301, 302, 303, 307, 308):
            raise RuntimeError("Artifact API failed: HTTP " + str(e.code)) from None
        location = e.headers.get("Location", "")
    else:
        raise RuntimeError("Artifact endpoint did not redirect as expected")
    p = urllib.parse.urlparse(location)
    if p.scheme != "https" or not p.netloc or p.username or p.password:
        raise ValueError("Invalid signed artifact URL")
    # Request the short-lived signed artifact URL without GitHub credentials.
    return location


def download_zip(url):
    req = request(url)
    with urllib.request.urlopen(req, timeout=90) as response:
        data = response.read(MAX_ZIP + 1)
    if len(data) > MAX_ZIP:
        raise ValueError("Artifact ZIP too large")
    return data


def validated_deb(archive):
    with zipfile.ZipFile(io.BytesIO(archive)) as z:
        entries = [i for i in z.infolist() if not i.is_dir()]
        if len(entries) != 1:
            raise ValueError("Artifact must contain exactly one file")
        item = entries[0]
        if not re.fullmatch(r"[^/\\]+\.deb", item.filename) or item.file_size > MAX_DEB:
            raise ValueError("Artifact must contain one reasonably sized root-level .deb")
        if (item.external_attr >> 16) & 0o170000 not in (0, 0o100000):
            raise ValueError("Unexpected ZIP entry type")
        if item.compress_size == 0 or item.file_size / item.compress_size > 250:
            raise ValueError("Unexpected ZIP compression ratio")
        return z.read(item)


def metadata(deb_path):
    proc = subprocess.run(
        ["dpkg-deb", "-f", str(deb_path), "Package", "Version", "Architecture"],
        check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    fields = proc.stdout.splitlines()
    if len(fields) != 3:
        raise ValueError("Could not read expected deb control fields")
    name, version, architecture = fields
    if name != PACKAGE or architecture != ARCH or not re.fullmatch(r"[0-9A-Za-z.+:~\-]+", version):
        raise ValueError("Unexpected package identity or architecture")
    inventory = subprocess.run(
        ["dpkg-deb", "-c", str(deb_path)], check=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True).stdout
    expected = ("ScarletXProbe.dylib", "ScarletXProbe.plist")
    if any(x not in inventory for x in expected):
        raise ValueError("Missing expected tweak files")
    return version


def installed_version():
    proc = subprocess.run(
        ["dpkg-query", "-W", "-f=${Version}", PACKAGE],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    return proc.stdout.strip() if proc.returncode == 0 else None


def is_newer(new, old):
    if not old:
        return True
    return subprocess.run(
        ["dpkg", "--compare-versions", new, "gt", old]).returncode == 0


def main():
    for command in ("dpkg-deb", "dpkg-query", "dpkg"):
        if shutil.which(command) is None:
            sys.exit("Missing prerequisite: " + command)
    token = getpass.getpass("GitHub Actions-read token (not saved): ").strip()
    if not token:
        sys.exit("No token supplied. Nothing changed.")
    try:
        q = urllib.parse.urlencode({"branch": "develop", "event": "push",
                                   "status": "success", "per_page": 20})
        runs = api_json(API + "/repos/" + REPO + "/actions/workflows/" + WORKFLOW + "/runs?" + q, token)
        candidates = [x for x in runs.get("workflow_runs", [])
                      if x.get("head_branch") == "develop"
                      and x.get("event") == "push"
                      and x.get("status") == "completed"
                      and x.get("conclusion") == "success"
                      and x.get("path", "").endswith(WORKFLOW)]
        if not candidates:
            raise ValueError("No successful develop push build found")
        # Take latest successful run by workflow run id, not a PR build.
        run = max(candidates, key=lambda r: r["id"])
        result = api_json(API + "/repos/" + REPO + "/actions/runs/" + str(run["id"]) + "/artifacts?per_page=100", token)
        artifacts = [x for x in result.get("artifacts", [])
                     if x.get("name") == ARTIFACT
                     and not x.get("expired") and x.get("workflow_run", {}).get("id", run["id"]) == run["id"]]
        if len(artifacts) != 1:
            raise ValueError("Expected one available artifact for the selected build")
        art = artifacts[0]
        print("Verified build:", run["id"], "commit:", run.get("head_sha", "?"))
        url = get_artifact_url(token, run["id"], art["id"])
        deb = validated_deb(download_zip(url))
        with tempfile.TemporaryDirectory(prefix="sxprobe-") as tmp:
            temp_deb = pathlib.Path(tmp) / "probe.deb"
            temp_deb.write_bytes(deb)
            version = metadata(temp_deb)
            installed = installed_version()
            if not is_newer(version, installed):
                print("No newer version available. Installed:", installed or "none", "Build:", version)
                return
            DEST.mkdir(mode=0o700, parents=True, exist_ok=True)
            output = DEST / ("SCARLET-X-Probe_" + version + ".deb")
            if output.exists():
                print("Version already downloaded:", output)
                return
            temp_output = output.with_suffix(".part")
            temp_output.write_bytes(deb)
            temp_output.chmod(0o600)
            os.replace(temp_output, output)
            print("Validated download:", output)
            print("Installed:", installed or "none", "Available:", version)
            print("Open this .deb with Filza/Sileo, confirm install, then fully relaunch X.")
            print("A download is NOT proof of a successful install or runtime injection.")
    except (OSError, ValueError, RuntimeError, zipfile.BadZipFile, subprocess.CalledProcessError,
            urllib.error.URLError, KeyError) as exc:
        sys.exit("Update check failed; installed Probe unchanged: " + str(exc))


if __name__ == "__main__":
    main()
