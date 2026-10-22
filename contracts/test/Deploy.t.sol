// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";

/// Responde como un Safe con el umbral que se le diga.
contract FakeSafe {
    uint256 public getThreshold;

    constructor(uint256 threshold) {
        getThreshold = threshold;
    }
}

/// Un contrato cualquiera que no es un Safe (otro tipo de multisig).
contract OtherMultisig {
    function isOwner(address) external pure returns (bool) {
        return true;
    }
}

/// @title  Las guardas de mainnet de Deploy.s.sol (ADR-009 §9)
/// @notice En la red principal de Base, ni la tesorería, ni el guardian, ni el
///         admin del gate pueden ser una sola clave. `forge test` no ejecuta
///         los scripts, así que sin esta prueba la guarda solo se ejercitaría
///         el día del despliegue.
contract DeployGuardsTest is Test {
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    uint256 constant DEPLOYER_KEY = 0xD3B;

    address treasury;
    address guardian;
    address admin;
    address hotKey = makeAddr("hotKey");

    function setUp() public {
        vm.chainId(8453);
        treasury = address(new FakeSafe(2));
        guardian = address(new FakeSafe(3));
        admin = address(new OtherMultisig());
    }

    function _run(address usdc, address t, address g, address a) internal {
        new Deploy()
            .deploy(
                Deploy.Params({
                    usdc: usdc,
                    treasury: t,
                    guardian: g,
                    signerAdmin: a,
                    signerKey: hotKey,
                    deployerKey: DEPLOYER_KEY,
                    initialMinStake: 40_000_000
                })
            );
    }

    function test_ConMultisigsDespliega() public {
        _run(BASE_USDC, treasury, guardian, admin);
    }

    function test_Revert_CarteraSuelta() public {
        vm.expectRevert(bytes("Deploy: on mainnet TREASURY_ADDRESS must be a multisig"));
        this.run(BASE_USDC, makeAddr("eoa"), guardian, admin);
    }

    /// Lo que se escapó al ensayar contra Base mainnet: una EOA con delegación
    /// EIP-7702 tiene código y sigue siendo una sola clave.
    function test_Revert_CarteraConDelegacion7702() public {
        address delegada = makeAddr("delegada");
        vm.etch(delegada, abi.encodePacked(hex"ef0100", makeAddr("implementacion")));
        vm.expectRevert(bytes("Deploy: on mainnet GUARDIAN_ADDRESS must be a multisig"));
        this.run(BASE_USDC, treasury, delegada, admin);
    }

    /// Un Safe 1-de-1 es una sola clave (OCT-05).
    function test_Revert_SafeDeUnaFirma() public {
        address unoDeUno = address(new FakeSafe(1));
        vm.expectRevert(bytes("Deploy: on mainnet INTENT_SIGNER_ADMIN_ADDRESS must be a multisig"));
        this.run(BASE_USDC, treasury, guardian, unoDeUno);
    }

    function test_Revert_OtroUsdc() public {
        vm.expectRevert(bytes("Deploy: USDC_ADDRESS is not Circle's USDC on Base"));
        this.run(makeAddr("otroUsdc"), treasury, guardian, admin);
    }

    /// En testnet valen carteras sueltas, como hasta ahora.
    function test_EnTestnetValenCarterasSueltas() public {
        vm.chainId(84532);
        _run(makeAddr("usdcSepolia"), makeAddr("t"), makeAddr("g"), makeAddr("a"));
    }

    /// Envoltorio externo: `expectRevert` necesita una llamada externa.
    function run(address usdc, address t, address g, address a) external {
        _run(usdc, t, g, a);
    }
}
