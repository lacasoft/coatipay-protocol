// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {IERC1271} from "openzeppelin-contracts/contracts/interfaces/IERC1271.sol";
import {SignatureChecker} from "openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";

/// @title  IntentSignerGate
/// @notice El `intentSigner` del hub (ADR-009 §4). Separa dos cosas que con
///         una cartera normal iban juntas:
///
///          - `signer`, la clave caliente con la que la API firma cada
///            registro, sola y sin coordinar a nadie;
///          - `admin`, un multisig frío en mainnet, que es lo único que puede
///            cambiar esa clave.
///
///         La dirección de este contrato es la que queda inmutable en el hub,
///         así que una clave caliente robada o perdida se retira llamando a
///         `setSigner`, sin redesplegar el hub. Quien robe la clave caliente
///         no puede rotarla ni tocar el admin: no puede quedarse con el
///         contrato. `setSigner(address(0))` es el freno de emergencia: ningún
///         registro nuevo pasa hasta nombrar otra clave.
///
///         Lo que una clave caliente robada puede hacer mientras siga vigente
///         está acotado por el hub: el `intentId` lleva dentro al comercio
///         (ADR-009 §3), así que no puede atar a otro comercio un pago que el
///         pagador ya firmó.
contract IntentSignerGate is IERC1271 {
    bytes4 private constant _INVALID = 0xffffffff;

    /// @notice Quien puede cambiar `signer`. Multisig frío en mainnet.
    address public admin;

    /// @notice Admin propuesto que aún no ha aceptado. Cero si no hay
    ///         ninguna transferencia en curso.
    address public pendingAdmin;

    /// @notice La clave cuya firma vale como la de este contrato. Puede ser
    ///         una cartera normal o, a su vez, un contrato ERC-1271. Cero =
    ///         ninguna firma vale.
    address public signer;

    event SignerChanged(address indexed previous, address indexed next);
    event AdminTransferStarted(address indexed current, address indexed proposed);
    event AdminTransferred(address indexed previous, address indexed next);

    error NotAdmin();
    error NotPendingAdmin();
    error ZeroAdmin();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    /// @param _admin  Quien rota la clave. No puede ser cero: el contrato
    ///                quedaría sin forma de cambiar nada.
    /// @param _signer La clave caliente de la API. Puede ser cero, para
    ///                desplegar con el freno puesto y nombrarla después.
    // `_signer` cero es a propósito: desplegar con el freno puesto.
    // slither-disable-next-line missing-zero-check
    constructor(address _admin, address _signer) {
        if (_admin == address(0)) revert ZeroAdmin();
        admin = _admin;
        signer = _signer;
        emit AdminTransferred(address(0), _admin);
        emit SignerChanged(address(0), _signer);
    }

    /// @inheritdoc IERC1271
    /// @dev Firma sobre el `hash` tal cual, sin envoltorio propio: el hub ya
    ///      le pasa un digest EIP-712 con su dominio, que lo ata a ese hub y a
    ///      esa cadena.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        address current = signer;
        if (current != address(0) && SignatureChecker.isValidSignatureNow(current, hash, signature)) {
            return IERC1271.isValidSignature.selector;
        }
        return _INVALID;
    }

    /// @notice Cambia la clave caliente al instante. Solo el admin.
    // Cero es a propósito: el freno de emergencia.
    // slither-disable-next-line missing-zero-check
    function setSigner(address newSigner) external onlyAdmin {
        emit SignerChanged(signer, newSigner);
        signer = newSigner;
    }

    /// @notice Propone un admin nuevo; no cambia nada hasta que el propuesto
    ///         acepte. Proponer la dirección cero cancela la propuesta.
    // Cero es a propósito: cancela la propuesta.
    // slither-disable-next-line missing-zero-check
    function transferAdmin(address newAdmin) external onlyAdmin {
        pendingAdmin = newAdmin;
        emit AdminTransferStarted(admin, newAdmin);
    }

    /// @notice El admin propuesto acepta el cargo.
    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert NotPendingAdmin();
        emit AdminTransferred(admin, msg.sender);
        admin = msg.sender;
        pendingAdmin = address(0);
    }
}
