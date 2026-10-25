// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {IntentSigning} from "./helpers/IntentSigning.sol";
import {SettlementHub} from "../src/SettlementHub.sol";
import {Pausable} from "../src/Pausable.sol";
import {MockUSDCAuth} from "./mocks/MockUSDCAuth.sol";
import {MockUSDCPermit} from "./mocks/MockUSDCPermit.sol";

/// @title  ADR-009 en el hub: una parte que falla no detiene a las demás
/// @notice Reparto *pull* (§1), lote de registro que salta lo inválido (§2),
///         `intentId` ligado al comercio (§3), cobros en pausa (§7) y rescate
///         de lo que sobra (§8). La lista negra se prueba aquí con el mock y,
///         contra el USDC real, en `SettlementHub.blacklist.fork.t.sol`.
contract SettlementHubAdr009Test is Test, IntentSigning {
    SettlementHub hub;
    MockUSDCAuth usdc;

    address treasury = makeAddr("treasury");
    address guardian = makeAddr("guardian");
    address merchant = makeAddr("merchant");
    address operator = makeAddr("operator");
    address operator2 = makeAddr("operator2");
    address payer;
    uint256 payerKey;

    uint256 constant AMOUNT = 1_000_000_000; // 1000 USDC
    uint256 constant FEE_OPERADOR = 10_500_000;
    uint256 constant FEE_TESORERIA = 4_500_000;
    uint256 constant AL_COMERCIO = 985_000_000;
    bytes constant BLOQUEADA = "Blacklistable: account is blacklisted";

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockUSDCAuth();
        hub = new SettlementHub(address(usdc), treasury, guardian, _intentSigner());
        (payer, payerKey) = makeAddrAndKey("payer");
        usdc.mint(payer, 100 * AMOUNT);
    }

    // ── Helpers ───────────────────────────────────────────────

    function _registrar(bytes32 ref, address op) internal returns (bytes32) {
        return _reg(hub, ref, merchant, op, AMOUNT, uint64(block.timestamp + 1 hours));
    }

    function _auth(bytes32 id) internal view returns (SettlementHub.Authorization memory) {
        uint256 va = block.timestamp - 1;
        uint256 vb = block.timestamp + 1 hours;
        bytes32 sh =
            keccak256(abi.encode(usdc.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(), payer, address(hub), AMOUNT, va, vb, id));
        bytes32 d = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), sh));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerKey, d);
        return SettlementHub.Authorization(id, payer, va, vb, id, abi.encodePacked(r, s, v));
    }

    function _pagar(bytes32 ref, address op) internal returns (bytes32 id) {
        id = _registrar(ref, op);
        hub.payIntentWithAuthorization(_auth(id));
    }

    function _regDe(bytes32 ref, uint256 amount, uint64 exp)
        internal
        view
        returns (SettlementHub.IntentRegistration memory)
    {
        return _regOf(hub, ref, merchant, operator, amount, exp);
    }

    // ── §1 Reparto pull: la lista negra ya no detiene a nadie ──

    function test_TesoreriaBloqueada_LosPagosSiguen() public {
        usdc.blacklist(treasury);

        _pagar("a", operator);
        _pagar("b", operator2);

        assertEq(usdc.balanceOf(merchant), 2 * AL_COMERCIO, "el comercio cobra");
        assertEq(hub.accrued(treasury), 2 * FEE_TESORERIA, "lo de la tesoreria espera");

        vm.expectRevert(BLOQUEADA);
        hub.claimFor(treasury);

        usdc.unBlacklist(treasury);
        hub.claimFor(treasury);
        assertEq(usdc.balanceOf(treasury), 2 * FEE_TESORERIA);
    }

    function test_OperadorBloqueado_SusPagosSiguen_YLosDemasCobran() public {
        usdc.blacklist(operator);

        _pagar("a", operator);
        _pagar("b", operator2);

        assertEq(usdc.balanceOf(merchant), 2 * AL_COMERCIO);
        vm.prank(operator);
        vm.expectRevert(BLOQUEADA);
        hub.claim();

        vm.prank(operator2);
        hub.claim();
        assertEq(usdc.balanceOf(operator2), FEE_OPERADOR);
    }

    /// A propósito: el comercio bloqueado no cobra, y su pago no pasa.
    function test_ComercioBloqueado_SuPagoRevierte() public {
        bytes32 id = _registrar("a", operator);
        usdc.blacklist(merchant);
        SettlementHub.Authorization memory auth = _auth(id);
        vm.expectRevert(BLOQUEADA);
        hub.payIntentWithAuthorization(auth);
        assertEq(hub.totalAccrued(), 0, "nada acreditado de un pago que no paso");
    }

    // ── §1 Cobrar lo acreditado ───────────────────────────────

    function test_Claim_EnviaYDejaACero() public {
        _pagar("a", operator);
        _pagar("b", operator);
        assertEq(hub.accrued(operator), 2 * FEE_OPERADOR, "se acumula entre pagos");

        vm.expectEmit(true, false, false, true);
        emit SettlementHub.FeesClaimed(operator, 2 * FEE_OPERADOR);
        vm.prank(operator);
        uint256 cobrado = hub.claim();

        assertEq(cobrado, 2 * FEE_OPERADOR);
        assertEq(usdc.balanceOf(operator), 2 * FEE_OPERADOR);
        assertEq(hub.accrued(operator), 0);
        assertEq(hub.totalAccrued(), 2 * FEE_TESORERIA, "solo queda lo de la tesoreria");
        assertEq(usdc.balanceOf(address(hub)), hub.totalAccrued());
    }

    function test_Claim_Revert_NadaQueCobrar() public {
        vm.prank(operator);
        vm.expectRevert(SettlementHub.NothingToClaim.selector);
        hub.claim();
    }

    /// Cualquiera puede llamar a `claimFor`, pero el dinero va a su dueño.
    function test_ClaimFor_CualquieraLoLlama_ElDineroVaASuDuenio() public {
        _pagar("a", operator);
        address extranio = makeAddr("extranio");

        vm.prank(extranio);
        hub.claimFor(operator);
        vm.prank(extranio);
        hub.claimFor(treasury);

        assertEq(usdc.balanceOf(operator), FEE_OPERADOR);
        assertEq(usdc.balanceOf(treasury), FEE_TESORERIA);
        assertEq(usdc.balanceOf(extranio), 0, "quien llama no se lleva nada");
    }

    /// §7: la pausa no retiene el dinero de nadie.
    function test_Claim_FuncionaEnPausa() public {
        _pagar("a", operator);
        vm.prank(guardian);
        hub.pause();

        vm.prank(operator);
        hub.claim();
        hub.claimFor(treasury);

        assertEq(usdc.balanceOf(operator), FEE_OPERADOR);
        assertEq(usdc.balanceOf(treasury), FEE_TESORERIA);
    }

    // ── §2 Un registro inválido no hunde el lote ──────────────

    /// Regresión de OCT-01: un cobro a 31 días hacía revertir el lote entero,
    /// y con él los pagos de todos los comercios del lote.
    function test_LoteDeRegistro_SaltaUnPlazoFueraDeRango() public {
        SettlementHub.IntentRegistration[] memory regs = new SettlementHub.IntentRegistration[](3);
        regs[0] = _regDe("bueno-1", AMOUNT, uint64(block.timestamp + 1 hours));
        regs[1] = _regDe("viejo-y-largo", AMOUNT, uint64(block.timestamp + 31 days));
        regs[2] = _regDe("bueno-2", AMOUNT, uint64(block.timestamp + 1 hours));

        vm.expectEmit(true, false, false, true);
        emit SettlementHub.IntentRegistrationSkipped(
            _idOf(merchant, "viejo-y-largo"), abi.encodeWithSelector(SettlementHub.InvalidExpiry.selector)
        );
        uint256 registrados = hub.registerIntentBatch(regs);

        assertEq(registrados, 2);
        assertEq(hub.getIntent(_idOf(merchant, "bueno-1")).merchant, merchant);
        assertEq(hub.getIntent(_idOf(merchant, "bueno-2")).merchant, merchant);
        assertEq(hub.getIntent(_idOf(merchant, "viejo-y-largo")).merchant, address(0));
    }

    /// El otro caso de OCT-01: un registro que caduca mientras el lote espera.
    function test_LoteDeRegistro_SaltaUnoQueCaducoEnElCamino() public {
        SettlementHub.IntentRegistration[] memory regs = new SettlementHub.IntentRegistration[](2);
        regs[0] = _regDe("caduca-ya", AMOUNT, uint64(block.timestamp + 10));
        regs[1] = _regDe("bueno", AMOUNT, uint64(block.timestamp + 1 hours));
        vm.warp(block.timestamp + 11);

        assertEq(hub.registerIntentBatch(regs), 1);
        assertEq(hub.getIntent(_idOf(merchant, "bueno")).merchant, merchant);
    }

    function test_LoteDeRegistro_SaltaImporteCeroYDemasiadoGrande() public {
        SettlementHub.IntentRegistration[] memory regs = new SettlementHub.IntentRegistration[](3);
        regs[0] = _regDe("cero", 0, uint64(block.timestamp + 1 hours));
        regs[1] = _regDe("enorme", uint256(type(uint96).max) + 1, uint64(block.timestamp + 1 hours));
        regs[2] = _regDe("bueno", AMOUNT, uint64(block.timestamp + 1 hours));

        assertEq(hub.registerIntentBatch(regs), 1);
    }

    /// Los ya registrados se siguen saltando en silencio: es el caso normal de
    /// un lote que se reintenta.
    function test_LoteDeRegistro_ElYaRegistradoSeSaltaSinEvento() public {
        bytes32 id = _registrar("a", operator);
        SettlementHub.IntentRegistration[] memory regs = new SettlementHub.IntentRegistration[](1);
        regs[0] = _regDe("a", AMOUNT, uint64(block.timestamp + 1 hours));

        vm.recordLogs();
        assertEq(hub.registerIntentBatch(regs), 0);
        assertEq(vm.getRecordedLogs().length, 0, "sin eventos");
        assertEq(hub.getIntent(id).merchant, merchant);
    }

    /// Lo que afecta a todos sigue revirtiendo el lote entero: no tiene
    /// sentido saltar uno a uno.
    function test_LoteDeRegistro_EnPausaRevierteEntero() public {
        SettlementHub.IntentRegistration[] memory regs = new SettlementHub.IntentRegistration[](1);
        regs[0] = _regDe("a", AMOUNT, uint64(block.timestamp + 1 hours));
        vm.prank(guardian);
        hub.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        hub.registerIntentBatch(regs);
    }

    function test_RegisterOneSelfCall_Revert_DesdeFuera() public {
        SettlementHub.IntentRegistration memory reg = _regDe("a", AMOUNT, uint64(block.timestamp + 1 hours));
        vm.expectRevert(SettlementHub.Forbidden.selector);
        hub.registerOneSelfCall(reg);
    }

    function test_RegisterIntent_DeUnoEnUnoSigueRevirtiendo() public {
        SettlementHub.IntentRegistration memory reg = _regDe("a", AMOUNT, uint64(block.timestamp + 31 days));
        vm.expectRevert(SettlementHub.InvalidExpiry.selector);
        hub.registerIntent(reg);
    }

    // ── §3 El intentId lleva dentro al comercio ───────────────

    function test_IntentIdOf_EsElComercioYLaReferencia() public {
        bytes32 ref = keccak256("pi_abc");
        assertEq(hub.intentIdOf(merchant, ref), keccak256(abi.encode(merchant, ref)));
        assertTrue(hub.intentIdOf(merchant, ref) != hub.intentIdOf(operator, ref), "otro comercio, otro id");
    }

    function test_RegisterIntent_DevuelveElIntentIdYLoEmite() public {
        bytes32 esperado = _idOf(merchant, "pi_1");
        uint64 exp = uint64(block.timestamp + 1 hours);
        vm.expectEmit(true, true, true, true);
        emit SettlementHub.IntentRegistered(esperado, merchant, operator, AMOUNT, exp);
        assertEq(hub.registerIntent(_regDe("pi_1", AMOUNT, exp)), esperado);
    }

    // ── §8 Lo que llega por error tiene salida ────────────────

    function test_SweepSurplus_AcreditaALaTesoreriaSoloLoQueSobra() public {
        _pagar("a", operator);
        usdc.mint(address(hub), 20_000_000); // 20 USDC por error

        vm.expectEmit(true, false, false, true);
        emit SettlementHub.SurplusSwept(address(usdc), 20_000_000);
        vm.prank(makeAddr("cualquiera"));
        hub.sweepSurplus();

        assertEq(hub.accrued(treasury), FEE_TESORERIA + 20_000_000);
        assertEq(hub.accrued(operator), FEE_OPERADOR, "lo del operador no se toca");
        assertEq(usdc.balanceOf(address(hub)), hub.totalAccrued(), "ya no sobra nada");

        hub.claimFor(treasury);
        assertEq(usdc.balanceOf(treasury), FEE_TESORERIA + 20_000_000);
    }

    function test_SweepSurplus_Revert_NoSobraNada() public {
        _pagar("a", operator);
        vm.expectRevert(SettlementHub.NothingToSweep.selector);
        hub.sweepSurplus();
    }

    function test_SweepToken_OtroToken() public {
        MockUSDCPermit otro = new MockUSDCPermit();
        otro.mint(address(hub), 7e6);
        hub.sweepToken(address(otro));
        assertEq(otro.balanceOf(treasury), 7e6);
    }

    function test_SweepToken_Revert_Usdc() public {
        vm.expectRevert(SettlementHub.UseSweepSurplus.selector);
        hub.sweepToken(address(usdc));
    }

    function test_SweepToken_Revert_NadaQueRescatar() public {
        MockUSDCPermit otro = new MockUSDCPermit();
        vm.expectRevert(SettlementHub.NothingToSweep.selector);
        hub.sweepToken(address(otro));
    }

    function test_ElHubNoAceptaEth() public {
        vm.deal(payer, 1 ether);
        vm.prank(payer);
        (bool ok,) = address(hub).call{value: 1 ether}("");
        assertFalse(ok, "sin receive: el ETH no entra");
    }

    // ── Fuzz: nada se pierde ni se crea ───────────────────────

    function testFuzz_ElHubCubreSiempreLoQueDebe(uint96 donado, uint8 pagos) public {
        pagos = uint8(bound(pagos, 1, 5));
        for (uint256 i; i < pagos; i++) {
            _pagar(keccak256(abi.encode(i)), i % 2 == 0 ? operator : operator2);
        }
        if (donado > 0) usdc.mint(address(hub), donado);
        if (donado > 0) hub.sweepSurplus();

        assertEq(usdc.balanceOf(address(hub)), hub.totalAccrued());
        assertEq(
            hub.totalAccrued(), hub.accrued(operator) + hub.accrued(operator2) + hub.accrued(treasury), "suma exacta"
        );
    }
}
