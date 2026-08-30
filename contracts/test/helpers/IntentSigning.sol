// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {SettlementHub} from "../../src/SettlementHub.sol";

/// @title  Firma de registros de intent para los tests
/// @notice Desde ADR-004, `registerIntent` exige la firma EIP-712 de
///         `intentSigner`. Quien envía la transacción es el nodeit —la parte
///         no confiable— y sin la firma podía sustituir la dirección del
///         comercio por la suya.
///
///         Los tests heredan este contrato y registran con `_reg(...)`, que
///         firma con la clave conocida del banco de pruebas. Así ningún test
///         puede registrar sin firma por descuido, y los que prueban el
///         camino inválido lo hacen explícitamente con `_signIntentWith`.
abstract contract IntentSigning is Test {
    /// Clave del firmante autorizado en los tests.
    uint256 internal constant INTENT_SIGNER_KEY = 0xA11CE;

    function _intentSigner() internal pure returns (address) {
        return vm.addr(INTENT_SIGNER_KEY);
    }

    /// Firma un registro con una clave arbitraria — para probar rechazos.
    function _signIntentWith(
        uint256 key,
        SettlementHub h,
        bytes32 intentId,
        address merchant,
        address operator,
        uint256 amount,
        uint64 expiresAt
    ) internal view returns (bytes memory) {
        bytes32 structHash =
            keccak256(abi.encode(h.REGISTER_INTENT_TYPEHASH(), intentId, merchant, operator, amount, expiresAt));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", h.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signIntent(
        SettlementHub h,
        bytes32 intentId,
        address merchant,
        address operator,
        uint256 amount,
        uint64 expiresAt
    ) internal view returns (bytes memory) {
        return _signIntentWith(INTENT_SIGNER_KEY, h, intentId, merchant, operator, amount, expiresAt);
    }

    /// Construye el registro firmado listo para enviar.
    function _regOf(
        SettlementHub h,
        bytes32 intentId,
        address merchant,
        address operator,
        uint256 amount,
        uint64 expiresAt
    ) internal view returns (SettlementHub.IntentRegistration memory) {
        return SettlementHub.IntentRegistration({
            intentId: intentId,
            merchant: merchant,
            operator: operator,
            amount: amount,
            expiresAt: expiresAt,
            signature: _signIntent(h, intentId, merchant, operator, amount, expiresAt)
        });
    }

    /// Convierte arreglos paralelos de un test en registros firmados.
    function _regsOf(
        SettlementHub h,
        bytes32[] memory intentIds,
        address[] memory merchants,
        address[] memory operators,
        uint256[] memory amounts,
        uint64[] memory expirations
    ) internal view returns (SettlementHub.IntentRegistration[] memory regs) {
        regs = new SettlementHub.IntentRegistration[](intentIds.length);
        for (uint256 i = 0; i < intentIds.length; i++) {
            regs[i] = _regOf(h, intentIds[i], merchants[i], operators[i], amounts[i], expirations[i]);
        }
    }

    /// Registra un intent con firma válida.
    function _reg(
        SettlementHub h,
        bytes32 intentId,
        address merchant,
        address operator,
        uint256 amount,
        uint64 expiresAt
    ) internal {
        h.registerIntent(_regOf(h, intentId, merchant, operator, amount, expiresAt));
    }
}
