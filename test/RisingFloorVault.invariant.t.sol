// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RisingFloorVault} from "../src/RisingFloorVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Drives the vault with random buys, sells, donations, deposits, withdrawals and spread
///      changes from a small set of actors, recording totals the invariants check against.
contract VaultHandler is Test {
    RisingFloorVault public immutable vault;
    MockERC20 public immutable token;
    address public immutable owner;

    address[] internal actors;
    uint256 public ethIn;
    uint256 public ethOut;
    uint256 public inventoryIn;
    uint256 public inventoryOut;
    uint256 public floorHighWater;
    uint256 public buys;
    uint256 public sells;
    uint256 public fullRedemptions;
    uint256 public forcedRedemptions;
    /// @dev Token base units force-redeemed holders kept: outside the vault but no longer credited.
    uint256 public uncreditedOutside;
    /// @dev Checks made inside handlers are recorded here, never asserted: with
    ///      `fail_on_revert = false` a reverting handler is silently discarded.
    uint256 public violations;

    constructor(RisingFloorVault vault_, MockERC20 token_, address owner_) {
        vault = vault_;
        token = token_;
        owner = owner_;
        actors.push(address(0xA1));
        actors.push(address(0xA2));
        actors.push(address(0xA3));
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev The high-water mark is an epoch's: while anything is outstanding the floor may only
    ///      rise; a full redemption pays everyone and the next epoch starts at the opening price.
    function _recordFloor() internal {
        if (vault.backedSupply() == 0) {
            floorHighWater = vault.openingPrice();
            return;
        }
        uint256 f = vault.floorPrice();
        if (f > floorHighWater) floorHighWater = f;
    }

    function buy(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        amount = bound(amount, 1, 50 ether);
        uint256 quote = vault.quoteBuy(amount);
        if (quote == 0 || quote > vault.inventory()) return;
        vm.deal(who, who.balance + amount);
        vm.prank(who);
        vault.buy{value: amount}(quote);
        ethIn += amount;
        buys++;
        _recordFloor();
    }

    function sell(uint256 seed, uint256 fraction) external {
        address who = _actor(seed);
        uint256 balance = token.balanceOf(who);
        uint256 credit = vault.redeemable(who);
        uint256 max = balance < credit ? balance : credit;
        if (max == 0) return;
        uint256 amount = bound(fraction, 1, max);
        uint256 quote = vault.quoteSellFor(who, amount);
        if (quote == 0) return;
        uint256 remaining = credit - amount;
        if (remaining != 0 && remaining < vault.minRemainingCredit()) amount = credit; // no dust left behind
        if (amount > balance) return;
        quote = vault.quoteSellFor(who, amount);
        vm.startPrank(who);
        token.approve(address(vault), amount);
        uint256 out = vault.sell(amount, quote);
        vm.stopPrank();
        ethOut += out;
        sells++;
        if (vault.backedSupply() == 0) fullRedemptions++;
        _recordFloor();
    }

    /// @dev Credit may move without tokens and vice versa; redemption needs both.
    function transferCredit(uint256 seedFrom, uint256 seedTo, uint256 amount, bool withTokens) external {
        address from = _actor(seedFrom);
        address to = _actor(seedTo + 1);
        uint256 credit = vault.redeemable(from);
        if (credit == 0) return;
        amount = bound(amount, 1, credit);
        uint256 min = vault.minRemainingCredit();
        if (credit - amount != 0 && credit - amount < min) amount = credit;
        if (vault.redeemable(to) + amount < min) return;
        vm.startPrank(from);
        vault.transferRedeemable(to, amount);
        uint256 balance = token.balanceOf(from);
        if (withTokens && balance != 0) token.transfer(to, amount < balance ? amount : balance);
        vm.stopPrank();
    }

    function donate(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        amount = bound(amount, 1, 10 ether);
        vm.deal(who, who.balance + amount);
        bool accepted = vault.backedSupply() != 0 && vault.reserve() >= vault.MIN_POSITION_VALUE();
        vm.prank(who);
        (bool ok,) = address(vault).call{value: amount}("");
        // Donations are accepted exactly while something is outstanding and the reserve is not dust.
        if (ok != accepted) violations++;
        if (!ok) return;
        ethIn += amount;
        _recordFloor();
    }

    /// @dev The owner ends an actor's position at the floor; the others' floor must not fall and
    ///      the payout waits in escrow for the holder.
    function forceRedeem(uint256 seed) external {
        address who = _actor(seed);
        uint256 credit = vault.redeemable(who);
        if (credit == 0) return;
        uint256 supply = vault.backedSupply();
        uint256 reserve = vault.reserve();
        uint256 floorBefore = vault.floorPrice();
        uint256 pendingBefore = vault.pendingPayout(who);
        address[] memory holders = new address[](1);
        holders[0] = who;
        vm.prank(owner);
        vault.forceRedeem(holders);
        uint256 payout = vault.pendingPayout(who) - pendingBefore;
        if (credit == supply ? payout != reserve : payout > credit * floorBefore / 1e18 + credit / 1e18 + 1) {
            violations++;
        }
        if (vault.backedSupply() != 0 && vault.floorPrice() < floorBefore) violations++;
        if (vault.redeemable(who) != 0) violations++;
        uncreditedOutside += credit;
        forcedRedemptions++;
        if (vault.backedSupply() == 0) fullRedemptions++;
        _recordFloor();
    }

    function withdrawPayout(uint256 seed) external {
        address who = _actor(seed);
        uint256 pending = vault.pendingPayout(who);
        if (pending == 0) return;
        vm.prank(who);
        uint256 out = vault.withdrawPayout(who);
        if (out != pending || vault.pendingPayout(who) != 0) violations++;
        ethOut += out;
    }

    function deposit(uint256 amount) external {
        amount = bound(amount, 1, 1_000_000e18);
        token.mint(address(this), amount);
        token.approve(address(vault), amount);
        vault.depositInventory(amount);
        inventoryIn += amount;
    }

    /// @dev The owner moves inventory out and then tries to redeem it: that must always fail, so
    ///      withdrawing inventory is never a route to the reserve.
    function withdraw(uint256 amount) external {
        uint256 available = vault.inventory();
        if (available == 0) return;
        amount = bound(amount, 1, available);
        vm.startPrank(owner);
        vault.withdrawInventory(owner, amount);
        inventoryOut += amount;
        token.approve(address(vault), amount);
        try vault.sell(amount, 0) {
            violations++; // the owner redeemed withdrawn inventory
        } catch (bytes memory err) {
            if (bytes4(err) != RisingFloorVault.ExceedsRedeemable.selector) violations++;
        }
        vm.stopPrank();
    }

    function setSpreads(uint256 premium, uint256 fee) external {
        premium = bound(premium, 0, vault.MAX_BUY_PREMIUM_BPS());
        fee = bound(fee, 0, vault.MAX_SELL_FEE_BPS());
        vm.prank(owner);
        vault.setSpreads(premium, fee);
    }

    function pause(bool paused) external {
        vm.prank(owner);
        vault.setBuysPaused(paused);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actor(uint256 i) external view returns (address) {
        return actors[i];
    }
}

contract RisingFloorVaultInvariantTest is Test {
    address internal constant OWNER = 0xD3f26A6Be348440110161dFD5748E7DE7B08cf69;
    uint256 internal constant OPENING = 0.001 ether;

    RisingFloorVault internal vault;
    MockERC20 internal token;
    VaultHandler internal handler;

    function setUp() public {
        vault = new RisingFloorVault(OWNER);
        token = new MockERC20();
        vm.startPrank(OWNER);
        vault.setToken(address(token));
        vault.setSpreads(300, 100);
        vault.setOpeningPrice(OPENING);
        vm.stopPrank();

        handler = new VaultHandler(vault, token, OWNER);
        token.mint(address(handler), 10_000_000e18);
        vm.prank(address(handler));
        token.approve(address(vault), type(uint256).max);
        vm.prank(address(handler));
        vault.depositInventory(10_000_000e18);

        targetContract(address(handler));
    }

    /// @dev The headline guarantee: within an epoch the quoted floor never goes below any floor seen
    ///      before, and the opening price never goes below one the vault sold at.
    function invariant_floorNeverFalls() public view {
        assertGe(vault.floorPrice(), handler.floorHighWater());
        assertGe(vault.openingPrice(), OPENING);
        assertGe(vault.openingPrice(), vault.minOpeningPrice());
        assertLe(vault.minOpeningPrice(), OPENING); // only the price actually sold at is recorded
    }

    /// @dev Checks the handlers made along the way: donations refused exactly while nothing is
    ///      outstanding, and the owner's withdrawn inventory never redeemable.
    function invariant_handlerChecksHold() public view {
        assertEq(handler.violations(), 0);
    }

    /// @dev ETH is conserved: the balance is exactly what came in minus what left, the escrow is
    ///      exactly the sum of the holders' pending payouts, and the reserve is the rest.
    function invariant_ethConservation() public view {
        assertEq(address(vault).balance, handler.ethIn() - handler.ethOut());
        uint256 pending;
        for (uint256 i; i < handler.actorCount(); ++i) {
            pending += vault.pendingPayout(handler.actor(i));
        }
        assertEq(vault.totalPendingPayouts(), pending);
        assertEq(vault.pendingPayout(OWNER), 0);
        assertEq(vault.reserve(), address(vault).balance - pending);
    }

    /// @dev Every token outside the vault was sold by it: the backed supply plus what forced
    ///      redemptions left uncredited is exactly the sum of actor balances, and the vault's own
    ///      balance is the rest.
    function invariant_tokenConservation() public view {
        uint256 outside;
        for (uint256 i; i < handler.actorCount(); ++i) {
            outside += token.balanceOf(handler.actor(i));
        }
        assertEq(vault.backedSupply() + handler.uncreditedOutside(), outside);
        assertEq(token.balanceOf(address(vault)) + outside + token.balanceOf(OWNER), token.totalSupply());
        assertEq(token.balanceOf(OWNER), handler.inventoryOut());
    }

    /// @dev Redemption credits always sum to the backed supply, and the owner never holds any.
    function invariant_creditsSumToBackedSupply() public view {
        uint256 credits;
        for (uint256 i; i < handler.actorCount(); ++i) {
            credits += vault.redeemable(handler.actor(i));
        }
        assertEq(credits, vault.backedSupply());
        assertEq(vault.redeemable(OWNER), 0);
    }

    /// @dev The reserve pays every backed token: redeeming the whole supply takes exactly the
    ///      reserve, and nothing is left behind once nothing is outstanding.
    function invariant_reserveCoversRedemptions() public view {
        uint256 supply = vault.backedSupply();
        if (supply == 0) {
            assertEq(vault.reserve(), 0);
            assertEq(vault.bidPrice(), 0);
            return;
        }
        uint256 reserve = vault.reserve();
        assertGt(reserve, 0);
        uint256 total;
        for (uint256 i; i < handler.actorCount(); ++i) {
            address who = handler.actor(i);
            uint256 credit = vault.redeemable(who);
            if (credit == 0) continue;
            uint256 quote = vault.quoteSellFor(who, credit);
            assertLe(quote, reserve);
            if (credit == supply) assertEq(quote, reserve);
            total += quote;
        }
        assertLe(total, reserve);
    }
}
