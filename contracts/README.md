# @lacasoft/coatipay-contracts

CoatiPay smart contracts -- NodeRegistry, StakeManager, SettlementHub and
IntentSignerGate (four contracts, plus a shared `Pausable` base). The addresses
deployed on each network are in `deployments/`. Design decisions: `../audits/adr/`
(ADR-009 for the current version).

Built with [Foundry](https://book.getfoundry.sh/).

## Development

```bash
forge build                   # Compile contracts
forge test -vvv               # Run tests with verbose output
forge fmt --check             # Check Solidity formatting
forge fmt                     # Auto-format Solidity files
forge clean                   # Remove build artifacts

# Tests against a fork of Base Sepolia (real USDC, real Safe). Not run by CI:
# a test that depends on a public RPC is flaky by definition.
FORK_TESTS=1 forge test --match-path 'test/*.fork.t.sol'
```

One test reads `../protocol/vectors/nonce.json` and requires
`SettlementHub.intentIdOf` to give every nonce the SDKs use.

## Deployment

```bash
# Deploy to Base Sepolia testnet
USDC_ADDRESS=... TREASURY_ADDRESS=... GUARDIAN_ADDRESS=... \
INTENT_SIGNER_ADMIN_ADDRESS=... INTENT_SIGNER_KEY_ADDRESS=... \
DEPLOYER_PRIVATE_KEY=... \
forge script script/Deploy.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --broadcast
```

`INTENT_SIGNER_KEY_ADDRESS` is the API's hot key; `INTENT_SIGNER_ADMIN_ADDRESS`
is the only one that can change it. On Base mainnet (chain id 8453) the script
refuses a treasury, guardian or gate admin that is not a contract (a multisig),
and any USDC other than Circle's.
