# Larva Content Rankings

Onchain content ranking and governance sandbox for the larv.ai ecosystem. Creators submit digital content (film, music, art, writing) by IPFS CID. Larvas vote by burning CLAWD tokens — every vote is sybil-resistant, stake-weighted, and permanently onchain.

## Live App

**https://bafybeigs3a6quhfy6ulhrn7sb6z33qr46aczco2xqwiwopbvgjgmnbhepu.ipfs.community.bgipfs.com/**

## Smart Contract

**ContentRanking** — Base Mainnet  
Address: [`0x55F605f04DA41Cbf821c6d5D028EA0cAB5B1cB39`](https://basescan.org/address/0x55f605f04da41cbf821c6d5d028ea0cab5b1cb39#code)

## What It Does

- **Submit Content** — Creators submit IPFS CIDs for film, music, art, or writing. A small anti-spam ETH fee (0.00001 ETH) is required.
- **Vote** — Larvas vote by specifying how much CLAWD to burn. The burn amount is the vote weight. Each address can vote once per content during the 7-day voting window.
- **Rankings** — Onchain deterministic ranking sorted by weighted vote score, with blockhash entropy for tiebreaking. Top 200 items returned.
- **Dispute** — After voting closes, anyone can stake 0.001 ETH to dispute a content. The owner resolves disputes (upheld → content removed; not upheld → 50% stake refunded). If the owner is inactive, anyone can call `resolveExpiredDispute()` after 24 hours.
- **Slash** — The owner can slash a fraudulent vote, reversing its score contribution.

## Architecture

| Component | Details |
|-----------|---------|
| Chain | Base (8453) |
| Framework | Scaffold-ETH 2 + Foundry |
| IPFS | bgipfs |
| CLAWD Token | Set by owner after deployment via `setClawdToken` |
| Owner | `0x1d266aae9E1f8cb9228821C40fB5DbC7C771cbce` (client) |

## Client Setup Required

After taking ownership, call `setClawdToken(address)` with the live CLAWD token address on Base. Until this is set, voting is disabled — content submission and disputes work immediately.

## Running Locally

```bash
git clone https://github.com/clawdbotatg/leftclaw-service-job-260
cd leftclaw-service-job-260
yarn install

# Start local fork
yarn fork --network base

# In new terminal, deploy contracts
yarn deploy

# In new terminal, start frontend
yarn start
```

Visit `http://localhost:3000`

## Security

- `Ownable2Step` — ownership transfer requires acceptance
- `ReentrancyGuard` on all state-changing external functions
- `SafeERC20` for all CLAWD token transfers
- CEI pattern throughout
- Burn via transfer-to-dead (compatible with any ERC20)
- int256 cast guard prevents vote inversion on large burn amounts
- Permissionless expired-dispute resolution prevents ETH stake lockup

## GitHub

https://github.com/clawdbotatg/leftclaw-service-job-260
