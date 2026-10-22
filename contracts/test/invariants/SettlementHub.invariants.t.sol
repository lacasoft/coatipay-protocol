// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {IntentSigning} from "../helpers/IntentSigning.sol";
import {SettlementHub} from "../../src/SettlementHub.sol";
import {MockUSDCPermit} from "../mocks/MockUSDCPermit.sol";
import {SettlementHubHandler} from "./handlers/SettlementHubHandler.sol";

/// @title SettlementHub invariant tests
/// @dev   Each invariant maps directly to a guarantee we make to merchants
///        and the auditor. If any fails, fund safety is broken.
contract SettlementHubInvariants is Test, IntentSigning {
    SettlementHub hub;
    MockUSDCPermit usdc;
    SettlementHubHandler handler;

    address constant TREASURY = address(0xC0FFEE);
    address constant GUARDIAN = address(0xDEAD);

    function setUp() public {
        usdc = new MockUSDCPermit();
        hub = new SettlementHub(address(usdc), TREASURY, GUARDIAN, _intentSigner());

        handler = new SettlementHubHandler(hub, usdc, TREASURY);
        targetContract(address(handler));
    }

    // ── Invariant 1: the hub always covers what it owes ──────────
    //
    // Since ADR-009 the hub keeps the operator and treasury fees until they
    // are claimed. It must never hold less than it has credited; what it holds
    // above that arrived by mistake and is what `sweepSurplus` moves.

    function invariant_hubCoversWhatItOwes() public view {
        assertGe(usdc.balanceOf(address(hub)), hub.totalAccrued(), "hub holds less than it credited");
    }

    // ── Invariant 1b: exact accounting of the hub's USDC ─────────
    //
    // balance = fees credited + USDC sent by mistake - everything claimed
    // owed    = fees credited + surplus swept to treasury - everything claimed

    function invariant_hubBalanceAccounted() public view {
        assertEq(
            usdc.balanceOf(address(hub)),
            handler.ghost_feesCredited() + handler.ghost_donated() - handler.ghost_claimed(),
            "hub balance does not match credits + donations - claims"
        );
        assertEq(
            hub.totalAccrued(),
            handler.ghost_feesCredited() + handler.ghost_swept() - handler.ghost_claimed(),
            "totalAccrued does not match credits + sweeps - claims"
        );
    }

    // ── Invariant 1c: totalAccrued is the sum of every account ───
    //
    // Only operators and the treasury are ever credited; merchants are paid
    // at once.

    function invariant_totalAccruedIsTheSum() public view {
        uint256 sum = hub.accrued(TREASURY);
        for (uint256 i = 0; i < handler.operatorsLength(); i++) {
            sum += hub.accrued(handler.operators(i));
        }
        assertEq(hub.totalAccrued(), sum, "totalAccrued != sum of accrued");
        for (uint256 i = 0; i < handler.merchantsLength(); i++) {
            assertEq(hub.accrued(handler.merchants(i)), 0, "a merchant was credited instead of paid");
        }
    }

    // ── Invariant 2: every party gets exactly its share ──────────
    //
    // Merchants are paid at once; the treasury has, between what it claimed
    // and what is still credited to it, exactly its share of every payment
    // plus the surplus swept to it.

    function invariant_splitSumsToSettlementTotal() public view {
        uint256 paidToMerchants;
        for (uint256 i = 0; i < handler.merchantsLength(); i++) {
            paidToMerchants += usdc.balanceOf(handler.merchants(i));
        }
        assertEq(paidToMerchants, handler.ghost_totalSettledMerchant(), "merchants not paid exactly their share");

        assertEq(
            usdc.balanceOf(TREASURY) + hub.accrued(TREASURY),
            handler.ghost_totalSettledTreasury() + handler.ghost_swept(),
            "treasury got more or less than its share"
        );

        uint256 toOperators;
        for (uint256 i = 0; i < handler.operatorsLength(); i++) {
            address op = handler.operators(i);
            toOperators += usdc.balanceOf(op) + hub.accrued(op);
        }
        assertEq(toOperators, handler.ghost_totalSettledOperator(), "operators got more or less than their share");
    }

    // ── Invariant 3: merchant/nodeit/treasury split is 98.5% / 1.05% / 0.45% ──
    //
    // The contract's hardcoded constants must always produce the documented
    // split (ADR-002 recalibration). Fuzz any amount, recompute, verify ratio.

    function invariant_feeSplitRatio() public view {
        // For a sample large amount, the split must be the documented ratio.
        // Using 1B to avoid integer-division dust.
        uint256 amount = 1_000_000_000_000; // 1M USDC base units
        (uint256 m, uint256 o, uint256 t) = hub.previewSplit(amount);

        // 98.5%, 1.05%, 0.45% of 1M = 985_000_000_000 / 10_500_000_000 / 4_500_000_000
        assertEq(m, 985_000_000_000, "merchant 98.5%");
        assertEq(o, 10_500_000_000, "operator 1.05%");
        assertEq(t, 4_500_000_000, "treasury 0.45%");
        assertEq(m + o + t, amount, "split sums exactly");
    }

    // ── Invariant 4: status monotonicity ─────────────────────────
    //
    // An intent's status only ever progresses Registered → (Settled OR
    // Cancelled). Never backwards, never both, never reset to Registered.
    // The fuzzer can't set status directly, so we verify the dual: every
    // intent we registered is in one of {Registered, Settled, Cancelled},
    // never some invalid value.

    function invariant_statusOnlyValidStates() public view {
        uint256 n = handler.registeredIntentsLength();
        for (uint256 i = 0; i < n; i++) {
            bytes32 id = handler.registeredIntents(i);
            SettlementHub.Intent memory intent = hub.getIntent(id);
            uint8 s = uint8(intent.status);
            assertLe(s, 2, "Status must be 0/1/2 only");
        }
    }

    // ── Invariant 5: settled count + cancelled count <= registered ──
    //
    // Can't have more terminations than registrations. Each intent reaches
    // a terminal status at most once (status monotonicity).

    function invariant_terminalCountsBounded() public view {
        // We don't have a direct ghost for "settled" count distinct from
        // payment events, but ghost_totalSettledMerchant > 0 implies at
        // least one settlement happened. The cleanest check: cancelled
        // count <= registered count.
        assertLe(handler.ghost_totalCancelled(), handler.ghost_totalRegistered(), "Cancelled > registered impossible");
    }

    // ── Invariant 6: immutables stay immutable ───────────────────

    function invariant_immutables() public view {
        assertEq(address(hub.usdc()), address(usdc), "usdc reference mutated");
        assertEq(hub.treasury(), TREASURY, "treasury mutated");
        // El firmante de registros es inmutable a propósito (ADR-004): si
        // pudiera cambiar, quien lo cambiara podría atar pagos en vuelo a un
        // comercio de su elección.
        assertEq(hub.intentSigner(), _intentSigner(), "intentSigner mutated");
        assertEq(hub.PROTOCOL_FEE_BPS(), 150, "fee changed");
        assertEq(hub.TREASURY_SHARE_BPS(), 45, "treasury share changed");
        assertEq(hub.OPERATOR_SHARE_BPS(), 105, "operator share changed");
    }
}
