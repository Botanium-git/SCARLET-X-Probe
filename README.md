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


## PatchLoader 0.0.8 versus TweakLoader — source verified (2026-10-21)

Official sources:
- `roothide/PatchLoader` `PatchLoader.c`, `control`, `Makefile`
  https://github.com/roothide/PatchLoader/blob/main/PatchLoader.c
- `roothide/Bootstrap-basebin` `bootstrap/bootstrap.c`
  https://github.com/roothide/Bootstrap-basebin/blob/main/bootstrap/bootstrap.c

The device-reported `com.roothide.patchloader 0.0.8` can now be mapped to an **exact upstream package manifest** (`control` says version `0.0.8`, description "RootHide Dynamic Patches Loader"). Its `Makefile` compiles library `roothidepatch` into `/usr/lib`, i.e. `roothidepatch.dylib`, not `TweakLoader.dylib`.

Its `image_load_handler` constructs the filename `<loaded Mach-O path>.roothidepatch`, verifies it exists with `lstat`, then calls `dlopen(patcher, RTLD_NOW)` and resolves `InitPatches`. Its constructor walks loaded Mach-O images outside dyld shared cache and registers callback for newly loaded images. This mechanism loads **per-image RootHide patch companions**, not the ordinary `/Library/MobileSubstrate/DynamicLibraries/ScarletXProbe.dylib` with the `ScarletXProbe.plist` filter.

The `bootstrap.c` call `dlopen(jbroot("/usr/lib/roothidepatch.dylib"), RTLD_NOW)` is **separate** from the later **TweakLoader** conditional path `if (access(jbroot("/var/mobile/.tweakenabled"), F_OK)==0) { if (access(jbroot("/usr/lib/TweakLoader.dylib"), F_OK)==0) dlopen(tweakloader, RTLD_NOW); }`, subject to earlier guards. The fact that PatchLoader 0.0.8 is installed and the application launches is **not evidence** that a generic tweak loader exists, executes, discovers the Probe plist, or loads Probe.

Confirmed by upstream source and device-reported package version. Still unconfirmed on device: `TweakLoader.dylib` presence, `.tweakenabled` presence, actual X launch-time loader path, and Probe dylib in dyld image list. User is away from SE: **no device actions requested**. Do not install ElleKit, toggle Bootstrap settings, or bump Probe version on this finding alone.

Next static study: identify the separate upstream TweakLoader/ElleKit injection package responsible for reading MobileSubstrate filters in RootHide Bootstrap; map exact package names and loader dependency, without assuming a current device state.


## Follow-up: how a TweakLoader path can be supplied (2026-10-21)

External implementation reference: `tealbathingsuit/ellekit` `Makefile` (https://github.com/tealbathingsuit/ellekit/blob/main/Makefile) installs a link `/usr/lib/TweakLoader.dylib` → `/usr/lib/ellekit/libinjector.dylib`; it also creates a MobileSubstrate DynamicLibraries ↔ TweakInject link in its packaging. This is **one documented ElleKit packaging implementation**, **not verification of the specific RootHide build or of what is present on the user's SE**. The previously reported `dpkg -l | grep -Ei 'ellekit|substitute|substrate|libhooker|roothide'` yielded no ElleKit package. It remains possible for a different package to supply TweakLoader, and naming / repository compatibility must be checked before recommending installation.

Source-backed chain now: Bootstrap app enablement → AppEnabler adds `.jbroot` → `bootstrap.dylib` guarded access to `.tweakenabled` and `TweakLoader.dylib` → a loader implementation (not yet inspected in the deployed build) would decide whether to load the Probe .plist/.dylib. Separately, `roothidepatch.dylib` from PatchLoader 0.0.8 handles `*.roothidepatch` sidecars, not normal tweak filters. Thus a **missing TweakLoader implementation is a specific hypothesis worth testing later**, not a diagnosed fact.

No changes to Probe code, package version, or user device. Avoid suggesting arbitrary ElleKit installation until exact installed path / compatible RootHide package is known.
