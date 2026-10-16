// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
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
    uint256 public ethOut; // redemptions
    uint256 public tokensSold; // base units sold by the vault
    uint256 public tokensRedeemed; // base units bought back
    uint256 public inventoryIn; // deposited
    uint256 public inventoryOut; // withdrawn by the owner
    uint256 public floorHighWater; // highest floor seen while supply was outstanding
    uint256 public epochs; // full redemptions seen

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

    function _recordFloor() internal {
        if (vault.backedSupply() == 0) return;
        uint256 f = vault.floorPrice();
        if (f > floorHighWater) floorHighWater = f;
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
        vm.prank(who);
        uint256 out = vault.buy{value: amount}(quote);

        assertEq(out, quote, "buy: output differs from quote");
        assertEq(vault.reserve(), reserveBefore + amount, "buy: reserve");
        assertEq(vault.backedSupply(), supplyBefore + out, "buy: supply");
        assertGe(vault.floorPrice(), floorBefore, "buy: floor fell");
        assertGe(amount.mulDiv(1e18, out), floorBefore, "buy: paid under the floor");

        ethIn += amount;
        tokensSold += out;
        buys++;
        _recordFloor();
    }

    function sell(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        uint256 balance = token.balanceOf(who);
        if (balance == 0) {
            // A holder of nothing cannot redeem anything, within the backed supply or not.
            probes++;
            vm.prank(who);
            vm.expectRevert(RisingFloorVault.ZeroAmount.selector);
            vault.sell(0, 0);
            return;
        }
        amount = bound(amount, 1, balance);
        _redeem(who, amount);
    }

    /// @dev Redeems everything a holder can: the whole balance, capped at the backed supply. This is
    ///      the path that empties the vault and exercises the opening-price ratchet.
    function sellAll(uint256 seed) external {
        address who = _actor(seed);
        uint256 amount = Math.min(token.balanceOf(who), vault.backedSupply());
        if (amount == 0) return;
        _redeem(who, amount);
    }

    function _redeem(address who, uint256 amount) internal {
        uint256 supply = vault.backedSupply();
        vm.prank(who);
        token.approve(address(vault), amount);

        if (amount > supply) {
            probes++;
            vm.prank(who);
            vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.ExceedsBackedSupply.selector, supply, amount));
            vault.sell(amount, 0);
            return;
        }
        uint256 quote = vault.quoteSell(amount);
        if (quote == 0) {
            probes++;
            vm.prank(who);
            vm.expectRevert(RisingFloorVault.ZeroOutput.selector);
            vault.sell(amount, 0);
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
        // At or below the exact floor (reserve / supply), not the rounded view of it.
        assertLe(out, amount.mulDiv(reserveBefore, supply), "sell: paid over the floor");
        assertGe(vault.floorPrice(), floorBefore, "sell: floor fell");
        if (vault.backedSupply() == 0) {
            epochs++;
            assertGe(vault.minOpeningPrice(), floorBefore, "sell: ratchet below last floor");
            assertEq(vault.floorPrice(), vault.openingPrice(), "sell: empty vault quotes the opening price");
        }

        ethOut += out;
        tokensRedeemed += amount;
        sells++;
        _recordFloor();
    }

    /// @dev Tokens move freely between holders; whoever holds them may redeem.
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed >> 8);
        uint256 balance = token.balanceOf(from);
        if (balance == 0 || from == to) return;
        amount = bound(amount, 1, balance);
        vm.prank(from);
        token.transfer(to, amount);
    }

    function donate(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        amount = bound(amount, 1, 10 ether);
        vm.deal(who, who.balance + amount);
        uint256 floorBefore = vault.floorPrice();
        vm.prank(who);
        (bool ok,) = address(vault).call{value: amount}("");
        assertTrue(ok, "donation refused");
        assertGe(vault.floorPrice(), floorBefore, "donate: floor fell");
        ethIn += amount;
        _recordFloor();
    }

    /// @dev ETH that arrives without a call (selfdestruct, block rewards) is reserve too.
    function forceEth(uint256 amount) external {
        amount = bound(amount, 1, 1 ether);
        uint256 floorBefore = vault.floorPrice();
        vm.deal(address(vault), address(vault).balance + amount);
        assertGe(vault.floorPrice(), floorBefore, "forced ETH: floor fell");
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
            vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.OpeningPriceBelowFloor.selector, price, min));
            vault.setOpeningPrice(price);
            return;
        }
        vm.prank(owner);
        vault.setOpeningPrice(price);
        assertEq(vault.openingPrice(), price);
        assertEq(vault.floorPrice(), price, "empty vault quotes the opening price");
    }

    function pause(bool paused) external {
        vm.prank(owner);
        vault.setBuysPaused(paused);
        assertEq(vault.buysPaused(), paused);
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
        vm.stopPrank();
    }

    /// @dev The slot is filled: nobody, not even the owner, can change the token any more.
    function probeTokenSlotIsFrozen() external {
        probes++;
        vm.prank(owner);
        vm.expectRevert(RisingFloorVault.TokenAlreadySet.selector);
        vault.setToken(address(0xBEEF));
        vm.prank(owner);
        vm.expectRevert(RisingFloorVault.ZeroAddress.selector);
        vault.setToken(address(0));
    }

    /// @dev Redeeming one unit past the backed supply always fails, however many tokens exist.
    function probeOverRedemptionAlwaysFails(uint256 seed) external {
        address who = _actor(seed);
        uint256 supply = vault.backedSupply();
        probes++;
        token.mint(who, supply + 1);
        vm.startPrank(who);
        token.approve(address(vault), supply + 1);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.ExceedsBackedSupply.selector, supply, supply + 1));
        vault.sell(supply + 1, 0);
        vm.stopPrank();
        // The probe's unbacked tokens become inventory, so actors stay the only holders outside the vault.
        vm.prank(who);
        token.transfer(address(this), supply + 1);
        token.approve(address(vault), supply + 1);
        vault.depositInventory(supply + 1);
        inventoryIn += supply + 1;
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
        bytes4[] memory selectors = new bytes4[](16);
        selectors[0] = SequenceHandler.buy.selector;
        selectors[1] = SequenceHandler.buy.selector; // weighted: buys and sells are the core
        selectors[2] = SequenceHandler.sell.selector;
        selectors[3] = SequenceHandler.sell.selector;
        selectors[15] = SequenceHandler.sellAll.selector;
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

    /// @dev The headline guarantee. While tokens are outstanding the floor is monotone; once they
    ///      are all redeemed the vault reopens at or above the highest floor it reached, and the
    ///      owner cannot set it lower.
    function invariant_floorNeverFallsBelowItsHighWater() public view {
        assertGe(vault.floorPrice(), handler.floorHighWater());
        assertGe(vault.openingPrice(), vault.minOpeningPrice());
        assertGt(vault.openingPrice(), 0);
        // Between epochs the reopen minimum is the best floor any past holder was ever quoted.
        if (vault.backedSupply() == 0 && handler.epochs() > 0) {
            assertGe(vault.minOpeningPrice(), handler.floorHighWater());
        }
    }

    /// @dev ETH only enters through buys, donations or force, and only leaves through redemptions.
    function invariant_ethIsConserved() public view {
        assertEq(vault.reserve(), handler.ethIn() - handler.ethOut());
        assertLe(handler.ethOut(), handler.ethIn());
        assertEq(OWNER.balance, 0, "the owner has no path to the reserve");
        assertEq(address(handler).balance, 0);
    }

    /// @dev Every token outside the vault was sold by it and is what `backedSupply` counts; the rest
    ///      of the supply is inventory, deposited minus withdrawn.
    function invariant_tokensAreConserved() public view {
        uint256 outside = _outside();
        assertEq(vault.backedSupply(), outside);
        assertEq(vault.backedSupply(), handler.tokensSold() - handler.tokensRedeemed());
        assertEq(vault.inventory(), INITIAL_INVENTORY + handler.inventoryIn() - handler.inventoryOut() - outside);
        assertEq(token.balanceOf(OWNER), handler.inventoryOut());
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(vault)) + outside + token.balanceOf(OWNER), token.totalSupply());
    }

    /// @dev The reserve can pay every holder at the quoted bid, and is never empty while anyone is owed.
    function invariant_reserveIsSolvent() public view {
        uint256 supply = vault.backedSupply();
        if (supply == 0) return;
        assertGt(vault.reserve(), 0);
        assertLe(vault.quoteSell(supply), vault.reserve());
        uint256 owed;
        for (uint256 i; i < handler.actorCount(); ++i) {
            owed += vault.quoteSell(token.balanceOf(handler.actor(i)));
        }
        assertLe(owed, vault.reserve());
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
