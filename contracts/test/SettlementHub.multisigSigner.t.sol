// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {SettlementHub} from "../src/SettlementHub.sol";
import {MockMultisigWallet} from "./mocks/MockMultisigWallet.sol";
import {MockUSDCAuth} from "./mocks/MockUSDCAuth.sol";

/// @title  `intentSigner` como multisig (ERC-1271)
/// @notice `intentSigner` es inmutable a propósito: si el guardian pudiera
///         rotarlo, podría atar pagos en vuelo a un comercio de su elección.
///         Pero con una sola clave, perderla o que se filtre obliga a
///         redesplegar el hub entero.
///
///         Apuntando a un multisig se resuelven las dos cosas a la vez: la
///         dirección sigue siendo inmutable —el guardian no la toca— y aun así
///         **los firmantes se rotan por dentro**, sin tocar el contrato. Además
///         una sola llave comprometida deja de bastar.
///
///         Estos tests comprueban que esa configuración funciona de verdad, no
///         que el código compile.
contract SettlementHubMultisigSignerTest is Test {
    SettlementHub hub;
    MockUSDCAuth usdc;
    MockMultisigWallet multisig;

    address treasury = makeAddr("treasury");
    address guardian = makeAddr("guardian");
    address merchant = makeAddr("merchant");
    address operator = makeAddr("operator");

    uint256 constant KEY_A = 0xA1;
    uint256 constant KEY_B = 0xB2;
    uint256 constant KEY_C = 0xC3;
    uint256 constant KEY_INTRUSO = 0xDEAD;

    bytes32 constant INTENT = keccak256("pi_multisig_001");
    uint256 constant AMOUNT = 1_000_000_000;
    uint64 expiresAt;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockUSDCAuth();

        // 2 de 3, como un Safe de operación.
        address[] memory owners = new address[](3);
        owners[0] = vm.addr(KEY_A);
        owners[1] = vm.addr(KEY_B);
        owners[2] = vm.addr(KEY_C);
        multisig = new MockMultisigWallet(owners, 2);

        hub = new SettlementHub(address(usdc), treasury, guardian, address(multisig));
        expiresAt = uint64(block.timestamp + 30 minutes);
    }

    // ── Helpers ───────────────────────────────────────────────

    function _digest(bytes32 intentId) internal view returns (bytes32) {
        bytes32 structHash =
            keccak256(abi.encode(hub.REGISTER_INTENT_TYPEHASH(), intentId, merchant, operator, AMOUNT, expiresAt));
        return keccak256(abi.encodePacked("\x19\x01", hub.DOMAIN_SEPARATOR(), structHash));
    }

    /// Concatena firmas ordenadas por dirección ascendente, como exige el mock.
    function _sign(uint256[] memory keys, bytes32 intentId) internal view returns (bytes memory blob) {
        bytes32 digest = _digest(intentId);
        // Ordenación por dirección (burbuja: son tres elementos como mucho).
        for (uint256 i = 0; i < keys.length; i++) {
            for (uint256 j = i + 1; j < keys.length; j++) {
                if (vm.addr(keys[j]) < vm.addr(keys[i])) {
                    (keys[i], keys[j]) = (keys[j], keys[i]);
                }
            }
        }
        for (uint256 i = 0; i < keys.length; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], digest);
            blob = bytes.concat(blob, abi.encodePacked(r, s, v));
        }
    }

    function _reg(bytes32 intentId, bytes memory signature)
        internal
        view
        returns (SettlementHub.IntentRegistration memory)
    {
        return SettlementHub.IntentRegistration({
            intentId: intentId,
            merchant: merchant,
            operator: operator,
            amount: AMOUNT,
            expiresAt: expiresAt,
            signature: signature
        });
    }

    function _keys2(uint256 a, uint256 b) internal pure returns (uint256[] memory k) {
        k = new uint256[](2);
        k[0] = a;
        k[1] = b;
    }

    // ── Tests ─────────────────────────────────────────────────

    function test_MultisigAlcanzandoElUmbralRegistra() public {
        hub.registerIntent(_reg(INTENT, _sign(_keys2(KEY_A, KEY_B), INTENT)));

        SettlementHub.Intent memory intent = hub.getIntent(INTENT);
        assertEq(intent.merchant, merchant, "el comercio queda registrado");
        assertEq(uint256(intent.amount), AMOUNT, "importe correcto");
    }

    /// Lo que aporta el multisig: una sola llave comprometida no basta.
    function test_RevertWhen_SoloUnaFirma() public {
        uint256[] memory una = new uint256[](1);
        una[0] = KEY_A;

        // Se firma ANTES: `_sign` hace llamadas de vista al hub y consumiría
        // el expectRevert.
        SettlementHub.IntentRegistration memory reg = _reg(INTENT, _sign(una, INTENT));
        vm.expectRevert(SettlementHub.InvalidIntentSignature.selector);
        hub.registerIntent(reg);
    }

    function test_RevertWhen_FirmanteNoEsDuenio() public {
        SettlementHub.IntentRegistration memory reg = _reg(INTENT, _sign(_keys2(KEY_A, KEY_INTRUSO), INTENT));
        vm.expectRevert(SettlementHub.InvalidIntentSignature.selector);
        hub.registerIntent(reg);
    }

    /// Alterar un campo firmado invalida la firma también por esta vía.
    function test_RevertWhen_SeAlteraElComercio() public {
        SettlementHub.IntentRegistration memory reg = _reg(INTENT, _sign(_keys2(KEY_A, KEY_B), INTENT));
        reg.merchant = makeAddr("atacante");

        vm.expectRevert(SettlementHub.InvalidIntentSignature.selector);
        hub.registerIntent(reg);
    }

    /// El motivo del cambio: rotar una llave comprometida SIN redesplegar.
    function test_RotarUnDuenioNoRequiereRedesplegar() public {
        // La llave C se compromete y se retira del multisig.
        multisig.setOwner(vm.addr(KEY_C), false);

        // Las dos llaves sanas siguen autorizando contra el MISMO hub.
        bytes32 otro = keccak256("pi_multisig_002");
        hub.registerIntent(_reg(otro, _sign(_keys2(KEY_A, KEY_B), otro)));
        assertEq(hub.getIntent(otro).merchant, merchant, "sigue operativo tras la rotacion");

        // Y la llave retirada ya no cuenta para el umbral.
        bytes32 tercero = keccak256("pi_multisig_003");
        SettlementHub.IntentRegistration memory conRetirada = _reg(tercero, _sign(_keys2(KEY_A, KEY_C), tercero));
        vm.expectRevert(SettlementHub.InvalidIntentSignature.selector);
        hub.registerIntent(conRetirada);

        // La dirección del firmante NO cambió en ningún momento.
        assertEq(hub.intentSigner(), address(multisig), "intentSigner sigue siendo inmutable");
    }

    /// Una cartera normal debe seguir funcionando: el cambio suma, no sustituye.
    function test_UnaCarteraNormalSigueSiendoValida() public {
        uint256 clave = 0xE0A;
        SettlementHub hubEoa = new SettlementHub(address(usdc), treasury, guardian, vm.addr(clave));

        bytes32 structHash =
            keccak256(abi.encode(hubEoa.REGISTER_INTENT_TYPEHASH(), INTENT, merchant, operator, AMOUNT, expiresAt));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", hubEoa.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(clave, digest);

        hubEoa.registerIntent(_reg(INTENT, abi.encodePacked(r, s, v)));
        assertEq(hubEoa.getIntent(INTENT).merchant, merchant, "la ruta EOA no se rompe");
    }
}
