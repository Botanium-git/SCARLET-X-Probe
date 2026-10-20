# SCARLET-X-Probe

Read-only runtime diagnostics for official X iOS, developed separately from SCARLET-X.

**Status:** Experimental non-hooking panel build. The X-native sidebar button is NOT implemented yet; on-device validation is required. No X user content, authentication information, or network traffic is collected.

- Device: iPhone SE (1st generation), iOS 15.8.3, RootHide Bootstrap.
- Build: GitHub Actions, roothide/theos, `THEOS_PACKAGE_SCHEME=roothide`.
- Output: roothide .deb in workflow artifact.

Do not enable X in Bootstrap App List until a build has succeeded and the installed App Store X version has been verified. Installing or injecting any tweak may affect stability or trigger application integrity protections.

See `docs/SAFETY.md` for operating constraints.

## Experimental panel entry

After the user explicitly enables X injection and installs a verified RootHide package, tap the temporary **SX Probe** button at the upper-left of the X window to open the diagnostic panel. It can record only version and class-presence metadata, export it to a local JSON share sheet, and clear it. No Drive authentication, layout hooks or actual side-menu modification are present yet. Do not infer actual runtime stability from a successful build.


## v0.1.2 injection diagnostic

The Tweak.xm constructor, independent of the temporary UIKit button, writes a short `SCARLET-X-Probe-loaded.txt` marker to X's `NSTemporaryDirectory()` and emits a matching `NSLog` message when loaded into `com.atebits.Tweetie2`. The marker records only Probe version and bundle ID, no account or timeline data. This file resides in X's sandbox and might require sandbox-aware file access or device logs to inspect; **absence of a visible SX Probe button alone does not reveal whether the marker exists**. Do not reset or reinstall official X to obtain it.


## v0.1.3 persistent injection marker check

After installing v0.1.3 and relaunching X, open **Filza → Apps → X (Twitter) → Documents**, and check for `SCARLET-X-Probe-loaded.txt` (not `tmp`). Its presence and the `0.1.3` version inside positively establish execution of the tweak constructor. Absence is inconclusive (the dylib may not have loaded, its guard may have returned, or the file write may have failed); it is **not proof of injection failure**. No credentials or post content are written. Do not delete or reinstall official X to inspect it.
