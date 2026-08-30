// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {SettlementHub} from "../src/SettlementHub.sol";
import {MockUSDCAuth} from "./mocks/MockUSDCAuth.sol";

/// @title  Atadura de la autorización ERC-3009 a su intent
/// @notice Regresión de F-1 (divulgación externa, 2026-08-29).
///
///         La firma ERC-3009 del pagador cubre `from`, `to`, `value`,
///         `validAfter`, `validBefore` y `nonce` — NO el intent. Como USDC
///         exige `msg.sender == to`, el `to` firmado es siempre el hub y no
///         puede nombrar al comercio. El destino lo decidía `auth.intentId`,
///         un campo del calldata que elige quien envía la transacción: el
///         nodeit, que es la parte NO confiable del diseño.
///
///         Un nodeit malicioso registraba un intent propio por el mismo
///         importe y aplicaba ahí la firma del pagador, quedándose el 99.7%.
///         Eso anulaba la razón de ser del contrato, que existe justamente
///         para que el operador no pueda robar el pago (ADR-001 §3.10).
///
///         El hub ahora exige `auth.nonce == auth.intentId`. Como
///         `registerIntent` rechaza identificadores repetidos, cada firma
///         queda encerrada en un intent que ya tiene dueño.
contract SettlementHubAuthBindingTest is Test {
    SettlementHub hub;
    MockUSDCAuth usdc;

    address treasury = makeAddr("treasury");
    address guardian = makeAddr("guardian");
    address merchant = makeAddr("merchant");
    address operator = makeAddr("operator");
    address payer;
    uint256 payerKey;

    /// El nodeit deshonesto: es a la vez el operador que enruta y el
    /// "comercio" del intent señuelo, así que se lleva las dos partes.
    address attacker = makeAddr("attacker");

    bytes32 constant HONEST_INTENT = keccak256("pi_honesto");
    bytes32 constant EVIL_INTENT = keccak256("pi_senuelo");
    uint256 constant AMOUNT = 1_000_000_000; // 1000 USDC
    uint64 expiresAt;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockUSDCAuth();
        hub = new SettlementHub(address(usdc), treasury, guardian);
        (payer, payerKey) = makeAddrAndKey("payer");
        usdc.mint(payer, 10 * AMOUNT);
        expiresAt = uint64(block.timestamp + 30 minutes);
    }

    function _signReceiveAuth(uint256 fromKey, address from, uint256 value, bytes32 nonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                usdc.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(),
                from,
                address(hub),
                value,
                block.timestamp - 1,
                block.timestamp + 1 hours,
                nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(fromKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _auth(bytes32 intentId, bytes32 nonce) internal view returns (SettlementHub.Authorization memory) {
        return SettlementHub.Authorization({
            intentId: intentId,
            payer: payer,
            validAfter: block.timestamp - 1,
            validBefore: block.timestamp + 1 hours,
            nonce: nonce,
            signature: _signReceiveAuth(payerKey, payer, AMOUNT, nonce)
        });
    }

    // ── F-1 ───────────────────────────────────────────────────

    /// El ataque exacto del reporte: la firma que el pagador emitió para el
    /// comercio honesto se aplica al intent señuelo del atacante.
    function test_RevertWhen_AuthorizationRedirectedToAnotherIntent() public {
        hub.registerIntent(HONEST_INTENT, merchant, operator, AMOUNT, expiresAt);
        // El atacante se registra como comercio Y como operador del señuelo,
        // por el mismo importe, que puede leer del intent honesto.
        hub.registerIntent(EVIL_INTENT, attacker, attacker, AMOUNT, expiresAt);

        // El pagador firma para SU intent. La firma llega al nodeit, que es
        // quien debe enviarla: ahí está la exposición.
        SettlementHub.Authorization memory stolen = _auth(EVIL_INTENT, HONEST_INTENT);

        vm.prank(attacker);
        vm.expectRevert(SettlementHub.AuthorizationNotBoundToIntent.selector);
        hub.payIntentWithAuthorization(stolen);

        assertEq(usdc.balanceOf(attacker), 0, "el atacante no recibe nada");
        assertEq(usdc.balanceOf(payer), 10 * AMOUNT, "no se debita al pagador");
    }

    /// Un nonce arbitrario tampoco sirve: es lo que hacía el SDK por defecto.
    function test_RevertWhen_NonceIsRandom() public {
        hub.registerIntent(HONEST_INTENT, merchant, operator, AMOUNT, expiresAt);
        SettlementHub.Authorization memory auth = _auth(HONEST_INTENT, keccak256("nonce_aleatorio"));

        vm.expectRevert(SettlementHub.AuthorizationNotBoundToIntent.selector);
        hub.payIntentWithAuthorization(auth);
    }

    /// El camino legítimo sigue funcionando con el nonce atado al intent.
    function test_SettlesWhenNonceMatchesIntent() public {
        hub.registerIntent(HONEST_INTENT, merchant, operator, AMOUNT, expiresAt);
        SettlementHub.Authorization memory auth = _auth(HONEST_INTENT, HONEST_INTENT);

        hub.payIntentWithAuthorization(auth);

        assertEq(usdc.balanceOf(merchant), 990_000_000, "comercio 99%");
        assertEq(usdc.balanceOf(operator), 7_000_000, "nodeit 0.7%");
        assertEq(usdc.balanceOf(treasury), 3_000_000, "treasury 0.3%");
        assertEq(usdc.balanceOf(attacker), 0, "el atacante sigue sin recibir nada");
    }

    /// En lote, la autorización redirigida se salta y las buenas prosperan:
    /// un elemento malicioso no debe envenenar el resto.
    function test_BatchSkipsRedirectedAuthorization() public {
        bytes32 otro = keccak256("pi_honesto_2");
        hub.registerIntent(HONEST_INTENT, merchant, operator, AMOUNT, expiresAt);
        hub.registerIntent(otro, merchant, operator, AMOUNT, expiresAt);
        hub.registerIntent(EVIL_INTENT, attacker, attacker, AMOUNT, expiresAt);

        SettlementHub.Authorization[] memory lote = new SettlementHub.Authorization[](2);
        lote[0] = _auth(EVIL_INTENT, otro); // redirigida
        lote[1] = _auth(HONEST_INTENT, HONEST_INTENT); // legítima

        vm.prank(attacker);
        uint256 liquidadas = hub.payIntentBatchWithAuthorization(lote);

        assertEq(liquidadas, 1, "solo prospera la legitima");
        assertEq(usdc.balanceOf(attacker), 0, "el atacante no recibe nada");
        assertEq(usdc.balanceOf(merchant), 990_000_000, "el comercio honesto cobra");
    }
}
