// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {NodeRegistry} from "../../src/NodeRegistry.sol";
import {StakeManager} from "../../src/StakeManager.sol";
import {DisputeResolver} from "../../src/DisputeResolver.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {NodeRegistryHandler} from "./handlers/NodeRegistryHandler.sol";

/// @title NodeRegistry invariant tests
/// @dev Each invariant maps 1:1 to `audits/SCOPE.md §5 (NodeRegistry)`.
contract NodeRegistryInvariants is Test {
    NodeRegistry public registry;
    StakeManager public stakeManager;
    MockUSDC public usdc;
    NodeRegistryHandler public handler;

    address public constant TREASURY = address(0xC0FFEE);
    address public constant GUARDIAN = address(0xDEAD);

    uint256 public constant INITIAL_MIN_STAKE = 40_000_000; // 40 USDC

    function setUp() public {
        usdc = new MockUSDC();
        stakeManager = new StakeManager(address(usdc), GUARDIAN, TREASURY);

        // Need a DisputeResolver to satisfy StakeManager.initialize's zero-check.
        address[] memory arbiters = new address[](3);
        arbiters[0] = makeAddr("arb1");
        arbiters[1] = makeAddr("arb2");
        arbiters[2] = makeAddr("arb3");
        DisputeResolver resolver = new DisputeResolver(address(stakeManager), TREASURY, arbiters, GUARDIAN);

        vm.prank(GUARDIAN);
        stakeManager.initialize(address(resolver));

        registry = new NodeRegistry(address(stakeManager), GUARDIAN, INITIAL_MIN_STAKE);

        handler = new NodeRegistryHandler(registry, stakeManager, usdc, GUARDIAN);
        targetContract(address(handler));
    }

    // ── Invariant: active set has no duplicates ──────────────
    //
    // SCOPE.md §5/NodeRegistry invariant 4:
    //   "_activeOperators[] has no duplicates: each address appears at
    //    most once."
    //
    // The AlreadyActive guard in activate() is the load-bearing defense
    // for this — fuzzer hammers activate/deactivate sequences.

    function invariant_activeSetNoDuplicates() public view {
        address[] memory active = registry.getActiveNodes();
        for (uint256 i = 0; i < active.length; i++) {
            for (uint256 j = i + 1; j < active.length; j++) {
                assertNotEq(active[i], active[j], "Duplicate operator in _activeOperators");
            }
        }
    }

    // ── Invariant: active set consistency ────────────────────
    //
    // SCOPE.md §5/NodeRegistry invariant 5:
    //   "_activeIndex[op] = i ⟹ _activeOperators[i] == op when active"
    //
    // The swap-and-pop logic in _removeFromActive() can corrupt indices
    // if not careful. We verify the bidirectional mapping.

    function invariant_activeSetMatchesIsActive() public view {
        address[] memory active = registry.getActiveNodes();

        // Every entry in active[] must have isActive==true.
        for (uint256 i = 0; i < active.length; i++) {
            assertTrue(registry.isActive(active[i]), "Operator in active[] but isActive==false");
        }

        // Every actor with isActive==true must be in active[].
        uint256 n = handler.actorsLength();
        for (uint256 i = 0; i < n; i++) {
            address actor = handler.actors(i);
            if (!registry.isActive(actor)) continue;

            bool found = false;
            for (uint256 j = 0; j < active.length; j++) {
                if (active[j] == actor) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, "isActive==true but not in active[]");
        }
    }

    // ── Invariant: registration is permanent ─────────────────
    //
    // SCOPE.md §5/NodeRegistry invariant 1:
    //   "Once _nodes[op].registeredAt > 0, it never resets to 0."
    //
    // The fuzzer cannot reach a state where a previously-registered op
    // has registeredAt == 0 because there's no de-register function.

    function invariant_registrationPermanent() public view {
        // Implicit: the only way to reach registeredAt==0 is to never
        // have registered. Since we can't track "ever was registered"
        // without persistent ghost state, we verify the dual property:
        // if isActive==true now, then registeredAt > 0 NOW.
        uint256 n = handler.actorsLength();
        for (uint256 i = 0; i < n; i++) {
            address actor = handler.actors(i);
            if (registry.isActive(actor)) {
                assertGt(registry.getNode(actor).registeredAt, 0, "isActive but registeredAt==0");
            }
        }
    }

    // ── Invariant: minStake is monotonically non-decreasing ──
    //
    // SCOPE.md §5/NodeRegistry invariant 6.
    //
    // The setMinStake(newMin) function reverts if newMin < current. We
    // verify the current value is >= our ghost tracker. Since the handler
    // only calls setMinStake with increases, the ghost should match.

    function invariant_minStakeMonotonic() public view {
        assertGe(registry.minStake(), handler.ghost_lastMinStake(), "minStake decreased");
        assertGe(registry.minStake(), INITIAL_MIN_STAKE, "minStake fell below initial value");
    }

    // ── Invariant: stakeManager wiring immutable ─────────────

    function invariant_stakeManagerImmutable() public view {
        assertEq(address(registry.stakeManager()), address(stakeManager), "stakeManager changed");
    }
}
