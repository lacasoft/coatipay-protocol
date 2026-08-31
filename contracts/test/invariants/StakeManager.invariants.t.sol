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

    address public constant GUARDIAN = address(0xDEAD);

    function setUp() public {
        usdc = new MockUSDC();
        stakeManager = new StakeManager(address(usdc), GUARDIAN);
        handler = new StakeManagerHandler(stakeManager, usdc);

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

    // ── Invariante 3: conservación del USDC ──────────────────
    //
    // Sin slashing (ADR-004) el stake solo tiene dos destinos: sigue en el
    // contrato a nombre de su dueño, o volvió al nodeit. Ninguna otra parte
    // puede sacarlo, así que la conservación es exacta, no una desigualdad.

    function invariant_usdcConservation() public view {
        uint256 sumOfStakes = 0;
        uint256 n = handler.actorsLength();
        for (uint256 i = 0; i < n; i++) {
            address actor = handler.actors(i);
            StakeManager.StakeInfo memory info = stakeManager.getStakeInfo(actor);
            sumOfStakes += info.staked + info.pendingWithdrawal;
        }

        uint256 inContract = usdc.balanceOf(address(stakeManager));
        uint256 deposited = handler.ghost_totalDeposited();
        uint256 withdrawn = handler.ghost_totalWithdrawn();

        assertEq(inContract, sumOfStakes, "el saldo del contrato no cuadra con la suma de stakes");
        assertEq(deposited, sumOfStakes + withdrawn, "no cuadra la contabilidad del USDC");
    }

    // ── Invariant 5: USDC reference immutable ────────────────

    function invariant_usdcImmutable() public view {
        assertEq(address(stakeManager.usdc()), address(usdc), "USDC reference changed");
    }
}
