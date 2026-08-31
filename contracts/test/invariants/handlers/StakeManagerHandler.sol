// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {StakeManager} from "../../../src/StakeManager.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";

/// @title StakeManagerHandler
/// @notice Bounded random-action harness for StakeManager invariant testing.
///         Foundry's invariant runner calls public functions of this contract
///         with random fuzzed inputs; we translate those into valid calls
///         against the system under test while maintaining ghost variables
///         that the invariants then verify.
/// @dev    Actors are a small fixed set (5 EOAs). The handler funds them
///         with USDC on demand to avoid silent reverts from missing balance.
contract StakeManagerHandler is Test {
    StakeManager public immutable stakeManager;
    MockUSDC public immutable usdc;

    address[] public actors;

    // ── Ghost state ───────────────────────────────────────────
    // Tracked outside the contract so invariants can verify against it.

    /// @notice Cumulative USDC withdrawn (executed) across all operators.
    uint256 public ghost_totalWithdrawn;

    /// @notice Cumulative USDC deposited across all operators.
    uint256 public ghost_totalDeposited;

    /// @notice Previous (staked + pendingWithdrawal) per actor; used to
    ///         verify monotonicity properties.
    mapping(address => uint256) public ghost_lastBalance;

    /// @notice Number of state-mutating calls observed; used as a sanity
    ///         signal that the fuzzer is actually doing work.
    uint256 public ghost_calls;

    constructor(StakeManager _stakeManager, MockUSDC _usdc) {
        stakeManager = _stakeManager;
        usdc = _usdc;

        // 5 fixed actors — small enough to keep state tractable, large
        // enough to exercise multi-operator interactions.
        actors.push(makeAddr("actor1"));
        actors.push(makeAddr("actor2"));
        actors.push(makeAddr("actor3"));
        actors.push(makeAddr("actor4"));
        actors.push(makeAddr("actor5"));
    }

    // ── Helpers ───────────────────────────────────────────────

    function _pickActor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _info(address actor) internal view returns (uint256 staked, uint256 pending) {
        StakeManager.StakeInfo memory info = stakeManager.getStakeInfo(actor);
        return (info.staked, info.pendingWithdrawal);
    }

    function _balanceOf(address actor) internal view returns (uint256) {
        (uint256 s, uint256 p) = _info(actor);
        return s + p;
    }

    // ── Fuzzed entry points ───────────────────────────────────

    function deposit(uint256 actorSeed, uint256 amount) external {
        address actor = _pickActor(actorSeed);
        amount = bound(amount, 1, 10_000_000_000); // 1 USDC base unit to 10k USDC

        ghost_lastBalance[actor] = _balanceOf(actor);

        usdc.mint(actor, amount);
        vm.startPrank(actor);
        usdc.approve(address(stakeManager), amount);
        stakeManager.deposit(amount);
        vm.stopPrank();

        ghost_totalDeposited += amount;
        ghost_calls++;
    }

    function requestWithdrawal(uint256 actorSeed, uint256 amount) external {
        address actor = _pickActor(actorSeed);
        (uint256 staked,) = _info(actor);
        if (staked == 0) return; // skip cleanly — no-op state

        amount = bound(amount, 1, staked);
        ghost_lastBalance[actor] = _balanceOf(actor);

        vm.prank(actor);
        stakeManager.requestWithdrawal(amount);

        ghost_calls++;
    }

    function executeWithdrawal(uint256 actorSeed, uint256 warpSeconds) external {
        address actor = _pickActor(actorSeed);
        (, uint256 pending) = _info(actor);
        if (pending == 0) return;

        // Warp far enough to satisfy the 7-day timelock most of the time.
        warpSeconds = bound(warpSeconds, 1, 30 days);
        vm.warp(block.timestamp + warpSeconds);

        ghost_lastBalance[actor] = _balanceOf(actor);

        vm.prank(actor);
        try stakeManager.executeWithdrawal() {
            ghost_totalWithdrawn += pending;
            ghost_calls++;
        } catch {
            // Timelock not yet expired — fine, no state change.
        }
    }

    // ── Accessors for invariants ──────────────────────────────

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }
}
