# @lacasoft/coatipay-contracts

CoatiPay smart contracts -- NodeRegistry, StakeManager and SettlementHub
(four deployed contracts, plus a shared `Pausable` base). All four are deployed on Base Sepolia.

Built with [Foundry](https://book.getfoundry.sh/).

## Development

```bash
forge build                   # Compile contracts
forge test -vvv               # Run tests with verbose output
forge fmt --check             # Check Solidity formatting
forge fmt                     # Auto-format Solidity files
forge clean                   # Remove build artifacts
```

## Deployment

```bash
# Deploy to Base Sepolia testnet
forge script script/Deploy.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast
```
