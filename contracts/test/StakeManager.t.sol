// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {StakeManager} from "../src/StakeManager.sol";
import {Pausable} from "../src/Pausable.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract StakeManagerTest is Test {
    StakeManager stakeManager;
    MockUSDC usdc;

    address operator = makeAddr("operator");
    address treasury = makeAddr("treasury");
    address guardian = makeAddr("guardian");

    uint256 constant STAKE = 500_000_000; // 500 USDC
    uint256 constant TIMELOCK = 7 days;

    function setUp() public {
        usdc = new MockUSDC();
        stakeManager = new StakeManager(address(usdc), guardian);

        usdc.mint(operator, 10_000 * 1e6); // 10,000 USDC
    }

    // ── deposit ───────────────────────────────────────────────

    function test_Deposit_Success() public {
        _deposit(operator, STAKE);

        StakeManager.StakeInfo memory info = stakeManager.getStakeInfo(operator);
        assertEq(info.staked, STAKE);
    }

    function test_Deposit_EmitsEvent() public {
        vm.startPrank(operator);
        usdc.approve(address(stakeManager), STAKE);

        vm.expectEmit(true, false, false, true);
        emit StakeManager.StakeDeposited(operator, STAKE);

        stakeManager.deposit(STAKE);
        vm.stopPrank();
    }

    function test_Deposit_Cumulative() public {
        _deposit(operator, STAKE);

        uint256 topUp = 100_000_000;
        _deposit(operator, topUp);

        StakeManager.StakeInfo memory info = stakeManager.getStakeInfo(operator);
        assertEq(info.staked, STAKE + topUp);
    }

    // ── requestWithdrawal ─────────────────────────────────────

    function test_RequestWithdrawal_Success() public {
        _deposit(operator, STAKE);

        vm.prank(operator);
        stakeManager.requestWithdrawal(STAKE);

        StakeManager.StakeInfo memory info = stakeManager.getStakeInfo(operator);
        assertEq(info.staked, 0);
        assertEq(info.pendingWithdrawal, STAKE);
        assertEq(info.unlockAt, block.timestamp + TIMELOCK);
    }

    function test_RequestWithdrawal_EmitsEvent() public {
        _deposit(operator, STAKE);

        vm.expectEmit(true, false, false, true);
        emit StakeManager.WithdrawalRequested(operator, STAKE, block.timestamp + TIMELOCK);

        vm.prank(operator);
        stakeManager.requestWithdrawal(STAKE);
    }

    function test_RequestWithdrawal_Revert_InsufficientStake() public {
        _deposit(operator, STAKE);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(StakeManager.InsufficientStake.selector, STAKE, STAKE + 1));
        stakeManager.requestWithdrawal(STAKE + 1);
    }

    // ── executeWithdrawal ─────────────────────────────────────

    function test_ExecuteWithdrawal_AfterTimelock() public {
        _deposit(operator, STAKE);

        vm.prank(operator);
        stakeManager.requestWithdrawal(STAKE);

        uint256 balanceBefore = usdc.balanceOf(operator);

        vm.warp(block.timestamp + TIMELOCK + 1);

        vm.prank(operator);
        stakeManager.executeWithdrawal();

        uint256 balanceAfter = usdc.balanceOf(operator);
        assertEq(balanceAfter - balanceBefore, STAKE);

        StakeManager.StakeInfo memory info = stakeManager.getStakeInfo(operator);
        assertEq(info.pendingWithdrawal, 0);
        assertEq(info.unlockAt, 0);
    }

    function test_ExecuteWithdrawal_Revert_TimelockNotExpired() public {
        _deposit(operator, STAKE);

        vm.prank(operator);
        stakeManager.requestWithdrawal(STAKE);

        vm.warp(block.timestamp + TIMELOCK - 1); // one second before unlock

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(StakeManager.TimelockNotExpired.selector, block.timestamp + 1));
        stakeManager.executeWithdrawal();
    }

    function test_ExecuteWithdrawal_Revert_NoPendingWithdrawal() public {
        _deposit(operator, STAKE);

        vm.prank(operator);
        vm.expectRevert(StakeManager.NoPendingWithdrawal.selector);
        stakeManager.executeWithdrawal();
    }

    // ── Fuzz ─────────────────────────────────────────────────

    function testFuzz_DepositAndWithdraw_FullCycle(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000 * 1e6); // 1 micro-USDC to 1M USDC

        usdc.mint(operator, amount);
        _deposit(operator, amount);

        vm.prank(operator);
        stakeManager.requestWithdrawal(amount);

        vm.warp(block.timestamp + TIMELOCK + 1);

        uint256 balBefore = usdc.balanceOf(operator);

        vm.prank(operator);
        stakeManager.executeWithdrawal();

        assertEq(usdc.balanceOf(operator) - balBefore, amount);
    }


    // ── Pausable ──────────────────────────────────────────────

    function test_Pause_DepositRevertsWhenPaused() public {
        vm.prank(guardian);
        stakeManager.pause();

        vm.startPrank(operator);
        usdc.approve(address(stakeManager), STAKE);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        stakeManager.deposit(STAKE);
        vm.stopPrank();
    }

    function test_Pause_RequestWithdrawalRevertsWhenPaused() public {
        _deposit(operator, STAKE);

        vm.prank(guardian);
        stakeManager.pause();

        vm.prank(operator);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        stakeManager.requestWithdrawal(STAKE);
    }

    function test_Pause_ExecuteWithdrawalRevertsWhenPaused() public {
        _deposit(operator, STAKE);

        vm.prank(operator);
        stakeManager.requestWithdrawal(STAKE);

        vm.warp(block.timestamp + TIMELOCK + 1);

        vm.prank(guardian);
        stakeManager.pause();

        vm.prank(operator);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        stakeManager.executeWithdrawal();
    }

    function test_Pause_UnpauseRestoresOperations() public {
        vm.prank(guardian);
        stakeManager.pause();

        vm.prank(guardian);
        stakeManager.unpause();

        // deposit should work again
        _deposit(operator, STAKE);

        StakeManager.StakeInfo memory info = stakeManager.getStakeInfo(operator);
        assertEq(info.staked, STAKE);
    }

    // ── Helpers ───────────────────────────────────────────────

    /// @dev Approve + deposit by `op`. Operator must already have USDC.
    function _deposit(address op, uint256 amount) internal {
        vm.startPrank(op);
        usdc.approve(address(stakeManager), amount);
        stakeManager.deposit(amount);
        vm.stopPrank();
    }

    // ── Guardas del constructor ───────────────────────────────

    function test_Constructor_Revert_ZeroUsdc() public {
        vm.expectRevert(StakeManager.ZeroAddress.selector);
        new StakeManager(address(0), guardian);
    }

    function test_Constructor_Revert_ZeroGuardian() public {
        vm.expectRevert(Pausable.ZeroGuardian.selector);
        new StakeManager(address(usdc), address(0));
    }


}
