// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {Test, console2} from "forge-std/Test.sol";

interface IGate {
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);
    function signer() external view returns (address);
}

interface IHub {
    function intentSigner() external view returns (address);
}

/// @notice ¿Puede un desconocido firmar por el `intentSigner` desplegado? La
///         clave de la cuenta de Hardhat es pública: si el gate acepta su
///         firma, cualquiera puede registrar intents. Va contra los contratos
///         de `deployments/sepolia.json`, no contra unos nuevos.
contract IntentSignerGateProdForkTest is Test {
    address constant HUB = 0x30CD3cc1bf5539bb627207AF19DF0BF0c11d02A0;
    address constant GATE = 0x1Baa57B09959642d09394B9AB2A22c24486AD2e2;
    bytes4 constant MAGIC = 0x1626ba7e;

    // Clave pública y conocida de la cuenta #2 de Hardhat. No es un secreto:
    // está en su documentación.
    uint256 constant CLAVE_PUBLICA_HARDHAT = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;

    function setUp() public {
        // Estos tests hablan con la red. CI corre `forge test` sin filtro, y un
        // test que depende de un RPC público es intermitente por definición: un
        // gate que falla al azar acaba ignorándose. Se activan a propósito:
        //
        //   FORK_TESTS=1 forge test --match-path 'test/*.fork.t.sol'
        if (bytes(vm.envOr("FORK_TESTS", string(""))).length == 0) vm.skip(true);
        vm.createSelectFork("https://sepolia.base.org");
    }

    function test_ElHubDesplegadoUsaElGate() public view {
        assertEq(IHub(HUB).intentSigner(), GATE);
    }

    function test_UnDesconocidoNoPuedeFirmarPorElGate() public view {
        bytes32 digest = keccak256("un registro de intent cualquiera");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(CLAVE_PUBLICA_HARDHAT, digest);
        bytes4 res = IGate(GATE).isValidSignature(digest, abi.encodePacked(r, s, v));
        console2.log("el gate respondio:", vm.toString(bytes32(res)));
        assertTrue(res != MAGIC, "REGRESION: el gate acepta una clave publica; cualquiera puede firmar");
        assertTrue(IGate(GATE).signer() != vm.addr(CLAVE_PUBLICA_HARDHAT));
    }
}
