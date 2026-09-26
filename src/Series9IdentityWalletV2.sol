// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {IERC1271} from "openzeppelin-contracts/contracts/interfaces/IERC1271.sol";
import {SignatureChecker} from "openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";
import {MessageHashUtils} from "openzeppelin-contracts/contracts/utils/cryptography/MessageHashUtils.sol";
import {Series9IdentityWallet, ISeries9IdentityForWallet} from "./Series9IdentityWallet.sol";

/// @title Series9IdentityWalletV2
/// @notice Wallet logic v2: adds ERC-1271 so the wallet can prove off-chain that the current identity
///         holder authorized a hash. This makes the wallet a usable signer for Permit2, marketplace
///         listings, SIWE logins and any other signature-based protocol — without moving authority
///         away from the NFT.
/// @dev Adds no storage: the layout stays exactly as v1 (slot 0 `identity`, slot 1 `tokenId`, then
///      `__gap`). Holders upgrade with `upgradeToAndCall(v2, "")` — there is nothing to initialize.
contract Series9IdentityWalletV2 is Series9IdentityWallet, IERC1271 {
    /// @dev Returned instead of the magic value; ERC-1271 callers treat any non-magic value as invalid.
    bytes4 private constant _INVALID = 0xffffffff;

    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _NAME_HASH = keccak256("Series9IdentityWallet");
    bytes32 private constant _VERSION_HASH = keccak256("1");
    bytes32 private constant _MESSAGE_TYPEHASH = keccak256("Series9IdentityWalletMessage(bytes32 hash)");

    /// @notice EIP-712 domain binding signatures to THIS wallet on THIS chain.
    function domainSeparator() public view returns (bytes32) {
        return keccak256(abi.encode(_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, address(this)));
    }

    /// @notice The digest the holder must actually sign for `hash`: EIP-712 typed data
    ///         `Series9IdentityWalletMessage(bytes32 hash)` under this wallet's domain.
    /// @dev Wrapping stops replay: a raw-hash signature the holder made for their own EOA (or any other
    ///      account they control) is not valid here, because the signed digest is bound to this wallet's
    ///      address and chain. Protocols whose digests omit the owner (e.g. Permit2) are the concrete risk.
    function replaySafeHash(bytes32 hash) public view returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(domainSeparator(), keccak256(abi.encode(_MESSAGE_TYPEHASH, hash)));
    }

    /// @notice Validate `signature` over `hash` on behalf of the identity that owns this wallet.
    /// @dev The signer is the *current* `ownerOf(tokenId)`, so signing authority follows the NFT exactly
    ///      like `execute` does: the old holder's signatures stop validating the moment the identity moves.
    ///      The holder signs {replaySafeHash}(hash), not the raw `hash`.
    /// @return magicValue `0x1626ba7e` if valid, `0xffffffff` otherwise. Never reverts.
    function isValidSignature(bytes32 hash, bytes memory signature) public view returns (bytes4) {
        address holder;
        try IERC721(identity).ownerOf(tokenId) returns (address holder_) {
            holder = holder_;
        } catch {
            return _INVALID; // identity burned or never minted
        }

        // Same authorization as every outbound call: current holder, and not frozen mid-escrow-transfer.
        // The hook is a view that reverts on failure, so a clean return means authorized.
        try ISeries9IdentityForWallet(identity).authorizeWalletCall(tokenId, holder) {}
        catch {
            return _INVALID;
        }

        // SignatureChecker covers both an EOA holder (ECDSA, malleability-safe) and a contract holder
        // (nested ERC-1271), so an identity held by another smart account can still sign.
        return SignatureChecker.isValidSignatureNow(holder, replaySafeHash(hash), signature)
            ? IERC1271.isValidSignature.selector
            : _INVALID;
    }
}
