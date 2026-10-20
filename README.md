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


## RootHide injection-chain investigation (2026-10-21)

Evidence: public RootHide source `roothide/Bootstrap` `Bootstrap/AppEnabler.m` and submodule `roothide/Bootstrap-basebin` `bootstrap/bootstrap.c`, checked against the existing Probe 0.1.3 package inventory and Mach-O CI logs (successful run 39457815941).

- `enableForApp` for an ordinary installed app creates a `.jbroot` symlink in the application bundle and refreshes registration with `uicache`; the enabled switch is **not** proof that a custom tweak was loaded.
- The public `bootstrap.c` uses several conditional guards (launch-job parent, coalition/process eligibility, process-specific exclusions, and `DISABLE_TWEAKS`, `_SafeMode`, `_MSSafeMode`).
- The relevant **TweakLoader invocation** is guarded by existence of `jbroot("/var/mobile/.tweakenabled")`, then `jbroot("/usr/lib/TweakLoader.dylib")`; only then does it call `dlopen(tweakloader, RTLD_NOW)`. This is a confirmed **source-level** pathway and does not prove the user's installed Bootstrap 2.2.1 binary has identical code.
- The earlier `dpkg -l` search for `ellekit|substrate|libhooker|roothide` and `/var/jb/usr/lib` substring scans cannot establish TweakLoader presence/absence. `com.roothide.patchloader` is not by itself evidence that the particular Probe library loaded.
- The CI run confirmed `ScarletXProbe.dylib` and `ScarletXProbe.plist` in `Library/MobileSubstrate/DynamicLibraries`, ARM64 native dylib and RootHide-style install-name. These are build/package findings only.
- Device reports: installed Probe 0.1.3, X enabled, X launches, no visible button, no `Documents/SCARLET-X-Probe-loaded.txt`. This does **not** yet distinguish an absent/failed TweakLoader, filter skip, constructor guard, or marker write failure.

**Next device check, read-only, without further toggling, reinstalling or respringing:** use NewTerm `ls -l /var/jb/usr/lib/TweakLoader.dylib` and `ls -la /var/jb/var/mobile/.tweakenabled`, separately; inspect exact errors. RootHide's jbroot location/symlinks may differ, so a negative result is not definitive without confirming current root mappings. Do not install ElleKit based on its name alone.

Source:
- https://github.com/roothide/Bootstrap/blob/main/Bootstrap/AppEnabler.m
- https://github.com/roothide/Bootstrap-basebin/blob/main/bootstrap/bootstrap.c

No app binary, package version, main branch or device data modifications in this investigation.
