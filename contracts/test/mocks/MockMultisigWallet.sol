// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

/// @title  MockMultisigWallet
/// @notice Multisig ERC-1271 mínimo (umbral de M firmas sobre N dueños) para
///         los tests. Modela un Safe: la firma que valida no es una, sino la
///         concatenación de varias, y el contrato decide si bastan.
///
///         Existe para probar que `intentSigner` puede ser un multisig. Eso
///         importa porque la dirección es inmutable: con una sola clave,
///         perderla obliga a redesplegar el hub. Apuntando a un multisig, la
///         dirección no cambia pero **sus dueños sí se rotan por dentro**.
contract MockMultisigWallet {
    bytes4 internal constant MAGIC = 0x1626ba7e;
    bytes4 internal constant INVALID = 0xffffffff;

    mapping(address => bool) public isOwner;
    uint256 public threshold;

    constructor(address[] memory owners, uint256 _threshold) {
        for (uint256 i = 0; i < owners.length; i++) {
            isOwner[owners[i]] = true;
        }
        threshold = _threshold;
    }

    /// Rotación de dueños: lo que un firmante inmutable no permitiría.
    function setOwner(address who, bool allowed) external {
        isOwner[who] = allowed;
    }

    /// @param signature Concatenación de firmas de 65 bytes, en orden
    ///        ascendente de dirección para que no se puedan repetir.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        if (signature.length % 65 != 0) return INVALID;
        uint256 count = signature.length / 65;
        if (count < threshold) return INVALID;

        address anterior = address(0);
        uint256 validas = 0;

        for (uint256 i = 0; i < count; i++) {
            bytes32 r;
            bytes32 s;
            uint8 v;
            uint256 off = i * 65;
            assembly {
                r := calldataload(add(signature.offset, off))
                s := calldataload(add(signature.offset, add(off, 0x20)))
                v := byte(0, calldataload(add(signature.offset, add(off, 0x40))))
            }
            address firmante = ecrecover(hash, v, r, s);
            // El orden estrictamente ascendente impide contar dos veces la
            // misma firma para alcanzar el umbral.
            if (firmante == address(0) || firmante <= anterior || !isOwner[firmante]) return INVALID;
            anterior = firmante;
            validas++;
        }

        return validas >= threshold ? MAGIC : INVALID;
    }
}
