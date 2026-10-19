# SCARLET-X-Probe

Read-only runtime diagnostics for official X iOS, developed separately from SCARLET-X.

**Status:** Initial non-hooking bootstrap probe. No X user content, authentication information, or network traffic is collected.

- Device: iPhone SE (1st generation), iOS 15.8.3, RootHide Bootstrap.
- Build: GitHub Actions, roothide/theos, `THEOS_PACKAGE_SCHEME=roothide`.
- Output: roothide .deb in workflow artifact.

Do not enable X in Bootstrap App List until a build has succeeded and the installed App Store X version has been verified. Installing or injecting any tweak may affect stability or trigger application integrity protections.

See `docs/SAFETY.md` for operating constraints.
