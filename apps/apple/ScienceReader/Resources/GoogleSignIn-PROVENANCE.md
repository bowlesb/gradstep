# Google sign-in resources

Retrieved 2026-10-04 from Google's primary distribution sources. These resources
are used only by `NativeGoogleAuthenticationButton`; no Google authentication SDK
or system font installation is required.

## Button and mark

The [Google Identity branding guide](https://developers.google.com/identity/branding-guidelines)
(updated 2026-07-07) permits custom sign-in controls that follow its brand rules.
The control uses the light treatment in both appearances: white fill, an inside
`#747775` border, `#1F1F1F` Google Sans Medium text, the standard 20-point mark,
and iOS 16/12/16-point horizontal spacing. The target is at least 50 points tall
to match the adjacent Apple control. Text scales with Dynamic Type and can wrap;
the mark keeps its size, colors and aspect ratio.

`Assets.xcassets/GoogleSignInMark.imageset/GoogleSignInMark.png` is the **unaltered**
standard gradient G linked by that guide:

- Source: <https://developers.google.com/static/identity/images/g-logo.png>
- Bytes: 33,661; PNG dimensions: 200 × 204.
- SHA-256: `d1ce9c2af0b10a7333abc99bc706f9a6a199e5b65bf3e3009624f076b8638e6a`.

The Google mark is a Google brand feature, used under the linked sign-in branding
guidance; it is not covered by the font's open-source license. Do not redraw,
recolor or substitute an older mark. This notice does not claim Google app
verification, provider configuration or successful live sign-in.

## Font

`GoogleSans-Medium.ttf` is the unmodified static Medium face from the official
[Google Fonts Google Sans v14.000 release](https://github.com/googlefonts/googlesans/releases/tag/v14.000):

- Archive: <https://github.com/googlefonts/googlesans/releases/download/v14.000/GoogleSans-v14.000.zip>
- Archive member: `build/GoogleSans/static/GoogleSans-Medium.ttf`.
- Archive SHA-256: `d338f0e74f5eabead86a85b87edf4cc50cd6561196dbe173d1db4139e95b3ca7`.
- Font bytes: 2,232,604; SHA-256: `1c87b72912ef81b48ab4852976f3d5bf75c7205e0a58a97ffca947d171c722a7`.
- PostScript name: `GoogleSans-Medium`; OS/2 weight: 500; version: `14.000;[08f2ac800]`.
- Copyright embedded in the font: **Copyright 2025 The Google Sans Project Authors
  (github.com/googlefonts/googlesans)**.

Both the font's name table and macOS CoreText's file descriptor confirm that
PostScript name. `UIAppFonts` registers the bundled file for iOS; the control
requests that name without substituting a different font. Device registration
and final layout remain part of the app's build/UI verification.

The font's embedded license identifies SIL Open Font License 1.1. Its official
[release-tag license](https://raw.githubusercontent.com/googlefonts/googlesans/v14.000/OFL.txt)
is preserved verbatim as `GoogleSans-OFL.txt` (SHA-256
`831b6e041705873c3e6efb18c4c96202bc41c8be42a456d3d26c47abf14816d0`).
OFL permits bundling the font with software when its copyright notice and license
are retained. That license file also retains the upstream Google Sans Flex
copyright notice; the static face's own copyright is reproduced above and remains
embedded in the unchanged font.
