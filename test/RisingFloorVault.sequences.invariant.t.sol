// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RisingFloorVault} from "../src/RisingFloorVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Second handler, stricter than the one in `RisingFloorVault.invariant.t.sol`: every call it
///      makes either succeeds and is checked against the quote and the floor it saw before, or is
///      a probe that asserts the exact revert. Nothing is silently skipped, so the run fails on any
///      revert the handler did not predict. It also drives the owner (spreads, opening price,
///      pauses, inventory moves), token transfers between holders and ETH forced in without a call.
contract SequenceHandler is Test {
    using Math for uint256;

    RisingFloorVault public immutable vault;
    MockERC20 public immutable token;
    address public immutable owner;
    uint256 internal constant OPENING = 0.001 ether;

    address[] internal actors;

    // Ghost totals the invariants are checked against.
    uint256 public ethIn; // buys + donations + forced ETH
    uint256 public ethOut; // redemptions and escrow withdrawals
    uint256 public tokensSold; // base units sold by the vault
    uint256 public tokensRedeemed; // base units bought back
    uint256 public tokensForced; // base units whose credit a forced redemption ended; the holder keeps them
    uint256 public forced; // forced redemptions that cleared at least one holder
    uint256 public inventoryIn; // deposited
    uint256 public inventoryOut; // withdrawn by the owner
    uint256 public floorHighWater; // highest floor seen in the current epoch; 0 between epochs
    uint256 public epochs; // full redemptions seen
    uint256 public openingSold; // highest opening price an epoch has actually opened at
    uint256 public strandedEth; // ETH forced in while nothing was outstanding, until the next epoch opens

    // Coverage counters so a run that only hit probes is visible.
    uint256 public buys;
    uint256 public sells;
    uint256 public probes;

    constructor(RisingFloorVault vault_, MockERC20 token_, address owner_) {
        vault = vault_;
        token = token_;
        owner = owner_;
        actors.push(address(0xA1));
        actors.push(address(0xA2));
        actors.push(address(0xA3));
        actors.push(address(0xA4));
    }

    // ------------------------------------------------------------------ bookkeeping

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actor(uint256 i) external view returns (address) {
        return actors[i];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev The floor is monotone within an epoch. A full redemption pays everyone out and the next
    ///      epoch opens at the owner's opening price, so the high-water mark resets with it.
    function _recordFloor() internal {
        if (vault.backedSupply() == 0) {
            floorHighWater = 0;
            return;
        }
        uint256 f = vault.floorPrice();
        if (f > floorHighWater) floorHighWater = f;
    }

    function _credits() internal view returns (uint256 total) {
        for (uint256 i; i < actors.length; ++i) {
            total += vault.redeemable(actors[i]);
        }
    }

    // ------------------------------------------------------------------ public actions

    function buy(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        amount = bound(amount, 1, 100 ether);
        vm.deal(who, who.balance + amount);
        uint256 quote = vault.quoteBuy(amount);
        uint256 available = vault.inventory();

        if (vault.buysPaused()) {
            probes++;
            vm.prank(who);
            vm.expectRevert(RisingFloorVault.BuysArePaused.selector);
            vault.buy{value: amount}(0);
            return;
        }
        if (quote == 0) {
            probes++;
            vm.prank(who);
            vm.expectRevert(RisingFloorVault.ZeroOutput.selector);
            vault.buy{value: amount}(0);
            return;
        }
        if (quote > available) {
            probes++;
            vm.prank(who);
            vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.InsufficientInventory.selector, available, quote));
            vault.buy{value: amount}(0);
            return;
        }

        uint256 floorBefore = vault.floorPrice();
        uint256 supplyBefore = vault.backedSupply();
        uint256 reserveBefore = vault.reserve();
        uint256 creditBefore = vault.redeemable(who);
        uint256 minBefore = vault.minOpeningPrice();
        uint256 opening = vault.openingPrice();
        vm.prank(who);
        uint256 out = vault.buy{value: amount}(quote);

        assertEq(out, quote, "buy: output differs from quote");
        assertEq(vault.reserve(), reserveBefore + amount, "buy: reserve");
        assertEq(vault.backedSupply(), supplyBefore + out, "buy: supply");
        assertEq(vault.redeemable(who), creditBefore + out, "buy: credit");
        assertGe(vault.floorPrice(), floorBefore, "buy: floor fell");
        assertGe(amount.mulDiv(1e18, out), floorBefore, "buy: paid under the floor");
        if (supplyBefore == 0) {
            // The epoch opened at the opening price and the ratchet records exactly that.
            assertEq(vault.minOpeningPrice(), Math.max(minBefore, opening), "buy: ratchet");
            if (opening > openingSold) openingSold = opening;
            strandedEth = 0;
        } else {
            assertEq(vault.minOpeningPrice(), minBefore, "buy: ratchet moved mid-epoch");
        }

        ethIn += amount;
        tokensSold += out;
        buys++;
        _recordFloor();
    }

    function sell(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        uint256 balance = token.balanceOf(who);
        uint256 credit = vault.redeemable(who);
        if (balance == 0 && credit == 0) {
            // A holder of nothing cannot redeem anything, however small.
            probes++;
            vm.startPrank(who);
            vm.expectRevert(RisingFloorVault.ZeroAmount.selector);
            vault.sell(0, 0);
            vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.ExceedsRedeemable.selector, 0, 1));
            vault.sell(1, 0);
            vm.stopPrank();
            return;
        }
        // Up to whichever is larger, so both "credit without tokens" and "tokens without credit"
        // are reached and asserted to fail.
        amount = bound(amount, 1, Math.max(balance, credit));
        _redeem(who, amount);
    }

    /// @dev Redeems everything a holder can: the whole credit, capped at the tokens in hand. This is
    ///      the path that empties the vault and closes an epoch.
    function sellAll(uint256 seed) external {
        address who = _actor(seed);
        uint256 amount = Math.min(token.balanceOf(who), vault.redeemable(who));
        if (amount == 0) return;
        _redeem(who, amount);
    }

    function _redeem(address who, uint256 amount) internal {
        uint256 supply = vault.backedSupply();
        uint256 credit = vault.redeemable(who);
        uint256 balance = token.balanceOf(who);
        vm.prank(who);
        token.approve(address(vault), amount);

        if (amount > credit) {
            probes++;
            vm.prank(who);
            vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.ExceedsRedeemable.selector, credit, amount));
            vault.sell(amount, 0);
            return;
        }
        uint256 quote = vault.quoteSellFor(who, amount);
        if (quote == 0) {
            probes++;
            vm.prank(who);
            vm.expectRevert(RisingFloorVault.ZeroOutput.selector);
            vault.sell(amount, 0);
            return;
        }
        uint256 remainingCredit = credit - amount;
        uint256 minCredit = vault.minRemainingCredit();
        if (remainingCredit != 0 && remainingCredit < minCredit) {
            // Leaving dust behind is refused whatever the caller holds; a whole exit never is.
            probes++;
            vm.prank(who);
            vm.expectRevert(
                abi.encodeWithSelector(RisingFloorVault.PositionTooSmall.selector, remainingCredit, minCredit)
            );
            vault.sell(amount, 0);
            assertEq(vault.redeemable(who), credit, "sell: refused dust changed the credit");
            return;
        }
        if (amount > balance) {
            // Credit without the tokens: the pull fails after every check passed, and nothing moved.
            probes++;
            vm.prank(who);
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, who, balance, amount)
            );
            vault.sell(amount, 0);
            assertEq(vault.redeemable(who), credit, "sell: failed pull changed the credit");
            assertEq(vault.backedSupply(), supply, "sell: failed pull changed the supply");
            return;
        }

        uint256 floorBefore = vault.floorPrice();
        uint256 reserveBefore = vault.reserve();
        uint256 whoBefore = who.balance;
        vm.prank(who);
        uint256 out = vault.sell(amount, quote);

        assertEq(out, quote, "sell: output differs from quote");
        assertEq(who.balance, whoBefore + out, "sell: payout");
        assertEq(vault.reserve(), reserveBefore - out, "sell: reserve");
        assertEq(vault.backedSupply(), supply - amount, "sell: supply");
        assertEq(vault.redeemable(who), credit - amount, "sell: credit");
        // At or below the exact floor (reserve / supply), not the rounded view of it.
        assertLe(out, amount.mulDiv(reserveBefore, supply), "sell: paid over the floor");
        if (vault.backedSupply() == 0) {
            epochs++;
            assertEq(out, reserveBefore, "sell: the last holder is paid the whole reserve");
            assertEq(vault.reserve(), 0, "sell: ETH left behind with nobody to own it");
            assertEq(vault.floorPrice(), vault.openingPrice(), "sell: empty vault quotes the opening price");
            assertEq(vault.bidPrice(), 0, "sell: nothing to bid for");
        } else {
            assertGe(vault.floorPrice(), floorBefore, "sell: floor fell");
        }

        ethOut += out;
        tokensRedeemed += amount;
        sells++;
        _recordFloor();
    }

    /// @dev Tokens move freely between holders; credit does not follow them.
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed >> 8);
        uint256 balance = token.balanceOf(from);
        if (balance == 0 || from == to) return;
        amount = bound(amount, 1, balance);
        uint256 creditFrom = vault.redeemable(from);
        uint256 creditTo = vault.redeemable(to);
        vm.prank(from);
        token.transfer(to, amount);
        assertEq(vault.redeemable(from), creditFrom, "transfer: credit followed the tokens");
        assertEq(vault.redeemable(to), creditTo, "transfer: credit followed the tokens");
    }

    /// @dev Credit moves on its own; tokens do not follow it.
    function transferCredit(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed >> 8);
        uint256 credit = vault.redeemable(from);
        if (credit == 0) {
            probes++;
            vm.prank(from);
            vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.ExceedsRedeemable.selector, 0, 1));
            vault.transferRedeemable(to, 1);
            return;
        }
        amount = bound(amount, 1, credit);
        uint256 creditTo = vault.redeemable(to);
        uint256 balanceFrom = token.balanceOf(from);
        uint256 supply = vault.backedSupply();
        uint256 remaining = credit - amount;
        uint256 received = (from == to ? remaining : creditTo) + amount;
        uint256 minCredit = vault.minRemainingCredit();
        if ((remaining != 0 && remaining < minCredit) || received < minCredit) {
            // Neither side may be left with dust; the sender's side is checked first.
            probes++;
            uint256 offending = remaining != 0 && remaining < minCredit ? remaining : received;
            vm.prank(from);
            vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.PositionTooSmall.selector, offending, minCredit));
            vault.transferRedeemable(to, amount);
            assertEq(vault.redeemable(from), credit, "credit: refused transfer changed the sender");
            assertEq(vault.redeemable(to), creditTo, "credit: refused transfer changed the recipient");
            return;
        }
        vm.prank(from);
        vault.transferRedeemable(to, amount);
        if (from == to) {
            assertEq(vault.redeemable(from), credit, "credit: self-transfer changed the credit");
        } else {
            assertEq(vault.redeemable(from), credit - amount, "credit: sender");
            assertEq(vault.redeemable(to), creditTo + amount, "credit: recipient");
        }
        assertEq(token.balanceOf(from), balanceFrom, "credit: tokens moved");
        assertEq(vault.backedSupply(), supply, "credit: supply moved");
        assertEq(_credits(), supply, "credit: credits no longer sum to the supply");
    }

    function donate(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        amount = bound(amount, 1, 10 ether);
        vm.deal(who, who.balance + amount);
        uint256 floorBefore = vault.floorPrice();
        uint256 reserveBefore = vault.reserve();
        if (vault.backedSupply() == 0) {
            // Nothing is outstanding: the ETH would belong to nobody, so it is refused.
            probes++;
            vm.prank(who);
            (bool refused, bytes memory err) = address(vault).call{value: amount}("");
            assertFalse(refused, "donate: accepted with nothing outstanding");
            assertEq(bytes4(err), RisingFloorVault.NothingOutstanding.selector, "donate: wrong refusal");
            assertEq(vault.reserve(), reserveBefore, "donate: refused but kept");
            return;
        }
        uint256 minReserve = vault.MIN_POSITION_VALUE();
        if (reserveBefore < minReserve) {
            // A donation against a dust reserve would pin the floor for the price of the donation.
            probes++;
            vm.prank(who);
            (bool refused, bytes memory err) = address(vault).call{value: amount}("");
            assertFalse(refused, "donate: accepted against a dust reserve");
            assertEq(
                err,
                abi.encodeWithSelector(RisingFloorVault.ReserveBelowMinimum.selector, reserveBefore, minReserve),
                "donate: wrong refusal"
            );
            assertEq(vault.reserve(), reserveBefore, "donate: refused but kept");
            return;
        }
        vm.prank(who);
        (bool ok,) = address(vault).call{value: amount}("");
        assertTrue(ok, "donation refused");
        assertEq(vault.reserve(), reserveBefore + amount, "donate: reserve");
        assertGe(vault.floorPrice(), floorBefore, "donate: floor fell");
        ethIn += amount;
        _recordFloor();
    }

    /// @dev ETH that arrives without a call (selfdestruct, block rewards) cannot be refused. While
    ///      something is outstanding it is reserve like any donation; between epochs it waits for
    ///      the next buyer, whose tokens then open above the opening price.
    function forceEth(uint256 amount) external {
        amount = bound(amount, 1, 1 ether);
        uint256 floorBefore = vault.floorPrice();
        vm.deal(address(vault), address(vault).balance + amount);
        assertGe(vault.floorPrice(), floorBefore, "forced ETH: floor fell");
        if (vault.backedSupply() == 0) strandedEth += amount;
        ethIn += amount;
        _recordFloor();
    }

    function deposit(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        amount = bound(amount, 1, 1_000_000e18);
        token.mint(who, amount);
        uint256 floorBefore = vault.floorPrice();
        uint256 supplyBefore = vault.backedSupply();
        vm.startPrank(who);
        token.approve(address(vault), amount);
        vault.depositInventory(amount);
        vm.stopPrank();
        assertEq(vault.floorPrice(), floorBefore, "deposit: floor moved");
        assertEq(vault.backedSupply(), supplyBefore, "deposit: supply moved");
        inventoryIn += amount;
    }

    // ------------------------------------------------------------------ owner actions

    function withdraw(uint256 amount) external {
        uint256 available = vault.inventory();
        if (available == 0) {
            probes++;
            vm.prank(owner);
            vm.expectRevert(RisingFloorVault.ZeroAmount.selector);
            vault.withdrawInventory(owner, 0);
            return;
        }
        amount = bound(amount, 1, available);
        uint256 floorBefore = vault.floorPrice();
        uint256 reserveBefore = vault.reserve();
        vm.prank(owner);
        vault.withdrawInventory(owner, amount);
        assertEq(vault.floorPrice(), floorBefore, "withdraw: floor moved");
        assertEq(vault.reserve(), reserveBefore, "withdraw: reserve moved");
        inventoryOut += amount;
        // Withdrawn inventory carries no credit: the owner can never turn it into reserve ETH.
        probes++;
        vm.startPrank(owner);
        token.approve(address(vault), amount);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.ExceedsRedeemable.selector, 0, amount));
        vault.sell(amount, 0);
        vm.stopPrank();
    }

    function setSpreads(uint256 premium, uint256 fee) external {
        premium = bound(premium, 0, vault.MAX_BUY_PREMIUM_BPS());
        fee = bound(fee, 0, vault.MAX_SELL_FEE_BPS());
        uint256 floorBefore = vault.floorPrice();
        vm.prank(owner);
        vault.setSpreads(premium, fee);
        assertEq(vault.floorPrice(), floorBefore, "spreads: floor moved");
    }

    function setOpeningPrice(uint256 price) external {
        uint256 min = vault.minOpeningPrice();
        price = bound(price, 1, 2 * min + 10 * OPENING);
        uint256 supply = vault.backedSupply();
        if (supply != 0) {
            probes++;
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.SupplyOutstanding.selector, supply));
            vault.setOpeningPrice(price);
            return;
        }
        if (price < min) {
            probes++;
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.OpeningPriceBelowMinimum.selector, price, min));
            vault.setOpeningPrice(price);
            return;
        }
        vm.prank(owner);
        vault.setOpeningPrice(price);
        assertEq(vault.openingPrice(), price);
        assertEq(vault.minOpeningPrice(), min, "setting a price must not move the ratchet; selling at it does");
        assertEq(vault.floorPrice(), price, "empty vault quotes the opening price");
    }

    function pause(bool paused) external {
        vm.prank(owner);
        vault.setBuysPaused(paused);
        assertEq(vault.buysPaused(), paused);
    }

    /// @dev The owner ends the positions of the actors selected by `mask` (low four bits) in one
    ///      call. If any selected actor holds no credit the whole call is refused and nothing moves;
    ///      otherwise each is paid exactly its pro-rata share into escrow, in list order, the floor
    ///      of whoever remains never falls, and ending the last credit empties the reserve.
    function forceRedeem(uint256 mask) external {
        mask = bound(mask, 1, 15);
        uint256 count;
        for (uint256 i; i < actors.length; ++i) {
            if (mask & (1 << i) != 0) count++;
        }
        address[] memory holders = new address[](count);
        uint256 k;
        for (uint256 i; i < actors.length; ++i) {
            if (mask & (1 << i) != 0) holders[k++] = actors[i];
        }
        if (_forceRedeemIsRefused(holders)) return;

        uint256 balance = address(vault).balance;
        uint256 floorBefore = vault.floorPrice();
        uint256[] memory expected = _expectedForcedPayouts(holders);
        uint256[] memory payoutsBefore = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            payoutsBefore[i] = vault.pendingPayout(holders[i]);
        }
        uint256 supplyAfter = vault.backedSupply();
        uint256 reserveAfter = vault.reserve();
        uint256 escrowAfter = vault.totalPendingPayouts();

        vm.prank(owner);
        vault.forceRedeem(holders);

        for (uint256 i; i < count; ++i) {
            assertEq(vault.pendingPayout(holders[i]) - payoutsBefore[i], expected[i], "force: payout is not pro rata");
            assertEq(vault.redeemable(holders[i]), 0, "force: credit survived");
            supplyAfter -= _forcedCredit(i);
            reserveAfter -= expected[i];
            escrowAfter += expected[i];
            tokensForced += _forcedCredit(i);
        }
        assertEq(vault.backedSupply(), supplyAfter, "force: supply");
        assertEq(vault.reserve(), reserveAfter, "force: reserve");
        assertEq(vault.totalPendingPayouts(), escrowAfter, "force: escrow total");
        assertEq(address(vault).balance, balance, "force: ETH left the contract");
        if (supplyAfter == 0) {
            epochs++;
            assertEq(vault.reserve(), 0, "force: ETH left behind with nobody to own it");
            assertEq(vault.floorPrice(), vault.openingPrice(), "force: empty vault quotes the opening price");
        } else {
            assertGe(vault.floorPrice(), floorBefore, "force: the others' floor fell");
        }
        forced++;
        _recordFloor();
    }

    uint256[] internal forcedCredits; // credits of the holders of the current forced redemption, in order

    function _forcedCredit(uint256 i) internal view returns (uint256) {
        return forcedCredits[i];
    }

    /// @dev If any listed holder has no credit the owner's call is refused as a whole; asserts that
    ///      and reports it, so the caller skips the settlement checks.
    function _forceRedeemIsRefused(address[] memory holders) internal returns (bool refused) {
        uint256 supply = vault.backedSupply();
        uint256 pendingBefore = vault.totalPendingPayouts();
        for (uint256 i; i < holders.length; ++i) {
            if (vault.redeemable(holders[i]) != 0) continue;
            probes++;
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.NoCredit.selector, holders[i]));
            vault.forceRedeem(holders);
            assertEq(vault.backedSupply(), supply, "force: refused call moved the supply");
            assertEq(vault.totalPendingPayouts(), pendingBefore, "force: refused call escrowed");
            return true;
        }
    }

    /// @dev The pro-rata payouts the contract must produce for `holders` in order: each takes its
    ///      share of what is left after the ones before it, and the one ending the supply takes all.
    function _expectedForcedPayouts(address[] memory holders) internal returns (uint256[] memory expected) {
        delete forcedCredits;
        expected = new uint256[](holders.length);
        uint256 supply = vault.backedSupply();
        uint256 reserve = vault.reserve();
        for (uint256 i; i < holders.length; ++i) {
            uint256 credit = vault.redeemable(holders[i]);
            forcedCredits.push(credit);
            expected[i] = credit == supply ? reserve : credit.mulDiv(reserve, supply);
            supply -= credit;
            reserve -= expected[i];
        }
    }

    /// @dev A force-redeemed actor takes its escrow, to itself or to another actor; an actor with
    ///      nothing in escrow is refused.
    function withdrawPayout(uint256 seed, uint256 toSeed) external {
        address who = _actor(seed);
        address to = _actor(toSeed >> 8);
        uint256 pending = vault.pendingPayout(who);
        if (pending == 0) {
            probes++;
            vm.prank(who);
            vm.expectRevert(RisingFloorVault.NothingToWithdraw.selector);
            vault.withdrawPayout(to);
            return;
        }
        uint256 reserveBefore = vault.reserve();
        uint256 floorBefore = vault.floorPrice();
        uint256 totalBefore = vault.totalPendingPayouts();
        uint256 toBefore = to.balance;
        vm.prank(who);
        uint256 out = vault.withdrawPayout(to);
        assertEq(out, pending, "payout: amount");
        assertEq(to.balance, toBefore + out, "payout: recipient");
        assertEq(vault.pendingPayout(who), 0, "payout: not cleared");
        assertEq(vault.totalPendingPayouts(), totalBefore - out, "payout: total");
        assertEq(vault.reserve(), reserveBefore, "payout: touched the reserve");
        assertEq(vault.floorPrice(), floorBefore, "payout: moved the floor");
        // Paid once: a second withdrawal is refused.
        vm.prank(who);
        vm.expectRevert(RisingFloorVault.NothingToWithdraw.selector);
        vault.withdrawPayout(to);
        ethOut += out;
    }

    // ------------------------------------------------------------------ probes

    /// @dev Nobody but the owner configures anything, whatever the state.
    function probeStrangerCannotConfigure(uint256 seed) external {
        address who = _actor(seed);
        probes++;
        vm.startPrank(who);
        vm.expectRevert();
        vault.setSpreads(0, 0);
        vm.expectRevert();
        vault.setOpeningPrice(OPENING);
        vm.expectRevert();
        vault.setBuysPaused(true);
        vm.expectRevert();
        vault.withdrawInventory(who, 1);
        vm.expectRevert();
        vault.setToken(who);
        vm.expectRevert();
        vault.rescueERC20(IERC20(address(token)), who, 1);
        address[] memory holders = new address[](1);
        holders[0] = who;
        vm.expectRevert();
        vault.forceRedeem(holders);
        vm.expectRevert();
        vault.transferOwnership(who);
        vm.expectRevert();
        vault.renounceOwnership();
        vm.stopPrank();
    }

    /// @dev The slot is filled: nobody, not even the owner, can change the token any more.
    function probeTokenSlotIsFrozen() external {
        probes++;
        vm.startPrank(owner);
        vm.expectRevert(RisingFloorVault.TokenAlreadySet.selector);
        vault.setToken(address(token));
        vm.expectRevert(RisingFloorVault.TokenAlreadySet.selector);
        vault.setToken(address(vault));
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.NotAContract.selector, address(0xBEEF)));
        vault.setToken(address(0xBEEF));
        vm.expectRevert(RisingFloorVault.ZeroAddress.selector);
        vault.setToken(address(0));
        vm.stopPrank();
    }

    /// @dev Redeeming one unit past the credit always fails, however many tokens the caller holds.
    function probeOverRedemptionAlwaysFails(uint256 seed) external {
        address who = _actor(seed);
        uint256 credit = vault.redeemable(who);
        uint256 extra = credit + 1;
        probes++;
        token.mint(who, extra);
        vm.startPrank(who);
        token.approve(address(vault), extra);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.ExceedsRedeemable.selector, credit, extra));
        vault.sell(extra, 0);
        vm.stopPrank();
        // The probe's unbacked tokens become inventory, so actors stay the only holders outside the vault.
        vm.prank(who);
        token.transfer(address(this), extra);
        token.approve(address(vault), extra);
        vault.depositInventory(extra);
        inventoryIn += extra;
    }
}

/// @title Random-sequence invariants for RisingFloorVault
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract RisingFloorVaultSequencesInvariantTest is Test {
    using Math for uint256;

    address internal constant OWNER = 0xD3f26A6Be348440110161dFD5748E7DE7B08cf69;
    uint256 internal constant OPENING = 0.001 ether;
    uint256 internal constant INITIAL_INVENTORY = 5_000_000e18;

    RisingFloorVault internal vault;
    MockERC20 internal token;
    SequenceHandler internal handler;

    function setUp() public {
        vault = new RisingFloorVault(OWNER);
        token = new MockERC20();
        vm.startPrank(OWNER);
        vault.setToken(address(token));
        vault.setSpreads(500, 100);
        vault.setOpeningPrice(OPENING);
        vm.stopPrank();

        handler = new SequenceHandler(vault, token, OWNER);
        token.mint(address(handler), INITIAL_INVENTORY);
        vm.startPrank(address(handler));
        token.approve(address(vault), type(uint256).max);
        vault.depositInventory(INITIAL_INVENTORY);
        vm.stopPrank();

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](19);
        selectors[17] = SequenceHandler.forceRedeem.selector;
        selectors[18] = SequenceHandler.withdrawPayout.selector;
        selectors[0] = SequenceHandler.buy.selector;
        selectors[1] = SequenceHandler.buy.selector; // weighted: buys and sells are the core
        selectors[2] = SequenceHandler.sell.selector;
        selectors[3] = SequenceHandler.sell.selector;
        selectors[15] = SequenceHandler.sellAll.selector;
        selectors[16] = SequenceHandler.transferCredit.selector;
        selectors[4] = SequenceHandler.transfer.selector;
        selectors[5] = SequenceHandler.donate.selector;
        selectors[6] = SequenceHandler.forceEth.selector;
        selectors[7] = SequenceHandler.deposit.selector;
        selectors[8] = SequenceHandler.withdraw.selector;
        selectors[9] = SequenceHandler.setSpreads.selector;
        selectors[10] = SequenceHandler.setOpeningPrice.selector;
        selectors[11] = SequenceHandler.pause.selector;
        selectors[12] = SequenceHandler.probeStrangerCannotConfigure.selector;
        selectors[13] = SequenceHandler.probeTokenSlotIsFrozen.selector;
        selectors[14] = SequenceHandler.probeOverRedemptionAlwaysFails.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function _outside() internal view returns (uint256 total) {
        for (uint256 i; i < handler.actorCount(); ++i) {
            total += token.balanceOf(handler.actor(i));
        }
    }

    /// @dev The headline guarantee. While tokens are outstanding the floor is monotone within the
    ///      epoch; the opening price never goes below one the vault has sold at, and only sales
    ///      move that minimum.
    function invariant_floorNeverFallsBelowItsHighWater() public view {
        if (vault.backedSupply() != 0) {
            assertGe(vault.floorPrice(), handler.floorHighWater());
            assertGe(vault.floorPrice(), vault.minOpeningPrice(), "a live epoch is below the price it opened at");
        }
        assertGe(vault.openingPrice(), vault.minOpeningPrice());
        assertGt(vault.openingPrice(), 0);
        assertEq(vault.minOpeningPrice(), handler.openingSold(), "the ratchet is exactly the best opening sold at");
        assertLe(vault.minOpeningPrice(), vault.openingPrice());
    }

    /// @dev ETH only enters through buys, donations or force, and only leaves through redemptions
    ///      and escrow withdrawals. The balance is the reserve plus the escrow, the escrow is exactly
    ///      the sum of the holders' pending payouts, and between epochs the reserve is empty but for
    ///      ETH that was forced in without a call.
    function invariant_ethIsConserved() public view {
        assertEq(address(vault).balance, handler.ethIn() - handler.ethOut());
        assertLe(handler.ethOut(), handler.ethIn());
        uint256 pending;
        for (uint256 i; i < handler.actorCount(); ++i) {
            pending += vault.pendingPayout(handler.actor(i));
        }
        assertEq(vault.totalPendingPayouts(), pending, "escrow total differs from the sum of the escrows");
        assertEq(vault.pendingPayout(OWNER), 0, "the owner was paid an escrow");
        assertEq(vault.pendingPayout(address(handler)), 0);
        assertLe(pending, address(vault).balance, "escrow exceeds what is held");
        assertEq(vault.reserve(), address(vault).balance - pending);
        assertEq(OWNER.balance, 0, "the owner has no path to the reserve");
        assertEq(address(handler).balance, 0);
        if (vault.backedSupply() == 0) {
            assertEq(vault.reserve(), handler.strandedEth(), "ETH left behind that nobody can redeem");
        }
    }

    /// @dev Every token outside the vault was sold by it: what `backedSupply` counts plus what forced
    ///      redemptions left uncredited with their holders; the rest of the supply is inventory,
    ///      deposited minus withdrawn.
    function invariant_tokensAreConserved() public view {
        uint256 outside = _outside();
        assertEq(vault.backedSupply() + handler.tokensForced(), outside);
        assertEq(vault.backedSupply(), handler.tokensSold() - handler.tokensRedeemed() - handler.tokensForced());
        assertEq(vault.inventory(), INITIAL_INVENTORY + handler.inventoryIn() - handler.inventoryOut() - outside);
        assertEq(token.balanceOf(OWNER), handler.inventoryOut());
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(vault)) + outside + token.balanceOf(OWNER), token.totalSupply());
    }

    /// @dev Redemption credit is conserved: it always sums to the backed supply, and only the actors
    ///      who bought ever hold any.
    function invariant_creditsSumToTheBackedSupply() public view {
        uint256 credits;
        for (uint256 i; i < handler.actorCount(); ++i) {
            credits += vault.redeemable(handler.actor(i));
        }
        assertEq(credits, vault.backedSupply());
        assertEq(vault.redeemable(OWNER), 0, "withdrawn inventory earned the owner credit");
        assertEq(vault.redeemable(address(handler)), 0, "deposits earned credit");
        assertEq(vault.redeemable(address(vault)), 0);
    }

    /// @dev The reserve can pay every credit holder, is never empty while anyone is owed, and the
    ///      holder of all the credit is owed all of it.
    function invariant_reserveIsSolvent() public view {
        uint256 supply = vault.backedSupply();
        if (supply == 0) {
            assertEq(vault.minRemainingCredit(), 0);
            return;
        }
        uint256 reserve = vault.reserve();
        assertGt(reserve, 0);
        // The dust threshold is the credit worth MIN_POSITION_VALUE at the floor, rounded up, and a
        // whole position is always below or at it: nothing can be trapped between the two rules.
        assertEq(vault.minRemainingCredit(), vault.MIN_POSITION_VALUE().mulDiv(supply, reserve, Math.Rounding.Ceil));
        uint256 owed;
        for (uint256 i; i < handler.actorCount(); ++i) {
            address who = handler.actor(i);
            uint256 credit = vault.redeemable(who);
            uint256 quote = vault.quoteSellFor(who, credit);
            assertLe(quote, reserve);
            if (credit == supply) assertEq(quote, reserve);
            else assertLe(quote, credit.mulDiv(reserve, supply), "a partial redemption pays over the floor");
            owed += quote;
        }
        assertLe(owed, reserve);
    }

    /// @dev bid <= floor <= ask, with the spreads inside their caps; an empty vault quotes the opening
    ///      price on both sides.
    function invariant_pricesAreOrdered() public view {
        assertLe(vault.bidPrice(), vault.floorPrice());
        assertGe(vault.askPrice(), vault.floorPrice());
        assertLe(vault.buyPremiumBps(), vault.MAX_BUY_PREMIUM_BPS());
        assertLe(vault.sellFeeBps(), vault.MAX_SELL_FEE_BPS());
        if (vault.backedSupply() == 0) {
            assertEq(vault.floorPrice(), vault.openingPrice());
            assertEq(vault.askPrice(), vault.openingPrice());
            assertEq(vault.bidPrice(), 0);
        }
    }

    /// @dev Configuration that must never move once made.
    function invariant_configurationIsSticky() public view {
        assertEq(vault.token(), address(token));
        assertTrue(vault.spreadsSet());
        assertTrue(vault.isConfigured());
        assertEq(vault.owner(), OWNER);
    }
}
