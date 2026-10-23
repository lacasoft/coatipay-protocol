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
        stakeManager = new StakeManager(address(usdc), guardian, treasury);

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

        // Two steps (ADR-009 §6): nothing changes until the new one accepts.
        assertEq(registry.guardian(), guardian);
        assertEq(registry.pendingGuardian(), newGuardian);

        vm.prank(newGuardian);
        registry.acceptGuardian();
        assertEq(registry.guardian(), newGuardian);
        assertEq(registry.pendingGuardian(), address(0));

        // Old guardian can no longer pause
        vm.prank(guardian);
        vm.expectRevert(Pausable.NotGuardian.selector);
        registry.pause();

        // New guardian can pause
        vm.prank(newGuardian);
        registry.pause();
        assertTrue(registry.paused());
    }

    // ── Adjustable min stake, with notice (ADR-009 §5) ────────

    function test_MinStake_InitialValue() public view {
        assertEq(registry.minStake(), MIN_STAKE);
        assertEq(registry.MIN_STAKE_DELAY(), 7 days);
    }

    function test_Constructor_Revert_ZeroMinStake() public {
        vm.expectRevert(NodeRegistry.ZeroMinStake.selector);
        new NodeRegistry(address(stakeManager), guardian, 0);
    }

    function _propose(uint256 newMin) internal {
        vm.prank(guardian);
        registry.proposeMinStake(newMin);
    }

    function test_ProposeMinStake_DoesNotApplyBeforeTheDelay() public {
        uint256 newMin = MIN_STAKE * 2;
        uint256 effectiveAt = block.timestamp + 7 days;

        vm.expectEmit(true, true, true, true);
        emit NodeRegistry.MinStakeProposed(MIN_STAKE, newMin, effectiveAt);
        _propose(newMin);

        assertEq(registry.minStake(), MIN_STAKE, "unchanged until applied");
        assertEq(registry.pendingMinStake(), newMin);
        assertEq(registry.minStakeEffectiveAt(), effectiveAt);

        vm.warp(effectiveAt - 1);
        vm.expectRevert(abi.encodeWithSelector(NodeRegistry.MinStakeDelayNotElapsed.selector, effectiveAt));
        registry.applyMinStake();
    }

    function test_ApplyMinStake_AnyoneAfterTheDelay() public {
        uint256 newMin = MIN_STAKE * 2;
        _propose(newMin);
        vm.warp(block.timestamp + 7 days);

        vm.expectEmit(true, true, true, true);
        emit NodeRegistry.MinStakeChanged(MIN_STAKE, newMin);
        vm.prank(makeAddr("anyone"));
        registry.applyMinStake();

        assertEq(registry.minStake(), newMin);
        assertEq(registry.pendingMinStake(), 0);
        assertEq(registry.minStakeEffectiveAt(), 0);
    }

    /// Before ADR-009 it could only go up: a mistake or a stolen key locked
    /// every nodeit out for good. Now a mistake is undone the same way.
    function test_MinStake_CanGoDown() public {
        _propose(MIN_STAKE / 2);
        vm.warp(block.timestamp + 7 days);
        registry.applyMinStake();
        assertEq(registry.minStake(), MIN_STAKE / 2);
    }

    function test_ProposeMinStake_Revert_NonGuardian() public {
        vm.prank(operator);
        vm.expectRevert(Pausable.NotGuardian.selector);
        registry.proposeMinStake(MIN_STAKE * 2);
    }

    function test_ProposeMinStake_Revert_Zero() public {
        vm.prank(guardian);
        vm.expectRevert(NodeRegistry.ZeroMinStake.selector);
        registry.proposeMinStake(0);
    }

    function test_ApplyMinStake_Revert_NoProposal() public {
        vm.expectRevert(NodeRegistry.NoMinStakeProposal.selector);
        registry.applyMinStake();
    }

    /// An absurd value — a mistake, or a stolen key — is seen a week ahead
    /// and cancelled before it applies.
    function test_CancelMinStakeProposal() public {
        _propose(type(uint256).max);

        vm.expectEmit(true, true, true, true);
        emit NodeRegistry.MinStakeProposalCancelled(type(uint256).max);
        vm.prank(guardian);
        registry.cancelMinStakeProposal();

        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(NodeRegistry.NoMinStakeProposal.selector);
        registry.applyMinStake();
        assertEq(registry.minStake(), MIN_STAKE);
    }

    function test_CancelMinStakeProposal_Revert_NonGuardian() public {
        _propose(MIN_STAKE * 2);
        vm.prank(operator);
        vm.expectRevert(Pausable.NotGuardian.selector);
        registry.cancelMinStakeProposal();
    }

    function test_CancelMinStakeProposal_Revert_NoProposal() public {
        vm.prank(guardian);
        vm.expectRevert(NodeRegistry.NoMinStakeProposal.selector);
        registry.cancelMinStakeProposal();
    }

    /// A new proposal replaces the pending one and its delay starts over:
    /// there is no way to shorten the notice.
    function test_ProposeMinStake_ReplacesAndRestartsTheDelay() public {
        _propose(MIN_STAKE * 2);
        vm.warp(block.timestamp + 6 days);
        _propose(MIN_STAKE * 3);

        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(abi.encodeWithSelector(NodeRegistry.MinStakeDelayNotElapsed.selector, block.timestamp + 6 days));
        registry.applyMinStake();

        vm.warp(block.timestamp + 6 days);
        registry.applyMinStake();
        assertEq(registry.minStake(), MIN_STAKE * 3);
    }

    function test_Register_AfterMinStakeIncrease_OldStakeTooLow() public {
        uint256 newMin = MIN_STAKE * 2;
        _propose(newMin);
        vm.warp(block.timestamp + 7 days);
        registry.applyMinStake();

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

    // ── Lectura por páginas (OCT-13) ──────────────────────────

    function test_GetActiveNodesPage() public {
        address[] memory ops = new address[](5);
        for (uint256 i; i < 5; i++) {
            ops[i] = makeAddr(string(abi.encode("op", i)));
            _registerOperator(ops[i], MIN_STAKE);
        }
        assertEq(registry.activeNodeCount(), 5);

        address[] memory p0 = registry.getActiveNodesPage(0, 2);
        address[] memory p1 = registry.getActiveNodesPage(2, 2);
        address[] memory p2 = registry.getActiveNodesPage(4, 2);
        assertEq(p0.length, 2);
        assertEq(p1.length, 2);
        assertEq(p2.length, 1, "la ultima pagina viene corta");
        assertEq(p0[0], ops[0]);
        assertEq(p1[1], ops[3]);
        assertEq(p2[0], ops[4]);

        assertEq(registry.getActiveNodesPage(5, 2).length, 0, "pasado el final, nada");
        assertEq(registry.getActiveNodesPage(0, 0).length, 0);
        assertEq(registry.getActiveNodesPage(1, type(uint256).max).length, 4, "sin desbordar");
    }

    function testFuzz_GetActiveNodesPage_CubreLaListaEntera(uint8 n, uint8 tam) public {
        n = uint8(bound(n, 0, 12));
        tam = uint8(bound(tam, 1, 5));
        for (uint256 i; i < n; i++) {
            _registerOperator(makeAddr(string(abi.encode("f", i))), MIN_STAKE);
        }
        address[] memory todos = registry.getActiveNodes();
        uint256 visto;
        for (uint256 off; off < n; off += tam) {
            address[] memory p = registry.getActiveNodesPage(off, tam);
            for (uint256 j; j < p.length; j++) {
                assertEq(p[j], todos[visto++]);
            }
        }
        assertEq(visto, n);
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
