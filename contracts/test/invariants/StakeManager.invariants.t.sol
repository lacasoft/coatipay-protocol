// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {StakeManager} from "../../src/StakeManager.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {StakeManagerHandler} from "./handlers/StakeManagerHandler.sol";

/// @title StakeManager invariant tests
/// @notice Property-based fuzzing — Foundry's invariant runner generates
///         random sequences of handler calls and verifies the `invariant_*`
///         functions still hold after each sequence.
/// @dev    Each invariant corresponds 1:1 with an entry in
///         `audits/SCOPE.md §5 (System Invariants)`. If you change an
///         invariant here, update the doc.
contract StakeManagerInvariants is Test {
    StakeManager public stakeManager;
    MockUSDC public usdc;
    StakeManagerHandler public handler;

    address public constant TREASURY = address(0xC0FFEE);
    address public constant GUARDIAN = address(0xDEAD);
    address public constant DISPUTE_RESOLVER = address(0xDEFEA7);

    function setUp() public {
        usdc = new MockUSDC();
        stakeManager = new StakeManager(address(usdc), GUARDIAN, TREASURY);

        vm.prank(GUARDIAN);
        stakeManager.initialize(DISPUTE_RESOLVER);

        handler = new StakeManagerHandler(stakeManager, usdc, DISPUTE_RESOLVER);

        // Tell the invariant runner: only call the handler's public fns
        // when generating random sequences. Without this, the runner would
        // call StakeManager.deposit() directly with the test contract as
        // msg.sender, which would fail because the test contract has no
        // approval flow.
        targetContract(address(handler));
    }

    // ── Invariant 1: Solvency ────────────────────────────────
    //
    // SCOPE.md §5/StakeManager invariant 8:
    //   "Contract USDC balance ≥ Σ all operators' (staked + pendingWithdrawal)"
    //
    // The contract must always hold AT LEAST enough USDC to cover every
    // operator's outstanding stake + pending withdrawal. Surplus is harmless.

    function invariant_solvency() public view {
        uint256 sumOfStakes = 0;
        uint256 n = handler.actorsLength();
        for (uint256 i = 0; i < n; i++) {
            address actor = handler.actors(i);
            StakeManager.StakeInfo memory info = stakeManager.getStakeInfo(actor);
            sumOfStakes += info.staked + info.pendingWithdrawal;
        }
        assertGe(
            usdc.balanceOf(address(stakeManager)), sumOfStakes, "Contract USDC balance below sum of outstanding stakes"
        );
    }

    // ── Invariant 2: Slashed funds reach treasury ────────────
    //
    // SCOPE.md §5/StakeManager invariant 2:
    //   "Treasury is immutable post-construction. Slashes always go to
    //    treasury, never elsewhere."
    //
    // ghost_totalSlashed tracks how much USDC actually left the operators'
    // accounting via slash() calls. Treasury must have received at least
    // that much.

    function invariant_slashedFundsReachTreasury() public view {
        assertGe(
            usdc.balanceOf(TREASURY),
            handler.ghost_totalSlashed(),
            "Treasury USDC balance below cumulative slashed amount"
        );
    }

    // ── Invariant 3: Conservation of USDC across all parties ─
    //
    // Stronger version of solvency: every USDC unit deposited must end up
    // somewhere accountable — still in the contract, withdrawn back to an
    // operator, or slashed to treasury. No USDC vanishes.

    function invariant_usdcConservation() public view {
        uint256 sumOfStakes = 0;
        uint256 n = handler.actorsLength();
        for (uint256 i = 0; i < n; i++) {
            address actor = handler.actors(i);
            StakeManager.StakeInfo memory info = stakeManager.getStakeInfo(actor);
            sumOfStakes += info.staked + info.pendingWithdrawal;
        }

        uint256 inContract = usdc.balanceOf(address(stakeManager));
        uint256 inTreasury = usdc.balanceOf(TREASURY);
        uint256 deposited = handler.ghost_totalDeposited();
        uint256 withdrawn = handler.ghost_totalWithdrawn();
        uint256 slashed = handler.ghost_totalSlashed();

        // deposited = (still in contract for the operators) + withdrawn + slashed
        // i.e. contract balance == deposited - withdrawn - slashed
        // and treasury balance >= slashed (>= because earlier slashes may
        // have happened before our ghost tracking caught up via the cap-at-
        // available behavior — in practice ghost_totalSlashed === treasury
        // balance, but we use >= to be defensive).
        assertEq(inContract, sumOfStakes, "Contract balance != sum of stake balances");
        assertEq(deposited, sumOfStakes + withdrawn + slashed, "USDC accounting mismatch");
        assertGe(inTreasury, slashed, "Treasury below slashed");
    }

    // ── Invariant 4: Treasury immutable ──────────────────────
    //
    // SCOPE.md §5/StakeManager invariant 2: "Treasury is immutable".
    // It's `immutable` in the bytecode, so verifying via getter is the
    // strongest assertion the fuzzer can make.

    function invariant_treasuryImmutable() public view {
        assertEq(stakeManager.treasury(), TREASURY, "Treasury changed after construction");
    }

    // ── Invariant 5: USDC reference immutable ────────────────

    function invariant_usdcImmutable() public view {
        assertEq(address(stakeManager.usdc()), address(usdc), "USDC reference changed");
    }

    // ── Invariant 6: DisputeResolver wiring immutable ────────
    //
    // SCOPE.md §5/StakeManager invariant 1: "Initialization is one-shot".
    // Once initialize() set the resolver, that address never changes.

    function invariant_disputeResolverImmutable() public view {
        assertEq(stakeManager.disputeResolver(), DISPUTE_RESOLVER, "DisputeResolver changed");
    }
}
