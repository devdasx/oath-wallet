# Oath Wallet brand assets

`Oath Brand Kit/` is the approved, unmodified source kit moved from Downloads on
2026-09-23. Its interlocking-ring artwork replaces the earlier envelope identity.

## App integration

- `AppIcon`: supplied light, dark, and tinted 1024 px icons. Run
  `swift Scripts/prepare_app_store_icons.swift` to install them. Only the unused
  alpha channel is removed; artwork, proportions, and colors are preserved.
- `OnboardingSplashLogo`: supplied light/dark icons for onboarding, privacy covers,
  and PDF transaction reports.
- `BrandLogo`: supplied transparent, multicolor light/dark marks for receive screens
  and shared receive cards. Render these with their original colors.
- `WalletIdentityMark`: supplied solid white mark for user-colored wallet tiles
  and the onboarding coin illustration. Tile clear space
  is applied by the shared component, not baked into the source artwork.
- Receive QR centers use the full-color light `OnboardingSplashLogo` in a rounded
  square, with a small clear border. Keep the light icon in both app appearances.

Asset names are centralized in `EVMWallet/AppBrandArtwork.swift`. Appearance variants
are selected by the asset catalog. Keep the supplied brand-kit files unchanged.
The kit is a project design source, not an extra bundled app resource.

Run `python3 Scripts/validate_oath_branding.py` to verify artwork against the kit,
localized product names, all icon variants, and stable wallet identifiers.
The source checksums and retired-artwork location are recorded in
`Reports/oath-branding-2026-09-23/`.
