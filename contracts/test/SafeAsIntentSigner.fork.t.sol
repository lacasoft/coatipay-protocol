// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {SettlementHub} from "../src/SettlementHub.sol";
import {MockUSDCAuth} from "./mocks/MockUSDCAuth.sol";

interface ISafeProxyFactory {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address);
}

interface ISafe {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);
    function domainSeparator() external view returns (bytes32);
}

/// @notice ¿Sirve un Safe REAL como `intentSigner`, y basta con la firma que
///         la API ya sabe producir? El mock de los tests valida con `ecrecover`
///         sobre el hash crudo; Safe puede no hacer lo mismo. Esto lo resuelve
///         contra los contratos desplegados de verdad, no contra una maqueta.
contract SafeAsIntentSignerForkTest is Test {
    address constant FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address constant SINGLETON = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    address constant HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;
    bytes4 constant MAGIC = 0x1626ba7e;

    uint256 constant OWNER_KEY = 0xA11CE;

    SettlementHub hub;
    address safe;

    function setUp() public {
        // Estos tests hablan con la red. CI corre `forge test` sin filtro, y un
        // test que depende de un RPC publico es intermitente por definicion: un
        // gate que falla al azar acaba ignorandose. Se activan a proposito:
        //
        //   FORK_TESTS=1 forge test --match-path 'test/*.fork.t.sol'
        if (bytes(vm.envOr("FORK_TESTS", string(""))).length == 0) vm.skip(true);
        vm.createSelectFork("https://sepolia.base.org");

        address[] memory owners = new address[](1);
        owners[0] = vm.addr(OWNER_KEY);
        bytes memory init = abi.encodeWithSelector(
            ISafe.setup.selector, owners, uint256(1), address(0), "", HANDLER, address(0), 0, payable(address(0))
        );
        safe = ISafeProxyFactory(FACTORY).createProxyWithNonce(SINGLETON, init, 0);

        hub = new SettlementHub(address(new MockUSDCAuth()), makeAddr("t"), makeAddr("g"), safe);
    }

    function _digest(bytes32 intentId, address merchant, address operator, uint256 amount, uint64 exp)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash =
            keccak256(abi.encode(hub.REGISTER_INTENT_TYPEHASH(), intentId, merchant, operator, amount, exp));
        return keccak256(abi.encodePacked("\x19\x01", hub.DOMAIN_SEPARATOR(), structHash));
    }

    /// LA PREGUNTA: la firma que la API ya sabe hacer (ECDSA cruda sobre el
    /// digest), ¿la acepta un Safe real?
    function test_FirmaCrudaDeLaApi_LaAceptaUnSafeReal() public {
        bytes32 digest = _digest(keccak256("pi_1"), makeAddr("m"), makeAddr("o"), 1e9, uint64(block.timestamp + 1800));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, digest);

        // Safe revierte con GS026 (owner invalido): NO valida sobre el hash
        // crudo. La firma que la API sabe hacer hoy no le vale.
        vm.expectRevert(bytes("GS026"));
        ISafe(safe).isValidSignature(digest, abi.encodePacked(r, s, v));
    }

    /// Y esto es lo que SI funciona: firmar el hash que Safe envuelve con su
    /// propio dominio EIP-712 (`SafeMessage(bytes message)`).
    function test_FirmandoElMensajeEnvueltoPorSafe_SiFunciona() public {
        bytes32 digest = _digest(keccak256("pi_2"), makeAddr("m"), makeAddr("o"), 1e9, uint64(block.timestamp + 1800));

        bytes32 safeMsgTypehash = keccak256("SafeMessage(bytes message)");
        bytes32 encoded = keccak256(abi.encode(safeMsgTypehash, keccak256(abi.encode(digest))));
        bytes32 safeDigest = keccak256(abi.encodePacked("\x19\x01", ISafe(safe).domainSeparator(), encoded));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, safeDigest);
        bytes4 res = ISafe(safe).isValidSignature(digest, abi.encodePacked(r, s, v));

        // Vector de referencia para verificar la implementacion en TypeScript.
        console2.log("VECTOR safe          ", vm.toString(safe));
        console2.log("VECTOR chainId       ", vm.toString(block.chainid));
        console2.log("VECTOR hub           ", vm.toString(address(hub)));
        console2.log("VECTOR domainSep     ", vm.toString(ISafe(safe).domainSeparator()));
        console2.log("VECTOR digest        ", vm.toString(digest));
        console2.log("VECTOR safeDigest    ", vm.toString(safeDigest));
        console2.log("VECTOR signature     ", vm.toString(abi.encodePacked(r, s, v)));
        assertEq(res, MAGIC, "tampoco vale envolviendo: revisar");
    }
}
