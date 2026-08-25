// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {DisputeResolver} from "../src/DisputeResolver.sol";
import {StakeManager} from "../src/StakeManager.sol";
import {Pausable} from "../src/Pausable.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract DisputeResolverTest is Test {
    DisputeResolver resolver;
    StakeManager stakeManager;
    MockUSDC usdc;

    address merchant = makeAddr("merchant");
    address nodeOperator = makeAddr("nodeOperator");
    address treasury = makeAddr("treasury");
    address guardian = makeAddr("guardian");
    address arbiter1 = makeAddr("arbiter1");
    address arbiter2 = makeAddr("arbiter2");
    address arbiter3 = makeAddr("arbiter3");
    address arbiter4 = makeAddr("arbiter4");
    address arbiter5 = makeAddr("arbiter5");
    address randomUser = makeAddr("randomUser");

    uint256 constant STAKE = 500_000_000; // 500 USDC
    uint256 constant RESPONSE_WINDOW = 48 hours;
    string constant EVIDENCE_CID = "bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi";
    string constant COUNTER_CID = "bafybeihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku";

    bytes32 paymentIntentId;

    function setUp() public {
        usdc = new MockUSDC();

        address[] memory arbiters = new address[](5);
        arbiters[0] = arbiter1;
        arbiters[1] = arbiter2;
        arbiters[2] = arbiter3;
        arbiters[3] = arbiter4;
        arbiters[4] = arbiter5;

        // Deploy StakeManager first, then wire up resolver via initialize().
        // Operator stakes directly via stakeManager.deposit() — no
        // depositFor proxy anymore (refactored away to eliminate Slither's
        // arbitrary-send-erc20 finding).
        stakeManager = new StakeManager(address(usdc), guardian, treasury);

        resolver = new DisputeResolver(address(stakeManager), treasury, arbiters, guardian);

        vm.prank(guardian);
        stakeManager.initialize(address(resolver));

        // Stake the node operator
        usdc.mint(nodeOperator, STAKE);
        vm.startPrank(nodeOperator);
        usdc.approve(address(stakeManager), STAKE);
        stakeManager.deposit(STAKE);
        vm.stopPrank();

        paymentIntentId = keccak256(abi.encodePacked("pi_testintent001"));
    }

    // ── Constructor ───────────────────────────────────────────

    function test_Constructor_SetsArbiters() public view {
        assertTrue(resolver.isArbiter(arbiter1));
        assertTrue(resolver.isArbiter(arbiter2));
        assertTrue(resolver.isArbiter(arbiter3));
        assertTrue(resolver.isArbiter(arbiter4));
        assertTrue(resolver.isArbiter(arbiter5));
        assertFalse(resolver.isArbiter(randomUser));
        assertEq(resolver.arbiterCount(), 5);
    }

    function test_Constructor_Revert_NotEnoughArbiters() public {
        address[] memory tooFew = new address[](2);
        tooFew[0] = arbiter1;
        tooFew[1] = arbiter2;

        vm.expectRevert(DisputeResolver.NotEnoughArbiters.selector);
        new DisputeResolver(address(stakeManager), treasury, tooFew, guardian);
    }

    // ── openDispute ───────────────────────────────────────────

    function test_OpenDispute_Success() public {
        bytes32 disputeId = _openDispute();

        DisputeResolver.Dispute memory d = resolver.getDispute(disputeId);

        assertEq(d.paymentIntentId, paymentIntentId);
        assertEq(d.merchant, merchant);
        assertEq(d.nodeOperator, nodeOperator);
        assertEq(d.evidenceCid, EVIDENCE_CID);
        assertEq(uint8(d.status), uint8(DisputeResolver.DisputeStatus.Open));
        assertEq(uint8(d.outcome), uint8(DisputeResolver.DisputeOutcome.None));
    }

    function test_OpenDispute_EmitsEvent() public {
        vm.expectEmit(false, true, true, false);
        emit DisputeResolver.DisputeOpened(bytes32(0), paymentIntentId, merchant, nodeOperator);

        vm.prank(merchant);
        resolver.openDispute(paymentIntentId, nodeOperator, EVIDENCE_CID);
    }

    function test_OpenDispute_MapsIntentToDispute() public {
        bytes32 disputeId = _openDispute();

        assertEq(resolver.intentToDispute(paymentIntentId), disputeId);
    }

    function test_OpenDispute_Revert_AlreadyExists() public {
        _openDispute();

        vm.prank(merchant);
        vm.expectRevert(DisputeResolver.DisputeAlreadyExists.selector);
        resolver.openDispute(paymentIntentId, nodeOperator, EVIDENCE_CID);
    }

    function test_OpenDispute_Revert_EmptyEvidence() public {
        vm.prank(merchant);
        vm.expectRevert(DisputeResolver.EmptyEvidence.selector);
        resolver.openDispute(paymentIntentId, nodeOperator, "");
    }

    // ── respondToDispute ──────────────────────────────────────

    function test_Respond_Success() public {
        bytes32 disputeId = _openDispute();

        vm.prank(nodeOperator);
        resolver.respondToDispute(disputeId, COUNTER_CID);

        DisputeResolver.Dispute memory d = resolver.getDispute(disputeId);
        assertEq(d.counterEvidenceCid, COUNTER_CID);
        assertEq(uint8(d.status), uint8(DisputeResolver.DisputeStatus.NodeResponded));
    }

    function test_Respond_EmitsEvent() public {
        bytes32 disputeId = _openDispute();

        vm.expectEmit(true, true, false, true);
        emit DisputeResolver.DisputeResponded(disputeId, nodeOperator, COUNTER_CID);

        vm.prank(nodeOperator);
        resolver.respondToDispute(disputeId, COUNTER_CID);
    }

    function test_Respond_Revert_NotNodeOperator() public {
        bytes32 disputeId = _openDispute();

        vm.prank(randomUser);
        vm.expectRevert(DisputeResolver.NotNodeOperator.selector);
        resolver.respondToDispute(disputeId, COUNTER_CID);
    }

    function test_Respond_Revert_WindowExpired() public {
        bytes32 disputeId = _openDispute();

        vm.warp(block.timestamp + RESPONSE_WINDOW + 1);

        vm.prank(nodeOperator);
        vm.expectRevert(DisputeResolver.ResponseWindowExpired.selector);
        resolver.respondToDispute(disputeId, COUNTER_CID);
    }

    function test_Respond_Revert_EmptyEvidence() public {
        bytes32 disputeId = _openDispute();

        vm.prank(nodeOperator);
        vm.expectRevert(DisputeResolver.EmptyEvidence.selector);
        resolver.respondToDispute(disputeId, "");
    }

    function test_Respond_Revert_DisputeNotFound() public {
        bytes32 fakeId = keccak256("fake");

        vm.prank(nodeOperator);
        vm.expectRevert(DisputeResolver.DisputeNotFound.selector);
        resolver.respondToDispute(fakeId, COUNTER_CID);
    }

    // ── vote / resolution ─────────────────────────────────────

    function test_Vote_MerchantWins_ThreeVotes_Resolves() public {
        bytes32 disputeId = _openDispute();

        vm.prank(arbiter1);
        resolver.vote(disputeId, DisputeResolver.DisputeOutcome.MerchantWins);

        vm.prank(arbiter2);
        resolver.vote(disputeId, DisputeResolver.DisputeOutcome.MerchantWins);

        // Not resolved yet — only 2 votes
        DisputeResolver.Dispute memory d = resolver.getDispute(disputeId);
        assertEq(uint8(d.status), uint8(DisputeResolver.DisputeStatus.Open));

        vm.prank(arbiter3);
        resolver.vote(disputeId, DisputeResolver.DisputeOutcome.MerchantWins);

        // Now resolved
        d = resolver.getDispute(disputeId);
        assertEq(uint8(d.status), uint8(DisputeResolver.DisputeStatus.Resolved));
        assertEq(uint8(d.outcome), uint8(DisputeResolver.DisputeOutcome.MerchantWins));
        assertGt(d.resolvedAt, 0);
    }

    function test_Vote_NodeWins_ThreeVotes_Resolves() public {
        bytes32 disputeId = _openDispute();
        _respond(disputeId);

        vm.prank(arbiter1);
        resolver.vote(disputeId, DisputeResolver.DisputeOutcome.NodeWins);
        vm.prank(arbiter2);
        resolver.vote(disputeId, DisputeResolver.DisputeOutcome.NodeWins);
        vm.prank(arbiter3);
        resolver.vote(disputeId, DisputeResolver.DisputeOutcome.NodeWins);

        DisputeResolver.Dispute memory d = resolver.getDispute(disputeId);
        assertEq(uint8(d.status), uint8(DisputeResolver.DisputeStatus.Resolved));
        assertEq(uint8(d.outcome), uint8(DisputeResolver.DisputeOutcome.NodeWins));
    }

    function test_Vote_MerchantWins_SlashesStake() public {
        bytes32 disputeId = _openDispute();

        StakeManager.StakeInfo memory before_ = stakeManager.getStakeInfo(nodeOperator);
        assertEq(before_.staked, STAKE);

        vm.prank(arbiter1);
        resolver.vote(disputeId, DisputeResolver.DisputeOutcome.MerchantWins);
        vm.prank(arbiter2);
        resolver.vote(disputeId, DisputeResolver.DisputeOutcome.MerchantWins);
        vm.prank(arbiter3);
        resolver.vote(disputeId, DisputeResolver.DisputeOutcome.MerchantWins);

        // Stake should have been slashed
        StakeManager.StakeInfo memory after_ = stakeManager.getStakeInfo(nodeOperator);
        assertLt(after_.staked, before_.staked);
    }

    function test_Vote_NodeWins_DoesNotSlash() public {
        bytes32 disputeId = _openDispute();

        vm.prank(arbiter1);
        resolver.vote(disputeId, DisputeResolver.DisputeOutcome.NodeWins);
        vm.prank(arbiter2);
        resolver.vote(disputeId, DisputeResolver.DisputeOutcome.NodeWins);
        vm.prank(arbiter3);
        resolver.vote(disputeId, DisputeResolver.DisputeOutcome.NodeWins);

        StakeManager.StakeInfo memory info = stakeManager.getStakeInfo(nodeOperator);
        assertEq(info.staked, STAKE); // unchanged
    }

    function test_Vote_Revert_NotArbiter() public {
        bytes32 disputeId = _openDispute();

        vm.prank(randomUser);
        vm.expectRevert(DisputeResolver.NotArbiter.selector);
        resolver.vote(disputeId, DisputeResolver.DisputeOutcome.MerchantWins);
    }

    function test_Vote_Revert_AlreadyVoted() public {
        bytes32 disputeId = _openDispute();

        vm.prank(arbiter1);
        resolver.vote(disputeId, DisputeResolver.DisputeOutcome.MerchantWins);

        vm.prank(arbiter1);
        vm.expectRevert(DisputeResolver.AlreadyVoted.selector);
        resolver.vote(disputeId, DisputeResolver.DisputeOutcome.MerchantWins);
    }

    function test_Vote_Revert_InvalidOutcome() public {
        bytes32 disputeId = _openDispute();

        vm.prank(arbiter1);
        vm.expectRevert(DisputeResolver.InvalidOutcome.selector);
        resolver.vote(disputeId, DisputeResolver.DisputeOutcome.None);
    }

    function test_Vote_Revert_DisputeAlreadyResolved() public {
        bytes32 disputeId = _openDispute();
        _resolveAsMerchantWins(disputeId);

        vm.prank(arbiter4);
        vm.expectRevert(DisputeResolver.DisputeNotResolvable.selector);
        resolver.vote(disputeId, DisputeResolver.DisputeOutcome.NodeWins);
    }

    // ── expireDispute ─────────────────────────────────────────

    function test_ExpireDispute_Success() public {
        bytes32 disputeId = _openDispute();

        vm.warp(block.timestamp + RESPONSE_WINDOW + 1);

        resolver.expireDispute(disputeId);

        DisputeResolver.Dispute memory d = resolver.getDispute(disputeId);
        assertEq(uint8(d.status), uint8(DisputeResolver.DisputeStatus.Expired));
    }

    function test_ExpireDispute_SlashesStake() public {
        bytes32 disputeId = _openDispute();

        vm.warp(block.timestamp + RESPONSE_WINDOW + 1);
        resolver.expireDispute(disputeId);

        StakeManager.StakeInfo memory info = stakeManager.getStakeInfo(nodeOperator);
        assertLt(info.staked, STAKE);
    }

    function test_ExpireDispute_Revert_WindowNotExpired() public {
        bytes32 disputeId = _openDispute();

        vm.expectRevert(DisputeResolver.ResponseWindowNotExpired.selector);
        resolver.expireDispute(disputeId);
    }

    function test_ExpireDispute_Revert_DisputeNotOpen_AfterResponse() public {
        bytes32 disputeId = _openDispute();
        _respond(disputeId);

        vm.warp(block.timestamp + RESPONSE_WINDOW + 1);

        vm.expectRevert(DisputeResolver.DisputeNotOpen.selector);
        resolver.expireDispute(disputeId);
    }

    // ── isResponseWindowOpen ─────────────────────────────────

    function test_IsResponseWindowOpen_True() public {
        bytes32 disputeId = _openDispute();
        assertTrue(resolver.isResponseWindowOpen(disputeId));
    }

    function test_IsResponseWindowOpen_False_AfterWindow() public {
        bytes32 disputeId = _openDispute();

        vm.warp(block.timestamp + RESPONSE_WINDOW + 1);
        assertFalse(resolver.isResponseWindowOpen(disputeId));
    }

    // ── getDisputeByIntent ────────────────────────────────────

    function test_GetDisputeByIntent() public {
        bytes32 disputeId = _openDispute();

        DisputeResolver.Dispute memory d = resolver.getDisputeByIntent(paymentIntentId);
        assertEq(d.id, disputeId);
    }

    // ── Arbiter management (multisig) ─────────────────────────

    function test_ProposeArbiter_SingleApproval_DoesNotAdd() public {
        address candidate = makeAddr("candidate");

        vm.prank(arbiter1);
        resolver.proposeArbiter(candidate);

        assertFalse(resolver.isArbiter(candidate));
        assertEq(resolver.arbiterCount(), 5);
    }

    function test_ProposeArbiter_TwoApprovals_DoesNotAdd() public {
        address candidate = makeAddr("candidate");

        vm.prank(arbiter1);
        resolver.proposeArbiter(candidate);

        vm.prank(arbiter2);
        resolver.proposeArbiter(candidate);

        assertFalse(resolver.isArbiter(candidate));
        assertEq(resolver.arbiterCount(), 5);
    }

    function test_ProposeArbiter_ThreeApprovals_AddsArbiter() public {
        address candidate = makeAddr("candidate");

        vm.prank(arbiter1);
        resolver.proposeArbiter(candidate);

        vm.prank(arbiter2);
        resolver.proposeArbiter(candidate);

        vm.prank(arbiter3);
        resolver.proposeArbiter(candidate);

        assertTrue(resolver.isArbiter(candidate));
        assertEq(resolver.arbiterCount(), 6);
    }

    function test_ProposeArbiter_ClearsApprovalsAfterAdd() public {
        address candidate = makeAddr("candidate");

        vm.prank(arbiter1);
        resolver.proposeArbiter(candidate);
        vm.prank(arbiter2);
        resolver.proposeArbiter(candidate);
        vm.prank(arbiter3);
        resolver.proposeArbiter(candidate);

        // Approvals should be cleared
        assertFalse(resolver.arbiterApprovals(candidate, arbiter1));
        assertFalse(resolver.arbiterApprovals(candidate, arbiter2));
        assertFalse(resolver.arbiterApprovals(candidate, arbiter3));
    }

    function test_ProposeArbiter_EmitsArbiterAdded() public {
        address candidate = makeAddr("candidate");

        vm.prank(arbiter1);
        resolver.proposeArbiter(candidate);
        vm.prank(arbiter2);
        resolver.proposeArbiter(candidate);

        vm.expectEmit(true, false, false, false);
        emit DisputeResolver.ArbiterAdded(candidate);

        vm.prank(arbiter3);
        resolver.proposeArbiter(candidate);
    }

    function test_ProposeArbiter_Revert_NotArbiter() public {
        address candidate = makeAddr("candidate");

        vm.prank(randomUser);
        vm.expectRevert(DisputeResolver.NotArbiter.selector);
        resolver.proposeArbiter(candidate);
    }

    function test_ProposeArbiter_NewArbiterCanVoteOnNextCandidate() public {
        address candidate1 = makeAddr("candidate1");
        address candidate2 = makeAddr("candidate2");

        // Add candidate1 via 3 approvals
        vm.prank(arbiter1);
        resolver.proposeArbiter(candidate1);
        vm.prank(arbiter2);
        resolver.proposeArbiter(candidate1);
        vm.prank(arbiter3);
        resolver.proposeArbiter(candidate1);

        assertTrue(resolver.isArbiter(candidate1));

        // Now candidate1 can participate in approving candidate2
        vm.prank(arbiter1);
        resolver.proposeArbiter(candidate2);
        vm.prank(arbiter2);
        resolver.proposeArbiter(candidate2);
        vm.prank(candidate1);
        resolver.proposeArbiter(candidate2);

        assertTrue(resolver.isArbiter(candidate2));
        assertEq(resolver.arbiterCount(), 7);
    }

    function test_RemoveArbiter_Success() public {
        vm.prank(arbiter1);
        resolver.removeArbiter(arbiter5);

        assertFalse(resolver.isArbiter(arbiter5));
        assertEq(resolver.arbiterCount(), 4);
    }

    function test_RemoveArbiter_Revert_BelowMinimum() public {
        // Remove down to 3
        vm.prank(arbiter1);
        resolver.removeArbiter(arbiter4);
        vm.prank(arbiter1);
        resolver.removeArbiter(arbiter5);

        // Now at 3 — cannot remove more
        vm.prank(arbiter1);
        vm.expectRevert(DisputeResolver.NotEnoughArbiters.selector);
        resolver.removeArbiter(arbiter3);
    }

    // ── Pausable ─────────────────────────────────────────────

    function test_Pause_OpenDisputeRevertsWhenPaused() public {
        vm.prank(guardian);
        resolver.pause();

        vm.prank(merchant);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        resolver.openDispute(paymentIntentId, nodeOperator, EVIDENCE_CID);
    }

    function test_Pause_RespondRevertsWhenPaused() public {
        bytes32 disputeId = _openDispute();

        vm.prank(guardian);
        resolver.pause();

        vm.prank(nodeOperator);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        resolver.respondToDispute(disputeId, COUNTER_CID);
    }

    function test_Pause_VoteRevertsWhenPaused() public {
        bytes32 disputeId = _openDispute();

        vm.prank(guardian);
        resolver.pause();

        vm.prank(arbiter1);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        resolver.vote(disputeId, DisputeResolver.DisputeOutcome.MerchantWins);
    }

    function test_Pause_UnpauseRestoresOperations() public {
        vm.prank(guardian);
        resolver.pause();

        vm.prank(guardian);
        resolver.unpause();

        // openDispute should work again
        vm.prank(merchant);
        bytes32 disputeId = resolver.openDispute(paymentIntentId, nodeOperator, EVIDENCE_CID);

        DisputeResolver.Dispute memory d = resolver.getDispute(disputeId);
        assertEq(uint8(d.status), uint8(DisputeResolver.DisputeStatus.Open));
    }

    // ── Fuzz ─────────────────────────────────────────────────

    function testFuzz_OpenDispute_UniqueIdPerIntent(bytes32 intentId1, bytes32 intentId2) public {
        vm.assume(intentId1 != intentId2);

        vm.startPrank(merchant);
        bytes32 d1 = resolver.openDispute(intentId1, nodeOperator, EVIDENCE_CID);
        bytes32 d2 = resolver.openDispute(intentId2, nodeOperator, EVIDENCE_CID);
        vm.stopPrank();

        assertTrue(d1 != d2);
    }

    // ── Helpers ───────────────────────────────────────────────

    function _openDispute() internal returns (bytes32) {
        vm.prank(merchant);
        return resolver.openDispute(paymentIntentId, nodeOperator, EVIDENCE_CID);
    }

    function _respond(bytes32 disputeId) internal {
        vm.prank(nodeOperator);
        resolver.respondToDispute(disputeId, COUNTER_CID);
    }

    function _resolveAsMerchantWins(bytes32 disputeId) internal {
        vm.prank(arbiter1);
        resolver.vote(disputeId, DisputeResolver.DisputeOutcome.MerchantWins);
        vm.prank(arbiter2);
        resolver.vote(disputeId, DisputeResolver.DisputeOutcome.MerchantWins);
        vm.prank(arbiter3);
        resolver.vote(disputeId, DisputeResolver.DisputeOutcome.MerchantWins);
    }

    // ── Tanda C fixes — slash percentage + treasury transfer ──

    function test_Vote_MerchantWins_SlashesExactly20Percent() public {
        // Previously _executeSlash passed type(uint256).max → StakeManager
        // capped to 100% of stake, devastating for operators. Now must
        // slash SLASH_PERCENTAGE (20%) of total stake.
        bytes32 disputeId = _openDispute();

        StakeManager.StakeInfo memory before_ = stakeManager.getStakeInfo(nodeOperator);
        uint256 totalBefore = before_.staked + before_.pendingWithdrawal;
        uint256 expectedSlash = (totalBefore * 20) / 100;
        uint256 treasuryBefore = usdc.balanceOf(treasury);

        _resolveAsMerchantWins(disputeId);

        StakeManager.StakeInfo memory after_ = stakeManager.getStakeInfo(nodeOperator);
        assertEq(after_.staked, before_.staked - expectedSlash);
        assertEq(usdc.balanceOf(treasury), treasuryBefore + expectedSlash);
    }

    // ── Tanda C fixes — constructor zero-check ────────────────

    function test_Constructor_Revert_ZeroTreasury() public {
        address[] memory arbiters = new address[](3);
        arbiters[0] = arbiter1;
        arbiters[1] = arbiter2;
        arbiters[2] = arbiter3;

        vm.expectRevert(DisputeResolver.ZeroTreasury.selector);
        new DisputeResolver(address(stakeManager), address(0), arbiters, guardian);
    }
}
