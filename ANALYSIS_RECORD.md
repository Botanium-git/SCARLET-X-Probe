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

## 2026-10-27: Bio font constructor path verified

- X 12.38 matching runtime/static T1Twitter UUID already confirmed.
- T1Twitter address 0x245008 branches to Objective-C stub for `initWithAttributedString:`; the 0x24500C stack-frame offset is its return address.
- Earlier 0x244F58 calls `initWithString:font:alignment:lineBreakMode:paragraphSpacing:lineHeight:` and passes its return object to the model initializer.
- Before constructing that text, 0x244EF0 and 0x244F18 dispatch `UIFont xds_body` through a shared stub. At 0x244F4C, x24 holds the font supplied to the attributed string constructor. Runtime observed `xds_body` returns 14pt .SFUI-Regular with line height 16.70703125pt.
- Conclusion for this observed Bio path: `UIFont xds_body` supplies the font to attributed string construction. The *implementation of xds_body itself* and alternate Dynamic Type conditions remain to investigate. SXP stays 0.1.62.


## 2026-11-04: X 12.38 Bio Dynamic Type, expansion and rich-text diagnostics

- Source: original iPhone SE (320 × 568 pt), X `12.38`, runtime T1Twitter UUID `1BC82B24-A66B-3F8C-9D8D-36D2B90D1329`. SXP manual Bio snapshot logs saved to Google Drive; the observation is limited to the tested profile / device / text settings.
- `UIFont xds_body` was observed as `.SFUI-Regular`. Measured content-size category → point size / font line height: XS → 12 / 14.3203125pt; M → 14 / 16.70703125pt; L → 14 / 16.70703125pt; XL → 15 / 17.900pt; XXL → 17 / 20.287pt; XXXL → 20 / 23.8671875pt. S and other categories are not newly measured in this series; previous SX assumptions for them must not be treated as confirmed X 12.38 values.
- SXP `0.1.64` added read-only explicit/manual Bio state and attributed-text metadata diagnostics. Three updated-build samples: `SXProbe_2026-11-04_022858.json` (Drive ID `1W0Kcx5RbBgxQRPWJn4WJBvIywWS-w7Gh`), `022931.json` (`1U0CarFvkn91Lv1AXftBw8FaIyQ4Q1sVf`) and `023026.json` (`148NegY15WxiJsKI3vEHN0fgSuf9NF1_e`).
- The manual samples support Bio `_bioExpanded=false`, `_maxLines=4` and `_truncated=true` before expansion; `_bioExpanded=true`, `_maxLines=0` (unlimited) and `_truncated=false` after expansion. These are runtime-observed state fields, not solely visual inference. The expanded-button view's `hidden` flag alone did not reliably indicate the expansion state.
- Measured the same 112 UTF-16-unit Bio at XS: 4 lines / 71pt collapsed vs 6 lines / 104pt expanded; L: 4 lines / 80pt vs 6 lines / 119pt; XXXL: 4 lines / 109pt vs 8 lines / 214pt. Text layout is sensitive to font size and wrap width; do not assume the number of expanded lines is constant.
- `TFNLinkTextAttributeName` was observed in Bio attributed-text diagnostics; standard `NSLinkAttributeName` alone is insufficient to detect X links. Earlier SXP `0.1.64` captures logged attribute names and rough emoji candidate counts, not full link targets, actual tap behavior or definite emoji classification. In one comparison emoji candidates differed between collapsed and expanded states. Link types and destinations are **not yet verified**.
- New SXP `0.1.65` source change (commit `1c8ce610ff6d505e8827a8178d6d02eb9bf409b4`) adds `tfnLinkAttributeRuns`, `tfnLinkAttributeCharacters`, bounded `tfnLinkStyles` and `ordinaryStyles` with UTF-16 attribute-run position/length, font name/size/line height, foreground color components when resolvable, underline style and TFN link-marker Objective-C class only. **No Bio body, URL, user ID, or attribute value is serialized in these new fields**. Color may be unresolved for dynamic colors. These measurements describe attributed runs rather than confirmed tappable ranges.
- Package `control`, `SXProbeOwnVersion` display source and `Tweak.xm` version marker have now all been set to `0.1.65`. GitHub Actions build and on-device validation must be checked separately; do not mark v0.1.65 verified until results are observed.
- Do not change Scarlet X main UI on the strength of SXP source alone. Verify the new diagnostics in a real v0.1.65 log, then apply minimal isolated changes after confirming the intended behavior.


## 2026-11-04 02:59 JST: SXP 0.1.65 link styling confirmed on original SE

- New real-device log: `SXProbe_2026-11-04_025905.json` (Drive ID `1iqPuNLs7yHKz1GOtFKOPI6iWeB2taLM_`), X 12.38, content size XS, `xds_body=.SFUI-Regular` 12pt / line height 14.3203125pt. Three `profile-bio-rendered-metrics` snapshots: collapsed, collapsed, expanded.
- Collapsed observations: `bioExpanded=false`, `modelMaxLines=4`, `modelTruncated=true`, visible attributed text length 89 UTF-16 units, 4 lines, layout 292×71pt. Attributed runs: [0,82) text color approximately RGB (217,217,217); [82,83) no color/font reported; [83,89) blue RGB (29,155,240). **No `TFNLinkTextAttributeName` in the captured truncated attributed model**, even though the final six code units are blue. Do not infer a tappable link from color alone.
- Expanded observation: `bioExpanded=true`, `modelMaxLines=0`, `modelTruncated=false`, attributed text length 112 UTF-16 units, 6 lines, layout 292×104pt. Exactly one `TFNLinkTextAttributeName` run: UTF-16 range location 83, length 16; marker value class `TFNLinkTextAttributeProperties`; `.SFUI-Regular` 12pt / line height 14.3203125pt; foreground `#1D9BF0` (RGB 29,155,240, alpha 1). Ordinary text color `#D9D9D9` (RGB 217,217,217, alpha 1). No standard `NSLinkAttributeName` runs.
- Emoji candidate clusters: 0 in truncated attributed model, 3 expanded. These are approximate candidates, not a Unicode emoji rendering proof.
- The link's UTF-16 styling range and color are now **runtime-confirmed**, but interaction/tap semantics, URL destination and generalized rules across profiles remain unverified. Avoid treating the collapsed trailing blue token as equivalent to the full expanded link.
- SXP 0.1.65 instrumentation was effective on-device; no SX UI changes have been made from this log. The extra diagnostics fields capture attribute-run metrics and the link marker's *class*, not marker content or target. Earlier general SXP view snapshots may separately include accessibility text; this entry refers only to the v0.1.65 added fields.


## 2026-11-04: SX native profile Bio audit and targeted font update

- Audited Scarlet X `develop` at `d8597c600dfd41b95c63bee0af53461a0b6af31d`, including `UI/NativeProfileViewController.m` and `UI/NativeProfilePolish230.m`.
- Confirmed SX Bio currently uses a `UILabel` with `numberOfLines=0` and plain `text=bio` in the base controller, i.e. no four-line truncation/expand UI or Bio-specific URL range treatment in those audited methods. Official X 12.38 observed default `modelMaxLines=4`, expanded `modelMaxLines=0`, and `TFNLinkTextAttributeName` for an expanded URL segment. This is a code/measurement difference, **not** verification of an SX on-device defect.
- SX profile polish code set Bio font XS 12, S 13, and all other categories 14pt; SXP measured X 12.38 Bio XS 12, M/L 14, XL 15, XXL 17 and XXXL 20pt.
- Applied *only the confirmed XL/XXL/XXXL point-size correction* in SX `UI/NativeProfilePolish230.m` (commit `fe8c10e1a825e1fc18fd8e5edd0f4cd1400b5a09`); bumped `Resources/Info.plist` to SX v1.4.170 build 352 (commit `7f5a34be6ef84c86389ba905962133829ec7aacf`). S=13 and bold-text handling were left unchanged as not newly verified in X 12.38; accessibility categories above XXXL remain unmeasured.
- Do not silently add link tapping based solely on attributed color/range, or implement expansion without accounting for profile rebuild lifecycle and the layout beneath Bio. Separate these changes into independently testable subsequent SX versions. GitHub Actions success, if observed, proves package build only; actual iPhone behavior requires user validation.
