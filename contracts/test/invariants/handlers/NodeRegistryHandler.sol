// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {NodeRegistry} from "../../../src/NodeRegistry.sol";
import {StakeManager} from "../../../src/StakeManager.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";

contract NodeRegistryHandler is Test {
    NodeRegistry public immutable registry;
    StakeManager public immutable stakeManager;
    MockUSDC public immutable usdc;
    address public immutable guardian;

    address[] public actors;

    /// @notice Last observed minStake value; used to verify monotonicity.
    uint256 public ghost_lastMinStake;

    /// @notice Cumulative count of state-mutating calls.
    uint256 public ghost_calls;

    constructor(NodeRegistry _registry, StakeManager _stakeManager, MockUSDC _usdc, address _guardian) {
        registry = _registry;
        stakeManager = _stakeManager;
        usdc = _usdc;
        guardian = _guardian;

        actors.push(makeAddr("nodeActor1"));
        actors.push(makeAddr("nodeActor2"));
        actors.push(makeAddr("nodeActor3"));
        actors.push(makeAddr("nodeActor4"));
        actors.push(makeAddr("nodeActor5"));

        ghost_lastMinStake = _registry.minStake();
    }

    function _pickActor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    // ── Fuzzed entry points ───────────────────────────────────

    function stakeAndRegister(uint256 actorSeed, uint256 stakeAmount, string calldata endpoint) external {
        address actor = _pickActor(actorSeed);

        // Skip already-registered (would revert with AlreadyRegistered)
        if (registry.getNode(actor).registeredAt != 0) return;
        // Skip empty endpoint (would revert with EmptyEndpoint)
        if (bytes(endpoint).length == 0) return;

        uint256 minStake = registry.minStake();
        // Bound around minStake to exercise both "below" and "above" paths.
        stakeAmount = bound(stakeAmount, 1, minStake * 5);

        usdc.mint(actor, stakeAmount);
        vm.startPrank(actor);
        usdc.approve(address(stakeManager), stakeAmount);
        stakeManager.deposit(stakeAmount);

        if (stakeAmount >= minStake) {
            registry.register(endpoint);
        } else {
            try registry.register(endpoint) {
            // If this didn't revert, the invariant for stake-floor is violated.
            // We don't assert here — let the invariant_* fns catch it via getter
            // state.
            }
                catch {
                // Expected
            }
        }
        vm.stopPrank();
        ghost_calls++;
    }

    function deactivate(uint256 actorSeed) external {
        address actor = _pickActor(actorSeed);
        if (registry.getNode(actor).registeredAt == 0) return;
        if (!registry.getNode(actor).active) return;

        vm.prank(actor);
        registry.deactivate();
        ghost_calls++;
    }

    function activate(uint256 actorSeed) external {
        address actor = _pickActor(actorSeed);
        if (registry.getNode(actor).registeredAt == 0) return;
        if (registry.getNode(actor).active) return; // AlreadyActive would revert

        vm.prank(actor);
        registry.activate();
        ghost_calls++;
    }

    function updateEndpoint(uint256 actorSeed, string calldata endpoint) external {
        address actor = _pickActor(actorSeed);
        if (registry.getNode(actor).registeredAt == 0) return;
        if (bytes(endpoint).length == 0) return;

        vm.prank(actor);
        registry.updateEndpoint(endpoint);
        ghost_calls++;
    }

    function setMinStakeIncrease(uint256 increaseBy) external {
        uint256 current = registry.minStake();
        increaseBy = bound(increaseBy, 0, type(uint128).max);
        uint256 newMin = current + increaseBy;

        ghost_lastMinStake = current;

        vm.prank(guardian);
        registry.setMinStake(newMin);
        ghost_calls++;
    }

    // ── Accessors ─────────────────────────────────────────────

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }
}
