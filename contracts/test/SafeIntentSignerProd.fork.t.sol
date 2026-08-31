// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {Test, console2} from "forge-std/Test.sol";

interface ISafe {
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);
    function domainSeparator() external view returns (bytes32);
}

/// @notice ¿Puede un desconocido firmar por este Safe? La clave de la cuenta
///         de Hardhat es publica: si el Safe acepta su firma, cualquiera puede
///         registrar intents y quedarse los pagos.
contract SafeIntentSignerProdForkTest is Test {
    address constant SAFE = 0xDCF862685E121ba506D51fc8119dc54a0824AD1B;
    bytes4 constant MAGIC = 0x1626ba7e;

    // Clave publica y conocida de la cuenta #2 de Hardhat. No es un secreto:
    // esta en su documentacion.
    uint256 constant CLAVE_PUBLICA_HARDHAT = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;

    function setUp() public {
        // Estos tests hablan con la red. CI corre `forge test` sin filtro, y un
        // test que depende de un RPC publico es intermitente por definicion: un
        // gate que falla al azar acaba ignorandose. Se activan a proposito:
        //
        //   FORK_TESTS=1 forge test --match-path 'test/*.fork.t.sol'
        if (bytes(vm.envOr("FORK_TESTS", string(""))).length == 0) vm.skip(true);
        vm.createSelectFork("https://sepolia.base.org");
    }

    function test_UnDesconocidoPuedeFirmarPorEsteSafe() public {
        bytes32 digest = keccak256("un registro de intent cualquiera");

        bytes32 encoded = keccak256(abi.encode(keccak256("SafeMessage(bytes message)"), keccak256(abi.encode(digest))));
        bytes32 safeDigest = keccak256(abi.encodePacked("\x19\x01", ISafe(SAFE).domainSeparator(), encoded));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(CLAVE_PUBLICA_HARDHAT, safeDigest);

        // Rechazar puede significar dos cosas: revertir (GS026, firmante que no
        // es duenio) o devolver algo distinto de la constante magica. Las dos
        // valen; lo que NO puede pasar es que devuelva MAGIC.
        try ISafe(SAFE).isValidSignature(digest, abi.encodePacked(r, s, v)) returns (bytes4 res) {
            console2.log("el Safe respondio:", vm.toString(bytes32(res)));
            assertTrue(res != MAGIC, "REGRESION: el Safe acepta una clave publica; cualquiera puede firmar");
        } catch {
            console2.log("el Safe REVIRTIO ante la clave publica: correcto");
        }
    }
}
