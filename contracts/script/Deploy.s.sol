// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {Script, console} from "forge-std/Script.sol";
import {DisputeResolver} from "../src/DisputeResolver.sol";
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
///   TREASURY_ADDRESS      — Wallet that receives protocol treasury funds (immutable
///                           in DisputeResolver after deploy)
///   GUARDIAN_ADDRESS      — Wallet with pause/setMinStake authority on all three
///                           contracts. Rotatable post-deploy via Pausable.transferGuardian().
///                           Should be a wallet SEPARATE from the deployer.
///   ARBITER_1             — First arbiter address
///   ARBITER_2             — Second arbiter address
///   ARBITER_3             — Third arbiter address
///   ARBITER_4             — Fourth arbiter address (optional, set to address(0) to skip)
///   ARBITER_5             — Fifth arbiter address (optional, set to address(0) to skip)
contract Deploy is Script {
    function run() external {
        address usdc = vm.envAddress("USDC_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address guardian = vm.envAddress("GUARDIAN_ADDRESS");

        address[] memory arbiters = _loadArbiters();

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Sanity checks: roles that should NEVER collapse into the deployer.
        // Treasury and guardian must be separate wallets so that a deployer-key
        // compromise does not hand over treasury funds + pause authority.
        address deployerAddr = vm.addr(deployerKey);
        require(treasury != deployerAddr, "Deploy: TREASURY_ADDRESS == deployer (separate them)");
        require(guardian != deployerAddr, "Deploy: GUARDIAN_ADDRESS == deployer (separate them)");
        require(guardian != treasury, "Deploy: GUARDIAN_ADDRESS == TREASURY_ADDRESS (separate them)");

        vm.startBroadcast(deployerKey);

        // ── Circular dependency resolution ─────────────────────
        // Only StakeManager↔DisputeResolver have a circular dependency:
        //   - DisputeResolver.vote() calls StakeManager.slash()
        //   - StakeManager.slash() must check msg.sender == disputeResolver
        // We break the cycle with an initialization pattern:
        //   1. Deploy the three contracts with the deployer as *temporary*
        //      guardian so the deployer can call stakeManager.initialize()
        //      (which is gated by onlyGuardian).
        //   2. Call stakeManager.initialize(disputeResolver).
        //   3. Transfer guardianship on all three contracts to the real
        //      GUARDIAN_ADDRESS via Pausable.transferGuardian(). After this,
        //      the deployer has no authority over the protocol.
        // Final state: guardian = GUARDIAN_ADDRESS on all three. Deployer
        // only paid gas.
        //
        // NodeRegistry no longer needs to be wired into StakeManager —
        // it doesn't proxy USDC anymore (operators stake directly via
        // stakeManager.deposit). NodeRegistry just verifies stake via
        // stakeManager.getStakeInfo(operator).

        // ── Step 1: StakeManager ───────────────────────────────
        // Treasury is also passed here so slash() can transfer slashed funds
        // out of the contract. Same address as the one passed to DisputeResolver
        // — deploy script enforces consistency by deriving from a single env var.
        StakeManager stakeManager = new StakeManager(
            usdc,
            deployerAddr, // temporary guardian (transferred to real guardian below)
            treasury
        );

        console.log("StakeManager deployed at:", address(stakeManager));

        // ── Step 2: DisputeResolver ───────────────────────────
        DisputeResolver disputeResolver = new DisputeResolver(
            address(stakeManager),
            treasury,
            arbiters,
            deployerAddr // temporary guardian
        );

        console.log("DisputeResolver deployed at:", address(disputeResolver));

        // ── Step 3: NodeRegistry ──────────────────────────────
        // Initial minStake: read from env var (defaults to 40 USDC for testnet).
        // Guardian can increase it later via setMinStake(). Recommended:
        //   testnet/early mainnet → 40 USDC (40_000_000)
        //   mature mainnet       → 100 USDC (100_000_000)
        uint256 initialMinStake = vm.envOr("MIN_STAKE_USDC_UNITS", uint256(40_000_000));

        NodeRegistry nodeRegistry = new NodeRegistry(
            address(stakeManager),
            deployerAddr, // temporary guardian
            initialMinStake
        );

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

        // ── Step 5: Wire StakeManager to the resolver ─────────
        stakeManager.initialize(address(disputeResolver));

        console.log("StakeManager initialized with resolver");

        // ── Step 6: Transfer guardian to the real guardian ────
        // From this point on, only GUARDIAN_ADDRESS can pause or adjust minStake.
        // The deployer keeps no authority over the protocol.
        // Note: SettlementHub already has the real guardian (set in constructor),
        // so it's not in this list.
        stakeManager.transferGuardian(guardian);
        disputeResolver.transferGuardian(guardian);
        nodeRegistry.transferGuardian(guardian);

        console.log("Guardianship transferred to:", guardian);

        vm.stopBroadcast();

        // ── Print .env block ──────────────────────────────────
        console.log("\n--- Copy to your .env ---");
        console.log("NODE_REGISTRY_ADDRESS=%s", address(nodeRegistry));
        console.log("STAKE_MANAGER_ADDRESS=%s", address(stakeManager));
        console.log("DISPUTE_RESOLVER_ADDRESS=%s", address(disputeResolver));
        console.log("SETTLEMENT_HUB_ADDRESS=%s", address(settlementHub));
        console.log("-------------------------\n");

        // ── Verification ──────────────────────────────────────
        console.log("Verifying deployment...");
        require(address(stakeManager.usdc()) == usdc, "StakeManager: wrong usdc");
        require(stakeManager.treasury() == treasury, "StakeManager: wrong treasury");
        require(disputeResolver.treasury() == treasury, "DisputeResolver: wrong treasury");
        require(address(disputeResolver.stakeManager()) == address(stakeManager), "DisputeResolver: wrong stakeManager");
        require(address(nodeRegistry.stakeManager()) == address(stakeManager), "NodeRegistry: wrong stakeManager");
        require(nodeRegistry.minStake() == initialMinStake, "NodeRegistry: wrong initial minStake");
        require(stakeManager.guardian() == guardian, "StakeManager: guardian not transferred");
        require(disputeResolver.guardian() == guardian, "DisputeResolver: guardian not transferred");
        require(nodeRegistry.guardian() == guardian, "NodeRegistry: guardian not transferred");
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

    function _loadArbiters() internal view returns (address[] memory) {
        address a1 = vm.envAddress("ARBITER_1");
        address a2 = vm.envAddress("ARBITER_2");
        address a3 = vm.envAddress("ARBITER_3");

        // Optional arbiters — skip if set to zero address
        address a4 = vm.envOr("ARBITER_4", address(0));
        address a5 = vm.envOr("ARBITER_5", address(0));

        uint256 count = 3;
        if (a4 != address(0)) count++;
        if (a5 != address(0)) count++;

        address[] memory arbiters = new address[](count);
        arbiters[0] = a1;
        arbiters[1] = a2;
        arbiters[2] = a3;
        if (count >= 4) arbiters[3] = a4;
        if (count == 5) arbiters[4] = a5;

        return arbiters;
    }
}
