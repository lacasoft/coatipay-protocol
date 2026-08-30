// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {StakeManager} from "../src/StakeManager.sol";
import {NodeRegistry} from "../src/NodeRegistry.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

/// @dev USDC mock that calls back into a configured target on every transfer.
///      Used to simulate a malicious token (or future hook-enabled USDC) that
///      gives the receiver an opportunity to re-enter the caller.
contract HookUSDC is IERC20 {
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;

    address public reenterTarget;
    bytes public reenterCalldata;
    bool public hookActive;

    function arm(address target, bytes calldata cd) external {
        reenterTarget = target;
        reenterCalldata = cd;
        hookActive = true;
    }

    function mint(address to, uint256 amount) external {
        balances[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balances[msg.sender] >= amount, "insufficient balance");
        balances[msg.sender] -= amount;
        balances[to] += amount;
        _maybeReenter();
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balances[from] >= amount, "insufficient balance");
        require(allowances[from][msg.sender] >= amount, "insufficient allowance");
        balances[from] -= amount;
        balances[to] += amount;
        allowances[from][msg.sender] -= amount;
        _maybeReenter();
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowances[msg.sender][spender] = amount;
        return true;
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return allowances[owner][spender];
    }

    function _maybeReenter() internal {
        if (!hookActive) return;
        // disarm so the re-entered call doesn't recurse infinitely
        hookActive = false;
        (bool ok, bytes memory data) = reenterTarget.call(reenterCalldata);
        if (!ok) {
            // Bubble up the EXACT revert data so the outer
            // `vm.expectRevert(ReentrancyGuardReentrantCall.selector)`
            // can distinguish a guard-triggered revert from any other.
            assembly {
                revert(add(data, 32), mload(data))
            }
        }
    }
}

/// @dev Reverse direction: if `_maybeReenter` succeeds, that means the guard
///      was missing — so we expect this contract's `_maybeReenter` to be
///      reached and the re-entered call to revert via ReentrancyGuard.
contract ReentrancyGuardTest is Test {
    HookUSDC usdc;
    StakeManager stakeManager;
    NodeRegistry nodeRegistry;

    address operator = makeAddr("operator");
    address treasury = makeAddr("treasury");
    address guardian = makeAddr("guardian");

    uint256 constant STAKE = 500_000_000;

    function setUp() public {
        usdc = new HookUSDC();
        stakeManager = new StakeManager(address(usdc), guardian);
        nodeRegistry = new NodeRegistry(address(stakeManager), guardian, 40_000_000);

        usdc.mint(operator, 10_000 * 1e6);
    }

    /// @notice If a malicious USDC transferFrom callback re-enters
    ///         StakeManager.deposit(), the second call must revert with
    ///         ReentrancyGuardReentrantCall.
    function test_StakeManager_Deposit_ReentryBlocked() public {
        vm.startPrank(operator);
        usdc.approve(address(stakeManager), 2 * STAKE);
        vm.stopPrank();

        // Arm USDC to call deposit() again from inside the first deposit's transferFrom.
        // We have to call AS the operator (msg.sender of the re-entry) for the
        // second deposit to deduct from operator's allowance — but the hook
        // executes inside transferFrom, which runs as the StakeManager (msg.sender).
        // So we encode the call directly; expect revert from the guard.
        usdc.arm(address(stakeManager), abi.encodeCall(StakeManager.deposit, (STAKE)));

        vm.prank(operator);
        // The outer deposit should revert because the re-entry inside the USDC
        // hook hits ReentrancyGuardReentrantCall, which our HookUSDC bubbles up.
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        stakeManager.deposit(STAKE);
    }

    /// @notice executeWithdrawal does the transfer to the operator; if the
    ///         operator-controlled contract re-enters, the second call must revert.
    function test_StakeManager_ExecuteWithdrawal_ReentryBlocked() public {
        // Set up a stake first (without the hook armed)
        vm.startPrank(operator);
        usdc.approve(address(stakeManager), STAKE);
        stakeManager.deposit(STAKE);
        stakeManager.requestWithdrawal(STAKE);
        vm.stopPrank();

        vm.warp(block.timestamp + 7 days + 1);

        // Arm USDC to re-enter executeWithdrawal during the transfer payout.
        usdc.arm(address(stakeManager), abi.encodeCall(StakeManager.executeWithdrawal, ()));

        vm.prank(operator);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        stakeManager.executeWithdrawal();
    }


    /// @notice After the depositFor → register refactor, NodeRegistry.register
    ///         no longer makes any USDC transfers itself — it only reads
    ///         StakeManager.getStakeInfo() (a view). The previous
    ///         test_NodeRegistry_Register_ReentryBlocked that exercised the
    ///         USDC hook → register → depositFor chain has no equivalent
    ///         attack surface to exercise; the entry was eliminated
    ///         structurally, not just guarded.
    function test_NodeRegistry_Register_NoExternalTransferToReenter() public {
        vm.startPrank(operator);
        usdc.approve(address(stakeManager), STAKE);
        stakeManager.deposit(STAKE);
        vm.stopPrank();

        // Arm USDC to do something nasty if it ever gets called from register.
        // It won't — the hook will never fire because register no longer calls
        // USDC. If a future refactor reintroduces a USDC call from register,
        // the hook will fire and the assertion below (that register succeeded
        // and the hook is still armed) will fail.
        usdc.arm(address(nodeRegistry), abi.encodeCall(NodeRegistry.register, ("https://hijack.example")));

        vm.prank(operator);
        nodeRegistry.register("https://legit.example");

        // Hook is still armed (it never fired) — confirms register made zero
        // USDC calls during its execution.
        assertTrue(usdc.hookActive(), "USDC hook fired - register made an unexpected USDC call");
    }
}
