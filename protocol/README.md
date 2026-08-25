# @lacasoft/coatipay-protocol

Shared types, interfaces, and constants for the CoatiPay protocol.

## Development

```bash
pnpm build      # Compile TypeScript to dist/
pnpm dev        # Watch mode
pnpm typecheck  # Type-check without emitting
```

## Usage

This package is consumed by other workspace packages via `workspace:*` dependency:

```typescript
import { PaymentIntent, NodeInfo } from '@lacasoft/coatipay-protocol'
```
