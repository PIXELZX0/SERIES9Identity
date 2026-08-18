# Series9IdentityRenderer

| Item | Value |
|------|-------|
| File | [`src/Series9IdentityRenderer.sol`](../src/Series9IdentityRenderer.sol) |
| Inheritance | None |
| Deployment | Not deployed separately; `Series9Identity` inherits it |
| State | Stateless; all renderer functions are `internal pure` |

## Overview

`Series9IdentityRenderer` creates the `tokenURI(tokenId)` response used by
`Series9Identity`. It builds a static premium identity card, embeds the SVG as
`data:image/svg+xml;base64,...`, then wraps the JSON in
`data:application/json;base64,...`.

The active renderer does not read `AvatarConfig`, hue, or saturation. The
legacy `AvatarConfig` struct remains only because the upgradeable identity
contract must preserve the historical `avatarConfig` mapping and setter ABI.

## Entry Point

```solidity
_renderTokenURI(
    tokenId,
    name,
    bio,
    entityType,
    verified,
    registeredAt,
    reputationScore,
    handle,
    imageUrl
)
```

`Series9Identity.tokenURI` passes the profile fields, the effective reputation,
the payment handle, and `imageUrls[tokenId]`.

The renderer creates two image modes:

- A clipped, framed external `<image href="...">` when `imageUrl` is set.
- A geometric `S9` identity mark when it is empty.

All user-controlled values used in SVG are XML escaped. JSON string values are
JSON escaped before the outer metadata is encoded.

## Metadata

The decoded JSON contains:

```json
{
  "name": "Alice",
  "description": "Series9 protocol builder. On-chain identity and payments.",
  "image": "data:image/svg+xml;base64,...",
  "image_url": "https://cdn.example/alice.png",
  "attributes": [
    {"trait_type":"Entity Type","value":"Human"},
    {"trait_type":"Verified","value":"true"},
    {"trait_type":"Image Source","value":"Custom Photo"},
    {"trait_type":"Reputation Score","value":"9"},
    {"trait_type":"Registered Year","value":"2023"},
    {"trait_type":"Handle","value":"alice"}
  ]
}
```

`description` is the identity's `bio` (set at mint or via `updateProfile`, max
128 bytes). Identities with an empty bio fall back to
`Series9 Identity premium black, white, and gold identity card` so listings are
never blank. The card renders the bio as three lines of up to 46 bytes each
(~138 bytes, so the whole 128-byte limit fits for ASCII); Korean and other
multi-byte text still truncates on the card, and the full value always reaches
the marketplace description.

`Image Source` is `Custom Photo` for a non-empty URL and `Generated Mark`
otherwise. The photo URL is also present in the SVG image element when set.

## Card Specification

- Viewbox: `0 0 720 440`, rounded black card.
- Palette: deep black (`#08080a`), warm near-black panel (`#121116`), white
  (`#f6f3ea`), champagne gold (`#cfae74`), and muted gray (`#8f8f91`).
  The card ground is a three-stop gradient (`#16151a` → `#0d0d10` → `#08080a`),
  and gold accents use the `gold` linear gradient
  (`#f2e3bd` → `#cfae74` → `#8c7040`).
- Layout grid: 40px margin on all four sides, so every element sits between
  `x=40` and `x=680`.
  - Photo column: `x[40,252]`, `y[112,364]`.
  - Data column: `x[290,680]`, split into three 130px stat columns at
    `x=290 / 420 / 550`.
  - No horizontal rules anywhere: sections are separated by whitespace alone,
    and there is no footer wordmark — the rim ring carries the branding.
- Entity pill and verification mark are right-aligned to `x=680`; the pill's
  left edge is `642 - pillWidth` so both entity types keep the same trailing gap.
- Gold border, engraved rim ring, and a soft radial halo behind the photo column.
- Rim ring: `@handle · #tokenId` repeats around the full card perimeter along the
  `rim` path (rounded rect inset 18, `rx=16`, 2148px long) and scrolls around the
  card continuously, one full lap per 60s. Two identical laps are emitted as
  separate `<text>` elements, each with its own `textLength="2148"`, so each lap
  is stretched to exactly the path length and the pair tiles the rim with a
  period of exactly 2148 regardless of font metrics. One lap chases the other
  (`0 → -2148` while `2148 → 0`), so the rim is always fully covered and the end
  of a cycle renders pixel-identically to its start.
  A single stretched run holding both laps does *not* work: `lengthAdjust`
  spreads the slack across every glyph gap including the junction, making the
  real period `2148 + gap/2` and the wrap jump about a pixel.
  Identities without a handle use `SERIES9 IDENTITY · #tokenId`. This SMIL
  `<animate>` on the rim is the card's only motion; everything else is static.
- Framed photo or generated mark on the left.
- Name, handle, and bio on the right, then one compact stat line: `REP <score>`
  at `x=290` and `SINCE <year>` at `x=485`, each a small gray label and its value
  on a shared baseline. Verification is shown only by the header badge, and the
  token id only by the rim ring and `<title>`.
- No hue palette, character layers, or avatar traits.

Sample cards are generated by
`forge script script/RenderIdentityCard.s.sol:RenderIdentityCard`, which writes
`examples/identity-card.svg` and `examples/identity-card-ai-photo.svg`.

## Utility Functions

- `_base64Encode(bytes)` — RFC 4648 base64 encoding.
- `_uint2str(uint256)` — decimal ASCII conversion.
- `_escapeXml(string)` — escapes XML metacharacters and sanitizes control bytes.
- `_escapeJson(string)` — escapes JSON quotes, slashes, and control bytes.
- `_yearOf(uint256)` — converts the registration timestamp to the displayed year.
- `_splitBio(string)` — splits the bio into the card's three lines.
- `_takeBioLine(bytes,uint256)` — takes one <=46 byte line, preferring a space
  boundary and otherwise cutting on a UTF-8 boundary.
- `_rimText(uint256,string)` — builds the repeating perimeter ring text.

## Upgrade Notes

The renderer is part of the `Series9Identity` implementation bytecode. Deploy a
new `Series9Identity` implementation and upgrade the proxy with UUPS
`upgradeToAndCall`. No renderer reinitializer is needed: `imageUrls` defaults to
empty, so existing identities show the generated mark until their owners set a
photo URL.

The preserved `avatarConfig` mapping remains before `imageUrls` at the end of
the identity storage layout. Existing avatar data is intentionally not rendered.
