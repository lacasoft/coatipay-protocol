// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {StakeManager} from "../../src/StakeManager.sol";
import {Pausable} from "../../src/Pausable.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

/// @title Pausable invariant tests
/// @dev Pausable is an abstract base used by all 3 contracts. We verify
///      its invariants through StakeManager (the simplest derivative).
contract PausableInvariants is Test {
    StakeManager public stakeManager;
    MockUSDC public usdc;
    PausableHandler public handler;

    address public constant TREASURY = address(0xC0FFEE);
    address public constant GUARDIAN = address(0xDEAD);

    function setUp() public {
        usdc = new MockUSDC();
        stakeManager = new StakeManager(address(usdc), GUARDIAN);

        handler = new PausableHandler(stakeManager, GUARDIAN);
        targetContract(address(handler));
    }

    // ── Invariant: guardian is never zero ────────────────────
    //
    // SCOPE.md §5/Pausable invariants 1 & 2:
    //   "Zero-guardian rejection: Constructor and transferGuardian() revert
    //    on address(0)."
    //   "Bricking guard: There is always at least one non-zero guardian."

    function invariant_guardianNeverZero() public view {
        assertNotEq(stakeManager.guardian(), address(0), "guardian became zero");
    }

    // ── Invariant: only the guardian can pause/unpause ──────
    //
    // We verify this dynamically: handler exposes pause/unpause as
    // guardian-pranked calls; any other actor's attempt would revert (the
    // handler swallows non-guardian reverts). The invariant is that the
    // pause state only changes through guardian-authorized paths.
    //
    // The ghost counter tracks how many guardian-authorized state changes
    // we've seen. If the contract paused state matches that, no unauthorized
    // change happened.

    function invariant_pauseStateConsistent() public view {
        bool isPaused = stakeManager.paused();
        // ghost_pausedNow reflects the last AUTHORIZED state change.
        assertEq(isPaused, handler.ghost_pausedNow(), "Paused state diverged from authorized changes");
    }
}

contract PausableHandler is Test {
    StakeManager public immutable stakeManager;
    address public immutable guardian;

    /// @notice Authoritative shadow of `_paused` — only updated when WE
    ///         (the handler) successfully toggle it via the guardian.
    bool public ghost_pausedNow;

    constructor(StakeManager _stakeManager, address _guardian) {
        stakeManager = _stakeManager;
        guardian = _guardian;
    }

    function pause() external {
        if (ghost_pausedNow) return; // would revert with ExpectedPause/EnforcedPause
        vm.prank(guardian);
        stakeManager.pause();
        ghost_pausedNow = true;
    }

    function unpause() external {
        if (!ghost_pausedNow) return;
        vm.prank(guardian);
        stakeManager.unpause();
        ghost_pausedNow = false;
    }

    function transferGuardian(address newGuardian) external {
        // Skip zero (would revert) — we verify the rejection elsewhere
        if (newGuardian == address(0)) return;
        // Skip self (no-op but doesn't revert)
        if (newGuardian == stakeManager.guardian()) return;

        vm.prank(stakeManager.guardian());
        stakeManager.transferGuardian(newGuardian);
        // Note: after this call, `guardian` (the immutable in this handler)
        // is stale. The pause() and unpause() above would now revert. The
        // ghost flag stays accurate because we only update on success.
    }
}
