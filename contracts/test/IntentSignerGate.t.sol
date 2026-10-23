// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {IntentSignerGate} from "../src/IntentSignerGate.sol";
import {SettlementHub} from "../src/SettlementHub.sol";
import {MockERC1271Wallet} from "./mocks/MockERC1271Wallet.sol";
import {MockUSDCAuth} from "./mocks/MockUSDCAuth.sol";

/// @title  IntentSignerGate como `intentSigner` del hub (ADR-009 §4)
/// @notice La clave caliente de la API firma cada registro; solo el admin
///         —un multisig frío en mainnet— puede cambiarla, sin redesplegar el
///         hub. Estos tests van contra un hub de verdad, no contra el gate
///         suelto: lo que importa es qué registros acepta el hub.
contract IntentSignerGateTest is Test {
    IntentSignerGate gate;
    SettlementHub hub;

    address admin = makeAddr("admin");
    address merchant = makeAddr("merchant");
    address operator = makeAddr("operator");

    uint256 constant CLAVE_CALIENTE = 0xA11CE;
    uint256 constant CLAVE_NUEVA = 0xB0B;
    uint256 constant AMOUNT = 1_000_000;
    uint64 exp;

    function setUp() public {
        vm.warp(1_700_000_000);
        gate = new IntentSignerGate(admin, vm.addr(CLAVE_CALIENTE));
        hub = new SettlementHub(address(new MockUSDCAuth()), makeAddr("treasury"), makeAddr("guardian"), address(gate));
        exp = uint64(block.timestamp + 1 hours);
    }

    function _digest(bytes32 ref) internal view returns (bytes32) {
        bytes32 sh = keccak256(
            abi.encode(hub.REGISTER_INTENT_TYPEHASH(), hub.intentIdOf(merchant, ref), merchant, operator, AMOUNT, exp)
        );
        return keccak256(abi.encodePacked("\x19\x01", hub.DOMAIN_SEPARATOR(), sh));
    }

    /// La API firma el digest EIP-712 del hub tal cual: sin envoltorio de Safe.
    function _reg(bytes32 ref, uint256 key) internal view returns (SettlementHub.IntentRegistration memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _digest(ref));
        return SettlementHub.IntentRegistration(ref, merchant, operator, AMOUNT, exp, abi.encodePacked(r, s, v));
    }

    // ── Lo normal ─────────────────────────────────────────────

    function test_LaClaveCalienteRegistra() public {
        bytes32 id = hub.registerIntent(_reg("a", CLAVE_CALIENTE));
        assertEq(hub.getIntent(id).merchant, merchant);
    }

    function test_Revert_UnaClaveCualquieraNoRegistra() public {
        SettlementHub.IntentRegistration memory reg = _reg("a", 0xBAD);
        vm.expectRevert(SettlementHub.InvalidIntentSignature.selector);
        hub.registerIntent(reg);
    }

    // ── Rotar sin redesplegar ─────────────────────────────────

    /// El motivo del contrato: una clave robada o perdida se retira y el hub
    /// sigue funcionando, con el MISMO `intentSigner`.
    function test_ElAdminRotaLaClave_SinRedesplegarElHub() public {
        vm.expectEmit(true, true, false, false);
        emit IntentSignerGate.SignerChanged(vm.addr(CLAVE_CALIENTE), vm.addr(CLAVE_NUEVA));
        vm.prank(admin);
        gate.setSigner(vm.addr(CLAVE_NUEVA));

        SettlementHub.IntentRegistration memory vieja = _reg("a", CLAVE_CALIENTE);
        vm.expectRevert(SettlementHub.InvalidIntentSignature.selector);
        hub.registerIntent(vieja);

        hub.registerIntent(_reg("b", CLAVE_NUEVA));
        assertEq(hub.intentSigner(), address(gate), "el hub no cambio");
    }

    /// Quien robe la clave caliente no puede quedarse con el contrato.
    function test_Revert_LaClaveCalienteNoPuedeRotarseNiTocarElAdmin() public {
        address caliente = vm.addr(CLAVE_CALIENTE);

        vm.prank(caliente);
        vm.expectRevert(IntentSignerGate.NotAdmin.selector);
        gate.setSigner(caliente);

        vm.prank(caliente);
        vm.expectRevert(IntentSignerGate.NotAdmin.selector);
        gate.transferAdmin(caliente);
    }

    /// `signer = 0` es el freno de emergencia: ningún registro nuevo pasa
    /// hasta nombrar otra clave.
    function test_Freno_SignerACero() public {
        vm.prank(admin);
        gate.setSigner(address(0));

        SettlementHub.IntentRegistration memory reg = _reg("a", CLAVE_CALIENTE);
        vm.expectRevert(SettlementHub.InvalidIntentSignature.selector);
        hub.registerIntent(reg);

        // Ni siquiera una firma "de la dirección cero" (ecrecover inválido).
        assertEq(gate.isValidSignature(bytes32(0), new bytes(65)), bytes4(0xffffffff));

        vm.prank(admin);
        gate.setSigner(vm.addr(CLAVE_NUEVA));
        hub.registerIntent(_reg("a", CLAVE_NUEVA));
    }

    /// En un lote, lo firmado con la clave retirada se salta en vez de hundir
    /// el lote (ADR-009 §2): lo firmado con la nueva sale.
    function test_EnLote_LoFirmadoConLaClaveRetiradaSeSalta() public {
        SettlementHub.IntentRegistration[] memory lote = new SettlementHub.IntentRegistration[](2);
        lote[0] = _reg("a", CLAVE_CALIENTE);
        lote[1] = _reg("b", CLAVE_NUEVA);
        vm.prank(admin);
        gate.setSigner(vm.addr(CLAVE_NUEVA));

        assertEq(hub.registerIntentBatch(lote), 1);
    }

    // ── El admin, en dos pasos ────────────────────────────────

    function test_TransferAdmin_EnDosPasos() public {
        address nuevo = makeAddr("nuevoAdmin");
        vm.prank(admin);
        gate.transferAdmin(nuevo);
        assertEq(gate.admin(), admin, "nada cambia hasta aceptar");
        assertEq(gate.pendingAdmin(), nuevo);

        vm.prank(nuevo);
        gate.acceptAdmin();
        assertEq(gate.admin(), nuevo);
        assertEq(gate.pendingAdmin(), address(0));

        vm.prank(admin);
        vm.expectRevert(IntentSignerGate.NotAdmin.selector);
        gate.setSigner(address(0));
    }

    /// Una dirección mal escrita nunca acepta: el admin sigue siendo el actual.
    function test_Revert_SoloElPropuestoAcepta() public {
        vm.prank(admin);
        gate.transferAdmin(makeAddr("malEscrita"));

        vm.prank(makeAddr("otro"));
        vm.expectRevert(IntentSignerGate.NotPendingAdmin.selector);
        gate.acceptAdmin();
        assertEq(gate.admin(), admin);
    }

    function test_TransferAdmin_ACeroCancela() public {
        address nuevo = makeAddr("nuevoAdmin");
        vm.startPrank(admin);
        gate.transferAdmin(nuevo);
        gate.transferAdmin(address(0));
        vm.stopPrank();

        vm.prank(nuevo);
        vm.expectRevert(IntentSignerGate.NotPendingAdmin.selector);
        gate.acceptAdmin();
    }

    // ── Constructor y ERC-1271 ────────────────────────────────

    function test_Constructor_Revert_AdminCero() public {
        vm.expectRevert(IntentSignerGate.ZeroAdmin.selector);
        new IntentSignerGate(address(0), vm.addr(CLAVE_CALIENTE));
    }

    /// Se puede desplegar con el freno puesto y nombrar la clave después.
    function test_Constructor_SignerCeroPermitido() public {
        IntentSignerGate frenado = new IntentSignerGate(admin, address(0));
        assertEq(frenado.signer(), address(0));
    }

    /// Una firma mal formada se rechaza sin revertir: ERC-1271 responde, no
    /// explota.
    function test_FirmaMalFormada_DevuelveInvalidoSinRevertir() public view {
        assertEq(gate.isValidSignature(keccak256("x"), hex"1234"), bytes4(0xffffffff));
        assertEq(gate.isValidSignature(keccak256("x"), ""), bytes4(0xffffffff));
    }

    /// La clave puede ser, a su vez, un contrato ERC-1271 (una cartera de un
    /// servicio de custodia de claves, por ejemplo).
    function test_LaClavePuedeSerUnContratoErc1271() public {
        MockERC1271Wallet cartera = new MockERC1271Wallet(vm.addr(CLAVE_NUEVA));
        vm.prank(admin);
        gate.setSigner(address(cartera));

        hub.registerIntent(_reg("a", CLAVE_NUEVA));
    }
}
