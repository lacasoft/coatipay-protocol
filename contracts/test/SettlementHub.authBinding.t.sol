// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {IntentSigning} from "./helpers/IntentSigning.sol";
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
///
///         Y desde ADR-009 §3 el `intentId` lleva dentro al comercio
///         (`intentIdOf(merchant, ref)`): ni quien controle `intentSigner`
///         puede atar a otro comercio un pago que el pagador ya firmó.
contract SettlementHubAuthBindingTest is Test, IntentSigning {
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

    /// Referencias de cobro fuera de la cadena; los `intentId` los calcula
    /// el hub con el comercio de cada uno.
    bytes32 constant HONEST_REF = keccak256("pi_honesto");
    bytes32 constant EVIL_REF = keccak256("pi_senuelo");
    uint256 constant AMOUNT = 1_000_000_000; // 1000 USDC
    uint64 expiresAt;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockUSDCAuth();
        hub = new SettlementHub(address(usdc), treasury, guardian, _intentSigner());
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
        bytes32 honest = _reg(hub, HONEST_REF, merchant, operator, AMOUNT, expiresAt);
        // El atacante se registra como comercio Y como operador del señuelo,
        // por el mismo importe, que puede leer del intent honesto.
        bytes32 evil = _reg(hub, EVIL_REF, attacker, attacker, AMOUNT, expiresAt);

        // El pagador firma para SU intent. La firma llega al nodeit, que es
        // quien debe enviarla: ahí está la exposición.
        SettlementHub.Authorization memory stolen = _auth(evil, honest);

        vm.prank(attacker);
        vm.expectRevert(SettlementHub.AuthorizationNotBoundToIntent.selector);
        hub.payIntentWithAuthorization(stolen);

        assertEq(usdc.balanceOf(attacker), 0, "el atacante no recibe nada");
        assertEq(usdc.balanceOf(payer), 10 * AMOUNT, "no se debita al pagador");
    }

    /// Un nonce arbitrario tampoco sirve: es lo que hacía el SDK por defecto.
    function test_RevertWhen_NonceIsRandom() public {
        bytes32 honest = _reg(hub, HONEST_REF, merchant, operator, AMOUNT, expiresAt);
        SettlementHub.Authorization memory auth = _auth(honest, keccak256("nonce_aleatorio"));

        vm.expectRevert(SettlementHub.AuthorizationNotBoundToIntent.selector);
        hub.payIntentWithAuthorization(auth);
    }

    /// El camino legítimo sigue funcionando con el nonce atado al intent.
    function test_SettlesWhenNonceMatchesIntent() public {
        bytes32 honest = _reg(hub, HONEST_REF, merchant, operator, AMOUNT, expiresAt);
        SettlementHub.Authorization memory auth = _auth(honest, honest);

        hub.payIntentWithAuthorization(auth);

        assertEq(usdc.balanceOf(merchant), 985_000_000, "comercio 98.5%");
        assertEq(hub.accrued(operator), 10_500_000, "nodeit 1.05% acreditado");
        assertEq(hub.accrued(treasury), 4_500_000, "treasury 0.45% acreditado");
        assertEq(usdc.balanceOf(attacker), 0, "el atacante sigue sin recibir nada");
    }

    /// En lote, la autorización redirigida se salta y las buenas prosperan:
    /// un elemento malicioso no debe envenenar el resto.
    function test_BatchSkipsRedirectedAuthorization() public {
        bytes32 honest = _reg(hub, HONEST_REF, merchant, operator, AMOUNT, expiresAt);
        bytes32 otro = _reg(hub, keccak256("pi_honesto_2"), merchant, operator, AMOUNT, expiresAt);
        bytes32 evil = _reg(hub, EVIL_REF, attacker, attacker, AMOUNT, expiresAt);

        SettlementHub.Authorization[] memory lote = new SettlementHub.Authorization[](2);
        lote[0] = _auth(evil, otro); // redirigida
        lote[1] = _auth(honest, honest); // legítima

        vm.prank(attacker);
        uint256 liquidadas = hub.payIntentBatchWithAuthorization(lote);

        assertEq(liquidadas, 1, "solo prospera la legitima");
        assertEq(usdc.balanceOf(attacker), 0, "el atacante no recibe nada");
        assertEq(usdc.balanceOf(merchant), 985_000_000, "el comercio honesto cobra");
    }

    // ── Registro firmado (ADR-004) ────────────────────────────

    /// El nodeit es quien envía registerIntent con los datos que le da el API.
    /// Sin firma podía sustituir la dirección del comercio por la suya y
    /// quedarse el pago, aunque la autorización estuviera bien atada al intent.
    function test_RevertWhen_OperatorNamesItselfMerchant() public {
        SettlementHub.IntentRegistration memory falso = SettlementHub.IntentRegistration({
            ref: HONEST_REF,
            merchant: attacker, // se pone a sí mismo
            operator: attacker,
            amount: AMOUNT,
            expiresAt: expiresAt,
            // Firma con SU clave, no con la del firmante autorizado.
            signature: _signIntentWith(0xBAD, hub, _idOf(attacker, HONEST_REF), attacker, attacker, AMOUNT, expiresAt)
        });

        vm.prank(attacker);
        vm.expectRevert(SettlementHub.InvalidIntentSignature.selector);
        hub.registerIntent(falso);
    }

    /// Tomar una firma legítima y alterar el comercio invalida el registro:
    /// la dirección forma parte de lo firmado.
    function test_RevertWhen_MerchantTamperedAfterSigning() public {
        SettlementHub.IntentRegistration memory reg = _regOf(hub, HONEST_REF, merchant, operator, AMOUNT, expiresAt);
        reg.merchant = attacker; // se altera después de firmar

        vm.expectRevert(SettlementHub.InvalidIntentSignature.selector);
        hub.registerIntent(reg);
    }

    /// Alterar el importe tampoco cuela.
    function test_RevertWhen_AmountTamperedAfterSigning() public {
        SettlementHub.IntentRegistration memory reg = _regOf(hub, HONEST_REF, merchant, operator, AMOUNT, expiresAt);
        reg.amount = AMOUNT * 2;

        vm.expectRevert(SettlementHub.InvalidIntentSignature.selector);
        hub.registerIntent(reg);
    }

    /// El lote no es un atajo: cada elemento necesita su firma. El que no la
    /// tiene no se registra; desde ADR-009 §2 se salta y el resto del lote
    /// sigue, en vez de revertir entero.
    function test_BatchSkipsUnsignedElement() public {
        SettlementHub.IntentRegistration[] memory lote = new SettlementHub.IntentRegistration[](2);
        lote[0] = _regOf(hub, HONEST_REF, merchant, operator, AMOUNT, expiresAt);
        lote[1] = _regOf(hub, EVIL_REF, merchant, operator, AMOUNT, expiresAt);
        lote[1].merchant = attacker; // alterado tras firmar

        vm.expectEmit(true, false, false, true);
        emit SettlementHub.IntentRegistrationSkipped(
            _idOf(attacker, EVIL_REF), abi.encodeWithSelector(SettlementHub.InvalidIntentSignature.selector)
        );
        vm.prank(attacker);
        uint256 registrados = hub.registerIntentBatch(lote);

        assertEq(registrados, 1, "solo el firmado");
        assertEq(hub.getIntent(_idOf(attacker, EVIL_REF)).merchant, address(0), "el alterado no existe");
        assertEq(hub.getIntent(_idOf(merchant, HONEST_REF)).merchant, merchant, "el legitimo si");
    }

    // ── El intentId lleva dentro al comercio (ADR-009 §3) ─────

    /// Ni con la firma de `intentSigner` se puede llevar a otro comercio un
    /// pago que el pagador ya firmó. Antes, quien controlara `intentSigner`
    /// podía registrar el `intentId` firmado por el pagador —aún sin
    /// registrar, porque el registro es perezoso— con su propio comercio.
    function test_IntentSignerCannotRebindASignedPaymentToAnotherMerchant() public {
        // El pagador firma para el intent del comercio honesto, todavía sin
        // registrar.
        bytes32 honest = hub.intentIdOf(merchant, HONEST_REF);
        SettlementHub.Authorization memory firmada = _auth(honest, honest);

        // Quien controla `intentSigner` registra la MISMA referencia con su
        // propio comercio, con una firma válida.
        bytes32 robado = _reg(hub, HONEST_REF, attacker, attacker, AMOUNT, expiresAt);
        assertTrue(robado != honest, "otro comercio, otro intentId");

        // La firma del pagador no sirve para ese intent...
        SettlementHub.Authorization memory redirigida = _auth(robado, honest);
        vm.expectRevert(SettlementHub.AuthorizationNotBoundToIntent.selector);
        hub.payIntentWithAuthorization(redirigida);

        // ...y el intent para el que sí sirve no existe hasta que se registre
        // con el comercio honesto.
        vm.expectRevert(SettlementHub.IntentNotFound.selector);
        hub.payIntentWithAuthorization(firmada);

        assertEq(usdc.balanceOf(attacker), 0, "el atacante no recibe nada");
        assertEq(usdc.balanceOf(payer), 10 * AMOUNT, "no se debita al pagador");
    }

    /// Y el camino legítimo sigue funcionando de punta a punta.
    function test_SignedRegistrationSettlesToRealMerchant() public {
        bytes32 honest = _reg(hub, HONEST_REF, merchant, operator, AMOUNT, expiresAt);
        SettlementHub.Authorization memory auth = _auth(honest, honest);

        vm.prank(operator);
        hub.payIntentWithAuthorization(auth);

        assertEq(usdc.balanceOf(merchant), 985_000_000, "el comercio real cobra el 98.5%");
        assertEq(usdc.balanceOf(attacker), 0, "el atacante no recibe nada");
    }
}
