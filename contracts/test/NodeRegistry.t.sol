// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {NodeRegistry} from "../src/NodeRegistry.sol";
import {StakeManager} from "../src/StakeManager.sol";
import {Pausable} from "../src/Pausable.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract NodeRegistryTest is Test {
    NodeRegistry registry;
    StakeManager stakeManager;
    MockUSDC usdc;

    address guardian = makeAddr("guardian");
    address treasury = makeAddr("treasury");
    address operator = makeAddr("operator");
    address operator2 = makeAddr("operator2");

    uint256 constant MIN_STAKE = 100_000_000; // 100 USDC
    string constant ENDPOINT = "https://node.example.com";

    function setUp() public {
        usdc = new MockUSDC();

        // NodeRegistry solo lee el stake vía getStakeInfo(); no hay nada
        // que cablear entre ambos contratos.
        stakeManager = new StakeManager(address(usdc), guardian);

        registry = new NodeRegistry(address(stakeManager), guardian, MIN_STAKE);

        // Fund operators
        usdc.mint(operator, 10 * MIN_STAKE);
        usdc.mint(operator2, 10 * MIN_STAKE);
    }

    // ── Registration ──────────────────────────────────────────

    function test_Register_Success() public {
        _stake(operator, MIN_STAKE);

        vm.prank(operator);
        registry.register(ENDPOINT);

        NodeRegistry.Node memory node = registry.getNode(operator);
        assertEq(node.operator, operator);
        assertEq(node.endpoint, ENDPOINT);
        assertEq(node.active, true);
        assertGt(node.registeredAt, 0);
    }

    function test_Register_EmitsEvent() public {
        _stake(operator, MIN_STAKE);

        vm.expectEmit(true, false, false, true);
        emit NodeRegistry.NodeRegistered(operator, ENDPOINT, MIN_STAKE);

        vm.prank(operator);
        registry.register(ENDPOINT);
    }

    function test_Register_AppearsInActiveNodes() public {
        _registerOperator(operator, MIN_STAKE);

        address[] memory active = registry.getActiveNodes();
        assertEq(active.length, 1);
        assertEq(active[0], operator);
    }

    function test_Register_Revert_AlreadyRegistered() public {
        _registerOperator(operator, MIN_STAKE);

        vm.prank(operator);
        vm.expectRevert(NodeRegistry.AlreadyRegistered.selector);
        registry.register(ENDPOINT);
    }

    function test_Register_Revert_StakeTooLow_NoStake() public {
        // Operator never staked — getStakeInfo returns 0
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(NodeRegistry.StakeTooLow.selector, 0, MIN_STAKE));
        registry.register(ENDPOINT);
    }

    function test_Register_Revert_StakeTooLow_BelowMin() public {
        uint256 lowStake = MIN_STAKE - 1;
        _stake(operator, lowStake);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(NodeRegistry.StakeTooLow.selector, lowStake, MIN_STAKE));
        registry.register(ENDPOINT);
    }

    function test_Register_Revert_EmptyEndpoint() public {
        _stake(operator, MIN_STAKE);

        vm.prank(operator);
        vm.expectRevert(NodeRegistry.EmptyEndpoint.selector);
        registry.register("");
    }

    function test_Register_AcceptsExtraStake() public {
        // Operator stakes more than the minimum — register still works,
        // event reports the actual deposited amount.
        uint256 extraStake = MIN_STAKE * 3;
        _stake(operator, extraStake);

        vm.expectEmit(true, false, false, true);
        emit NodeRegistry.NodeRegistered(operator, ENDPOINT, extraStake);

        vm.prank(operator);
        registry.register(ENDPOINT);
    }

    // ── UpdateEndpoint ────────────────────────────────────────

    function test_UpdateEndpoint_Success() public {
        _registerOperator(operator, MIN_STAKE);

        vm.prank(operator);
        registry.updateEndpoint("https://new-endpoint.example.com");

        NodeRegistry.Node memory node = registry.getNode(operator);
        assertEq(node.endpoint, "https://new-endpoint.example.com");
    }

    function test_UpdateEndpoint_EmitsEvent() public {
        _registerOperator(operator, MIN_STAKE);
        string memory newEndpoint = "https://new.example.com";

        vm.expectEmit(true, false, false, true);
        emit NodeRegistry.NodeUpdated(operator, newEndpoint);

        vm.prank(operator);
        registry.updateEndpoint(newEndpoint);
    }

    function test_UpdateEndpoint_Revert_NotRegistered() public {
        vm.prank(operator);
        vm.expectRevert(NodeRegistry.NotRegistered.selector);
        registry.updateEndpoint("https://example.com");
    }

    function test_UpdateEndpoint_Revert_EmptyEndpoint() public {
        _registerOperator(operator, MIN_STAKE);

        vm.prank(operator);
        vm.expectRevert(NodeRegistry.EmptyEndpoint.selector);
        registry.updateEndpoint("");
    }

    // ── Deactivate / Activate ─────────────────────────────────

    function test_Deactivate_Success() public {
        _registerOperator(operator, MIN_STAKE);

        vm.prank(operator);
        registry.deactivate();

        assertFalse(registry.getNode(operator).active);
        assertFalse(registry.isActive(operator));
    }

    function test_Deactivate_RemovesFromActiveList() public {
        _registerOperator(operator, MIN_STAKE);
        _registerOperator(operator2, MIN_STAKE);

        vm.prank(operator);
        registry.deactivate();

        address[] memory active = registry.getActiveNodes();
        assertEq(active.length, 1);
        assertEq(active[0], operator2);
    }

    function test_Activate_Success() public {
        _registerOperator(operator, MIN_STAKE);

        vm.startPrank(operator);
        registry.deactivate();
        registry.activate();
        vm.stopPrank();

        assertTrue(registry.isActive(operator));

        address[] memory active = registry.getActiveNodes();
        assertEq(active.length, 1);
    }

    function test_Deactivate_Revert_NotRegistered() public {
        vm.prank(operator);
        vm.expectRevert(NodeRegistry.NotRegistered.selector);
        registry.deactivate();
    }

    // ── Multiple nodes ────────────────────────────────────────

    function test_MultipleNodes_ActiveList() public {
        _registerOperator(operator, MIN_STAKE);
        _registerOperator(operator2, MIN_STAKE * 2);

        address[] memory active = registry.getActiveNodes();
        assertEq(active.length, 2);
    }

    // ── Fuzz ─────────────────────────────────────────────────

    function testFuzz_Register_StakeBelowMin_AlwaysReverts(uint256 stake) public {
        stake = bound(stake, 1, MIN_STAKE - 1);
        _stake(operator, stake);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(NodeRegistry.StakeTooLow.selector, stake, MIN_STAKE));
        registry.register(ENDPOINT);
    }

    function testFuzz_Register_StakeAboveMin_Succeeds(uint256 stake) public {
        stake = bound(stake, MIN_STAKE, 1_000 * MIN_STAKE);
        usdc.mint(operator, stake);
        _stake(operator, stake);

        vm.prank(operator);
        registry.register(ENDPOINT);

        assertTrue(registry.isActive(operator));
    }

    // ── Pausable ──────────────────────────────────────────────

    function test_Pause_GuardianCanPause() public {
        vm.prank(guardian);
        registry.pause();
        assertTrue(registry.paused());
    }

    function test_Pause_GuardianCanUnpause() public {
        vm.prank(guardian);
        registry.pause();

        vm.prank(guardian);
        registry.unpause();
        assertFalse(registry.paused());
    }

    function test_Pause_NonGuardianCannotPause() public {
        vm.prank(operator);
        vm.expectRevert(Pausable.NotGuardian.selector);
        registry.pause();
    }

    function test_Pause_RegisterRevertsWhenPaused() public {
        _stake(operator, MIN_STAKE);

        vm.prank(guardian);
        registry.pause();

        vm.prank(operator);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.register(ENDPOINT);
    }

    function test_Pause_DeactivateRevertsWhenPaused() public {
        _registerOperator(operator, MIN_STAKE);

        vm.prank(guardian);
        registry.pause();

        vm.prank(operator);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.deactivate();
    }

    function test_Pause_RegisterWorksAfterUnpause() public {
        vm.prank(guardian);
        registry.pause();

        vm.prank(guardian);
        registry.unpause();

        _registerOperator(operator, MIN_STAKE);
        assertTrue(registry.isActive(operator));
    }

    function test_TransferGuardian() public {
        address newGuardian = makeAddr("newGuardian");

        vm.prank(guardian);
        registry.transferGuardian(newGuardian);

        assertEq(registry.guardian(), newGuardian);

        // Old guardian can no longer pause
        vm.prank(guardian);
        vm.expectRevert(Pausable.NotGuardian.selector);
        registry.pause();

        // New guardian can pause
        vm.prank(newGuardian);
        registry.pause();
        assertTrue(registry.paused());
    }

    // ── Adjustable min stake ──────────────────────────────────

    function test_MinStake_InitialValue() public view {
        assertEq(registry.minStake(), MIN_STAKE);
    }

    function test_SetMinStake_GuardianCanIncrease() public {
        uint256 newMin = MIN_STAKE * 2;

        vm.expectEmit(true, true, true, true);
        emit NodeRegistry.MinStakeIncreased(MIN_STAKE, newMin);

        vm.prank(guardian);
        registry.setMinStake(newMin);

        assertEq(registry.minStake(), newMin);
    }

    function test_SetMinStake_Revert_Decrease() public {
        uint256 lowerMin = MIN_STAKE - 1;

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(NodeRegistry.MinStakeCannotDecrease.selector, MIN_STAKE, lowerMin));
        registry.setMinStake(lowerMin);
    }

    function test_SetMinStake_Revert_NonGuardian() public {
        vm.prank(operator);
        vm.expectRevert(Pausable.NotGuardian.selector);
        registry.setMinStake(MIN_STAKE * 2);
    }

    function test_SetMinStake_SameValueAllowed() public {
        // Setting to the same value is a no-op but shouldn't revert
        // (it's a set, not a strict increase — emits the event anyway)
        vm.prank(guardian);
        registry.setMinStake(MIN_STAKE);
        assertEq(registry.minStake(), MIN_STAKE);
    }

    function test_Register_AfterMinStakeIncrease_OldStakeTooLow() public {
        uint256 newMin = MIN_STAKE * 2;
        vm.prank(guardian);
        registry.setMinStake(newMin);

        // Operator stakes the OLD minimum, then tries to register
        usdc.mint(operator, MIN_STAKE);
        _stake(operator, MIN_STAKE);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(NodeRegistry.StakeTooLow.selector, MIN_STAKE, newMin));
        registry.register(ENDPOINT);
    }

    // ── Tanda C fixes — activate guard against duplicates ─────

    function test_Activate_Revert_AlreadyActive() public {
        _registerOperator(operator, MIN_STAKE);
        // After register the node is already active — calling activate()
        // again must revert (previously it would silently push a duplicate
        // into _activeOperators and break _removeFromActive).
        vm.prank(operator);
        vm.expectRevert(NodeRegistry.AlreadyActive.selector);
        registry.activate();
    }

    function test_Activate_DoesNotDuplicateInActiveList() public {
        _registerOperator(operator, MIN_STAKE);
        // Sanity: before fix this would have produced length=2 with two
        // copies of `operator`. With the AlreadyActive guard, length stays 1.
        address[] memory active = registry.getActiveNodes();
        assertEq(active.length, 1);
        assertEq(active[0], operator);
    }

    function test_Activate_Pause_RevertsWhenPaused() public {
        _registerOperator(operator, MIN_STAKE);
        vm.prank(operator);
        registry.deactivate();

        vm.prank(guardian);
        registry.pause();

        vm.prank(operator);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.activate();
    }

    // ── Helpers ───────────────────────────────────────────────

    /// @dev Approve + deposit. Operator must be funded with USDC first.
    function _stake(address op, uint256 amount) internal {
        vm.startPrank(op);
        usdc.approve(address(stakeManager), amount);
        stakeManager.deposit(amount);
        vm.stopPrank();
    }

    /// @dev Stake then register — the standard registration flow.
    function _registerOperator(address op, uint256 stake) internal {
        usdc.mint(op, stake);
        _stake(op, stake);
        vm.prank(op);
        registry.register(ENDPOINT);
    }
}
