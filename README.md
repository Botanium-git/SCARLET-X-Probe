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
