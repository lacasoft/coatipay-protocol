// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {Script, console} from "forge-std/Script.sol";
import {IntentSignerGate} from "../src/IntentSignerGate.sol";
import {NodeRegistry} from "../src/NodeRegistry.sol";
import {SettlementHub} from "../src/SettlementHub.sol";
import {StakeManager} from "../src/StakeManager.sol";

/// @notice Deploys the four OpenRelay contracts in the correct order:
///         StakeManager, NodeRegistry, IntentSignerGate and SettlementHub.
///
/// Usage (Base Sepolia testnet):
///   forge script script/Deploy.s.sol \
///     --rpc-url $BASE_SEPOLIA_RPC_URL \
///     --broadcast \
///     --private-key $DEPLOYER_PRIVATE_KEY
///
/// Required env vars:
///   USDC_ADDRESS          — USDC token contract on the target chain
///   TREASURY_ADDRESS      — Cartera que recibe la comisión del protocolo
///                           (inmutable en SettlementHub y StakeManager)
///   GUARDIAN_ADDRESS      — Cartera con autoridad de pausa y de proponer
///                           `minStake`. Rotable después en dos pasos
///                           (transferGuardian + acceptGuardian).
///                           Should be a wallet SEPARATE from the deployer.
///   INTENT_SIGNER_ADMIN_ADDRESS — Admin de IntentSignerGate: el único que
///                           puede cambiar la clave que firma los registros.
///   INTENT_SIGNER_KEY_ADDRESS   — La clave caliente con la que firma la API.
///
/// En la red principal de Base (chainid 8453) la tesorería, el guardian y el
/// admin del gate tienen que ser contratos —un multisig—, y USDC tiene que ser
/// el de Circle (ADR-009 §9). En testnet valen carteras sueltas.
contract Deploy is Script {
    uint256 internal constant BASE_MAINNET = 8453;
    address internal constant BASE_MAINNET_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    /// @dev Lo más que se puede comprobar desde aquí de que `who` es un
    ///      multisig y no una sola clave:
    ///       - Tiene que tener código, y no ser una cartera con delegación
    ///         EIP-7702: desde Pectra/Isthmus una EOA puede tener "código"
    ///         (`0xef0100 ‖ dirección`) y seguir siendo una sola clave. Pasó al
    ///         ensayar este script contra Base mainnet: las carteras de prueba
    ///         de Anvil, cuyas claves son públicas, tienen delegación.
    ///       - Si responde como un Safe (`getThreshold()`), el umbral tiene que
    ///         ser 2 o más: un Safe 1-de-1 es una sola clave (revisión de
    ///         octubre, OCT-05).
    function _requireMultisig(address who, string memory message) internal view {
        bytes memory code = who.code;
        require(code.length > 0, message);
        bool delegated = code.length == 23 && code[0] == 0xef && code[1] == 0x01 && code[2] == 0x00;
        require(!delegated, message);
        (bool ok, bytes memory ret) = who.staticcall(abi.encodeWithSignature("getThreshold()"));
        if (ok && ret.length == 32) require(abi.decode(ret, (uint256)) >= 2, message);
    }

    struct Params {
        address usdc;
        address treasury;
        address guardian;
        address signerAdmin;
        address signerKey;
        uint256 deployerKey;
        uint256 initialMinStake;
    }

    function run() external {
        deploy(
            Params({
                usdc: vm.envAddress("USDC_ADDRESS"),
                treasury: vm.envAddress("TREASURY_ADDRESS"),
                guardian: vm.envAddress("GUARDIAN_ADDRESS"),
                // Firmante autorizado de registros de intent (ADR-004). Es la
                // clave que usa el API para atar cada intent a su comercio; el
                // nodeit envía la transacción pero no puede alterar su
                // contenido. Desde ADR-009 va detrás de un IntentSignerGate: la
                // clave se rota sin redesplegar.
                signerAdmin: vm.envAddress("INTENT_SIGNER_ADMIN_ADDRESS"),
                signerKey: vm.envAddress("INTENT_SIGNER_KEY_ADDRESS"),
                deployerKey: vm.envUint("DEPLOYER_PRIVATE_KEY"),
                // Initial minStake: defaults to 40 USDC for testnet. Guardian can
                // change it later with a 7-day notice (proposeMinStake →
                // applyMinStake, ADR-009 §5). Recommended:
                //   testnet/early mainnet → 40 USDC (40_000_000)
                //   mature mainnet       → 100 USDC (100_000_000)
                initialMinStake: vm.envOr("MIN_STAKE_USDC_UNITS", uint256(40_000_000))
            })
        );
    }

    /// @notice Lo que hace `run()`, con los parámetros explícitos en vez de
    ///         leídos del entorno: así las pruebas ejercitan las guardas sin
    ///         tocar variables de entorno, que comparten todas las pruebas.
    function deploy(Params memory p) public {
        address usdc = p.usdc;
        address treasury = p.treasury;
        address guardian = p.guardian;
        address signerAdmin = p.signerAdmin;
        address signerKey = p.signerKey;
        uint256 deployerKey = p.deployerKey;

        // Sanity checks: roles that should NEVER collapse into the deployer.
        // Treasury and guardian must be separate wallets so that a deployer-key
        // compromise does not hand over treasury funds + pause authority.
        address deployerAddr = vm.addr(deployerKey);
        require(treasury != deployerAddr, "Deploy: TREASURY_ADDRESS == deployer (separate them)");
        require(guardian != deployerAddr, "Deploy: GUARDIAN_ADDRESS == deployer (separate them)");
        require(guardian != treasury, "Deploy: GUARDIAN_ADDRESS == TREASURY_ADDRESS (separate them)");
        // La clave de intents va aparte de todo lo demás: su compromiso
        // permite registrar intents falsos, y compartir cartera multiplicaría
        // la superficie sin ninguna ventaja. Y nunca puede ser su propio
        // admin: entonces quien la robara podría rotarla.
        require(signerKey != address(0), "Deploy: INTENT_SIGNER_KEY_ADDRESS is zero");
        require(signerKey != deployerAddr, "Deploy: INTENT_SIGNER_KEY_ADDRESS == deployer (separate them)");
        require(signerKey != guardian, "Deploy: INTENT_SIGNER_KEY_ADDRESS == GUARDIAN_ADDRESS (separate them)");
        require(signerKey != treasury, "Deploy: INTENT_SIGNER_KEY_ADDRESS == TREASURY_ADDRESS (separate them)");
        require(signerKey != signerAdmin, "Deploy: INTENT_SIGNER_KEY_ADDRESS == INTENT_SIGNER_ADMIN_ADDRESS");
        require(signerAdmin != deployerAddr, "Deploy: INTENT_SIGNER_ADMIN_ADDRESS == deployer (separate them)");

        // Mainnet: ninguna palanca crítica en una cartera suelta (ADR-009 §9).
        if (block.chainid == BASE_MAINNET) {
            require(usdc == BASE_MAINNET_USDC, "Deploy: USDC_ADDRESS is not Circle's USDC on Base");
            _requireMultisig(treasury, "Deploy: on mainnet TREASURY_ADDRESS must be a multisig");
            _requireMultisig(guardian, "Deploy: on mainnet GUARDIAN_ADDRESS must be a multisig");
            _requireMultisig(signerAdmin, "Deploy: on mainnet INTENT_SIGNER_ADMIN_ADDRESS must be a multisig");
        }

        vm.startBroadcast(deployerKey);

        // Sin dependencias circulares: los cuatro contratos son
        // independientes y reciben al guardian real en su constructor. El
        // deployer no llega a tener autoridad sobre el protocolo en ningún
        // momento — antes hacía falta una fase intermedia porque
        // StakeManager.initialize() estaba restringido al guardian.
        //
        // NodeRegistry no se cablea dentro de StakeManager: los nodeits
        // depositan directamente con stakeManager.deposit y el registro
        // consulta el stake vía stakeManager.getStakeInfo(operator).

        // ── Paso 1: StakeManager ───────────────────────────────
        // El stake solo entra y sale hacia su propio dueño (ADR-004). La
        // tesorería solo recibe lo que sobra: USDC que llegó sin `deposit`
        // u otros tokens enviados por error (ADR-009 §8).
        StakeManager stakeManager = new StakeManager(usdc, guardian, treasury);

        console.log("StakeManager deployed at:", address(stakeManager));

        // ── Paso 2: NodeRegistry ──────────────────────────────
        NodeRegistry nodeRegistry = new NodeRegistry(address(stakeManager), guardian, p.initialMinStake);

        console.log("NodeRegistry deployed at:", address(nodeRegistry));

        // ── Paso 3: IntentSignerGate (ADR-009 §4) ─────────────
        IntentSignerGate gate = new IntentSignerGate(signerAdmin, signerKey);

        console.log("IntentSignerGate deployed at:", address(gate));

        // ── Paso 4: SettlementHub (ADR-001 + ADR-002 + ADR-003 + ADR-009) ─
        // Independent contract — no circular dependencies. Receives the
        // real guardian directly (no transfer dance needed) because it
        // doesn't have an init step that requires temporary deployer
        // authority. Fee constants are baked into bytecode (ADR-005).
        // Supports payIntent / payIntentWithPermit / payIntentWithAuthorization
        // (ADR-003 ERC-3009 path) + batch variant.
        SettlementHub settlementHub = new SettlementHub(usdc, treasury, guardian, address(gate));

        console.log("SettlementHub deployed at:", address(settlementHub));

        vm.stopBroadcast();

        // ── Print .env block ──────────────────────────────────
        console.log("\n--- Copy to your .env ---");
        console.log("NODE_REGISTRY_ADDRESS=%s", address(nodeRegistry));
        console.log("STAKE_MANAGER_ADDRESS=%s", address(stakeManager));
        console.log("SETTLEMENT_HUB_ADDRESS=%s", address(settlementHub));
        console.log("INTENT_SIGNER_GATE_ADDRESS=%s", address(gate));
        console.log("-------------------------\n");

        // ── Verification ──────────────────────────────────────
        console.log("Verifying deployment...");
        require(address(stakeManager.usdc()) == usdc, "StakeManager: wrong usdc");
        require(address(nodeRegistry.stakeManager()) == address(stakeManager), "NodeRegistry: wrong stakeManager");
        require(stakeManager.guardian() == guardian, "StakeManager: wrong guardian");
        require(stakeManager.treasury() == treasury, "StakeManager: wrong treasury");
        require(nodeRegistry.guardian() == guardian, "NodeRegistry: wrong guardian");
        require(nodeRegistry.minStake() == p.initialMinStake, "NodeRegistry: wrong initial minStake");
        // SettlementHub checks
        require(address(settlementHub.usdc()) == usdc, "SettlementHub: wrong usdc");
        require(settlementHub.treasury() == treasury, "SettlementHub: wrong treasury");
        require(settlementHub.intentSigner() == address(gate), "SettlementHub: intentSigner is not the gate");
        require(gate.admin() == signerAdmin, "IntentSignerGate: wrong admin");
        require(gate.signer() == signerKey, "IntentSignerGate: wrong signer");
        require(settlementHub.guardian() == guardian, "SettlementHub: guardian not set");
        // Estos numeros se repiten a proposito: son la comprobacion de que el
        // artefacto desplegado es el que creemos. Repetir el valor del contrato
        // aqui no seria comprobacion ninguna.
        //
        // Por eso mismo hay que moverlos CON el contrato. El gate
        // `check:fee-constants` compara estas tres lineas contra
        // SettlementHub.sol y falla si divergen. ADR-005: 150 / 45 / 105.
        require(settlementHub.PROTOCOL_FEE_BPS() == 150, "SettlementHub: wrong fee bps (expected ADR-005 150)");
        require(settlementHub.TREASURY_SHARE_BPS() == 45, "SettlementHub: wrong treasury bps");
        require(settlementHub.OPERATOR_SHARE_BPS() == 105, "SettlementHub: wrong operator bps");
        // Relacion derivada: se mantiene sola aunque cambien los valores.
        require(
            settlementHub.OPERATOR_SHARE_BPS() + settlementHub.TREASURY_SHARE_BPS() == settlementHub.PROTOCOL_FEE_BPS(),
            "SettlementHub: shares do not sum to the protocol fee"
        );
        require(settlementHub.MAX_BATCH_SIZE() == 50, "SettlementHub: wrong max batch size");
        console.log("All checks passed.");
    }
}
