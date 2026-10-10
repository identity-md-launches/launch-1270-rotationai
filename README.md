# RotationAI ($RAI)

`src/RAIToken.sol` is a self-contained ERC-20 token compiled with Solidity 0.8.26 for Cancun. It has no constructor arguments, external dependencies, owner, administration, upgrade mechanism, or external calls.

The constructor mints exactly **1,000,000,000 RAI with 18 decimals (1e27 units)** to its caller. Supply cannot increase or decrease. The launch factory subsequently transfers 10% to its Merkle distributor and seeds the pool with 90% in an untaxed transfer. The token itself performs neither allocation.

Transfers **from** `0x8366a39CC670B4001A1121B8F6A443A643e40951` to another address pay a fixed 3% tax to `0xD85D2A13bD490a21959F1EcABe8aC82221D253bc`. The buyer receives the remainder. Tax rounds down to the nearest token minor unit. The source loses exactly the gross amount; `transferFrom` spends gross allowance. Transfers to the PoolManager, including a self-transfer, and ordinary wallet transfers are untaxed. A transfer to the tax recipient credits its total gross amount across the tax and net legs.

`launch.json` specifies the requested native-ETH pool, 1.25% pool fee, tick spacing 60, 1 ETH initial market cap, and 90% pool allocation. These are launch factory settings; an ERC-20 cannot configure the pool fee. The initial price field is provenance, with the actual opening price derived by the factory from economics and deployed currency order.

The launch targets **Robinhood Chain (4663)**, selected by the order; the manifest intentionally has no chain field. All addresses and economic values come from the assignment. The token does not check the chain ID or call the PoolManager during construction.

| Deployment parameter | Fixed value |
| --- | --- |
| Contract / constructor arguments | `RAIToken` / `[]` |
| Supply in minor units | `1000000000000000000000000000` |
| PoolManager | `0x8366a39cc670b4001a1121b8f6a443a643e40951` |
| Creator tax recipient | `0xD85D2A13bD490a21959F1EcABe8aC82221D253bc` |
| Buy tax | 300 basis points (3%) |
| Paired currency | Native ETH: `0x0000000000000000000000000000000000000000` |
| Pool fee / tick spacing | `12500` (1.25%) / `60` |
| Initial price provenance | `2505414483750479311864138`, sqrtPriceX96 with RAI as currency0 |
| Pool allocation / opening market cap | `9000` basis points / `1000000000000000000` wei |
| Remainder recipient | `0x000000000000000000000000000000000000dead` |

The launch factory deploys the token with no arguments and receives the entire supply. It then sends 100,000,000 RAI to its Merkle distributor and seeds the pool from its balance with the 900,000,000 RAI allocation through the PoolManager settlement flow. A plain transfer to the PoolManager alone does not create a liquidity position. The factory initializes the pool, derives the opening price using the deployed currency order and opening market cap, and forwards any allocation or liquidity-rounding remainder to `remainderTo`. The 90% pool and 10% swarm allocations leave no planned unallocated share. There are no additional application contracts or token initialization calls.

The tax condition uses the transfer's source address, including for `transferFrom`; it does not identify swaps. Consequently every PoolManager outflow to another address, including a liquidity withdrawal, follows the same 3% rule. For a gross buy of 100 RAI the recipient gets 97 RAI and the creator gets 3 RAI. Routers and interfaces must account for that net receipt when forwarding tokens or checking minimum output. Approvals authorize gross amounts; the maximum uint256 approval persists until replaced or revoked. Zero-address transfers revert, and failed transfers restore allowances and balances.

Deployment and pool/distributor operation belong to the launch service. After launch there are no token settings, maintenance calls, or privileged recovery functions. Confirming the configured PoolManager on the target chain, running the protected pool integration checks, and verifying the deployed bytecode remain deployment responsibilities.

## Local checks

```sh
forge build
forge test
forge fmt --check
python3 scripts/check_artwork.py
```

Tests need no network or downloaded libraries. They cover complete factory/distributor transfers, seed and buy/sell balance accounting, tax events and rounding, direct and approved transfers, gross and infinite allowances, rollback on failure, self-transfers, zero amounts, recipient overlap, supply conservation, forbidden opcode scanning, and absent admin/mint/burn selectors. Two fuzz tests each use 1,000 runs; the sequence test checks conservation after each of 64 transfers.

These local token tests do not execute a real Uniswap v4 PoolManager or live Robinhood Chain fork. The supplied protected integration harness depends on verifier-owned factory helpers and launch environment values, which are not supplied as project dependencies. Its pool initialization, liquidity seed, and swap checks remain for the verifier; the local suite checks the gross-in/net-out token accounting they depend on. The harness deploys a local PoolManager and is not itself evidence of a live-chain fork run.

The five generated logo options are documented in `logos/README.md`. The selected wallet mark is `artifacts/logo.png`.
