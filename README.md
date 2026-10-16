# RisingFloorVault

Contracts for the brief *"tạo cho tôi 1 token lôi cuốn người dùng không bao giờ rớt giá"* ("create a
token that attracts users and never drops in price"), launched on Ethereum mainnet (chain id 1) as a
contracts-only launch. The project token itself is launched later on Keel, so this repository ships
the application contract that gives that token its "never drops" property and leaves a one-time
`setToken` slot for its address.

## What "never drops in price" means here

No contract can control the price people agree on elsewhere. What a contract *can* guarantee is a
**redemption floor**: a price at which the vault will always buy the token back, fully backed by ETH
it holds, that is mathematically unable to go down. Arbitrage then keeps any market price at or above
the floor (minus the redemption fee), because anyone can buy below the floor and redeem at it.

`RisingFloorVault` holds an ETH **reserve** and an **inventory** of the project token.

| Term | Definition |
| --- | --- |
| `backedSupply` | token base units the vault has sold and not yet bought back |
| `floorPrice` | `reserve * 1e18 / backedSupply` (wei per 1e18 token base units) |
| `askPrice` | `floorPrice * (1 + buyPremiumBps / 10000)`: what buyers pay |
| `bidPrice` | `floorPrice * (1 - sellFeeBps / 10000)`: what sellers receive |

Every operation keeps `floorAfter >= floorBefore`:

- **buy** adds ETH at or above the floor, so backing per token rises;
- **sell** removes ETH at or below the floor, so backing per token rises (a non-zero fee stays in the
  reserve for the remaining holders);
- **donation** (plain ETH transfer) adds ETH and removes nothing;
- **inventory deposit / withdrawal** moves unsold tokens only; it never touches the reserve or the
  backed supply, so it cannot move the floor.

Nobody can withdraw ETH from the reserve. There is no owner withdrawal, no rescue path for ETH and no
upgrade mechanism. ETH only leaves through `sell`, at the floor. Redemptions can never be paused.
When every backed token has been redeemed, the vault remembers the floor it reached and may reopen
only at or above it (`minOpeningPrice`).

Prices are quoted in wei per `1e18` token base units regardless of the token's decimals. For an
18-decimal token this is simply wei per whole token. The vault reads nothing from the token except
balances and transfers, so it works with any standard ERC-20; it rejects fee-on-transfer and
rebasing behaviour by checking the exact amount received.

## Contract

`src/RisingFloorVault.sol`: `contract RisingFloorVault is Ownable2Step, ReentrancyGuard`.
ABI: `docs/abi/RisingFloorVault.json`.

### Constructor

| Argument | Type | Launch value |
| --- | --- | --- |
| `owner_` | `address` | `$owner` = `0xd3f26a6be348440110161dfd5748e7de7b08cf69` (the creator's wallet named by the brief) |

The constructor only records the owner. It makes no external calls and does not require any address
to have code, so it deploys on an empty chain. The deployer (the launch factory) keeps no rights.

### The one-time token slot

- `setToken(address token)`: owner only, once. Reverts with `ZeroAddress` for the zero address and
  `TokenAlreadySet` if a token is already set. Emits `TokenSet(token)`.
- `token()`: the token address, the zero address until set.
- Every token feature (`buy`, `sell`, `depositInventory`, `withdrawInventory`) reverts with
  `TokenNotSet` until the slot is filled; `inventory()` returns 0. The website reads `token()` and
  hides token features while it is zero.

### Owner functions (trust assumptions)

| Function | Effect | Limits |
| --- | --- | --- |
| `setToken(address)` | fills the token slot | once, non-zero |
| `setOpeningPrice(uint256)` | ask price while nothing is outstanding (wei per 1e18 base units) | only while `backedSupply == 0`; never below `minOpeningPrice` |
| `setSpreads(uint256 buyPremiumBps, uint256 sellFeeBps)` | buy premium and redemption fee | premium ≤ `MAX_BUY_PREMIUM_BPS` (2000 = 20%), fee ≤ `MAX_SELL_FEE_BPS` (1000 = 10%); may be changed at any time within the caps |
| `setBuysPaused(bool)` | stops or resumes new sales | redemptions are never affected |
| `withdrawInventory(address to, uint256 amount)` | moves unsold project tokens out | cannot touch the reserve or the floor |
| `rescueERC20(IERC20, address to, uint256)` | recovers an unrelated ERC-20 sent by mistake | refuses the project token |
| `transferOwnership` / `acceptOwnership` / `renounceOwnership` | OpenZeppelin `Ownable2Step` | renouncing freezes configuration; trading continues |

The owner **cannot**: withdraw ETH, change the floor, pause redemptions, mint or burn, upgrade the
contract, or raise the spreads above the caps. Those are the guarantees users rely on. The owner
**can** pause new sales, change the spreads within the caps and drain the inventory (unsold tokens),
which is a censorship and availability power rather than a custody one. A multisig owner is
recommended once the launch settles; the contract does not enforce it.

### Public functions

| Function | Who | Effect |
| --- | --- | --- |
| `buy(uint256 minTokensOut) payable` | anyone | sends ETH, receives inventory at the ask; reverts on dust (`ZeroOutput`), slippage, paused buys or insufficient inventory |
| `sell(uint256 amount, uint256 minEthOut)` | anyone holding the token | redeems up to `backedSupply` at the bid; reverts if the amount exceeds the backed supply |
| `depositInventory(uint256 amount)` | anyone | adds project tokens to the inventory for sale |
| `receive()` | anyone | plain ETH transfers are donations to the reserve and raise the floor |
| `quoteBuy`, `quoteSell`, `floorPrice`, `askPrice`, `bidPrice`, `reserve`, `inventory`, `backedSupply`, `isConfigured` | views | what the website shows |

Tokens bought elsewhere are fungible with tokens bought from the vault, so any holder may redeem, but
total redemptions are capped at `backedSupply`. This is what lets arbitrage hold the market at the
floor; it also means early redemption by outside holders is first come, first served.

### Rounding

Buys round token output down and sells round ETH output down, both in the reserve's favour, using
`Math.mulDiv` so there is no intermediate truncation. Fuzz tests assert the floor is monotone for
every spread within the caps and that a buy-then-sell round trip can never extract ETH.

## Named constants (choices the brief left open)

| Constant | Value | Why |
| --- | --- | --- |
| `MAX_BUY_PREMIUM_BPS` | 2000 (20%) | hard ceiling on the buy premium the owner may set |
| `MAX_SELL_FEE_BPS` | 1000 (10%) | hard ceiling on the redemption fee the owner may set |
| `WAD` | 1e18 | price scale, wei per 1e18 base units |
| `BPS` | 10000 | basis-point denominator |

The opening price and the actual spreads are prices and fees, which belong to the requester, so they
are owner-set after launch rather than guessed here (see below).

## After launch

The owner (`0xd3f26a6be348440110161dfd5748e7de7b08cf69`) completes configuration in this order.
Until all three settings are made, `buy` reverts (`TokenNotSet`, `SpreadsNotSet`, `OpeningPriceNotSet`)
and `isConfigured()` is false.

1. **`setSpreads(buyPremiumBps, sellFeeBps)`**: choose the buy premium and redemption fee in basis
   points, each within the caps above. A reasonable start is a 3% premium (300) and 1% fee (100); 0 and
   0 is also valid. Can be done before the token exists.
2. **`setOpeningPrice(price)`**: the price in wei per 1e18 token base units at which the very first
   sale happens (for an 18-decimal token, wei per whole token; e.g. `1000000000000000` is 0.001 ETH).
   Only possible while nothing is outstanding. Can be done before the token exists.
3. **`setToken(tokenAddress)`**: once the token is launched on Keel, pass its address. Take it from the
   Keel launch's deployment record. This can be done only once; verify the address before sending.
4. **`depositInventory(amount)`** after approving the vault for `amount` on the token: the tokens the
   vault will sell. Anyone may add inventory; the owner withdraws unsold inventory with
   `withdrawInventory`.
5. Optional: send ETH directly to the vault to seed the reserve. Donated ETH raises the floor for
   holders and can never be taken back.

Operational responsibilities:

- the owner must not lose the key: there is no recovery, and the token slot is one-shot;
- the token must be a standard ERC-20 (no fee on transfer, no rebasing); the vault rejects such
  transfers with `NonStandardTokenTransfer`;
- `setBuysPaused(true)` is the only emergency control and only stops new sales;
- the website should show `floorPrice`, `askPrice`, `bidPrice`, `reserve`, `inventory` and
  `backedSupply`, and pass `quoteBuy` / `quoteSell` results as the slippage minimums;
- verification of source on the block explorer and any move of ownership to a multisig are the
  launch operator's and owner's steps after deployment.

## Build and test

```
forge build
forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, `bytecode_hash = "none"`, optimizer on (200 runs), `ffi`
off and no filesystem permissions. Dependencies are vendored as plain files under `lib/`:
forge-std v1.9.7 and OpenZeppelin Contracts v5.4.0 (`Ownable2Step`, `ReentrancyGuard`, `SafeERC20`,
`Math`). No submodules.

Tests (`test/`):

- `RisingFloorVault.t.sol`: construction and ownership (named owner, deployer has no rights,
  two-step transfer), the `setToken` slot (once, zero address, owner only, features disabled until
  set), opening price and spread configuration with caps, pausing buys but never sells, inventory
  deposit/withdraw/rescue, buy and sell success paths with exact amounts and events, every failure
  path (zero amounts, dust, slippage, insufficient inventory, over-redemption, rejecting ETH
  receiver, fee-on-transfer token), the opening-price ratchet, donations, reentrancy from the ETH
  payout into `sell`, `buy` and `depositInventory`, and fuzz tests that the floor never falls on any
  buy or sell and that a round trip never profits against the reserve.
- `RisingFloorVault.invariant.t.sol`: a handler drives random buys, sells, donations, inventory
  moves, spread changes and pauses; invariants check the floor never goes below its high-water mark,
  ETH conservation, token conservation (backed supply equals tokens outside the vault) and that the
  reserve always covers full redemption.

Security review used the eth-security checklist: checks-effects-interactions plus `nonReentrant`
on every external-calling function, SafeERC20 with exact-amount checks, explicit access control,
bounded fees, no delegatecall, no selfdestruct, no proxies, no oracles, no infinite approvals, input
validation and events on every state change. Only Foundry's compiler, linter, unit, fuzz and
invariant tests were run; Slither and Mythril were not available in this environment. Tests are not
an audit: an independent adversarial review is part of this launch's workflow before deployment.

## Deployment

The launch deploys `RisingFloorVault` through the project factory with the single constructor
argument `$owner`. This repository contains no deploy script, no keys and no `launch.json`; the
manifest step writes the manifest after review.
