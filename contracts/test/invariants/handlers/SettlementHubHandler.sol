// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {IntentSigning} from "../../helpers/IntentSigning.sol";
import {SettlementHub} from "../../../src/SettlementHub.sol";
import {MockUSDCPermit} from "../../mocks/MockUSDCPermit.sol";

contract SettlementHubHandler is Test, IntentSigning {
    SettlementHub public immutable hub;
    MockUSDCPermit public immutable usdc;
    address public immutable treasury;

    address[] public merchants;
    address[] public operators;
    address[] public payers;
    bytes32[] public registeredIntents;

    /// @notice Cumulative deposits/transfers we expect for invariants.
    uint256 public ghost_totalSettledMerchant;
    uint256 public ghost_totalSettledOperator;
    uint256 public ghost_totalSettledTreasury;
    uint256 public ghost_totalCancelled;
    uint256 public ghost_totalRegistered;
    uint256 public ghost_calls;

    /// @notice Comisiones acreditadas por los pagos (operador + tesorería).
    uint256 public ghost_feesCredited;
    /// @notice Todo lo cobrado con `claim` / `claimFor`.
    uint256 public ghost_claimed;
    /// @notice USDC enviado al hub por error, sin pasar por un pago.
    uint256 public ghost_donated;
    /// @notice Lo que `sweepSurplus` acreditó a la tesorería.
    uint256 public ghost_swept;

    constructor(SettlementHub _hub, MockUSDCPermit _usdc, address _treasury) {
        hub = _hub;
        usdc = _usdc;
        treasury = _treasury;

        merchants.push(makeAddr("merchant_a"));
        merchants.push(makeAddr("merchant_b"));
        operators.push(makeAddr("operator_a"));
        operators.push(makeAddr("operator_b"));
        payers.push(makeAddr("payer_a"));
        payers.push(makeAddr("payer_b"));
        payers.push(makeAddr("payer_c"));
    }

    function _pickAddr(address[] storage arr, uint256 seed) internal view returns (address) {
        return arr[seed % arr.length];
    }

    // ── Fuzzed entry points ───────────────────────────────────

    function registerIntent(uint256 merchantSeed, uint256 operatorSeed, uint256 amount, uint256 expiryOffset) external {
        amount = bound(amount, 1, 1_000_000_000_000); // 1 wei to 1M USDC
        expiryOffset = bound(expiryOffset, 1, 30 days - 1); // valid lifetime

        bytes32 ref = keccak256(abi.encode("intent", ghost_calls, amount));
        address merchant = _pickAddr(merchants, merchantSeed);
        // Skip if already registered
        if (hub.getIntent(hub.intentIdOf(merchant, ref)).merchant != address(0)) return;

        address operator = _pickAddr(operators, operatorSeed);
        uint64 expiresAt = uint64(block.timestamp + expiryOffset);

        bytes32 intentId = _reg(hub, ref, merchant, operator, amount, expiresAt);
        registeredIntents.push(intentId);
        ghost_totalRegistered++;
        ghost_calls++;
    }

    function payIntent(uint256 payerSeed, uint256 intentSeed) external {
        if (registeredIntents.length == 0) return;
        bytes32 intentId = registeredIntents[intentSeed % registeredIntents.length];

        SettlementHub.Intent memory intent = hub.getIntent(intentId);
        if (intent.status != SettlementHub.IntentStatus.Registered) return;
        if (block.timestamp >= intent.expiresAt) return; // would revert IntentExpired

        address payer = _pickAddr(payers, payerSeed);
        usdc.mint(payer, intent.amount);
        vm.startPrank(payer);
        usdc.approve(address(hub), intent.amount);
        hub.payIntent(intentId);
        vm.stopPrank();

        // Track ghost balances
        (uint256 m, uint256 o, uint256 t) = hub.previewSplit(intent.amount);
        ghost_totalSettledMerchant += m;
        ghost_totalSettledOperator += o;
        ghost_totalSettledTreasury += t;
        ghost_feesCredited += o + t;
        ghost_calls++;
    }

    /// Un operador cobra lo suyo.
    function claim(uint256 operatorSeed) external {
        address operator = _pickAddr(operators, operatorSeed);
        uint256 owed = hub.accrued(operator);
        if (owed == 0) return;
        vm.prank(operator);
        hub.claim();
        ghost_claimed += owed;
        ghost_calls++;
    }

    /// La tarea periódica barre lo de la tesorería, sin sus llaves.
    function claimTreasury(uint256 callerSeed) external {
        uint256 owed = hub.accrued(treasury);
        if (owed == 0) return;
        vm.prank(_pickAddr(payers, callerSeed));
        hub.claimFor(treasury);
        ghost_claimed += owed;
        ghost_calls++;
    }

    /// Alguien envía USDC al hub directamente, por error.
    function donate(uint256 amount) external {
        amount = bound(amount, 1, 1_000_000_000_000);
        usdc.mint(address(hub), amount);
        ghost_donated += amount;
        ghost_calls++;
    }

    function sweepSurplus() external {
        uint256 balance = usdc.balanceOf(address(hub));
        uint256 owed = hub.totalAccrued();
        if (balance <= owed) return;
        hub.sweepSurplus();
        ghost_swept += balance - owed;
        ghost_calls++;
    }

    function cancelExpired(uint256 intentSeed, uint256 warpAmount) external {
        if (registeredIntents.length == 0) return;
        bytes32 intentId = registeredIntents[intentSeed % registeredIntents.length];

        SettlementHub.Intent memory intent = hub.getIntent(intentId);
        if (intent.status != SettlementHub.IntentStatus.Registered) return;

        // Warp past expiry if needed
        warpAmount = bound(warpAmount, 1, 365 days);
        if (block.timestamp < intent.expiresAt) {
            vm.warp(uint256(intent.expiresAt) + warpAmount);
        }

        hub.cancelExpired(intentId);
        ghost_totalCancelled++;
        ghost_calls++;
    }

    // ── Accessors for invariants ──────────────────────────────

    function registeredIntentsLength() external view returns (uint256) {
        return registeredIntents.length;
    }

    function merchantsLength() external view returns (uint256) {
        return merchants.length;
    }

    function operatorsLength() external view returns (uint256) {
        return operators.length;
    }
}
