// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title Series9IdentityRenderer
/// @notice Stateless on-chain metadata renderer for Series9Identity.
contract Series9IdentityRenderer {
    uint8 private constant ENTITY_HUMAN = 0;
    uint8 private constant ENTITY_AI = 1;

    /// @dev Bytes per rendered bio line; the card shows three of them.
    uint256 private constant BIO_LINE_BYTES = 46;

    /// @dev Legacy type retained so upgraded proxies keep the existing avatar ABI.
    ///      Avatar values are no longer read by the active renderer.
    struct AvatarConfig {
        uint8 skinTone;
        uint8 hairStyle;
        uint8 hairColor;
        uint8 eyes;
        uint8 mouth;
        uint8 outfit;
        uint8 accessory;
        uint8 background;
    }

    struct RenderProfile {
        string name;
        string bio;
        uint8 entityType;
        bool verified;
        uint64 registeredAt;
        uint256 reputationScore;
        string handle;
        string imageUrl;
    }

    function _renderTokenURI(
        uint256 tokenId,
        string memory name,
        string memory bio,
        uint8 entityType,
        bool verified,
        uint64 registeredAt,
        uint256 reputationScore,
        string memory handle,
        string memory imageUrl
    ) internal pure returns (string memory) {
        RenderProfile memory p = RenderProfile({
            name: name,
            bio: bio,
            entityType: entityType,
            verified: verified,
            registeredAt: registeredAt,
            reputationScore: reputationScore,
            handle: handle,
            imageUrl: imageUrl
        });

        string memory svg = _generateSVG(tokenId, p);
        string memory imageSource = bytes(p.imageUrl).length == 0 ? "Generated Mark" : "Custom Photo";

        string memory attributes = string(
            abi.encodePacked(
                '{"trait_type":"Entity Type","value":"',
                p.entityType == ENTITY_AI ? "AI" : "Human",
                '"},{"trait_type":"Verified","value":"',
                p.verified ? "true" : "false",
                '"},{"trait_type":"Image Source","value":"',
                imageSource,
                '"},{"trait_type":"Reputation Score","value":"',
                _uint2str(p.reputationScore),
                '"},{"trait_type":"Registered Year","value":"',
                _uint2str(_yearOf(p.registeredAt)),
                '"},{"trait_type":"Handle","value":"',
                _escapeJson(p.handle),
                '"}'
            )
        );

        // The owner-supplied bio is the marketplace description; the protocol
        // blurb is only a fallback so listings are never blank.
        string memory description = bytes(p.bio).length == 0
            ? "Series9 Identity premium black, white, and gold identity card"
            : _escapeJson(p.bio);

        string memory json = string(
            abi.encodePacked(
                '{"name":"',
                _escapeJson(p.name),
                '","description":"',
                description,
                '",',
                '"image":"data:image/svg+xml;base64,',
                _base64Encode(bytes(svg)),
                '","image_url":"',
                _escapeJson(p.imageUrl),
                '","attributes":[',
                attributes,
                "]}"
            )
        );

        return string(abi.encodePacked("data:application/json;base64,", _base64Encode(bytes(json))));
    }

    function _generateSVG(uint256 tokenId, RenderProfile memory p) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                _svgHead(tokenId, p.handle),
                _photoOrMark(p.imageUrl),
                _entityBadge(p.entityType),
                _verifiedBadge(p.verified),
                _svgBody(p),
                "</svg>"
            )
        );
    }

    /// @dev Layout grid: 720x440 card, 40px outer margin on every side.
    ///      Left photo column x[40,252], right data column x[290,680].
    function _svgHead(uint256 tokenId, string memory handle) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 720 440" width="720" height="440" shape-rendering="geometricPrecision">',
                "<title>Series9 Identity #",
                _uint2str(tokenId),
                "</title>",
                "<defs>",
                '<linearGradient id="gold" x1="0" y1="0" x2="1" y2="1">',
                '<stop offset="0" stop-color="#f2e3bd"/><stop offset=".5" stop-color="#cfae74"/><stop offset="1" stop-color="#8c7040"/>',
                "</linearGradient>",
                '<linearGradient id="card" x1="0" y1="0" x2=".6" y2="1">',
                '<stop offset="0" stop-color="#16151a"/><stop offset=".55" stop-color="#0d0d10"/><stop offset="1" stop-color="#08080a"/>',
                "</linearGradient>",
                '<radialGradient id="halo" cx=".5" cy=".5" r=".5">',
                '<stop offset="0" stop-color="#cfae74" stop-opacity=".16"/><stop offset="1" stop-color="#cfae74" stop-opacity="0"/>',
                "</radialGradient>",
                '<clipPath id="photoClip"><rect x="48" y="120" width="196" height="236" rx="16"/></clipPath>',
                '<clipPath id="nameClip"><rect x="290" y="138" width="390" height="46"/></clipPath>',
                '<clipPath id="bioClip"><rect x="290" y="220" width="390" height="76"/></clipPath>',
                '<path id="rim" fill="none" d="M34 18H686a16 16 0 0 1 16 16V406a16 16 0 0 1-16 16H34a16 16 0 0 1-16-16V34a16 16 0 0 1 16-16Z"/>',
                "</defs>",
                _svgFrame(),
                _rimText(tokenId, handle)
            )
        );
    }

    function _svgFrame() internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<rect width="720" height="440" rx="30" fill="#08080a"/>',
                '<rect width="720" height="440" rx="30" fill="url(#card)"/>',
                '<ellipse cx="146" cy="238" rx="220" ry="205" fill="url(#halo)"/>',
                '<rect x="1.5" y="1.5" width="717" height="437" rx="28.5" fill="none" stroke="url(#gold)" stroke-opacity=".85" stroke-width="3"/>',
                '<g font-family="Inter, Helvetica, Arial, sans-serif">',
                '<text x="40" y="52" font-size="17" font-weight="800" fill="#f6f3ea" letter-spacing="5">SERIES9</text>',
                '<text x="40" y="72" font-size="9" font-weight="600" fill="#8f8f91" letter-spacing="2.4">IDENTITY CARD</text>',
                "</g>"
            )
        );
    }

    /// @dev Repeating "@handle - #id" ring engraved between the gold border and
    ///      the content margin, scrolling around the card forever.
    ///      Two identical laps are emitted as separate <text> elements, each with
    ///      its own `textLength="2148"`, so each lap is stretched to exactly the
    ///      rim path length and the pair tiles the rim with a period of exactly
    ///      2148 whatever the font metrics are. One lap chases the other
    ///      (0 -> -2148 while 2148 -> 0), so the rim is always fully covered and
    ///      the end of a cycle is pixel-identical to its start.
    ///      A single stretched run of both laps would not work: `lengthAdjust`
    ///      spreads the slack across every glyph gap, including the junction, so
    ///      the real period becomes 2148 plus half a gap and the wrap jumps ~1px.
    function _rimText(uint256 tokenId, string memory handle) internal pure returns (string memory) {
        string memory unit = string(
            abi.encodePacked(
                bytes(handle).length == 0
                    ? "SERIES9 IDENTITY"
                    : string(abi.encodePacked("@", _escapeXml(handle))),
                unicode" · #",
                _uint2str(tokenId),
                unicode" · "
            )
        );

        // One lap fits ~300 glyphs at 9px with 1.6px tracking; a middot costs 2 bytes.
        uint256 repeats = 300 / bytes(unit).length;
        if (repeats < 3) repeats = 3;
        if (repeats > 40) repeats = 40;

        string memory lap;
        for (uint256 i = 0; i < repeats; i++) {
            lap = string(abi.encodePacked(lap, unit));
        }

        return string(abi.encodePacked(_rimLap(lap, "0", "-2148"), _rimLap(lap, "2148", "0")));
    }

    function _rimLap(string memory lap, string memory from, string memory to) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<text font-family="Inter, Helvetica, Arial, sans-serif" font-size="9" font-weight="700" fill="#cfae74" fill-opacity=".62" letter-spacing="1.6">',
                '<textPath href="#rim" startOffset="',
                from,
                '" textLength="2148" lengthAdjust="spacing">',
                lap,
                '<animate attributeName="startOffset" from="',
                from,
                '" to="',
                to,
                '" dur="60s" repeatCount="indefinite"/>',
                "</textPath></text>"
            )
        );
    }

    function _photoOrMark(string memory imageUrl) internal pure returns (string memory) {
        string memory frame =
            '<rect x="40" y="112" width="212" height="252" rx="22" fill="#121116" stroke="url(#gold)" stroke-opacity=".7" stroke-width="1.5"/>';
        string memory overlay = string(
            abi.encodePacked(
                '<rect x="48" y="120" width="196" height="236" rx="16" fill="none" stroke="#f6f3ea" stroke-opacity=".38"/>',
                '<path d="M64 132H92M64 344H92M200 132H228M200 344H228" stroke="#cfae74" stroke-width="2" stroke-linecap="round"/>'
            )
        );

        if (bytes(imageUrl).length != 0) {
            return string(
                abi.encodePacked(
                    frame,
                    '<g clip-path="url(#photoClip)">',
                    '<rect x="48" y="120" width="196" height="236" fill="#121116"/>',
                    '<image href="',
                    _escapeXml(imageUrl),
                    '" x="48" y="120" width="196" height="236" preserveAspectRatio="xMidYMid slice"/>',
                    "</g>",
                    overlay
                )
            );
        }

        return string(
            abi.encodePacked(
                frame,
                '<g transform="translate(146 238)">',
                '<circle r="70" fill="none" stroke="#cfae74" stroke-opacity=".3" stroke-width="1.5"/>',
                '<circle r="52" fill="none" stroke="#f6f3ea" stroke-opacity=".18"/>',
                '<path d="M-52 0H52M0-52V52" stroke="#8f8f91" stroke-opacity=".2"/>',
                '<path d="M-28-26L0-54L28-26M-28 26L0 54L28 26" fill="none" stroke="url(#gold)" stroke-width="2" stroke-linejoin="round"/>',
                '<text x="-2" y="13" text-anchor="middle" font-family="Inter, Helvetica, Arial, sans-serif" font-size="36" font-weight="800" fill="#f6f3ea" letter-spacing="3">S9</text>',
                "</g>",
                overlay
            )
        );
    }

    /// @dev Pills are right-aligned to the 680px content edge so both entity
    ///      widths keep the same trailing gap to the verification mark.
    function _entityBadge(uint8 entityType) internal pure returns (string memory) {
        string memory label = entityType == ENTITY_AI ? "AI" : "HUMAN";
        uint256 width = entityType == ENTITY_AI ? 58 : 84;

        return string(
            abi.encodePacked(
                '<g transform="translate(',
                _uint2str(642 - width),
                ' 40)" font-family="Inter, Helvetica, Arial, sans-serif">',
                '<rect width="',
                _uint2str(width),
                '" height="28" rx="14" fill="#121116" stroke="#cfae74" stroke-opacity=".72"/>',
                '<circle cx="15" cy="14" r="4" fill="url(#gold)"/>',
                '<text x="',
                _uint2str(width / 2 + 7),
                '" y="18" text-anchor="middle" font-size="9" font-weight="800" fill="#f6f3ea" letter-spacing="1.4">',
                label,
                "</text>",
                "</g>"
            )
        );
    }

    function _verifiedBadge(bool verified) internal pure returns (string memory) {
        if (verified) {
            return string(
                abi.encodePacked(
                    '<g transform="translate(652 40)">',
                    '<circle cx="14" cy="14" r="14" fill="url(#gold)"/>',
                    '<path d="M7 14l5 5 9-10" fill="none" stroke="#08080a" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/>',
                    "</g>"
                )
            );
        }

        return string(
            abi.encodePacked(
                '<g transform="translate(652 40)">',
                '<circle cx="14" cy="14" r="13.5" fill="none" stroke="#8f8f91" stroke-opacity=".65"/>',
                '<path d="M8 14h12" stroke="#8f8f91" stroke-width="1.6" stroke-linecap="round"/>',
                "</g>"
            )
        );
    }

    function _svgBody(RenderProfile memory p) internal pure returns (string memory) {
        (string memory bioLine1, string memory bioLine2, string memory bioLine3) = _splitBio(p.bio);
        string memory displayName = bytes(p.name).length == 0 ? "UNNAMED IDENTITY" : _escapeXml(p.name);
        string memory displayHandle =
            bytes(p.handle).length == 0 ? "HANDLE PENDING" : string(abi.encodePacked("@", _escapeXml(p.handle)));
        string memory displayBio = bytes(p.bio).length == 0 ? "No bio provided" : _escapeXml(bioLine1);

        return string(
            abi.encodePacked(
                '<g font-family="Inter, Helvetica, Arial, sans-serif">',
                '<text x="290" y="130" font-size="9" font-weight="700" fill="#cfae74" letter-spacing="2.4">PERSONAL IDENTITY</text>',
                '<g clip-path="url(#nameClip)"><text x="290" y="172" font-size="34" font-weight="800" fill="#f6f3ea" letter-spacing="-.8">',
                displayName,
                "</text></g>",
                '<text x="290" y="198" font-size="13" font-weight="600" fill="#cfae74" letter-spacing="1.2">',
                displayHandle,
                "</text>",
                '<g clip-path="url(#bioClip)" font-size="14" font-weight="400" fill="#f6f3ea" fill-opacity=".84">',
                '<text x="290" y="238">',
                displayBio,
                '</text><text x="290" y="260">',
                _escapeXml(bioLine2),
                '</text><text x="290" y="282">',
                _escapeXml(bioLine3),
                "</text></g>",
                _svgStats(p),
                "</g>"
            )
        );
    }

    /// @dev One compact line per stat: small gray label, then the value on the
    ///      same baseline, in two 195px columns from x=290. Whitespace separates
    ///      the stats from the bio; the card carries no rules at all.
    ///      Verification is shown by the header badge, not repeated here.
    function _svgStats(RenderProfile memory p) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<g font-size="22" font-weight="800" fill="#f6f3ea">',
                '<text x="290" y="346"><tspan font-size="9" font-weight="700" fill="#8f8f91" letter-spacing="1.6">REP </tspan>',
                _uint2str(p.reputationScore),
                '</text>',
                '<text x="485" y="346"><tspan font-size="9" font-weight="700" fill="#8f8f91" letter-spacing="1.6">SINCE </tspan>',
                _uint2str(_yearOf(p.registeredAt)),
                "</text>",
                "</g>"
            )
        );
    }


    function _base64Encode(bytes memory data) internal pure returns (string memory) {
        bytes memory alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        if (data.length == 0) return "";

        uint256 encodedLength = 4 * ((data.length + 2) / 3);
        bytes memory result = new bytes(encodedLength);
        uint256 i;
        uint256 j;

        for (; i + 3 <= data.length; i += 3) {
            uint24 chunk = uint24(uint8(data[i])) << 16 | uint24(uint8(data[i + 1])) << 8 | uint24(uint8(data[i + 2]));
            result[j++] = alphabet[chunk >> 18];
            result[j++] = alphabet[(chunk >> 12) & 0x3f];
            result[j++] = alphabet[(chunk >> 6) & 0x3f];
            result[j++] = alphabet[chunk & 0x3f];
        }

        uint256 remaining = data.length - i;
        if (remaining == 1) {
            uint24 chunk = uint24(uint8(data[i])) << 16;
            result[j++] = alphabet[chunk >> 18];
            result[j++] = alphabet[(chunk >> 12) & 0x3f];
            result[j++] = "=";
            result[j] = "=";
        } else if (remaining == 2) {
            uint24 chunk = uint24(uint8(data[i])) << 16 | uint24(uint8(data[i + 1])) << 8;
            result[j++] = alphabet[chunk >> 18];
            result[j++] = alphabet[(chunk >> 12) & 0x3f];
            result[j++] = alphabet[(chunk >> 6) & 0x3f];
            result[j] = "=";
        }

        return string(result);
    }

    function _uint2str(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }

        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            buffer[--digits] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    function _escapeXml(string memory value) internal pure returns (string memory) {
        bytes memory source = bytes(value);
        bytes memory output = new bytes(source.length * 6);
        uint256 length;

        for (uint256 i = 0; i < source.length; i++) {
            bytes1 c = source[i];
            if (c == bytes1(0x26)) {
                output[length++] = "&";
                output[length++] = "a";
                output[length++] = "m";
                output[length++] = "p";
                output[length++] = ";";
            } else if (c == bytes1(0x3c)) {
                output[length++] = "&";
                output[length++] = "l";
                output[length++] = "t";
                output[length++] = ";";
            } else if (c == bytes1(0x3e)) {
                output[length++] = "&";
                output[length++] = "g";
                output[length++] = "t";
                output[length++] = ";";
            } else if (c == bytes1(0x22)) {
                output[length++] = "&";
                output[length++] = "q";
                output[length++] = "u";
                output[length++] = "o";
                output[length++] = "t";
                output[length++] = ";";
            } else if (c == bytes1(0x27)) {
                output[length++] = "&";
                output[length++] = "a";
                output[length++] = "p";
                output[length++] = "o";
                output[length++] = "s";
                output[length++] = ";";
            } else if (uint8(c) < 0x20 || uint8(c) == 0x7f) {
                output[length++] = " ";
            } else {
                output[length++] = c;
            }
        }

        bytes memory trimmed = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            trimmed[i] = output[i];
        }
        return string(trimmed);
    }

    function _escapeJson(string memory value) internal pure returns (string memory) {
        bytes16 hexDigits = "0123456789abcdef";
        bytes memory source = bytes(value);
        bytes memory output = new bytes(source.length * 6);
        uint256 length;

        for (uint256 i = 0; i < source.length; i++) {
            uint8 c = uint8(source[i]);
            if (c == 0x22 || c == 0x5c) {
                output[length++] = bytes1(0x5c);
                output[length++] = source[i];
            } else if (c < 0x20) {
                output[length++] = bytes1(0x5c);
                output[length++] = "u";
                output[length++] = "0";
                output[length++] = "0";
                output[length++] = hexDigits[c >> 4];
                output[length++] = hexDigits[c & 0x0f];
            } else {
                output[length++] = source[i];
            }
        }

        bytes memory trimmed = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            trimmed[i] = output[i];
        }
        return string(trimmed);
    }

    function _yearOf(uint256 timestamp) internal pure returns (uint256) {
        return 1970 + timestamp / 31556952;
    }

    /// @dev Splits the bio into the three lines the card renders, breaking on
    ///      whitespace where possible and never mid-UTF-8-sequence. Anything
    ///      past line three is dropped from the card; the full bio still reaches
    ///      the metadata description.
    function _splitBio(string memory bio)
        internal
        pure
        returns (string memory line1, string memory line2, string memory line3)
    {
        bytes memory source = bytes(bio);
        uint256 cursor;
        (line1, cursor) = _takeBioLine(source, cursor);
        (line2, cursor) = _takeBioLine(source, cursor);
        (line3,) = _takeBioLine(source, cursor);
    }

    /// @dev Returns the next line of at most BIO_LINE_BYTES bytes from `start`,
    ///      plus the cursor the following line begins at.
    function _takeBioLine(bytes memory source, uint256 start)
        internal
        pure
        returns (string memory line, uint256 next)
    {
        if (start >= source.length) {
            return ("", source.length);
        }

        if (source.length - start <= BIO_LINE_BYTES) {
            return (_slice(source, start, source.length), source.length);
        }

        // Prefer the last space inside the window so words stay intact.
        uint256 end = start + BIO_LINE_BYTES;
        uint256 spaceEnd = end;
        while (spaceEnd > start && source[spaceEnd] != bytes1(0x20)) {
            spaceEnd--;
        }
        if (spaceEnd > start) {
            return (_slice(source, start, spaceEnd), spaceEnd + 1);
        }

        // No space in range (CJK, long URLs): hard cut on a UTF-8 boundary.
        while (end > start && _isUtf8Continuation(source[end])) {
            end--;
        }
        return (_slice(source, start, end), end);
    }

    function _slice(bytes memory source, uint256 start, uint256 end) internal pure returns (string memory) {
        bytes memory output = new bytes(end - start);
        for (uint256 i = start; i < end; i++) {
            output[i - start] = source[i];
        }
        return string(output);
    }

    function _isUtf8Continuation(bytes1 value) internal pure returns (bool) {
        uint8 c = uint8(value);
        return c >= 0x80 && c <= 0xbf;
    }
}
