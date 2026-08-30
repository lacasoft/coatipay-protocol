// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {Script, console} from "forge-std/Script.sol";
import {NodeRegistry} from "../src/NodeRegistry.sol";
import {SettlementHub} from "../src/SettlementHub.sol";
import {StakeManager} from "../src/StakeManager.sol";

/// @notice Deploys all three OpenRelay contracts in the correct order.
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
///                           (inmutable en SettlementHub tras el despliegue)
///   GUARDIAN_ADDRESS      — Cartera con autoridad de pausa y setMinStake.
///                           Rotable después vía Pausable.transferGuardian().
///                           Should be a wallet SEPARATE from the deployer.
contract Deploy is Script {
    function run() external {
        address usdc = vm.envAddress("USDC_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address guardian = vm.envAddress("GUARDIAN_ADDRESS");


        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Sanity checks: roles that should NEVER collapse into the deployer.
        // Treasury and guardian must be separate wallets so that a deployer-key
        // compromise does not hand over treasury funds + pause authority.
        address deployerAddr = vm.addr(deployerKey);
        require(treasury != deployerAddr, "Deploy: TREASURY_ADDRESS == deployer (separate them)");
        require(guardian != deployerAddr, "Deploy: GUARDIAN_ADDRESS == deployer (separate them)");
        require(guardian != treasury, "Deploy: GUARDIAN_ADDRESS == TREASURY_ADDRESS (separate them)");

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
        // Sin treasury: el stake solo entra y sale hacia su propio dueño, así
        // que el contrato ya no mueve fondos a terceros (ADR-004).
        StakeManager stakeManager = new StakeManager(usdc, guardian);

        console.log("StakeManager deployed at:", address(stakeManager));

        // ── Step 3: NodeRegistry ──────────────────────────────
        // Initial minStake: read from env var (defaults to 40 USDC for testnet).
        // Guardian can increase it later via setMinStake(). Recommended:
        //   testnet/early mainnet → 40 USDC (40_000_000)
        //   mature mainnet       → 100 USDC (100_000_000)
        uint256 initialMinStake = vm.envOr("MIN_STAKE_USDC_UNITS", uint256(40_000_000));

        NodeRegistry nodeRegistry = new NodeRegistry(address(stakeManager), guardian, initialMinStake);

        console.log("NodeRegistry deployed at:", address(nodeRegistry));

        // ── Step 4: SettlementHub (ADR-001 + ADR-002 + ADR-003) ─
        // Independent contract — no circular dependencies. Receives the
        // real guardian directly (no transfer dance needed) because it
        // doesn't have an init step that requires temporary deployer
        // authority.
        // Uses fee constants baked into bytecode (PROTOCOL_FEE_BPS = 100,
        // OPERATOR_SHARE_BPS = 70, TREASURY_SHARE_BPS = 30 per ADR-002).
        // Supports payIntent / payIntentWithPermit / payIntentWithAuthorization
        // (ADR-003 ERC-3009 path) + batch variant.
        SettlementHub settlementHub = new SettlementHub(usdc, treasury, guardian);

        console.log("SettlementHub deployed at:", address(settlementHub));

        vm.stopBroadcast();

        // ── Print .env block ──────────────────────────────────
        console.log("\n--- Copy to your .env ---");
        console.log("NODE_REGISTRY_ADDRESS=%s", address(nodeRegistry));
        console.log("STAKE_MANAGER_ADDRESS=%s", address(stakeManager));
        console.log("SETTLEMENT_HUB_ADDRESS=%s", address(settlementHub));
        console.log("-------------------------\n");

        // ── Verification ──────────────────────────────────────
        console.log("Verifying deployment...");
        require(address(stakeManager.usdc()) == usdc, "StakeManager: wrong usdc");
        require(address(nodeRegistry.stakeManager()) == address(stakeManager), "NodeRegistry: wrong stakeManager");
        require(stakeManager.guardian() == guardian, "StakeManager: wrong guardian");
        require(nodeRegistry.guardian() == guardian, "NodeRegistry: wrong guardian");
        require(nodeRegistry.minStake() == initialMinStake, "NodeRegistry: wrong initial minStake");
        // SettlementHub checks
        require(address(settlementHub.usdc()) == usdc, "SettlementHub: wrong usdc");
        require(settlementHub.treasury() == treasury, "SettlementHub: wrong treasury");
        require(settlementHub.guardian() == guardian, "SettlementHub: guardian not set");
        require(settlementHub.PROTOCOL_FEE_BPS() == 100, "SettlementHub: wrong fee bps (expected ADR-002 100)");
        require(settlementHub.TREASURY_SHARE_BPS() == 30, "SettlementHub: wrong treasury bps");
        require(settlementHub.OPERATOR_SHARE_BPS() == 70, "SettlementHub: wrong operator bps");
        require(settlementHub.MAX_BATCH_SIZE() == 50, "SettlementHub: wrong max batch size");
        console.log("All checks passed.");
    }


}
