# RisingFloorVault

Contracts for the brief *"tạo cho tôi 1 token lôi cuốn người dùng không bao giờ rớt giá"* ("create a
token that attracts users and never drops in price"), launched on Ethereum mainnet (chain id 1) as a
contracts-only launch. The project token itself is launched later on Keel, so this repository ships
the application contract that gives that token its "never drops" property and leaves a one-time
`setToken` slot for its address.

## What "never drops in price" means here

No contract can control the price people agree on elsewhere. What a contract *can* guarantee is a
**redemption floor**: a price at which the vault will always buy back the tokens it sold, fully backed
by ETH it holds, that is mathematically unable to go down while those tokens are outstanding.

`RisingFloorVault` holds an ETH **reserve** and an **inventory** of the project token.

| Term | Definition |
| --- | --- |
| `backedSupply` | token base units the vault has sold and not yet bought back |
| `redeemable(account)` | base units `account` may redeem: credited by `buy`, spent by `sell`, movable with `transferRedeemable`; credits always sum to `backedSupply` |
| `floorPrice` | `reserve * 1e18 / backedSupply` (wei per 1e18 token base units); the opening price while nothing is outstanding |
| `askPrice` | `floorPrice * (1 + buyPremiumBps / 10000)`: what buyers pay. The opening sale of an epoch carries no premium: its ask is `openingPrice` |
| `bidPrice` | `floorPrice * (1 - sellFeeBps / 10000)`: what sellers receive; 0 while nothing is outstanding, because nothing is redeemable then |

While any backed token is outstanding, every operation keeps `floorAfter >= floorBefore`:

- **buy** adds ETH at or above the floor, so backing per token rises;
- **sell** removes ETH at or below the floor, so backing per token rises. The fee is a pro-rata
  transfer to whoever still holds credit afterwards, the seller's own remaining stake included; a
  holder who sells in several pieces therefore keeps part of their own fee, and a sole holder who
  leaves in two steps pays none. The fee bites when other holders remain, which is who it is for;
- **donation** (plain ETH transfer) adds ETH and removes nothing. It is accepted only while
  something is outstanding and the reserve is at least `MIN_POSITION_VALUE` (a donation against
  dust would pin the floor for the price of the donation), and goes pro rata to exactly the credits
  outstanding at that moment: check `backedSupply` and `reserve` before donating;
- **forced redemption** (`forceRedeem`, owner only) removes a holder's credit and the exact pro-rata
  share of the reserve it backs, so the others' backing per token is unchanged;
- **inventory deposit / withdrawal** moves unsold tokens only; it never touches the reserve or the
  backed supply, so it cannot move the floor.

**No dust left behind.** Fees and rounding residue stay in the reserve for whoever still holds
credit, so a tiny remaining position would concentrate them and pin the floor, and with it the ask,
at an absurd level (one base unit left behind a 1 ETH position would be "worth" 0.0099 ETH). A
partial redemption or a credit transfer therefore may not leave any account with a nonzero credit
worth less than `MIN_POSITION_VALUE` (0.01 ETH) at the floor; `minRemainingCredit()` is that credit
in base units right now (it shrinks as the floor rises). A position may always be redeemed in full,
whatever its size, and buys of any size are accepted. Because the fee of a large holder who leaves
still lands on whoever remains, a floor can still be pushed up by somebody who buys dust and lets
others' fees accrue to it, or by donating; that costs the pusher locked capital rather than nothing,
and the owner has a remedy: `forceRedeem` pays the pinning position its full floor value into an
escrow only that holder can withdraw, clears its credit, and the epoch reopens at the opening price.
Nobody is ever paid less than the floor, and the owner cannot direct the ETH anywhere else.

**Only credited tokens can be redeemed.** `buy` credits the buyer with the right to redeem exactly
the base units it sold them. Tokens that never passed through a vault sale, including inventory the
owner withdraws and tokens bought on a market, carry no claim on the reserve. A holder who passes
tokens on may pass the credit on with `transferRedeemable`; the credit moves no tokens, and a
redemption needs both. Nobody, including the owner, can withdraw ETH from the reserve: there is no
owner withdrawal, no rescue path for ETH and no upgrade mechanism. ETH only leaves through `sell`,
or through `withdrawPayout` by a holder the owner force-redeemed at the floor. Redemptions can never
be paused.

**Epochs.** The redemption that returns `backedSupply` to zero pays out the whole reserve with no
fee: there is no remaining holder for a fee to stay behind for. So the reserve is empty whenever
nothing is outstanding, ETH is refused in that state (`NothingOutstanding`), and the next buyer gets
exactly the backing they pay for. The next epoch opens at `openingPrice`, which the owner sets while
nothing is outstanding and can never set below an opening price at which the vault has already sold
(`minOpeningPrice`, recorded by the first sale of each epoch). Only owner-set values are ever
recorded there, so no sequence of buys, donations or redemptions can push it. Within an epoch the
floor is at least the opening price; across epochs the vault's own sale price never goes down. An
epoch's floor may have risen far above its opening price before everyone redeemed; that higher floor
is not carried into the next epoch, because every holder it protected has been paid at it.

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
| `owner_` | `address` | `0xd3f26a6be348440110161dfd5748e7de7b08cf69`, the creator's wallet named by the brief, written into the manifest as that static address |

The constructor only records the owner. It makes no external calls and does not require any address
to have code, so it deploys on an empty chain. The deployer (the launch factory) keeps no rights.

### The one-time token slot

- `setToken(address token)`: owner only, once. Reverts with `ZeroAddress` for the zero address,
  `NotAContract` for an address without code (a typo or an address copied before Keel deployed it
  would otherwise consume the slot for good) and `TokenAlreadySet` if a token is already set. Emits
  `TokenSet(token)`.
- `token()`: the token address, the zero address until set.
- Every token feature (`buy`, `sell`, `depositInventory`, `withdrawInventory`) reverts with
  `TokenNotSet` until the slot is filled; `inventory()` returns 0. The website reads `token()` and
  hides token features while it is zero.
- `renounceOwnership` is refused until the slot is filled, so the slot can never be left empty
  with nobody able to fill it.

### Owner functions (trust assumptions)

| Function | Effect | Limits |
| --- | --- | --- |
| `setToken(address)` | fills the token slot | once, non-zero, must have code |
| `setOpeningPrice(uint256)` | ask price while nothing is outstanding (wei per 1e18 base units) | only while `backedSupply == 0`; never below `minOpeningPrice` |
| `setSpreads(uint256 buyPremiumBps, uint256 sellFeeBps)` | buy premium and redemption fee | premium ≤ `MAX_BUY_PREMIUM_BPS` (2000 = 20%), fee ≤ `MAX_SELL_FEE_BPS` (1000 = 10%); may be changed at any time within the caps, with no timelock |
| `setBuysPaused(bool)` | stops or resumes new sales | redemptions are never affected |
| `withdrawInventory(address to, uint256 amount)` | moves unsold project tokens out | cannot touch the reserve or the floor; withdrawn tokens carry no credit, so they cannot be redeemed |
| `rescueERC20(IERC20, address to, uint256)` | recovers an unrelated ERC-20 sent by mistake | refuses the project token |
| `forceRedeem(address[] holders)` | ends the listed holders' backed positions: each is paid its full pro-rata share of the reserve (the floor, no fee) into `pendingPayout`, its credit is cleared, the holders keep their tokens | the ETH goes only to the holder, who withdraws it with `withdrawPayout`; the others' floor does not move; reverts `NoCredit` for an address without credit |
| `transferOwnership` / `acceptOwnership` / `renounceOwnership` | OpenZeppelin `Ownable2Step` | renouncing freezes configuration (only after `setToken`); trading continues |

The owner **cannot**: withdraw ETH, redeem anything it did not buy, change the floor, pause
redemptions, mint or burn, upgrade the contract, lower the opening price below one the vault sold
at, or raise the spreads above the caps. Those are the guarantees users rely on. The owner **can**
pause new sales, change the spreads within the caps, drain the inventory (unsold tokens) and end any
holder's backed position at the floor with `forceRedeem`. The first three are censorship and
availability powers rather than custody ones. The last is the remedy for a pinned floor (see "No
dust left behind"), and it is also a trust assumption: a force-redeemed holder is paid exactly what
the floor guarantees them and keeps their tokens, but loses the option of staying backed while the
floor keeps rising. The owner gains nothing from it (the ETH can only go to the holder) beyond
reopening sales. Because a spread change takes effect immediately, the owner could move the spreads
to their caps between a user's quote and its execution: a user who passes zero as the slippage
minimum can pay up to 20% premium or 10% fee. The website must pass the quoted amounts as
`minTokensOut` / `minEthOut`, which makes such a change revert the trade instead. A multisig owner
is recommended once the launch settles; the contract does not enforce it. If the owner renounces,
`forceRedeem` is gone with the rest of the configuration, so a pinned floor could then only be
cleared by the pinning holder.

### Public functions

| Function | Who | Effect |
| --- | --- | --- |
| `buy(uint256 minTokensOut) payable` | anyone | sends ETH, receives inventory at the ask and the credit to redeem it; reverts on dust (`ZeroOutput`), slippage, paused buys or insufficient inventory |
| `sell(uint256 amount, uint256 minEthOut)` | anyone with credit | redeems up to `redeemable(caller)` at the bid; the redemption that empties the backed supply pays the whole reserve, fee-free; reverts with `ExceedsRedeemable` beyond the credit and with `PositionTooSmall` if a nonzero credit below `minRemainingCredit()` would be left (redeem all of it instead) |
| `transferRedeemable(address to, uint256 amount)` | anyone with credit | moves redemption credit (not tokens) to `to`; neither side may be left with a nonzero credit below `minRemainingCredit()` |
| `withdrawPayout(address to)` | a force-redeemed holder | pays the caller's `pendingPayout` to `to`; reverts `NothingToWithdraw` when there is none |
| `depositInventory(uint256 amount)` | anyone | adds project tokens to the inventory for sale |
| `receive()` | anyone | plain ETH transfers are donations to the reserve and raise the floor for the current credit holders; refused while nothing is outstanding (`NothingOutstanding`) or the reserve is below `MIN_POSITION_VALUE` (`ReserveBelowMinimum`) |
| `quoteBuy(ethIn)`, `quoteSell(amount)`, `quoteSellFor(account, amount)`, `floorPrice`, `askPrice`, `bidPrice`, `reserve`, `inventory`, `backedSupply`, `redeemable(account)`, `minRemainingCredit`, `pendingPayout(account)`, `totalPendingPayouts`, `minOpeningPrice`, `isConfigured` | views | what the website shows. `quoteSell` quotes for `msg.sender`, so an off-chain reader sets `from` to the user's account or calls `quoteSellFor`. `reserve` is the balance less the escrowed payouts |

Tokens bought elsewhere are the same ERC-20, but only credited base units can be redeemed, so a
market price below the bid is an opportunity only for credit holders (past vault buyers who passed
their tokens on but kept the credit). Total redemption is always exactly `backedSupply`.

### Rounding

Buys round token output down and sells round ETH output down, both in the reserve's favour, using
`Math.mulDiv` so there is no intermediate truncation. A position so small that its payout rounds to
zero reverts with `ZeroOutput` unless it is the last position, which always takes the whole reserve.
Fuzz tests assert the floor is monotone within an epoch for every spread within the caps, that a
buy-then-sell round trip can never extract ETH that other holders are owed, and that the reserve is
empty whenever the backed supply is.

ETH forced into the contract without a call (a `selfdestruct` beneficiary, a block reward) is
counted in the reserve like a donation. While something is outstanding it benefits the credit
holders; while nothing is outstanding it benefits the first buyer of the next epoch. In both cases
the sender gives it away and nobody loses anything, so the contract does not guard against it.

## Named constants (choices the brief left open)

| Constant | Value | Why |
| --- | --- | --- |
| `MAX_BUY_PREMIUM_BPS` | 2000 (20%) | hard ceiling on the buy premium the owner may set |
| `MAX_SELL_FEE_BPS` | 1000 (10%) | hard ceiling on the redemption fee the owner may set |
| `MIN_POSITION_VALUE` | 0.01 ETH | smallest value, at the floor, a nonzero credit may be left with by a partial redemption or a credit transfer, and the smallest reserve a donation is accepted against; large enough that residue landing on it cannot pin the floor by accident, small enough not to matter to a real position |
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
2. **`setOpeningPrice(price)`**: the price in wei per 1e18 token base units at which the first sale
   of an epoch happens (for an 18-decimal token, wei per whole token; e.g. `1000000000000000` is
   0.001 ETH). Only possible while nothing is outstanding, and it can be corrected freely until
   somebody buys at it: from then on it can only be set at or above that price. Can be done before
   the token exists.
3. **`setToken(tokenAddress)`**: once the token is launched on Keel, pass its address. Take it from the
   Keel launch's deployment record. This can be done only once; the vault refuses an address with no
   code, but not a wrong contract, so verify the address before sending.
4. **`depositInventory(amount)`** after approving the vault for `amount` on the token: the tokens the
   vault will sell. Anyone may add inventory; the owner withdraws unsold inventory with
   `withdrawInventory`.
5. Optional: seed the reserve. The vault refuses plain ETH while nothing is outstanding, because
   such ETH would go to the next buyer whatever they paid, and while the reserve is below
   `MIN_POSITION_VALUE`. To seed, first `buy` at least 0.01 ETH (the owner becomes a credited
   holder like anyone else), then send ETH directly: the donation raises the floor for every credit
   outstanding at that moment, pro rata, and can never be taken back except by redeeming the
   credits it backs.

Operational responsibilities:

- the owner must not lose the key: there is no recovery, and the token slot is one-shot;
- the token must be a standard ERC-20 (no fee on transfer, no rebasing); the vault rejects such
  transfers with `NonStandardTokenTransfer`;
- `setBuysPaused(true)` is the emergency control for sales and only stops new sales;
- a pinned floor (the ask far above what the market will pay because fees or a donation accrued to
  a small remaining position, typically visible as `quoteBuy(1 ether)` returning a sliver of a
  token while `backedSupply` is tiny) is cleared with `forceRedeem([holders])`: take the holders
  from `Bought` / `RedeemableTransferred` events, pass every address with nonzero `redeemable`,
  then set the next `openingPrice`. The holders withdraw their payout with `withdrawPayout`; the
  website should show `pendingPayout(account)` and offer that call when it is nonzero. Use the
  remedy only to reopen sales, never to push a holder out for its own sake: it is visible on chain;
- after a full redemption the vault stays open at the current `openingPrice`; raise it with
  `setOpeningPrice` before the next sale if the previous epoch's floor should carry over;
- the website should show `floorPrice`, `askPrice`, `bidPrice`, `reserve`, `inventory`,
  `backedSupply`, `minRemainingCredit` and the connected account's `redeemable` and
  `pendingPayout`, hide redemption for accounts with no credit, offer "redeem all" as the default
  (a partial redemption that would leave less than `minRemainingCredit` reverts), and pass
  `quoteBuy` / `quoteSellFor(account, …)` results as the slippage minimums;
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
  two-step transfer, renounce refused before `setToken`), the `setToken` slot (once, zero address,
  no code, owner only, features disabled until set), opening price and spread configuration with
  caps, the opening-price minimum (free before a sale, locked to the price sold at afterwards, not
  movable by a dust buy plus donation nor by concentrating fee residue), pausing buys but never
  sells, inventory deposit/withdraw/rescue, buy and sell success paths with exact amounts and
  events, every failure path (zero amounts, dust, slippage, insufficient inventory, redeeming beyond
  one's credit, outside holders and withdrawn inventory having no credit, rejecting ETH receiver,
  fee-on-transfer token), the fee-free final redemption, the minimum remaining position on partial
  redemptions and credit transfers (the reviewer's 1000 wei and 1 ETH dust scenarios, the exact
  boundary, the minimum tracking the floor, self-transfers), donations accepted only while something
  is outstanding and the reserve is not dust, the first buyer of an epoch capturing nothing, forced
  redemption (owner only, needs credit, clears a pinned floor and reopens the epoch, pays pro rata
  without moving the others' floor, escrows for a holder that refuses ETH, payout withdrawal to a
  chosen recipient, no reentrancy from the payout), reentrancy from the ETH payout into `sell`,
  `buy` and `depositInventory`, and fuzz tests that the floor never falls on any buy, sell or forced
  redemption within an epoch, that a round trip never profits against the reserve and that an empty
  backed supply always means an empty reserve.
- `RisingFloorVault.invariant.t.sol`: a handler drives random buys, sells, credit transfers,
  donations, forced redemptions and payout withdrawals, inventory moves (with the owner trying to
  redeem what it withdrew), spread changes and pauses; invariants check the floor never goes below
  its epoch high-water mark, ETH conservation including the escrow, token conservation including
  force-redeemed holders' uncredited tokens, credits summing to the backed supply with none for the
  owner, the reserve paying exactly the whole supply and being empty when nothing is outstanding,
  and that every check made inside a handler held.

Security review used the eth-security checklist: checks-effects-interactions plus `nonReentrant`
on every external-calling function, SafeERC20 with exact-amount checks, explicit access control,
bounded fees, no delegatecall, no selfdestruct, no proxies, no oracles, no infinite approvals, input
validation and events on every state change. Only Foundry's compiler, linter, unit, fuzz and
invariant tests were run; Slither and Mythril were not available in this environment. Tests are not
an audit: an independent adversarial review is part of this launch's workflow before deployment.

## Deployment

The launch deploys `RisingFloorVault` through the project factory with the single constructor
argument `0xd3f26a6be348440110161dfd5748e7de7b08cf69`, the owner the brief names, written into the
manifest as that static address rather than `$owner`. This source assignment contains no deploy
script and no keys and does not write `launch.json`; the separate manifest assignment writes it
after this work is accepted.
