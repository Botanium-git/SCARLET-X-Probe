# Safety and validation protocol

1. Keep the App Store X installation and login session intact. Never delete, re-sign, export account tokens, or replace it with a patched IPA.
2. Record the actual installed X version **before** enabling injection. The available v12.25 static analysis may not match the build running on iOS 15.8.3.
3. This initial probe is **non-hooking**: it emits only package version and class-presence diagnostics via NSLog. It cannot yet measure font sizes or layout metrics.
4. Build success is not proof of injection, startup safety, or correct measurements. Validate on the device.
5. Keep Bootstrap's X toggle **OFF** until the packaged artifact is verified and the user explicitly decides to test.
6. Disable X in Bootstrap App List to undo injection if X becomes unstable; troubleshoot without deleting the App Store app.
7. Do not publish user content, private logs, cookies, passwords, authentication headers, or personally identifying information.
8. Runtime probing can still affect App Store X stability or account integrity checks. Avoid assumptions.
