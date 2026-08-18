// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {Series9IdentityRenderer} from "../src/Series9IdentityRenderer.sol";

/// @notice Writes a sample identity card SVG to examples/ so layout changes can be eyeballed.
/// @dev forge script script/RenderIdentityCard.s.sol:RenderIdentityCard
contract RenderIdentityCard is Script, Series9IdentityRenderer {
    function run() external {
        RenderProfile memory p = RenderProfile({
            name: "Yuchan Han",
            bio: "Series9 protocol builder. Working on on-chain identity, payments and autonomous agent wallets.",
            entityType: 0,
            verified: true,
            registeredAt: 1_760_000_000,
            reputationScore: 942,
            handle: "yuchan",
            imageUrl: ""
        });

        vm.writeFile("examples/identity-card.svg", _generateSVG(9, p));

        p.entityType = 1;
        p.verified = false;
        p.name = "Nova Agent";
        p.handle = "nova-ai";
        p.bio = unicode"Series9 아이덴티티로 운영되는 자율 결제 에이전트입니다. 온체인 신원 검증.";
        p.imageUrl = "https://cdn.example.com/nova.png";
        vm.writeFile("examples/identity-card-ai-photo.svg", _generateSVG(1042, p));
    }
}
