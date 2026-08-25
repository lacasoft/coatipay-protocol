// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {DisputeResolver} from "../../../src/DisputeResolver.sol";
import {StakeManager} from "../../../src/StakeManager.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";

contract DisputeResolverHandler is Test {
    DisputeResolver public immutable resolver;
    StakeManager public immutable stakeManager;
    MockUSDC public immutable usdc;

    address[] public merchants;
    address[] public operators;
    address[] public arbiters;

    /// @notice Dispute IDs we have opened, used so the fuzzer can target
    ///         existing disputes for vote/respond/expire calls.
    bytes32[] public openedDisputes;

    /// @notice Counter of mutating calls (sanity).
    uint256 public ghost_calls;

    constructor(DisputeResolver _resolver, StakeManager _stakeManager, MockUSDC _usdc, address[] memory _arbiters) {
        resolver = _resolver;
        stakeManager = _stakeManager;
        usdc = _usdc;

        merchants.push(makeAddr("merchant1"));
        merchants.push(makeAddr("merchant2"));
        merchants.push(makeAddr("merchant3"));

        operators.push(makeAddr("op1"));
        operators.push(makeAddr("op2"));
        operators.push(makeAddr("op3"));

        for (uint256 i = 0; i < _arbiters.length; i++) {
            arbiters.push(_arbiters[i]);
        }

        // Stake the operators so slash() has something to slash.
        for (uint256 i = 0; i < operators.length; i++) {
            usdc.mint(operators[i], 1_000_000_000); // 1000 USDC each
            vm.startPrank(operators[i]);
            usdc.approve(address(stakeManager), 1_000_000_000);
            stakeManager.deposit(1_000_000_000);
            vm.stopPrank();
        }
    }

    function _pick(address[] storage arr, uint256 seed) internal view returns (address) {
        return arr[seed % arr.length];
    }

    // ── Fuzzed entry points ───────────────────────────────────

    function openDispute(uint256 merchantSeed, uint256 operatorSeed, uint256 intentSeed) external {
        address merchant = _pick(merchants, merchantSeed);
        address operator = _pick(operators, operatorSeed);
        bytes32 intentId = keccak256(abi.encode("intent", intentSeed));

        // Skip if dispute already exists for this intent
        if (resolver.intentToDispute(intentId) != bytes32(0)) return;

        vm.prank(merchant);
        bytes32 disputeId = resolver.openDispute(intentId, operator, "QmEvidence");
        openedDisputes.push(disputeId);
        ghost_calls++;
    }

    function vote(uint256 arbiterSeed, uint256 disputeSeed, uint8 outcomeRaw) external {
        if (openedDisputes.length == 0) return;
        address arbiter = _pick(arbiters, arbiterSeed);
        bytes32 disputeId = openedDisputes[disputeSeed % openedDisputes.length];

        // Skip if dispute already resolved or expired
        DisputeResolver.Dispute memory d = resolver.getDispute(disputeId);
        if (d.status == DisputeResolver.DisputeStatus.Resolved || d.status == DisputeResolver.DisputeStatus.Expired) {
            return;
        }
        // Skip if this arbiter already voted
        if (resolver.arbiterVotes(disputeId, arbiter) != DisputeResolver.DisputeOutcome.None) return;

        // outcome: 1 = MerchantWins, 2 = NodeWins (skip 0 = None which reverts)
        DisputeResolver.DisputeOutcome outcome = (outcomeRaw % 2 == 0)
            ? DisputeResolver.DisputeOutcome.MerchantWins
            : DisputeResolver.DisputeOutcome.NodeWins;

        vm.prank(arbiter);
        resolver.vote(disputeId, outcome);
        ghost_calls++;
    }

    function expireDispute(uint256 disputeSeed) external {
        if (openedDisputes.length == 0) return;
        bytes32 disputeId = openedDisputes[disputeSeed % openedDisputes.length];

        DisputeResolver.Dispute memory d = resolver.getDispute(disputeId);
        if (d.status != DisputeResolver.DisputeStatus.Open) return;

        // Warp past the response window
        uint256 expiry = d.openedAt + resolver.NODE_RESPONSE_WINDOW() + 1;
        if (block.timestamp < expiry) {
            vm.warp(expiry);
        }

        resolver.expireDispute(disputeId);
        ghost_calls++;
    }

    // ── Accessors ─────────────────────────────────────────────

    function openedDisputesLength() external view returns (uint256) {
        return openedDisputes.length;
    }

    function arbitersLength() external view returns (uint256) {
        return arbiters.length;
    }
}
