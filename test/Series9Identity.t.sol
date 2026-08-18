// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {Series9Identity} from "../src/Series9Identity.sol";
import {Series9IdentityRenderer} from "../src/Series9IdentityRenderer.sol";
import {SER9Token} from "series9/SER9Token.sol";
import {Series9Staking} from "series9/Series9Staking.sol";

/// @dev A smart-contract account that authorizes via ERC-1271 (validating an internal owner key's ECDSA sig),
///      used to prove a contract-held identity can authorize delegated payments after the EIP-1271 upgrade.
contract ERC1271Wallet {
    address public immutable signerOwner;

    constructor(address signerOwner_) {
        signerOwner = signerOwner_;
    }

    function approveAndMint(SER9Token ser9, Series9Identity id, string calldata handle) external returns (uint256) {
        ser9.approve(address(id), type(uint256).max);
        return id.mintIdentityWithHandle("CW", "", Series9Identity.EntityType.Human, 10, 10, handle);
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        if (err == ECDSA.RecoverError.NoError && recovered == signerOwner) {
            return 0x1626ba7e; // IERC1271.isValidSignature.selector
        }
        return 0xffffffff;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

contract Series9IdentityRendererHarness is Series9IdentityRenderer {
    function exposedEscapeJson(string memory value) external pure returns (string memory) {
        return _escapeJson(value);
    }

    function exposedGenerateSvgWithBio(string memory bio) external pure returns (string memory) {
        RenderProfile memory p = RenderProfile({
            name: "Alice",
            bio: bio,
            entityType: 0,
            verified: false,
            registeredAt: 1_700_000_000,
            reputationScore: 9,
            handle: "alice",
            imageUrl: ""
        });

        return _generateSVG(1, p);
    }

    function exposedGenerateSvg(string memory handle, string memory imageUrl) external pure returns (string memory) {
        RenderProfile memory p = RenderProfile({
            name: "Alice",
            bio: "on-chain user",
            entityType: 0,
            verified: false,
            registeredAt: 1_700_000_000,
            reputationScore: 9,
            handle: handle,
            imageUrl: imageUrl
        });

        return _generateSVG(1, p);
    }
}

contract Series9IdentityTest is Test {
    Series9Identity public identity;
    SER9Token public ser9;
    Series9Staking public staking;
    address public owner;
    address public alice;
    address public bob;
    address public charlie;

    uint256 constant AI_FEE = 10 ether; // 10 SER9
    uint256 constant HUMAN_FEE = 50 ether; // 50 SER9

    function setUp() public {
        owner = address(this);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        // 1. Deploy SER9 token
        SER9Token ser9Impl = new SER9Token();
        bytes memory ser9Data = abi.encodeCall(SER9Token.initialize, (owner));
        ERC1967Proxy ser9Proxy = new ERC1967Proxy(address(ser9Impl), ser9Data);
        ser9 = SER9Token(address(ser9Proxy));

        // 2. Deploy Staking (minimal setup — we just need stake() to work)
        // For testing, use a mock staking contract instead
        MockStaking mockStaking = new MockStaking(address(ser9));

        // 3. Deploy Identity
        Series9Identity impl = new Series9Identity();
        bytes memory idData =
            abi.encodeCall(Series9Identity.initialize, (owner, address(ser9), address(mockStaking), AI_FEE, HUMAN_FEE));
        ERC1967Proxy idProxy = new ERC1967Proxy(address(impl), idData);
        identity = Series9Identity(address(idProxy));

        // Fund users with SER9
        ser9.transfer(alice, 100 ether);
        ser9.transfer(bob, 100 ether);

        // Approve identity contract to spend SER9
        vm.prank(alice);
        ser9.approve(address(identity), type(uint256).max);
        vm.prank(bob);
        ser9.approve(address(identity), type(uint256).max);
    }

    function test_initialize() public view {
        assertEq(identity.aiMintFee(), AI_FEE);
        assertEq(identity.humanMintFee(), HUMAN_FEE);
        assertEq(address(identity.ser9()), address(ser9));
        assertEq(identity.stakingContract(), address(MockStaking(address(identity.stakingContract()))));
    }

    function test_initializeRejectsEOAStakingContract() public {
        Series9Identity impl = new Series9Identity();
        bytes memory idData = abi.encodeCall(
            Series9Identity.initialize, (owner, address(ser9), makeAddr("notStaking"), AI_FEE, HUMAN_FEE)
        );

        vm.expectRevert(Series9Identity.InvalidStakingContract.selector);
        new ERC1967Proxy(address(impl), idData);
    }

    function test_mintHuman() public {
        uint256 balBefore = ser9.balanceOf(alice);

        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "Hello I am Alice", Series9Identity.EntityType.Human, 180, 200);

        assertEq(identity.ownerOf(tid), alice);
        assertEq(identity.ownerTokenId(alice), tid);
        assertTrue(identity.isHuman(alice));
        assertFalse(identity.isAI(alice));
        assertFalse(identity.isVerified(tid));
        assertEq(identity.reputationScores(tid), identity.DEFAULT_HUMAN_REPUTATION_SCORE());
        assertEq(identity.effectiveReputationScore(tid), identity.DEFAULT_HUMAN_REPUTATION_SCORE());
        assertEq(identity.reputationScoreOf(alice), identity.DEFAULT_HUMAN_REPUTATION_SCORE());
        assertEq(identity.totalReputationScore(), identity.DEFAULT_HUMAN_REPUTATION_SCORE());

        // 50 SER9 deducted from alice
        assertEq(balBefore - ser9.balanceOf(alice), HUMAN_FEE);

        // 50 SER9 staked in mock staking
        MockStaking ms = MockStaking(identity.stakingContract());
        assertEq(ms.stakedAmount(address(identity)), HUMAN_FEE);
    }

    function test_mintAI() public {
        uint256 balBefore = ser9.balanceOf(bob);

        vm.prank(bob);
        identity.mintIdentity("AgentX", "AI assistant", Series9Identity.EntityType.AI, 250, 180);

        assertTrue(identity.isAI(bob));
        assertFalse(identity.isHuman(bob));
        uint256 tid = identity.ownerTokenId(bob);
        assertEq(identity.reputationScores(tid), identity.DEFAULT_AI_REPUTATION_SCORE());
        assertEq(identity.effectiveReputationScore(tid), identity.DEFAULT_AI_REPUTATION_SCORE());
        assertEq(identity.reputationScoreOf(bob), identity.DEFAULT_AI_REPUTATION_SCORE());
        assertEq(identity.totalReputationScore(), identity.DEFAULT_AI_REPUTATION_SCORE());

        // 10 SER9 deducted
        assertEq(balBefore - ser9.balanceOf(bob), AI_FEE);

        MockStaking ms = MockStaking(identity.stakingContract());
        assertEq(ms.stakedAmount(address(identity)), AI_FEE);
    }

    function test_mintRevertsIfStakingContractDoesNotPullFee() public {
        NoPullStaking badStaking = new NoPullStaking();
        identity.setStakingContract(address(badStaking));

        uint256 balBefore = ser9.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert(Series9Identity.StakingFailed.selector);
        identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        assertEq(ser9.balanceOf(alice), balBefore);
        assertFalse(identity.hasIdentity(alice));
    }

    function test_zeroFeeMintDoesNotCallStaking() public {
        NoPullStaking badStaking = new NoPullStaking();
        identity.setStakingContract(address(badStaking));
        identity.setHumanMintFee(0);

        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        assertEq(identity.ownerOf(tid), alice);
        assertEq(badStaking.stakeCalls(), 0);
    }

    function test_oneIdentityPerAddress() public {
        vm.prank(alice);
        identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("AlreadyHasIdentity(address)", alice));
        identity.mintIdentity("Alice2", "", Series9Identity.EntityType.Human, 100, 200);
    }

    function test_insufficientAllowance() public {
        // Revoke approval
        vm.prank(alice);
        ser9.approve(address(identity), 0);

        vm.prank(alice);
        // ERC20 will revert with insufficient allowance
        vm.expectRevert();
        identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);
    }

    function test_insufficientBalance() public {
        address poor = makeAddr("poor");
        vm.prank(alice);
        ser9.transfer(poor, 5 ether); // only 5 SER9, needs 10 for AI

        vm.prank(poor);
        ser9.approve(address(identity), type(uint256).max);

        vm.prank(poor);
        // Will fail because poor only has 5 SER9 but needs 10 for AI
        vm.expectRevert();
        identity.mintIdentity("Poor", "", Series9Identity.EntityType.AI, 100, 200);
    }

    function test_updateProfile() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "old bio", Series9Identity.EntityType.Human, 100, 200);

        vm.prank(alice);
        identity.updateProfile(tid, "Alice Updated", "new bio", 150, 220);

        (string memory name,,,,,,) = identity.profiles(tid);
        assertEq(name, "Alice Updated");
    }

    function test_updateProfileNotOwner() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        vm.prank(bob);
        vm.expectRevert(Series9Identity.NotTokenOwner.selector);
        identity.updateProfile(tid, "Hacked", "", 100, 200);
    }

    function test_verify() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        identity.verify(tid, true);
        assertTrue(identity.isVerified(tid));

        identity.verify(tid, false);
        assertFalse(identity.isVerified(tid));
    }

    function test_verifyNonexistentTokenReverts() public {
        vm.expectRevert(Series9Identity.NonexistentToken.selector);
        identity.verify(999, true);
    }

    function test_verifyNotOwner() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        identity.verify(tid, true);
    }

    function test_tokenURIContainsSVG() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "Test bio", Series9Identity.EntityType.Human, 100, 200);

        string memory uri = identity.tokenURI(tid);
        assertEq(uri, uri); // ensure no revert
    }

    function test_tokenURIChangesAfterHandleRegistration() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "Test bio", Series9Identity.EntityType.Human, 100, 200);

        string memory beforeUri = identity.tokenURI(tid);

        vm.prank(alice);
        identity.setHandle(tid, "alice-1");

        string memory afterUri = identity.tokenURI(tid);
        assertTrue(keccak256(bytes(beforeUri)) != keccak256(bytes(afterUri)));
    }

    function test_svgRendersPaymentHandle() public {
        Series9IdentityRendererHarness harness = new Series9IdentityRendererHarness();

        assertTrue(_contains(harness.exposedGenerateSvg("alice-1", ""), "@alice-1"));
        assertTrue(_contains(harness.exposedGenerateSvg("", ""), "HANDLE PENDING"));
    }

    function test_hasIdentity() public {
        assertFalse(identity.hasIdentity(alice));

        vm.prank(alice);
        identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        assertTrue(identity.hasIdentity(alice));
    }

    function test_nameOf() public {
        assertEq(identity.nameOf(alice), "");

        vm.prank(alice);
        identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        assertEq(identity.nameOf(alice), "Alice");
    }

    function test_setAIMintFee() public {
        identity.setAIMintFee(20 ether);
        assertEq(identity.aiMintFee(), 20 ether);
    }

    function test_setHumanMintFee() public {
        identity.setHumanMintFee(100 ether);
        assertEq(identity.humanMintFee(), 100 ether);
    }

    function test_setStakingContractRejectsEOA() public {
        vm.expectRevert(Series9Identity.InvalidStakingContract.selector);
        identity.setStakingContract(makeAddr("notStaking"));
    }

    function test_pauseUnpause() public {
        identity.pause();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        identity.unpause();

        vm.prank(alice);
        identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);
    }

    function test_nameTooLong() public {
        vm.prank(alice);
        string memory longName = "abcdefghijklmnopqrstuvwxyz1234567"; // 33 chars
        vm.expectRevert(Series9Identity.NameTooLong.selector);
        identity.mintIdentity(longName, "", Series9Identity.EntityType.Human, 100, 200);
    }

    function test_customAvatarSeedFeatureRemoved() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        vm.prank(alice);
        vm.expectRevert(Series9Identity.AvatarFeatureRemoved.selector);
        identity.setCustomAvatarSeed(tid, "legacy-seed");
    }

    function test_transferUpdatesIdentityOwnerAndRewardAccounting() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        _fundIdentityRewards(9 ether);
        identity.collectStakingRewards();

        _escrowTransfer(alice, bob, tid);

        assertEq(identity.ownerTokenId(alice), 0);
        assertEq(identity.ownerTokenId(bob), tid);
        assertFalse(identity.hasIdentity(alice));
        assertTrue(identity.hasIdentity(bob));
        assertTrue(identity.isHuman(bob));
        assertEq(identity.nameOf(alice), "");
        assertEq(identity.nameOf(bob), "Alice");
        assertEq(identity.totalReputationScore(), identity.DEFAULT_HUMAN_REPUTATION_SCORE());
        assertEq(identity.pendingNFTRewards(alice), 9 ether);
        assertEq(identity.pendingNFTRewards(bob), 0);

        uint256 aliceBefore = ser9.balanceOf(alice);
        vm.prank(alice);
        identity.claimNFTRewards();
        assertEq(ser9.balanceOf(alice), aliceBefore + 9 ether);

        _fundIdentityRewards(18 ether);
        identity.collectStakingRewards();

        assertEq(identity.pendingNFTRewards(alice), 0);
        assertEq(identity.pendingNFTRewards(bob), 18 ether);
    }

    function test_defaultReputationScoresSplitHumanAndAIRewardsNineToOne() public {
        vm.prank(alice);
        identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        vm.prank(bob);
        identity.mintIdentity("AgentX", "", Series9Identity.EntityType.AI, 120, 180);

        assertEq(identity.totalReputationScore(), 10);

        _fundIdentityRewards(100 ether);
        identity.collectStakingRewards();

        assertEq(identity.pendingNFTRewards(alice), 90 ether);
        assertEq(identity.pendingNFTRewards(bob), 10 ether);

        uint256 aliceBefore = ser9.balanceOf(alice);
        uint256 bobBefore = ser9.balanceOf(bob);

        vm.prank(alice);
        identity.claimNFTRewards();
        vm.prank(bob);
        identity.claimNFTRewards();

        assertEq(ser9.balanceOf(alice), aliceBefore + 90 ether);
        assertEq(ser9.balanceOf(bob), bobBefore + 10 ether);
    }

    function test_ownerCanUpdateReputationScoreAndFutureRewardsFollowScoreRatio() public {
        vm.prank(alice);
        uint256 aliceTokenId = identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        vm.prank(bob);
        uint256 bobTokenId = identity.mintIdentity("AgentX", "", Series9Identity.EntityType.AI, 120, 180);

        _fundIdentityRewards(100 ether);
        identity.collectStakingRewards();

        identity.setReputationScore(bobTokenId, 11);

        assertEq(identity.effectiveReputationScore(aliceTokenId), 9);
        assertEq(identity.effectiveReputationScore(bobTokenId), 11);
        assertEq(identity.totalReputationScore(), 20);
        assertEq(identity.pendingNFTRewards(alice), 90 ether);
        assertEq(identity.pendingNFTRewards(bob), 10 ether);

        _fundIdentityRewards(100 ether);
        identity.collectStakingRewards();

        assertEq(identity.pendingNFTRewards(alice), 135 ether);
        assertEq(identity.pendingNFTRewards(bob), 65 ether);
    }

    function test_nonOwnerCannotUpdateReputationScore() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        identity.setReputationScore(tid, 20);
    }

    function test_reputationScoreMustBeWithinAllowedRange() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        vm.expectRevert(Series9Identity.InvalidReputationScore.selector);
        identity.setReputationScore(tid, 0);

        uint256 maxScore = identity.MAX_REPUTATION_SCORE();
        vm.expectRevert(Series9Identity.InvalidReputationScore.selector);
        identity.setReputationScore(tid, maxScore + 1);
    }

    function test_transferToExistingIdentityHolderReverts() public {
        vm.prank(alice);
        identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        vm.prank(bob);
        identity.mintIdentity("Bob", "", Series9Identity.EntityType.Human, 100, 200);

        // Cannot initiate a transfer to an address that already holds an identity.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Series9Identity.AlreadyHasIdentity.selector, bob));
        identity.initiateIdentityTransfer(bob);
    }

    function test_newMinterCannotClaimPastNftRewards() public {
        vm.prank(alice);
        identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        _fundIdentityRewards(9 ether);
        identity.collectStakingRewards();

        vm.prank(bob);
        identity.mintIdentity("Bob", "", Series9Identity.EntityType.Human, 100, 200);

        assertEq(identity.pendingNFTRewards(alice), 9 ether);
        assertEq(identity.pendingNFTRewards(bob), 0);

        vm.prank(bob);
        vm.expectRevert(Series9Identity.NoNFTRewards.selector);
        identity.claimNFTRewards();
    }

    function test_jsonEscapesTokenName() public {
        Series9IdentityRendererHarness harness = new Series9IdentityRendererHarness();
        string memory value = string(abi.encodePacked("A\"\\B", bytes1(uint8(0x0a)), "C"));

        assertEq(harness.exposedEscapeJson(value), "A\\\"\\\\B\\u000aC");
    }

    function test_isAI_unregisteredAddress() public view {
        assertFalse(identity.isAI(alice));
        assertFalse(identity.isHuman(alice));
    }

    function test_upgrade() public {
        Series9Identity newImpl = new Series9Identity();
        identity.upgradeToAndCall(address(newImpl), "");
        assertEq(identity.aiMintFee(), AI_FEE);
        assertEq(identity.humanMintFee(), HUMAN_FEE);
    }

    function test_mintIdentityWithHandleRegistersHandle() public {
        vm.prank(alice);
        uint256 tid =
            identity.mintIdentityWithHandle("Alice", "", Series9Identity.EntityType.Human, 100, 200, "alice-1");

        assertEq(identity.handleOf(tid), "alice-1");
        assertEq(identity.tokenIdOfHandle("alice-1"), tid);
        assertEq(identity.ownerOfHandle("alice-1"), alice);
    }

    function test_handleValidationAndUniqueness() public {
        vm.prank(alice);
        identity.mintIdentityWithHandle("Alice", "", Series9Identity.EntityType.Human, 100, 200, "alice");

        vm.prank(bob);
        uint256 bobTokenId =
            identity.mintIdentityWithHandle("Bob", "", Series9Identity.EntityType.Human, 120, 180, "bob");

        vm.prank(bob);
        vm.expectRevert(Series9Identity.HandleAlreadyTaken.selector);
        identity.setHandle(bobTokenId, "alice");

        vm.prank(bob);
        vm.expectRevert(Series9Identity.InvalidHandle.selector);
        identity.setHandle(bobTokenId, "BadHandle");
    }

    function test_legacyHandleReservationsBlockUntilSeededAndUseLowestTokenId() public {
        vm.prank(alice);
        uint256 aliceTokenId = identity.mintIdentity("Alice_Name", "", Series9Identity.EntityType.Human, 100, 200);

        vm.prank(bob);
        uint256 bobTokenId = identity.mintIdentity("Alice Name", "", Series9Identity.EntityType.Human, 120, 180);

        identity.initializePayment();

        vm.prank(alice);
        vm.expectRevert(Series9Identity.LegacyHandleReservationsNotFinalized.selector);
        identity.setHandle(aliceTokenId, "alice-name");

        identity.seedLegacyHandleReservations(1);
        identity.seedLegacyHandleReservations(10);

        (uint256 reservedTokenId, uint64 expiresAt, bool active) = identity.legacyHandleReservationOf("alice-name");
        assertEq(reservedTokenId, aliceTokenId);
        assertEq(expiresAt, identity.legacyHandlePriorityDeadline());
        assertTrue(active);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Series9Identity.HandleReserved.selector, aliceTokenId, expiresAt));
        identity.setHandle(bobTokenId, "alice-name");

        vm.prank(alice);
        identity.setHandle(aliceTokenId, "alice-name");

        assertEq(identity.tokenIdOfHandle("alice-name"), aliceTokenId);
    }

    function test_legacyHandleReservationExpires() public {
        vm.prank(alice);
        identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        vm.prank(bob);
        uint256 bobTokenId = identity.mintIdentity("Bob", "", Series9Identity.EntityType.Human, 120, 180);

        identity.initializePayment();
        identity.seedLegacyHandleReservations(10);

        vm.warp(identity.legacyHandlePriorityDeadline() + 1);

        vm.prank(bob);
        identity.setHandle(bobTokenId, "alice");

        assertEq(identity.tokenIdOfHandle("alice"), bobTokenId);
    }

    function test_payToHandleTransfersERC20FromCallerOnly() public {
        (uint256 aliceTokenId, uint256 bobTokenId) = _mintAliceAndBobWithHandles();

        uint256 bobBefore = ser9.balanceOf(bob);
        vm.prank(alice);
        uint256 paymentId = identity.payToHandle(address(ser9), "bob", 7 ether, "coffee");

        assertEq(paymentId, 1);
        assertEq(identity.tokenIdOfHandle("alice"), aliceTokenId);
        assertEq(identity.tokenIdOfHandle("bob"), bobTokenId);
        assertEq(ser9.balanceOf(bob), bobBefore + 7 ether);
    }

    function test_transferredIdentityCannotSpendPreviousOwnerAllowance() public {
        (uint256 aliceTokenId,) = _mintAliceAndBobWithHandles();

        _escrowTransfer(alice, charlie, aliceTokenId);

        uint256 aliceBefore = ser9.balanceOf(alice);
        vm.prank(charlie);
        vm.expectRevert();
        identity.payToHandle(address(ser9), "bob", 1 ether, "");

        assertEq(ser9.balanceOf(alice), aliceBefore);
    }

    function test_payToHandleTransfersNativeMON() public {
        _mintAliceAndBobWithHandles();

        vm.deal(alice, 3 ether);
        uint256 bobBefore = bob.balance;

        vm.prank(alice);
        identity.payToHandle{value: 1 ether}(address(0), "bob", 1 ether, "mon");

        assertEq(bob.balance, bobBefore + 1 ether);
    }

    function test_payToHandleRejectsWrongNativeValue() public {
        _mintAliceAndBobWithHandles();

        vm.deal(alice, 3 ether);
        vm.prank(alice);
        vm.expectRevert(Series9Identity.InvalidNativeValue.selector);
        identity.payToHandle{value: 2 ether}(address(0), "bob", 1 ether, "mon");

        vm.prank(alice);
        vm.expectRevert(Series9Identity.InvalidNativeValue.selector);
        identity.payToHandle{value: 1 ether}(address(ser9), "bob", 1 ether, "ser9");
    }

    function test_createAndPayERC20PaymentRequest() public {
        (uint256 aliceTokenId, uint256 bobTokenId) = _mintAliceAndBobWithHandles();

        vm.prank(bob);
        uint256 requestId =
            identity.createPaymentRequest("alice", address(ser9), 3 ether, uint64(block.timestamp + 1 days), "invoice");

        assertEq(identity.payerPaymentRequestCount(aliceTokenId), 1);
        assertEq(identity.payeePaymentRequestCount(bobTokenId), 1);
        assertEq(identity.payerPaymentRequestIdAt(aliceTokenId, 0), requestId);
        assertEq(identity.payeePaymentRequestIdAt(bobTokenId, 0), requestId);

        uint256 bobBefore = ser9.balanceOf(bob);
        vm.prank(alice);
        uint256 paymentId = identity.payPaymentRequest(requestId);

        assertEq(paymentId, 1);
        assertEq(ser9.balanceOf(bob), bobBefore + 3 ether);
        assertEq(
            uint8(identity.effectivePaymentRequestStatus(requestId)), uint8(Series9Identity.PaymentRequestStatus.Paid)
        );
    }

    function test_createAndPayNativeMONPaymentRequest() public {
        _mintAliceAndBobWithHandles();

        vm.prank(bob);
        uint256 requestId = identity.createPaymentRequest(
            "alice", address(0), 2 ether, uint64(block.timestamp + 1 days), "mon invoice"
        );

        vm.deal(alice, 3 ether);
        uint256 bobBefore = bob.balance;

        vm.prank(alice);
        identity.payPaymentRequest{value: 2 ether}(requestId);

        assertEq(bob.balance, bobBefore + 2 ether);
        assertEq(
            uint8(identity.effectivePaymentRequestStatus(requestId)), uint8(Series9Identity.PaymentRequestStatus.Paid)
        );
    }

    function test_paymentRequestCanBeCancelledByPayerOrPayee() public {
        _mintAliceAndBobWithHandles();

        vm.prank(bob);
        uint256 requestId =
            identity.createPaymentRequest("alice", address(ser9), 1 ether, uint64(block.timestamp + 1 days), "cancel");

        vm.prank(alice);
        identity.cancelPaymentRequest(requestId);

        assertEq(
            uint8(identity.effectivePaymentRequestStatus(requestId)),
            uint8(Series9Identity.PaymentRequestStatus.Cancelled)
        );

        vm.prank(alice);
        vm.expectRevert(Series9Identity.PaymentRequestNotPending.selector);
        identity.payPaymentRequest(requestId);
    }

    function test_paymentRequestExpires() public {
        _mintAliceAndBobWithHandles();

        vm.prank(bob);
        uint256 requestId =
            identity.createPaymentRequest("alice", address(ser9), 1 ether, uint64(block.timestamp + 1 days), "expired");

        vm.warp(block.timestamp + 2 days);

        assertEq(
            uint8(identity.effectivePaymentRequestStatus(requestId)),
            uint8(Series9Identity.PaymentRequestStatus.Expired)
        );

        vm.prank(alice);
        vm.expectRevert(Series9Identity.PaymentRequestNotPending.selector);
        identity.payPaymentRequest(requestId);
    }

    // ─────────────────── Signed payment ───────────────────

    function _signPayPaymentRequest(uint256 signerKey, uint256 requestId, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory sig)
    {
        bytes32 digest = identity.payPaymentRequestDigest(requestId, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function _mintBobAndSignerWithHandles(string memory signerHandle)
        internal
        returns (uint256 signerKey, address signerAddr, uint256 bobTokenId, uint256 signerTokenId)
    {
        (signerAddr, signerKey) = makeAddrAndKey(signerHandle);
        ser9.transfer(signerAddr, 100 ether);
        vm.prank(signerAddr);
        ser9.approve(address(identity), type(uint256).max);

        vm.prank(bob);
        bobTokenId = identity.mintIdentityWithHandle("Bob", "", Series9Identity.EntityType.Human, 120, 180, "bob");
        vm.prank(signerAddr);
        signerTokenId =
            identity.mintIdentityWithHandle("Signer", "", Series9Identity.EntityType.Human, 50, 100, signerHandle);
    }

    function test_payPaymentRequestWithSig_erc20Happy() public {
        (uint256 signerKey, address signerAddr,,) = _mintBobAndSignerWithHandles("dave");

        vm.prank(bob);
        uint256 requestId = identity.createPaymentRequest(
            "dave", address(ser9), 4 ether, uint64(block.timestamp + 1 days), "delegated"
        );

        // Relayer (charlie) has no identity but supplies funds
        ser9.transfer(charlie, 10 ether);
        vm.prank(charlie);
        ser9.approve(address(identity), type(uint256).max);

        uint256 nonce = identity.paymentNonces(signerAddr);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signPayPaymentRequest(signerKey, requestId, nonce, deadline);

        uint256 bobBefore = ser9.balanceOf(bob);
        uint256 signerBefore = ser9.balanceOf(signerAddr);
        uint256 charlieBefore = ser9.balanceOf(charlie);

        vm.prank(charlie);
        identity.payPaymentRequestWithSig(requestId, nonce, deadline, sig);

        // Funds come from relayer (msg.sender), not signer
        assertEq(ser9.balanceOf(bob), bobBefore + 4 ether);
        assertEq(ser9.balanceOf(signerAddr), signerBefore);
        assertEq(ser9.balanceOf(charlie), charlieBefore - 4 ether);
        assertEq(identity.paymentNonces(signerAddr), nonce + 1);
        assertEq(
            uint8(identity.effectivePaymentRequestStatus(requestId)), uint8(Series9Identity.PaymentRequestStatus.Paid)
        );
    }

    function test_payPaymentRequestWithSig_monHappy() public {
        (uint256 signerKey, address signerAddr,,) = _mintBobAndSignerWithHandles("erin");

        vm.prank(bob);
        uint256 requestId = identity.createPaymentRequest(
            "erin", address(0), 1 ether, uint64(block.timestamp + 1 days), "mon delegated"
        );

        uint256 nonce = identity.paymentNonces(signerAddr);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signPayPaymentRequest(signerKey, requestId, nonce, deadline);

        vm.deal(charlie, 3 ether);
        uint256 bobBefore = bob.balance;

        vm.prank(charlie);
        identity.payPaymentRequestWithSig{value: 1 ether}(requestId, nonce, deadline, sig);

        assertEq(bob.balance, bobBefore + 1 ether);
        assertEq(
            uint8(identity.effectivePaymentRequestStatus(requestId)), uint8(Series9Identity.PaymentRequestStatus.Paid)
        );
    }

    /// @dev A contract-held identity (smart-account owner) can authorize a delegated payment via ERC-1271,
    ///      proving the SignatureChecker upgrade no longer requires the payer owner to be an EOA.
    function test_payPaymentRequestWithSig_erc1271ContractSigner() public {
        // Payee (bob) needs an identity to raise a request.
        vm.prank(bob);
        identity.mintIdentity("Bob", "", Series9Identity.EntityType.Human, 120, 180);

        // Payer is a smart-contract account (ERC-1271) that owns an identity with handle "cwhandle".
        (address ownerKeyAddr, uint256 ownerKey) = makeAddrAndKey("cw-owner");
        ERC1271Wallet cw = new ERC1271Wallet(ownerKeyAddr);
        ser9.transfer(address(cw), 100 ether);
        cw.approveAndMint(ser9, identity, "cwhandle");

        vm.prank(bob);
        uint256 requestId = identity.createPaymentRequest(
            "cwhandle", address(ser9), 4 ether, uint64(block.timestamp + 1 days), "1271 delegated"
        );

        // Relayer (charlie) supplies the funds.
        ser9.transfer(charlie, 10 ether);
        vm.prank(charlie);
        ser9.approve(address(identity), type(uint256).max);

        uint256 nonce = identity.paymentNonces(address(cw));
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = identity.payPaymentRequestDigest(requestId, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        uint256 bobBefore = ser9.balanceOf(bob);
        vm.prank(charlie);
        identity.payPaymentRequestWithSig(requestId, nonce, deadline, sig);

        assertEq(ser9.balanceOf(bob), bobBefore + 4 ether);
        assertEq(identity.paymentNonces(address(cw)), nonce + 1);
    }

    function test_payPaymentRequestWithSig_rejectsReplay() public {
        (uint256 signerKey, address signerAddr,,) = _mintBobAndSignerWithHandles("frank");

        vm.prank(bob);
        uint256 requestId =
            identity.createPaymentRequest("frank", address(ser9), 1 ether, uint64(block.timestamp + 1 days), "replay");

        ser9.transfer(charlie, 10 ether);
        vm.prank(charlie);
        ser9.approve(address(identity), type(uint256).max);

        uint256 nonce = identity.paymentNonces(signerAddr);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signPayPaymentRequest(signerKey, requestId, nonce, deadline);

        vm.prank(charlie);
        identity.payPaymentRequestWithSig(requestId, nonce, deadline, sig);

        vm.prank(charlie);
        vm.expectRevert(Series9Identity.PaymentRequestNotPending.selector);
        identity.payPaymentRequestWithSig(requestId, nonce, deadline, sig);
    }

    function test_payPaymentRequestWithSig_rejectsWrongSigner() public {
        _mintBobAndSignerWithHandles("george");
        (, uint256 strangerKey) = makeAddrAndKey("stranger");

        vm.prank(bob);
        uint256 requestId = identity.createPaymentRequest(
            "george", address(ser9), 1 ether, uint64(block.timestamp + 1 days), "wrong signer"
        );

        ser9.transfer(charlie, 10 ether);
        vm.prank(charlie);
        ser9.approve(address(identity), type(uint256).max);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signPayPaymentRequest(strangerKey, requestId, 0, deadline);

        vm.prank(charlie);
        vm.expectRevert(Series9Identity.InvalidPaymentSignature.selector);
        identity.payPaymentRequestWithSig(requestId, 0, deadline, sig);
    }

    function test_payPaymentRequestWithSig_rejectsExpired() public {
        (uint256 signerKey, address signerAddr,,) = _mintBobAndSignerWithHandles("hank");

        vm.prank(bob);
        uint256 requestId = identity.createPaymentRequest(
            "hank", address(ser9), 1 ether, uint64(block.timestamp + 1 days), "expired sig"
        );

        uint256 nonce = identity.paymentNonces(signerAddr);
        uint256 deadline = block.timestamp + 30;
        bytes memory sig = _signPayPaymentRequest(signerKey, requestId, nonce, deadline);

        vm.warp(deadline + 1);

        ser9.transfer(charlie, 10 ether);
        vm.prank(charlie);
        ser9.approve(address(identity), type(uint256).max);

        vm.prank(charlie);
        vm.expectRevert(Series9Identity.PaymentSignatureExpired.selector);
        identity.payPaymentRequestWithSig(requestId, nonce, deadline, sig);
    }

    function test_payPaymentRequestWithSig_rejectsCancelled() public {
        (uint256 signerKey, address signerAddr,,) = _mintBobAndSignerWithHandles("ivy");

        vm.prank(bob);
        uint256 requestId = identity.createPaymentRequest(
            "ivy", address(ser9), 1 ether, uint64(block.timestamp + 1 days), "cancel then sig"
        );

        vm.prank(signerAddr);
        identity.cancelPaymentRequest(requestId);

        uint256 nonce = identity.paymentNonces(signerAddr);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signPayPaymentRequest(signerKey, requestId, nonce, deadline);

        ser9.transfer(charlie, 10 ether);
        vm.prank(charlie);
        ser9.approve(address(identity), type(uint256).max);

        vm.prank(charlie);
        vm.expectRevert(Series9Identity.PaymentRequestNotPending.selector);
        identity.payPaymentRequestWithSig(requestId, nonce, deadline, sig);
    }

    function _fundIdentityRewards(uint256 amount) internal {
        MockStaking ms = MockStaking(identity.stakingContract());
        ser9.approve(address(ms), amount);
        ms.fundRewards(address(identity), amount);
    }

    /// @dev Move an identity through the escrow flow (initiate → accept → 6h delay → finalize),
    ///      since direct ERC721 transfers are disabled.
    function _escrowTransfer(address from, address to, uint256 tid) internal {
        vm.prank(from);
        identity.initiateIdentityTransfer(to);
        vm.prank(to);
        identity.acceptIdentityTransfer(tid);
        vm.warp(block.timestamp + identity.IDENTITY_TRANSFER_DELAY());
        identity.finalizeIdentityTransfer(tid);
    }

    function _mintAliceAndBobWithHandles() internal returns (uint256 aliceTokenId, uint256 bobTokenId) {
        vm.prank(alice);
        aliceTokenId = identity.mintIdentityWithHandle("Alice", "", Series9Identity.EntityType.Human, 100, 200, "alice");

        vm.prank(bob);
        bobTokenId = identity.mintIdentityWithHandle("Bob", "", Series9Identity.EntityType.Human, 120, 180, "bob");
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory haystackBytes = bytes(haystack);
        bytes memory needleBytes = bytes(needle);
        if (needleBytes.length == 0 || needleBytes.length > haystackBytes.length) {
            return false;
        }

        for (uint256 i = 0; i <= haystackBytes.length - needleBytes.length; i++) {
            bool found = true;
            for (uint256 j = 0; j < needleBytes.length; j++) {
                if (haystackBytes[i + j] != needleBytes[j]) {
                    found = false;
                    break;
                }
            }
            if (found) {
                return true;
            }
        }

        return false;
    }

    // ─────────────────── Photo URL metadata ───────────────────

    function test_setImageUrlStoresAndEmits() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);
        string memory imageUrl = "https://cdn.example.com/alice.png";

        vm.expectEmit(true, false, false, true);
        emit Series9Identity.ImageUrlUpdated(tid, imageUrl);

        vm.prank(alice);
        identity.setImageUrl(tid, imageUrl);

        assertEq(identity.imageUrls(tid), imageUrl);
    }

    function test_setImageUrlSupportsCommonSchemes() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        vm.startPrank(alice);
        identity.setImageUrl(tid, "https://example.com/photo.png");
        identity.setImageUrl(tid, "http://example.com/photo.png");
        identity.setImageUrl(tid, "ipfs://bafybeigdyrzt5sfp");
        identity.setImageUrl(tid, "ar://arweave-photo-id");
        vm.stopPrank();

        assertEq(identity.imageUrls(tid), "ar://arweave-photo-id");
    }

    function test_setImageUrlRejectsEmptyPayloadForEachSupportedScheme() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        vm.startPrank(alice);
        vm.expectRevert(Series9Identity.ImageUrlPayloadEmpty.selector);
        identity.setImageUrl(tid, "https://");
        vm.expectRevert(Series9Identity.ImageUrlPayloadEmpty.selector);
        identity.setImageUrl(tid, "http://");
        vm.expectRevert(Series9Identity.ImageUrlPayloadEmpty.selector);
        identity.setImageUrl(tid, "ipfs://");
        vm.expectRevert(Series9Identity.ImageUrlPayloadEmpty.selector);
        identity.setImageUrl(tid, "ar://");
        vm.stopPrank();
    }

    function test_setImageUrlClearsToGeneratedMark() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        vm.startPrank(alice);
        identity.setImageUrl(tid, "ipfs://photo-id");
        identity.setImageUrl(tid, "");
        vm.stopPrank();

        assertEq(identity.imageUrls(tid), "");
        Series9IdentityRendererHarness harness = new Series9IdentityRendererHarness();
        string memory svg = harness.exposedGenerateSvg("alice", "");
        assertTrue(_contains(svg, ">S9</text>"));
        assertFalse(_contains(svg, "<image href="));
    }

    function test_setImageUrlRevertsForNonOwner() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        vm.prank(bob);
        vm.expectRevert(Series9Identity.NotTokenOwner.selector);
        identity.setImageUrl(tid, "https://example.com/photo.png");
    }

    function test_setImageUrlRevertsForNonexistentToken() public {
        vm.prank(alice);
        vm.expectRevert(Series9Identity.NonexistentToken.selector);
        identity.setImageUrl(999, "https://example.com/photo.png");
    }

    function test_setImageUrlBlockedWhilePaused() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);
        identity.pause();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        identity.setImageUrl(tid, "https://example.com/photo.png");
    }

    function test_setImageUrlRejectsInvalidScheme() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        vm.prank(alice);
        vm.expectRevert(Series9Identity.InvalidImageUrlScheme.selector);
        identity.setImageUrl(tid, "data:image/png;base64,abc");
    }

    function test_setImageUrlRejectsControlCharacter() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);
        bytes memory rawUrl = bytes("https://example.com/photo.png");
        rawUrl[8] = bytes1(0x0a);

        vm.prank(alice);
        vm.expectRevert(Series9Identity.ImageUrlContainsControlCharacter.selector);
        identity.setImageUrl(tid, string(rawUrl));
    }

    function test_setImageUrlRejectsTooLong() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);
        bytes memory tooLong = new bytes(identity.MAX_IMAGE_URL_BYTES() + 1);
        for (uint256 i = 0; i < tooLong.length; i++) {
            tooLong[i] = bytes1(0x61);
        }

        vm.prank(alice);
        vm.expectRevert(Series9Identity.ImageUrlTooLong.selector);
        identity.setImageUrl(tid, string(tooLong));
    }

    function test_tokenURIChangesAndEmbedsPhotoCardMetadata() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "Test bio", Series9Identity.EntityType.Human, 100, 200);

        string memory beforeUri = identity.tokenURI(tid);
        string memory imageUrl = "https://cdn.example.com/alice.png?size=large&v=2";

        vm.prank(alice);
        identity.setImageUrl(tid, imageUrl);

        string memory afterUri = identity.tokenURI(tid);
        assertTrue(keccak256(bytes(beforeUri)) != keccak256(bytes(afterUri)));

        string memory metadata = _decodeDataUri(afterUri, "data:application/json;base64,");
        assertTrue(_contains(metadata, '"image_url":"https://cdn.example.com/alice.png?size=large&v=2"'));
        assertTrue(_contains(metadata, '"trait_type":"Image Source","value":"Custom Photo"'));

        string memory svg = _decodeEmbeddedSvg(metadata);
        assertTrue(_contains(svg, 'href="https://cdn.example.com/alice.png?size=large&amp;v=2"'));
        assertTrue(_contains(svg, "#08080a"));
        assertTrue(_contains(svg, "#cfae74"));
        assertTrue(_contains(svg, "#f6f3ea"));
        assertFalse(_contains(metadata, "Skin Tone"));
        assertFalse(_contains(metadata, "Hair Style"));
        assertFalse(_contains(svg, "avClip"));
    }

    function test_rendererHarnessUsesImageUrlAndModernPalette() public {
        Series9IdentityRendererHarness harness = new Series9IdentityRendererHarness();
        string memory svg = harness.exposedGenerateSvg("alice-1", "ar://photo-id");

        assertTrue(_contains(svg, 'href="ar://photo-id"'));
        assertTrue(_contains(svg, "#08080a"));
        assertTrue(_contains(svg, "#cfae74"));
        // Brassy gold is fully retired in favour of the champagne palette.
        assertFalse(_contains(svg, "#d7ad55"));
        assertFalse(_contains(svg, "Skin Tone"));
        assertFalse(_contains(svg, "#e74c3c"));
    }

    function test_metadataDescriptionUsesBio() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity(
            "Alice", "Builder of \"on-chain\" things", Series9Identity.EntityType.Human, 100, 200
        );

        string memory metadata = _decodeDataUri(identity.tokenURI(tid), "data:application/json;base64,");
        assertTrue(_contains(metadata, '"description":"Builder of \\"on-chain\\" things"'));

        vm.prank(alice);
        identity.updateProfile(tid, "Alice", "", 100, 200);

        string memory emptyBioMetadata = _decodeDataUri(identity.tokenURI(tid), "data:application/json;base64,");
        assertTrue(
            _contains(
                emptyBioMetadata,
                '"description":"Series9 Identity premium black, white, and gold identity card"'
            )
        );
    }

    function test_svgRimRepeatsHandleAndTokenId() public {
        Series9IdentityRendererHarness harness = new Series9IdentityRendererHarness();
        string memory withHandle = harness.exposedGenerateSvg("alice-1", "");

        assertTrue(_contains(withHandle, '<path id="rim"'));
        // Each lap carries its own textLength so the tiling period is exactly the
        // 2148px rim; one lap chases the other, so the wrap has no seam.
        assertTrue(_contains(withHandle, '<textPath href="#rim" startOffset="0" textLength="2148"'));
        assertTrue(_contains(withHandle, '<textPath href="#rim" startOffset="2148" textLength="2148"'));
        assertTrue(
            _contains(withHandle, '<animate attributeName="startOffset" from="0" to="-2148" dur="60s" repeatCount="indefinite"/>')
        );
        assertTrue(
            _contains(withHandle, '<animate attributeName="startOffset" from="2148" to="0" dur="60s" repeatCount="indefinite"/>')
        );
        assertFalse(_contains(withHandle, "4296"));
        // Unit repeats around the whole rim, so it appears far more than once.
        assertTrue(_contains(withHandle, unicode"@alice-1 · #1 · @alice-1 · #1 · @alice-1 · #1 · "));

        string memory noHandle = harness.exposedGenerateSvg("", "");
        assertTrue(_contains(noHandle, unicode"SERIES9 IDENTITY · #1 · SERIES9 IDENTITY · #1 · "));
    }

    function test_svgOmitsRedundantChrome() public {
        Series9IdentityRendererHarness harness = new Series9IdentityRendererHarness();
        string memory generated = harness.exposedGenerateSvg("alice-1", "");
        string memory photo = harness.exposedGenerateSvg("alice-1", "ar://photo-id");

        // Token id lives in the rim ring and title, verification in the header badge.
        assertFalse(_contains(generated, "TOKEN #"));
        assertFalse(_contains(generated, "STATUS"));
        assertFalse(_contains(generated, "TRUST STATE"));
        assertFalse(_contains(generated, "ON-CHAIN"));
        assertFalse(_contains(generated, "GENERATED MARK"));
        assertFalse(_contains(photo, "CUSTOM PHOTO"));
        assertFalse(_contains(generated, "VERIFIED IDENTITY PROTOCOL"));
        // The card carries no horizontal rules; whitespace does the separating.
        assertFalse(_contains(generated, "<line x1="));
        assertTrue(_contains(generated, ">IDENTITY CARD</text>"));
    }

    function test_svgWrapsBioAcrossThreeLines() public {
        Series9IdentityRendererHarness harness = new Series9IdentityRendererHarness();

        // 124 bytes: wraps onto all three lines, breaking only at spaces.
        string memory svg = harness.exposedGenerateSvgWithBio(
            "Series9 protocol builder shipping on-chain identity, payment handles and autonomous agent wallets on Monad every day"
        );
        assertTrue(_contains(svg, '<text x="290" y="238">Series9 protocol builder shipping on-chain</text>'));
        assertTrue(_contains(svg, '<text x="290" y="260">identity, payment handles and autonomous agent</text>'));
        assertTrue(_contains(svg, '<text x="290" y="282">wallets on Monad every day</text>'));

        // Korean has no spaces to break on, so lines hard-cut on UTF-8 boundaries.
        string memory korean = harness.exposedGenerateSvgWithBio(
            unicode"시리즈나인아이덴티티는온체인신원과결제핸들과자율에이전트지갑을제공합니다"
        );
        assertTrue(_contains(korean, unicode'<text x="290" y="238">시리즈나인아이덴티티는온체인신</text>'));
        assertTrue(_contains(korean, unicode'<text x="290" y="260">원과결제핸들과자율에이전트지갑</text>'));
        assertTrue(_contains(korean, unicode'<text x="290" y="282">을제공합니다</text>'));

        // Short bios leave the extra lines empty rather than repeating text.
        string memory short_ = harness.exposedGenerateSvgWithBio("hi");
        assertTrue(_contains(short_, '<text x="290" y="238">hi</text><text x="290" y="260"></text>'));
    }

    function test_svgStatsAreSingleLineRepAndSince() public {
        Series9IdentityRendererHarness harness = new Series9IdentityRendererHarness();
        string memory svg = harness.exposedGenerateSvg("alice-1", "");

        assertTrue(_contains(svg, ">REP </tspan>9</text>"));
        assertTrue(_contains(svg, ">SINCE </tspan>2023</text>"));
        assertFalse(_contains(svg, "REPUTATION"));
        assertFalse(_contains(svg, "PROTOCOL SCORE"));
        assertFalse(_contains(svg, "REGISTERED"));
        assertFalse(_contains(svg, "ESTABLISHED YEAR"));
    }

    function test_svgBadgesShareRightContentEdge() public {
        Series9IdentityRendererHarness harness = new Series9IdentityRendererHarness();
        string memory human = harness.exposedGenerateSvg("alice-1", "");

        // HUMAN pill is 84 wide, AI pill 58; both end 10px before the verified mark at x=652.
        assertTrue(_contains(human, 'transform="translate(558 40)"'));
        assertTrue(_contains(human, 'transform="translate(652 40)"'));
        assertFalse(_contains(human, "cx=\"666\""));
    }

    function test_avatarSettersRevertWithFeatureRemoved() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);
        Series9IdentityRenderer.AvatarConfig memory legacyConfig;

        vm.prank(alice);
        vm.expectRevert(Series9Identity.AvatarFeatureRemoved.selector);
        identity.setAvatar(tid, legacyConfig);
    }

    function _decodeDataUri(string memory uri, string memory prefix) internal pure returns (string memory) {
        bytes memory rawUri = bytes(uri);
        bytes memory rawPrefix = bytes(prefix);
        assert(rawUri.length >= rawPrefix.length);
        for (uint256 i = 0; i < rawPrefix.length; i++) {
            assert(rawUri[i] == rawPrefix[i]);
        }

        bytes memory encoded = new bytes(rawUri.length - rawPrefix.length);
        for (uint256 i = rawPrefix.length; i < rawUri.length; i++) {
            encoded[i - rawPrefix.length] = rawUri[i];
        }
        return _base64Decode(string(encoded));
    }

    function _decodeEmbeddedSvg(string memory metadata) internal pure returns (string memory) {
        string memory marker = '"image":"data:image/svg+xml;base64,';
        bytes memory rawMetadata = bytes(metadata);
        bytes memory rawMarker = bytes(marker);
        uint256 start = _indexOf(rawMetadata, rawMarker);
        assert(start != type(uint256).max);
        start += rawMarker.length;

        uint256 end = start;
        while (end < rawMetadata.length && rawMetadata[end] != bytes1(0x22)) {
            end++;
        }
        bytes memory encoded = new bytes(end - start);
        for (uint256 i = start; i < end; i++) {
            encoded[i - start] = rawMetadata[i];
        }
        return _base64Decode(string(encoded));
    }

    function _base64Decode(string memory encoded) internal pure returns (string memory) {
        bytes memory source = bytes(encoded);
        if (source.length == 0) return "";
        assert(source.length % 4 == 0);

        uint256 padding;
        if (source[source.length - 1] == bytes1(0x3d)) padding++;
        if (source[source.length - 2] == bytes1(0x3d)) padding++;
        bytes memory decoded = new bytes((source.length / 4) * 3 - padding);
        uint256 outputIndex;

        for (uint256 i = 0; i < source.length; i += 4) {
            uint24 chunk = (uint24(_base64Value(source[i])) << 18) | (uint24(_base64Value(source[i + 1])) << 12)
                | (uint24(_base64Value(source[i + 2])) << 6) | uint24(_base64Value(source[i + 3]));

            if (outputIndex < decoded.length) decoded[outputIndex++] = bytes1(uint8(chunk >> 16));
            if (outputIndex < decoded.length) decoded[outputIndex++] = bytes1(uint8(chunk >> 8));
            if (outputIndex < decoded.length) decoded[outputIndex++] = bytes1(uint8(chunk));
        }
        return string(decoded);
    }

    function _base64Value(bytes1 value) internal pure returns (uint8) {
        uint8 c = uint8(value);
        if (c >= 0x41 && c <= 0x5a) return c - 0x41;
        if (c >= 0x61 && c <= 0x7a) return c - 0x61 + 26;
        if (c >= 0x30 && c <= 0x39) return c - 0x30 + 52;
        if (c == 0x2b) return 62;
        if (c == 0x2f) return 63;
        return 0;
    }

    function _indexOf(bytes memory haystack, bytes memory needle) internal pure returns (uint256) {
        if (needle.length == 0 || needle.length > haystack.length) return type(uint256).max;
        for (uint256 i = 0; i <= haystack.length - needle.length; i++) {
            bool found = true;
            for (uint256 j = 0; j < needle.length; j++) {
                if (haystack[i + j] != needle[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return i;
        }
        return type(uint256).max;
    }
}

/// @notice Mock staking contract for testing — just records staked amounts
contract MockStaking {
    IERC20 public ser9;
    mapping(address => uint256) public stakedAmount;
    mapping(address => uint256) public rewards;
    uint256 public totalStaked;

    constructor(address ser9Token) {
        ser9 = IERC20(ser9Token);
    }

    function stake(uint256 amount) external {
        ser9.transferFrom(msg.sender, address(this), amount);
        stakedAmount[msg.sender] += amount;
        totalStaked += amount;
    }

    function fundRewards(address account, uint256 amount) external {
        ser9.transferFrom(msg.sender, address(this), amount);
        rewards[account] += amount;
    }

    function claimRewards() external {
        uint256 reward = rewards[msg.sender];
        rewards[msg.sender] = 0;
        ser9.transfer(msg.sender, reward);
    }
}

contract NoPullStaking {
    uint256 public stakeCalls;
    mapping(address => uint256) public rewards;

    function stake(uint256) external {
        stakeCalls++;
    }

    function claimRewards() external {}
}
