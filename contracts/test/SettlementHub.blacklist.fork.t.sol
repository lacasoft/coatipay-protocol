// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {SettlementHub} from "../src/SettlementHub.sol";
import {IntentSigning} from "./helpers/IntentSigning.sol";

interface IFiatToken {
    function blacklist(address) external;
    function unBlacklist(address) external;
    function blacklister() external view returns (address);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function RECEIVE_WITH_AUTHORIZATION_TYPEHASH() external view returns (bytes32);
}

/// @title  La lista negra de USDC, contra el USDC real (ADR-009 §1)
/// @notice Regresión de OCT-02 y OCT-03 (reporte externo de octubre de
///         2026). Con el reparto en el momento, la tesorería en la lista negra
///         detenía TODOS los pagos, y un operador en la lista negra dejaba sin
///         cobrar los suyos. Con el reparto *pull*, los pagos siguen y la
///         comisión de quien está bloqueado espera en el hub.
///
///         Contra el FiatToken desplegado en Base Sepolia, no contra un mock:
///         el bloqueo lo hace su `blacklister` real.
///
///           FORK_TESTS=1 forge test --match-path 'test/*.fork.t.sol'
contract SettlementHubBlacklistForkTest is IntentSigning {
    IFiatToken constant USDC = IFiatToken(0x036CbD53842c5426634e7929541eC2318f3dCF7e);
    /// El hub de agosto tiene 20 USDC sin salida (ADR-009 §8): en la
    /// bifurcación se usan para fondear al pagador.
    address constant HUB_ANTERIOR = 0xE0941E1A2b9710fc81547CDfF2e67d2C58eBAF09;
    bytes constant BLOQUEADA = "Blacklistable: account is blacklisted";

    SettlementHub hub;
    address treasury = makeAddr("treasury");
    address merchant = makeAddr("merchant");
    address operator = makeAddr("operator");
    address operator2 = makeAddr("operator2");
    uint256 constant PAYER_KEY = 0xB0B;
    address payer;
    uint256 constant AMOUNT = 1_000_000; // 1 USDC
    uint256 constant FEE_OPERADOR = 10_500; // 1.05%
    uint256 constant FEE_TESORERIA = 4_500; // 0.45%
    uint256 constant AL_COMERCIO = 985_000; // 98.5%

    function setUp() public {
        // Estos tests hablan con la red. CI corre `forge test` sin filtro, y un
        // test que depende de un RPC publico es intermitente por definicion: un
        // gate que falla al azar acaba ignorandose. Se activan a proposito.
        if (bytes(vm.envOr("FORK_TESTS", string(""))).length == 0) vm.skip(true);
        vm.createSelectFork("https://sepolia.base.org");
        hub = new SettlementHub(address(USDC), treasury, makeAddr("guardian"), _intentSigner());
        payer = vm.addr(PAYER_KEY);
        vm.prank(HUB_ANTERIOR);
        USDC.transfer(payer, 10 * AMOUNT);
    }

    function _registrar(bytes32 ref, address merch, address op) internal returns (bytes32) {
        return _reg(hub, ref, merch, op, AMOUNT, uint64(block.timestamp + 1 hours));
    }

    function _auth(bytes32 id) internal view returns (SettlementHub.Authorization memory) {
        uint256 vb = block.timestamp + 1 hours;
        bytes32 sh =
            keccak256(abi.encode(USDC.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(), payer, address(hub), AMOUNT, 0, vb, id));
        bytes32 d = keccak256(abi.encodePacked("\x19\x01", USDC.DOMAIN_SEPARATOR(), sh));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PAYER_KEY, d);
        return SettlementHub.Authorization(id, payer, 0, vb, id, abi.encodePacked(r, s, v));
    }

    function _bloquear(address a) internal {
        vm.prank(USDC.blacklister());
        USDC.blacklist(a);
    }

    function _desbloquear(address a) internal {
        vm.prank(USDC.blacklister());
        USDC.unBlacklist(a);
    }

    // OCT-02: antes, ningún pago pasaba por ningún camino.
    function test_TesoreriaBloqueada_LosPagosSiguen_YSuComisionEspera() public {
        bytes32 a = _registrar("a", merchant, operator);
        bytes32 b = _registrar("b", merchant, operator2);
        bytes32 c = _registrar("c", merchant, operator);
        bytes32 d = _registrar("d", merchant, operator2);
        _bloquear(treasury);

        // Los tres caminos de pago: autorización, approve y lote.
        hub.payIntentWithAuthorization(_auth(a));
        vm.prank(payer);
        USDC.approve(address(hub), AMOUNT);
        vm.prank(payer);
        hub.payIntent(b);
        SettlementHub.Authorization[] memory lote = new SettlementHub.Authorization[](2);
        lote[0] = _auth(c);
        lote[1] = _auth(d);
        assertEq(hub.payIntentBatchWithAuthorization(lote), 2, "el lote liquida todo");

        assertEq(USDC.balanceOf(merchant), 4 * AL_COMERCIO, "el comercio cobra en el acto");
        assertEq(hub.accrued(treasury), 4 * FEE_TESORERIA, "la comision de la tesoreria queda acreditada");

        // Mientras siga bloqueada no puede cobrar —y nadie puede llevarse lo
        // suyo a otra parte—, pero no detiene nada.
        vm.expectRevert(BLOQUEADA);
        hub.claimFor(treasury);

        _desbloquear(treasury);
        hub.claimFor(treasury);
        assertEq(USDC.balanceOf(treasury), 4 * FEE_TESORERIA, "cobra todo al desbloquearla");
        assertEq(hub.accrued(treasury), 0);
    }

    // OCT-03: antes, sus intents no se podían cobrar y la firma del pagador
    // quedaba inservible.
    function test_OperadorBloqueado_SusPagosSiguen_YCobraAlDesbloquearlo() public {
        bytes32 a = _registrar("a", merchant, operator);
        bytes32 b = _registrar("b", merchant, operator2);
        _bloquear(operator);

        hub.payIntentWithAuthorization(_auth(a));
        hub.payIntentWithAuthorization(_auth(b));

        assertEq(USDC.balanceOf(merchant), 2 * AL_COMERCIO, "los dos pagos llegan al comercio");
        assertEq(hub.accrued(operator), FEE_OPERADOR, "la comision del bloqueado espera");

        vm.prank(operator);
        vm.expectRevert(BLOQUEADA);
        hub.claim();

        // El otro operador cobra con normalidad.
        vm.prank(operator2);
        hub.claim();
        assertEq(USDC.balanceOf(operator2), FEE_OPERADOR);

        _desbloquear(operator);
        vm.prank(operator);
        hub.claim();
        assertEq(USDC.balanceOf(operator), FEE_OPERADOR);
    }

    // Lo que NO cambia, a propósito: un comercio bloqueado no cobra. Acreditarle
    // el pago dejaría retenido el dinero del pagador; mejor que no pase. En un
    // lote, su pago se salta y los demás siguen.
    function test_ComercioBloqueado_SuPagoNoPasa_YNoFrenaAlLote() public {
        address otroComercio = makeAddr("otroComercio");
        bytes32 a = _registrar("a", merchant, operator);
        bytes32 b = _registrar("b", otroComercio, operator);
        _bloquear(merchant);

        SettlementHub.Authorization memory authA = _auth(a);
        vm.expectRevert(BLOQUEADA);
        hub.payIntentWithAuthorization(authA);

        SettlementHub.Authorization[] memory lote = new SettlementHub.Authorization[](2);
        lote[0] = authA;
        lote[1] = _auth(b);
        assertEq(hub.payIntentBatchWithAuthorization(lote), 1, "solo el del comercio sano");
        assertEq(USDC.balanceOf(otroComercio), AL_COMERCIO);
        assertEq(uint8(hub.getIntent(a).status), uint8(SettlementHub.IntentStatus.Registered));
    }

    // OCT-14: con el hub bloqueado no hay diseño de reparto que ayude. Es lo
    // que el vigía de la API avisa en cuanto pasa.
    function test_HubBloqueado_TodoSeDetiene() public {
        bytes32 a = _registrar("a", merchant, operator);
        _bloquear(address(hub));
        SettlementHub.Authorization memory authA = _auth(a);
        vm.expectRevert(BLOQUEADA);
        hub.payIntentWithAuthorization(authA);
    }
}
