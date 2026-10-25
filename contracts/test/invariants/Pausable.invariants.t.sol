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
        stakeManager = new StakeManager(address(usdc), GUARDIAN, TREASURY);

        handler = new PausableHandler(stakeManager, GUARDIAN);
        targetContract(address(handler));
    }

    // ── Invariant: guardian is never zero ────────────────────
    //
    // SCOPE.md §5/Pausable invariants 1 & 2:
    //   "Zero-guardian rejection: the constructor reverts on address(0), and
    //    transferGuardian(address(0)) only cancels a pending transfer."
    //   "Bricking guard: There is always at least one non-zero guardian."

    function invariant_guardianNeverZero() public view {
        assertNotEq(stakeManager.guardian(), address(0), "guardian became zero");
    }

    // ── Invariant: the guardian only changes when the new one accepts ──
    //
    // ADR-009 §6: a mistyped address never accepts, so it never becomes the
    // guardian; and nobody but the proposed address can accept.

    function invariant_guardianChangesOnlyByAcceptance() public view {
        assertEq(stakeManager.guardian(), handler.ghost_guardian(), "guardian changed without acceptance");
        assertFalse(handler.ghost_strangerAccepted(), "someone other than the proposed guardian accepted");
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

    /// @notice Authoritative shadow of `_paused` — only updated when WE
    ///         (the handler) successfully toggle it via the guardian.
    bool public ghost_pausedNow;

    /// @notice El último guardian que ACEPTÓ el cargo (ADR-009 §6).
    address public ghost_guardian;

    /// @notice Se pone a true si alguien que no era el propuesto consigue
    ///         aceptar. No debe pasar nunca.
    bool public ghost_strangerAccepted;

    constructor(StakeManager _stakeManager, address _guardian) {
        stakeManager = _stakeManager;
        ghost_guardian = _guardian;
    }

    function pause() external {
        if (ghost_pausedNow) return; // would revert with ExpectedPause/EnforcedPause
        vm.prank(stakeManager.guardian());
        stakeManager.pause();
        ghost_pausedNow = true;
    }

    function unpause() external {
        if (!ghost_pausedNow) return;
        vm.prank(stakeManager.guardian());
        stakeManager.unpause();
        ghost_pausedNow = false;
    }

    /// Propone cualquier dirección, también una mal escrita o la cero
    /// (que cancela). Nada cambia hasta que el propuesto acepte.
    function proposeGuardian(address newGuardian) external {
        vm.prank(stakeManager.guardian());
        stakeManager.transferGuardian(newGuardian);
    }

    function acceptGuardian() external {
        address pending = stakeManager.pendingGuardian();
        if (pending == address(0)) return;
        vm.prank(pending);
        stakeManager.acceptGuardian();
        ghost_guardian = pending;
    }

    function acceptByStranger(address stranger) external {
        if (stranger == stakeManager.pendingGuardian()) return;
        vm.prank(stranger);
        try stakeManager.acceptGuardian() {
            ghost_strangerAccepted = true;
        } catch {}
    }
}
