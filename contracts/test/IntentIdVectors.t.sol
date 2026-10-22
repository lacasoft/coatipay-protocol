// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {SettlementHub} from "../src/SettlementHub.sol";

/// @title  El intentId de la cadena es el de los SDK (ADR-009 §3)
/// @notice La API, el checkout y los tres SDK calculan el nonce que firma el
///         pagador con el paquete de TypeScript o con su propia copia, contra
///         `protocol/vectors/nonce.json`. Esta prueba lee ese mismo fichero y
///         exige que `SettlementHub.intentIdOf` dé cada nonce: si la cadena y
///         lo de fuera divergieran, el pagador firmaría un nonce que el hub
///         no acepta, y el pago nunca saldría.
contract IntentIdVectorsTest is Test {
    function test_IntentIdOf_EsElDeLosVectoresDeLosSdk() public {
        SettlementHub hub = new SettlementHub(address(1), address(2), address(3), address(4));
        string memory json = vm.readFile("../protocol/vectors/nonce.json");
        assertEq(vm.parseJsonUint(json, ".formato"), 2, "formato de vectores inesperado");

        // Campo a campo y con su tipo: `vm.parseJson` sin tipo lee el texto
        // "0xdeadbeef" como bytes hexadecimales, que es justo el error que el
        // vector existe para atrapar.
        uint256 i;
        for (; vm.keyExistsJson(json, string.concat(".casos[", vm.toString(i), "]")); i++) {
            string memory caso = string.concat(".casos[", vm.toString(i), "]");
            string memory id = vm.parseJsonString(json, string.concat(caso, ".intent_id"));
            address merchant = vm.parseJsonAddress(json, string.concat(caso, ".merchant"));
            bytes32 ref = vm.parseJsonBytes32(json, string.concat(caso, ".ref"));
            bytes32 nonce = vm.parseJsonBytes32(json, string.concat(caso, ".nonce"));

            assertEq(ref, keccak256(bytes(id)), string.concat("ref de ", id));
            assertEq(hub.intentIdOf(merchant, ref), nonce, string.concat("intentId de ", id));
        }
        assertGt(i, 0, "sin casos");
    }
}
