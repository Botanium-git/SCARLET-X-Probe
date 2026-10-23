# Private Probe updater — stage 1

The private updater is `tools/private_probe_update.py` on the `develop` branch.
This is a **download-and-handoff** utility, not a privileged installer and not yet a one-tap shortcut.

## Why
Keep both source code and .deb private; don't host a public APT repository. Reuse successful push builds from the existing private GitHub Actions workflow.

## SE prerequisites (not yet checked on the device)
- Python 3, `dpkg-deb`, `dpkg-query`, `dpkg`.
- Network access to `api.github.com` and temporary GitHub artifact delivery URLs.
- A GitHub fine-grained personal access token scoped to *only* `Botanium-git/SCARLET-X-Probe` with Actions read and Metadata read. Use an expiration and revoke when no longer needed.
- The script must be made available locally from this private repository (do not publish it together with secrets).

## Usage
Run `python3 /path/to/private_probe_update.py` from NewTerm. Paste the token only into the script's hidden prompt; **not** into the command line, URL, Shortcuts text action, chat or logs.

It checks the most recent successful `develop` push run of `build.yml`, obtains exactly one unexpired named artifact, downloads the ZIP with no credential header on the signed redirect target, checks that there is one ordinary .deb, checks package identity `com.botanium.scarletxprobe`, architecture `iphoneos-arm64e`, presence of tweak .dylib/.plist and strict version increase (using dpkg), and writes the verified deb with restrictive permissions under `~/Documents/SXProbeUpdates/`.

Open the resulting package in Filza and hand off to Sileo for explicit installation approval. Fully exit and relaunch official X, then check SX panel / exported diagnostic JSON. **Download, installation and runtime success are three separate checkpoints.** The updater does not run `dpkg -i`, kill X or alter the installed package.

## Important limitations
- A prompt for the token is required at *every* run currently. No credential persistence or home-screen button exists yet.
- The script requires Python 3 on SE and has not been tested there.
- The Actions artifact retention currently is 14 days; expired artifacts are not available.
- GitHub Actions build and actual SE runtime behavior for Probe v0.1.12 are not confirmed by this script.
- Package maintainer scripts are not automatically executed by the downloader; review the deb before confirming installation. A valid GitHub artifact is not equivalent to a signed trusted binary.
- The next stage is a secure keychain/Shortcut front end after these prerequisites are verified, without exposing a root install endpoint.

## Development state (2026-10-23)
- `tools/private_probe_update.py` created on develop in commit `e91f00001ccff6959d9be0901e3e0b4cda96d2ab`.
- Credentialed redirect hardening in commit `ec28df51c546b0f51b2a02b75d9f16048c0150e5`.
- Main branch and installed SE Probe unchanged.
