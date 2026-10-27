# Scarlet X Probe — Binary / Bio typography analysis record

## 2026-10-27: Official X updated on original iPhone SE

- User updated the original X installation on the original iPhone SE and provided a decrypted IPA and the extracted main `Twitter` executable.
- Supplied IPA: `com.atebits.Tweetie2_12.38_decrypted.ipa`; reported version `12.38`, build `24`. The separately supplied main executable `Twitter_12.38_decrypted` corresponds to the IPA's main executable (checked in the analysis session).
- Supplied `T1Twitter_12.38.bin`: its SHA-256 agrees exactly with the `Payload/Twitter.app/Frameworks/T1Twitter.framework/T1Twitter` member in that IPA. Local Mach-O UUID: `1BC82B24-A66B-3F8C-9D8D-36D2B90D1329`.
- Older SXP runtime diagnostic was from X `12.35`; do **not** reuse its image-relative call addresses against X `12.38` without revalidation.
- X 12.35 Bio model creation call stack included `T1Twitter + 0x248A54` (return address, not necessarily the font-setting instruction).
- New diagnostic `SXProbe_2026-10-27_052644.json` (Drive file ID `1_qJxsRj1In85ljhrsCZ2WA3jh-d9lJxm`) reports X `12.38`, build `24`. On both observed Bio setter invocations, the `TFNAttributedTextModel initWithAttributedString:` incoming string is `.SFUI-Regular`, `14pt`, line height `16.70703125pt`. Shared image-relative return address in the two stack samples: `T1Twitter + 0x24500C`. Other frames: first call `0x2426A8`, second `0x242430`.
- **Critical unresolved discrepancy:** Static disassembly of the IPA's `T1Twitter_12.38.bin` at `0x24500C` is a `mov x27, x0` inside a symbol identified by local tools as `_T1CreateAppNavigationTabViewWithAXLabelAndDisplaySize`, not a plausible immediate return address of the observed Bio initializer. The preceding instruction at `0x245008` is a branch/call. Matching application version/build and matching IPA/extracted framework are not evidence that the installed SE framework is byte-identical. Check the **installed runtime T1Twitter Mach-O UUID** (and loaded image name/base) on the SE before equating dynamic `dladdr` offsets with local file offsets. Also validate whether return-address adjustment and Mach-O address mapping can account for the discrepancy.
- Status: Bio `14pt` generation pathway remains **unresolved**. Do not label the address as confirmed font-setting code.
- Scope: SXP diagnostic and binary analysis only; do not modify Scarlet X application UI based on an unproven binary correspondence.

## Artifact roles

- `Twitter_12.38_decrypted`: app **main executable**. Useful for app entry points, startup and links to framework code, but the profile Bio implementation currently appears to be in the `T1Twitter` framework, which requires analysis of `T1Twitter.framework/T1Twitter` itself.
- `T1Twitter_12.38.bin`: framework executable; direct target for disassembly of X's profile methods, provided its build UUID is matched against the running SE instance.

## 2026-10-27 follow-up: static call-site check

- Reparsed the latest X 12.38 SXP log. The model initializer stack recorded `T1Twitter+0x24500C` for all four captured constructor entries (two Bio setter invocations, with two initializer selectors each). Additional observed offsets were `0x2426A8` in the first setter call and `0x242430` in the second.
- `llvm-objdump` on supplied `T1Twitter_12.38.bin`: `0x245008: bl 0x145B4A0`; `0x24500C: mov x27, x0`. The address is a valid post-`bl` return location but its identity as the Bio constructor caller is **not verified**. The symbol labeling shown for this region is `_T1CreateAppNavigationTabViewWithAXLabelAndDisplaySize`; do not infer the actual enclosing function from that broad symbol alone.
- Mach-O `__TEXT` segment has `vmaddr=0`, `fileoff=0`, `__text` begins at `0x4000`. Offset `0x24500C` can be inspected directly as a VM address in this local image. Yet static/runtime binary identity is not proven without installed `T1Twitter` UUID or equivalent hash.
- Attempted to add safe runtime Mach-O UUID diagnostic, but the tool operation was blocked; **no UUID collection was installed** and SXP remains `0.1.61`. A temporary no-op metadata change was reverted (latest `ProbePanel.m` content SHA again `fead45622dee0d9d657b00283d0f6c233e904bf1`). No new diagnostic binary has been built or validated.

## 2026-10-27 21:44 JST: SXP 0.1.62 runtime UUID confirmed

- Latest Drive diagnostic: `SXProbe_2026-10-27_214410.json` (file ID `1bXnkfTlx4gV_UGliz9kvMTUfpMu0cQGT`), X `12.38` build `24`.
- New `profile-bio-runtime-uuid` event succeeded: running `T1Twitter` UUID **`1BC82B24-A66B-3F8C-9D8D-36D2B90D1329`**.
- This matches the supplied IPA's extracted `T1Twitter` Mach-O UUID exactly. The former *build-identity* uncertainty is resolved. UUID matching does not guarantee byte-for-byte equality, but establishes matching Mach-O build identity.
- Four Bio model initializer log events still show `.SFUI-Regular` 14pt, line height 16.70703125pt, and all share runtime `T1Twitter+0x24500C` in the stack trace.
- With the exact matching Mach-O UUID, disassembly at `0x245008` is `bl 0x145B4A0`; `0x24500C` is `mov x27, x0`. This is consistent with a return address immediately after a call, but the target's actual semantic meaning is **not yet established**. Earlier interpretation that the call site was unrelated based only on nearest symbol label may be unreliable; follow its target and relevant ObjC method address ranges before concluding.
- No new probe update in response to this log; SXP remains 0.1.62.
