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
    address disputeResolver = makeAddr("disputeResolver");
    address treasury = makeAddr("treasury");
    address guardian = makeAddr("guardian");

    uint256 constant STAKE = 500_000_000; // 500 USDC
    uint256 constant TIMELOCK = 7 days;

    function setUp() public {
        usdc = new MockUSDC();
        stakeManager = new StakeManager(address(usdc), guardian, treasury);

        vm.prank(guardian);
        stakeManager.initialize(disputeResolver);

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

    // ── slash ─────────────────────────────────────────────────

    function test_Slash_ReducesStake() public {
        _deposit(operator, STAKE);

        bytes32 disputeId = keccak256("dispute-1");
        uint256 slashAmount = STAKE / 5; // 20%

        vm.prank(disputeResolver);
        stakeManager.slash(operator, slashAmount, disputeId);

        StakeManager.StakeInfo memory info = stakeManager.getStakeInfo(operator);
        assertEq(info.staked, STAKE - slashAmount);
    }

    function test_Slash_EmitsEvent() public {
        _deposit(operator, STAKE);
        bytes32 disputeId = keccak256("dispute-1");

        vm.expectEmit(true, false, false, true);
        emit StakeManager.Slashed(operator, STAKE / 5, disputeId);

        vm.prank(disputeResolver);
        stakeManager.slash(operator, STAKE / 5, disputeId);
    }

    function test_Slash_CanReachIntoPendingWithdrawal() public {
        _deposit(operator, STAKE);

        // Operator requests to withdraw half
        uint256 halfStake = STAKE / 2;
        vm.prank(operator);
        stakeManager.requestWithdrawal(halfStake);

        // Slash more than remaining staked — should eat into pending
        bytes32 disputeId = keccak256("dispute-big");

        vm.prank(disputeResolver);
        stakeManager.slash(operator, STAKE, disputeId); // slash full amount

        StakeManager.StakeInfo memory info = stakeManager.getStakeInfo(operator);
        assertEq(info.staked, 0);
        assertEq(info.pendingWithdrawal, 0);
    }

    function test_Slash_CapsAtAvailableStake() public {
        _deposit(operator, STAKE);
        bytes32 disputeId = keccak256("dispute-cap");

        // Slash more than staked — should cap at staked amount
        vm.prank(disputeResolver);
        stakeManager.slash(operator, STAKE * 10, disputeId);

        StakeManager.StakeInfo memory info = stakeManager.getStakeInfo(operator);
        assertEq(info.staked, 0);
    }

    function test_Slash_Revert_OnlyDisputeResolver() public {
        _deposit(operator, STAKE);

        vm.prank(operator);
        vm.expectRevert(StakeManager.OnlyDisputeResolver.selector);
        stakeManager.slash(operator, STAKE, bytes32(0));
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

    function testFuzz_Slash_NeverExceedsTotal(uint256 stakeAmount, uint256 slashAmount) public {
        stakeAmount = bound(stakeAmount, 1, 10_000 * 1e6);
        slashAmount = bound(slashAmount, 1, type(uint256).max / 2);

        usdc.mint(operator, stakeAmount);
        _deposit(operator, stakeAmount);

        vm.prank(disputeResolver);
        stakeManager.slash(operator, slashAmount, keccak256("fuzz-dispute"));

        StakeManager.StakeInfo memory info = stakeManager.getStakeInfo(operator);
        uint256 remaining = info.staked + info.pendingWithdrawal;

        // Invariant 1: slash never takes more than what was available
        assertLe(remaining, stakeAmount);

        // Invariant 2: if slashAmount >= stakeAmount, everything is gone
        if (slashAmount >= stakeAmount) {
            assertEq(remaining, 0);
        } else {
            // Otherwise, exactly slashAmount was taken
            assertEq(remaining, stakeAmount - slashAmount);
        }
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

    // ── Tanda C fixes — slash transfers to treasury ───────────

    function test_Slash_TransfersToTreasury() public {
        _deposit(operator, STAKE);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 contractBefore = usdc.balanceOf(address(stakeManager));

        uint256 slashAmount = STAKE / 5; // 20%

        vm.prank(disputeResolver);
        stakeManager.slash(operator, slashAmount, bytes32("test_dispute"));

        // Treasury received the slashed funds
        assertEq(usdc.balanceOf(treasury), treasuryBefore + slashAmount);
        // Contract released them
        assertEq(usdc.balanceOf(address(stakeManager)), contractBefore - slashAmount);
        // Operator's accounting reduced
        StakeManager.StakeInfo memory info = stakeManager.getStakeInfo(operator);
        assertEq(info.staked, STAKE - slashAmount);
    }

    function test_Slash_ZeroAmount_NoTransferAndNoRevert() public {
        _deposit(operator, STAKE);
        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.prank(disputeResolver);
        stakeManager.slash(operator, 0, bytes32("zero_amount"));

        assertEq(usdc.balanceOf(treasury), treasuryBefore);
        StakeManager.StakeInfo memory info = stakeManager.getStakeInfo(operator);
        assertEq(info.staked, STAKE);
    }

    // ── Constructor + initialize zero-checks ──────────────────

    function test_Constructor_Revert_ZeroTreasury() public {
        vm.expectRevert(StakeManager.ZeroTreasury.selector);
        new StakeManager(address(usdc), guardian, address(0));
    }

    function test_Constructor_Revert_ZeroGuardian() public {
        vm.expectRevert(Pausable.ZeroGuardian.selector);
        new StakeManager(address(usdc), address(0), treasury);
    }

    function test_Initialize_Revert_ZeroResolver() public {
        StakeManager fresh = new StakeManager(address(usdc), guardian, treasury);

        vm.prank(guardian);
        vm.expectRevert(StakeManager.ZeroAddress.selector);
        fresh.initialize(address(0));
    }

    function test_Initialize_Revert_AlreadyInitialized() public {
        vm.prank(guardian);
        vm.expectRevert(StakeManager.AlreadyInitialized.selector);
        stakeManager.initialize(disputeResolver);
    }
}
