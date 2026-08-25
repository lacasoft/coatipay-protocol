// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {DisputeResolver} from "../../src/DisputeResolver.sol";
import {StakeManager} from "../../src/StakeManager.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {DisputeResolverHandler} from "./handlers/DisputeResolverHandler.sol";

contract DisputeResolverInvariants is Test {
    DisputeResolver public resolver;
    StakeManager public stakeManager;
    MockUSDC public usdc;
    DisputeResolverHandler public handler;

    address public constant TREASURY = address(0xC0FFEE);
    address public constant GUARDIAN = address(0xDEAD);

    address[] internal arbiterList;

    function setUp() public {
        usdc = new MockUSDC();
        stakeManager = new StakeManager(address(usdc), GUARDIAN, TREASURY);

        arbiterList.push(makeAddr("arb1"));
        arbiterList.push(makeAddr("arb2"));
        arbiterList.push(makeAddr("arb3"));
        arbiterList.push(makeAddr("arb4"));
        arbiterList.push(makeAddr("arb5"));

        resolver = new DisputeResolver(address(stakeManager), TREASURY, arbiterList, GUARDIAN);

        vm.prank(GUARDIAN);
        stakeManager.initialize(address(resolver));

        handler = new DisputeResolverHandler(resolver, stakeManager, usdc, arbiterList);
        targetContract(address(handler));
    }

    // ── Invariant: arbiter count floor ───────────────────────
    //
    // SCOPE.md §5/DisputeResolver invariant 8:
    //   "Arbiter floor: removeArbiter() reverts when arbiterCount == REQUIRED_ARBITERS"
    //
    // The fuzzer doesn't call removeArbiter (handler doesn't expose it),
    // but we still verify the floor as a starting condition.

    function invariant_arbiterCountAboveFloor() public view {
        assertGe(resolver.arbiterCount(), resolver.REQUIRED_ARBITERS(), "arbiterCount fell below REQUIRED_ARBITERS");
    }

    // ── Invariant: vote count consistency ────────────────────
    //
    // SCOPE.md §5/DisputeResolver invariant 3:
    //   "Vote uniqueness: an arbiter's vote on a given dispute can only be
    //    cast once."
    //
    // Combined invariant: total votes (merchant + node) for a dispute must
    // be ≤ arbiterCount, since each arbiter votes at most once.

    function invariant_votesNeverExceedArbiters() public view {
        uint256 n = handler.openedDisputesLength();
        uint256 arbCount = resolver.arbiterCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 disputeId = handler.openedDisputes(i);
            uint256 mw = resolver.merchantWinsVotes(disputeId);
            uint256 nw = resolver.nodeWinsVotes(disputeId);
            assertLe(mw + nw, arbCount, "Total votes exceeds arbiterCount");
        }
    }

    // ── Invariant: status monotonicity ───────────────────────
    //
    // SCOPE.md §5/DisputeResolver invariant 4:
    //   "Resolution is one-shot: once dispute.status == Resolved, no
    //    further votes affect outcome."
    //
    // Once Resolved/Expired, status cannot revert to Open or NodeResponded.
    // The handler doesn't track previous status, but we can verify that any
    // Resolved dispute has outcome != None (i.e., it actually resolved to a
    // concrete outcome, not just set the flag).

    function invariant_resolvedDisputesHaveOutcome() public view {
        uint256 n = handler.openedDisputesLength();
        for (uint256 i = 0; i < n; i++) {
            bytes32 disputeId = handler.openedDisputes(i);
            DisputeResolver.Dispute memory d = resolver.getDispute(disputeId);
            if (d.status == DisputeResolver.DisputeStatus.Resolved) {
                assertTrue(
                    d.outcome == DisputeResolver.DisputeOutcome.MerchantWins
                        || d.outcome == DisputeResolver.DisputeOutcome.NodeWins,
                    "Resolved dispute has outcome == None"
                );
            }
        }
    }

    // ── Invariant: intentToDispute mapping consistency ───────
    //
    // SCOPE.md §5/DisputeResolver invariant 1:
    //   "Disputes are unique per intent: intentToDispute[id] is set once
    //    on first openDispute(); second call reverts."
    //
    // We verify the dual: every disputeId we have must satisfy
    // intentToDispute[that.paymentIntentId] == this.id.

    function invariant_intentToDisputeRoundTrip() public view {
        uint256 n = handler.openedDisputesLength();
        for (uint256 i = 0; i < n; i++) {
            bytes32 disputeId = handler.openedDisputes(i);
            DisputeResolver.Dispute memory d = resolver.getDispute(disputeId);
            assertEq(resolver.intentToDispute(d.paymentIntentId), disputeId, "intentToDispute mapping inconsistent");
        }
    }

    // ── Invariant: treasury immutable ────────────────────────

    function invariant_treasuryImmutable() public view {
        assertEq(resolver.treasury(), TREASURY, "DisputeResolver.treasury changed");
    }

    function invariant_stakeManagerImmutable() public view {
        assertEq(address(resolver.stakeManager()), address(stakeManager), "DisputeResolver.stakeManager changed");
    }
}
