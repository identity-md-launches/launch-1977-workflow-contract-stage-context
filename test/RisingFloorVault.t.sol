// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {RisingFloorVault} from "../src/RisingFloorVault.sol";
import {MockERC20, FeeOnTransferToken} from "./mocks/MockERC20.sol";
import {ReentrantSeller, RejectingReceiver} from "./mocks/Actors.sol";

contract RisingFloorVaultTest is Test {
    using Math for uint256;

    /// @dev The launch owner named by the brief. The factory (deployer) keeps no rights.
    address internal constant OWNER = 0xD3f26A6Be348440110161dFD5748E7DE7B08cf69;
    address internal constant DEPLOYER = address(0xFAC7047);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant OPENING = 0.001 ether; // 0.001 ETH per whole token
    uint256 internal constant PREMIUM = 500; // 5%
    uint256 internal constant FEE = 100; // 1%
    uint256 internal constant INVENTORY = 1_000_000e18;

    RisingFloorVault internal vault;
    MockERC20 internal token;

    event TokenSet(address indexed token);
    event OpeningPriceSet(uint256 price);
    event SpreadsSet(uint256 buyPremiumBps, uint256 sellFeeBps);
    event BuysPausedSet(bool paused);
    event Bought(address indexed buyer, uint256 ethIn, uint256 tokensOut, uint256 floorAfter);
    event Sold(address indexed seller, uint256 tokensIn, uint256 ethOut, uint256 floorAfter);
    event ReserveDonated(address indexed from, uint256 amount);
    event InventoryDeposited(address indexed from, uint256 amount);
    event InventoryWithdrawn(address indexed to, uint256 amount);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

    function setUp() public {
        vm.prank(DEPLOYER);
        vault = new RisingFloorVault(OWNER);
        token = new MockERC20();
        vm.deal(ALICE, 1_000 ether);
        vm.deal(BOB, 1_000 ether);
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Full post-launch configuration as the README's "After launch" section describes it.
    function _configure() internal {
        vm.startPrank(OWNER);
        vault.setToken(address(token));
        vault.setSpreads(PREMIUM, FEE);
        vault.setOpeningPrice(OPENING);
        vm.stopPrank();
        token.mint(address(this), INVENTORY);
        token.approve(address(vault), INVENTORY);
        vault.depositInventory(INVENTORY);
    }

    function _buy(address who, uint256 ethIn) internal returns (uint256 out) {
        vm.prank(who);
        out = vault.buy{value: ethIn}(0);
    }

    function _sell(address who, uint256 amount) internal returns (uint256 out) {
        vm.startPrank(who);
        token.approve(address(vault), amount);
        out = vault.sell(amount, 0);
        vm.stopPrank();
    }

    function _expectOnlyOwner(address caller) internal {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
    }

    // ------------------------------------------------------------------ construction

    function test_constructor_ownerIsTheNamedOwnerNotTheDeployer() public view {
        assertEq(vault.owner(), OWNER);
        assertTrue(vault.owner() != DEPLOYER);
        assertEq(vault.pendingOwner(), address(0));
    }

    function test_constructor_rejectsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new RisingFloorVault(address(0));
    }

    function test_initialState_everythingUnsetAndDisabled() public view {
        assertEq(vault.token(), address(0));
        assertEq(vault.openingPrice(), 0);
        assertEq(vault.minOpeningPrice(), 0);
        assertFalse(vault.spreadsSet());
        assertFalse(vault.buysPaused());
        assertFalse(vault.isConfigured());
        assertEq(vault.backedSupply(), 0);
        assertEq(vault.reserve(), 0);
        assertEq(vault.inventory(), 0);
        assertEq(vault.floorPrice(), 0);
        assertEq(vault.askPrice(), 0);
        assertEq(vault.bidPrice(), 0);
        assertEq(vault.quoteBuy(1 ether), 0);
        assertEq(vault.quoteSell(1e18), 0);
    }

    function test_constants_areSane() public view {
        assertEq(vault.BPS(), BPS);
        assertEq(vault.WAD(), WAD);
        assertEq(vault.MAX_BUY_PREMIUM_BPS(), 2_000);
        assertEq(vault.MAX_SELL_FEE_BPS(), 1_000);
    }

    // ------------------------------------------------------------------ setToken slot

    function test_setToken_onlyOwner() public {
        _expectOnlyOwner(DEPLOYER);
        vm.prank(DEPLOYER);
        vault.setToken(address(token));

        _expectOnlyOwner(ALICE);
        vm.prank(ALICE);
        vault.setToken(address(token));
    }

    function test_setToken_rejectsZeroAddress() public {
        vm.prank(OWNER);
        vm.expectRevert(RisingFloorVault.ZeroAddress.selector);
        vault.setToken(address(0));
    }

    function test_setToken_storesAndEmits() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit TokenSet(address(token));
        vm.prank(OWNER);
        vault.setToken(address(token));
        assertEq(vault.token(), address(token));
    }

    function test_setToken_onlyOnce() public {
        vm.startPrank(OWNER);
        vault.setToken(address(token));
        MockERC20 other = new MockERC20();
        vm.expectRevert(RisingFloorVault.TokenAlreadySet.selector);
        vault.setToken(address(other));
        vm.expectRevert(RisingFloorVault.TokenAlreadySet.selector);
        vault.setToken(address(token));
        vm.stopPrank();
        assertEq(vault.token(), address(token));
    }

    function test_tokenFeatures_disabledUntilTokenIsSet() public {
        vm.startPrank(OWNER);
        vault.setSpreads(PREMIUM, FEE);
        vault.setOpeningPrice(OPENING);
        vm.stopPrank();

        vm.expectRevert(RisingFloorVault.TokenNotSet.selector);
        vault.depositInventory(1e18);

        vm.prank(ALICE);
        vm.expectRevert(RisingFloorVault.TokenNotSet.selector);
        vault.buy{value: 1 ether}(0);

        vm.prank(ALICE);
        vm.expectRevert(RisingFloorVault.TokenNotSet.selector);
        vault.sell(1e18, 0);

        vm.prank(OWNER);
        vm.expectRevert(RisingFloorVault.TokenNotSet.selector);
        vault.withdrawInventory(OWNER, 1e18);

        assertEq(vault.inventory(), 0);
        assertFalse(vault.isConfigured());
    }

    // ------------------------------------------------------------------ opening price

    function test_setOpeningPrice_onlyOwner() public {
        _expectOnlyOwner(ALICE);
        vm.prank(ALICE);
        vault.setOpeningPrice(OPENING);
    }

    function test_setOpeningPrice_rejectsZero() public {
        vm.prank(OWNER);
        vm.expectRevert(RisingFloorVault.ZeroAmount.selector);
        vault.setOpeningPrice(0);
    }

    function test_setOpeningPrice_storesAndEmits() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit OpeningPriceSet(OPENING);
        vm.prank(OWNER);
        vault.setOpeningPrice(OPENING);
        assertEq(vault.openingPrice(), OPENING);
        assertEq(vault.floorPrice(), OPENING);
        assertEq(vault.askPrice(), OPENING);
    }

    function test_setOpeningPrice_canBeChangedWhileNothingIsOutstanding() public {
        vm.startPrank(OWNER);
        vault.setOpeningPrice(OPENING);
        vault.setOpeningPrice(OPENING / 2);
        vault.setOpeningPrice(OPENING * 3);
        vm.stopPrank();
        assertEq(vault.openingPrice(), OPENING * 3);
    }

    function test_setOpeningPrice_rejectedWhileSupplyIsOutstanding() public {
        _configure();
        _buy(ALICE, 1 ether);
        uint256 supply = vault.backedSupply();
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.SupplyOutstanding.selector, supply));
        vault.setOpeningPrice(OPENING * 2);
    }

    function test_buy_revertsUntilOpeningPriceIsSet() public {
        vm.startPrank(OWNER);
        vault.setToken(address(token));
        vault.setSpreads(PREMIUM, FEE);
        vm.stopPrank();
        vm.prank(ALICE);
        vm.expectRevert(RisingFloorVault.OpeningPriceNotSet.selector);
        vault.buy{value: 1 ether}(0);
    }

    // ------------------------------------------------------------------ spreads

    function test_setSpreads_onlyOwner() public {
        _expectOnlyOwner(ALICE);
        vm.prank(ALICE);
        vault.setSpreads(PREMIUM, FEE);
    }

    function test_setSpreads_enforcesCaps() public {
        vm.startPrank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.PremiumTooHigh.selector, 2_001, 2_000));
        vault.setSpreads(2_001, 0);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.FeeTooHigh.selector, 1_001, 1_000));
        vault.setSpreads(0, 1_001);
        // The caps themselves are allowed.
        vault.setSpreads(2_000, 1_000);
        vm.stopPrank();
        assertEq(vault.buyPremiumBps(), 2_000);
        assertEq(vault.sellFeeBps(), 1_000);
    }

    function test_setSpreads_zeroIsAValidConfiguration() public {
        assertFalse(vault.spreadsSet());
        vm.expectEmit(false, false, false, true, address(vault));
        emit SpreadsSet(0, 0);
        vm.prank(OWNER);
        vault.setSpreads(0, 0);
        assertTrue(vault.spreadsSet());
    }

    function test_buy_revertsUntilSpreadsAreSet() public {
        vm.startPrank(OWNER);
        vault.setToken(address(token));
        vault.setOpeningPrice(OPENING);
        vm.stopPrank();
        vm.prank(ALICE);
        vm.expectRevert(RisingFloorVault.SpreadsNotSet.selector);
        vault.buy{value: 1 ether}(0);
    }

    function test_isConfigured_trueOnlyWhenEverythingIsSet() public {
        vm.startPrank(OWNER);
        vault.setToken(address(token));
        assertFalse(vault.isConfigured());
        vault.setSpreads(PREMIUM, FEE);
        assertFalse(vault.isConfigured());
        vault.setOpeningPrice(OPENING);
        assertTrue(vault.isConfigured());
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ pause

    function test_setBuysPaused_onlyOwner() public {
        _expectOnlyOwner(ALICE);
        vm.prank(ALICE);
        vault.setBuysPaused(true);
    }

    function test_pause_blocksBuysButNeverRedemptions() public {
        _configure();
        uint256 bought = _buy(ALICE, 1 ether);

        vm.expectEmit(false, false, false, true, address(vault));
        emit BuysPausedSet(true);
        vm.prank(OWNER);
        vault.setBuysPaused(true);
        assertTrue(vault.buysPaused());

        vm.prank(BOB);
        vm.expectRevert(RisingFloorVault.BuysArePaused.selector);
        vault.buy{value: 1 ether}(0);

        uint256 ethOut = _sell(ALICE, bought);
        assertGt(ethOut, 0);

        vm.prank(OWNER);
        vault.setBuysPaused(false);
        _buy(BOB, 1 ether);
    }

    // ------------------------------------------------------------------ inventory

    function test_depositInventory_anyonePullsExactAmountAndEmits() public {
        vm.prank(OWNER);
        vault.setToken(address(token));
        token.mint(ALICE, 10e18);
        vm.startPrank(ALICE);
        token.approve(address(vault), 10e18);
        vm.expectEmit(true, false, false, true, address(vault));
        emit InventoryDeposited(ALICE, 10e18);
        vault.depositInventory(10e18);
        vm.stopPrank();
        assertEq(vault.inventory(), 10e18);
        assertEq(token.balanceOf(ALICE), 0);
        // Inventory is not backing: no floor, no supply.
        assertEq(vault.backedSupply(), 0);
    }

    function test_depositInventory_rejectsZero() public {
        vm.prank(OWNER);
        vault.setToken(address(token));
        vm.expectRevert(RisingFloorVault.ZeroAmount.selector);
        vault.depositInventory(0);
    }

    function test_depositInventory_rejectsFeeOnTransferToken() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        vm.prank(DEPLOYER);
        RisingFloorVault v2 = new RisingFloorVault(OWNER);
        vm.prank(OWNER);
        v2.setToken(address(feeToken));
        feeToken.mint(address(this), 100e18);
        feeToken.approve(address(v2), 100e18);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.NonStandardTokenTransfer.selector, 100e18, 99e18));
        v2.depositInventory(100e18);
    }

    function test_withdrawInventory_onlyOwner() public {
        _configure();
        _expectOnlyOwner(DEPLOYER);
        vm.prank(DEPLOYER);
        vault.withdrawInventory(DEPLOYER, 1e18);
    }

    function test_withdrawInventory_validatesInputs() public {
        _configure();
        vm.startPrank(OWNER);
        vm.expectRevert(RisingFloorVault.ZeroAddress.selector);
        vault.withdrawInventory(address(0), 1e18);
        vm.expectRevert(RisingFloorVault.ZeroAmount.selector);
        vault.withdrawInventory(OWNER, 0);
        vm.stopPrank();
    }

    function test_withdrawInventory_movesTokensWithoutTouchingTheFloor() public {
        _configure();
        _buy(ALICE, 2 ether);
        uint256 floorBefore = vault.floorPrice();
        uint256 reserveBefore = vault.reserve();
        uint256 inventoryBefore = vault.inventory();

        vm.expectEmit(true, false, false, true, address(vault));
        emit InventoryWithdrawn(BOB, 5e18);
        vm.prank(OWNER);
        vault.withdrawInventory(BOB, 5e18);

        assertEq(token.balanceOf(BOB), 5e18);
        assertEq(vault.inventory(), inventoryBefore - 5e18);
        assertEq(vault.floorPrice(), floorBefore);
        assertEq(vault.reserve(), reserveBefore);
    }

    function test_rescueERC20_onlyOwnerAndNeverTheVaultToken() public {
        _configure();
        MockERC20 stray = new MockERC20();
        stray.mint(address(vault), 7e18);

        _expectOnlyOwner(ALICE);
        vm.prank(ALICE);
        vault.rescueERC20(IERC20(address(stray)), ALICE, 7e18);

        vm.startPrank(OWNER);
        vm.expectRevert(RisingFloorVault.UseWithdrawInventory.selector);
        vault.rescueERC20(IERC20(address(token)), OWNER, 1e18);
        vm.expectRevert(RisingFloorVault.ZeroAddress.selector);
        vault.rescueERC20(IERC20(address(stray)), address(0), 7e18);
        vm.expectRevert(RisingFloorVault.ZeroAmount.selector);
        vault.rescueERC20(IERC20(address(stray)), OWNER, 0);

        vm.expectEmit(true, true, false, true, address(vault));
        emit ERC20Rescued(address(stray), BOB, 7e18);
        vault.rescueERC20(IERC20(address(stray)), BOB, 7e18);
        vm.stopPrank();
        assertEq(stray.balanceOf(BOB), 7e18);
    }

    // ------------------------------------------------------------------ buy

    function test_buy_firstBuyAtOpeningPrice() public {
        _configure();
        uint256 ethIn = 1 ether;
        uint256 expected = ethIn * WAD / OPENING; // 1000 tokens
        assertEq(expected, 1_000e18);
        assertEq(vault.quoteBuy(ethIn), expected);

        vm.expectEmit(true, false, false, true, address(vault));
        emit Bought(ALICE, ethIn, expected, OPENING);
        uint256 out = _buy(ALICE, ethIn);

        assertEq(out, expected);
        assertEq(token.balanceOf(ALICE), expected);
        assertEq(vault.backedSupply(), expected);
        assertEq(vault.reserve(), ethIn);
        assertEq(vault.inventory(), INVENTORY - expected);
        assertEq(vault.floorPrice(), OPENING);
        assertEq(vault.askPrice(), OPENING * (BPS + PREMIUM) / BPS);
        assertEq(vault.bidPrice(), OPENING * (BPS - FEE) / BPS);
    }

    function test_buy_secondBuyPaysPremiumAndRaisesFloor() public {
        _configure();
        _buy(ALICE, 1 ether);
        uint256 floorBefore = vault.floorPrice();
        uint256 ask = vault.askPrice();
        assertEq(ask, floorBefore * (BPS + PREMIUM) / BPS);

        uint256 ethIn = 3 ether;
        uint256 expected = (ethIn * BPS).mulDiv(vault.backedSupply(), vault.reserve() * (BPS + PREMIUM));
        assertEq(vault.quoteBuy(ethIn), expected);
        // Buyer pays roughly the ask (rounding is in the vault's favour).
        assertApproxEqRel(ethIn * WAD / expected, ask, 1e12);

        uint256 out = _buy(BOB, ethIn);
        assertEq(out, expected);
        assertGt(vault.floorPrice(), floorBefore);
        assertEq(vault.reserve(), 4 ether);
        assertEq(vault.backedSupply(), 1_000e18 + expected);
    }

    function test_buy_rejectsZeroValue() public {
        _configure();
        vm.prank(ALICE);
        vm.expectRevert(RisingFloorVault.ZeroAmount.selector);
        vault.buy{value: 0}(0);
    }

    function test_buy_rejectsDustThatBuysNothing() public {
        vm.startPrank(OWNER);
        vault.setToken(address(token));
        vault.setSpreads(0, 0);
        vault.setOpeningPrice(2 * WAD); // 2 wei per base unit: 1 wei buys 0
        vm.stopPrank();
        token.mint(address(vault), 1e18);
        vm.prank(ALICE);
        vm.expectRevert(RisingFloorVault.ZeroOutput.selector);
        vault.buy{value: 1}(0);
    }

    function test_buy_enforcesMinTokensOut() public {
        _configure();
        uint256 quote = vault.quoteBuy(1 ether);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.SlippageExceeded.selector, quote, quote + 1));
        vault.buy{value: 1 ether}(quote + 1);

        vm.prank(ALICE);
        vault.buy{value: 1 ether}(quote);
    }

    function test_buy_rejectsWhenInventoryIsShort() public {
        _configure();
        // Inventory is 1,000,000 tokens at 0.001 ETH each = 1,000 ETH; 1,001 ETH overshoots.
        uint256 ethIn = 1_001 ether;
        vm.deal(ALICE, ethIn);
        uint256 wanted = ethIn * WAD / OPENING;
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.InsufficientInventory.selector, INVENTORY, wanted));
        vault.buy{value: ethIn}(0);
        // Nothing moved on the revert.
        assertEq(vault.reserve(), 0);
        assertEq(vault.backedSupply(), 0);
    }

    function test_buy_withoutInventoryReverts() public {
        vm.startPrank(OWNER);
        vault.setToken(address(token));
        vault.setSpreads(PREMIUM, FEE);
        vault.setOpeningPrice(OPENING);
        vm.stopPrank();
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.InsufficientInventory.selector, 0, 1_000e18));
        vault.buy{value: 1 ether}(0);
    }

    // ------------------------------------------------------------------ sell

    function test_sell_paysFloorMinusFeeAndReturnsTokensToInventory() public {
        _configure();
        uint256 bought = _buy(ALICE, 1 ether); // 1000 tokens, floor 0.001
        uint256 amount = 400e18;
        uint256 expected = (amount * (BPS - FEE)).mulDiv(vault.reserve(), vault.backedSupply() * BPS);
        assertEq(expected, 0.396 ether);
        assertEq(vault.quoteSell(amount), expected);

        uint256 inventoryBefore = vault.inventory();
        uint256 aliceEthBefore = ALICE.balance;
        uint256 floorBefore = vault.floorPrice();

        uint256 floorAfter = (1 ether - expected) * WAD / (bought - amount);
        vm.startPrank(ALICE);
        token.approve(address(vault), amount);
        vm.expectEmit(true, false, false, true, address(vault));
        emit Sold(ALICE, amount, expected, floorAfter);
        uint256 out = vault.sell(amount, 0);
        vm.stopPrank();

        assertEq(out, expected);
        assertEq(ALICE.balance, aliceEthBefore + expected);
        assertEq(vault.reserve(), 1 ether - expected);
        assertEq(vault.backedSupply(), bought - amount);
        assertEq(vault.inventory(), inventoryBefore + amount);
        assertEq(token.balanceOf(ALICE), bought - amount);
        assertGt(vault.floorPrice(), floorBefore); // the fee stays with the remaining holders
        assertEq(vault.floorPrice(), floorAfter);
    }

    function test_sell_withZeroFeeKeepsFloorExactlyFlat() public {
        vm.startPrank(OWNER);
        vault.setToken(address(token));
        vault.setSpreads(0, 0);
        vault.setOpeningPrice(OPENING);
        vm.stopPrank();
        token.mint(address(vault), INVENTORY);
        uint256 bought = _buy(ALICE, 1 ether);
        uint256 floorBefore = vault.floorPrice();
        uint256 out = _sell(ALICE, bought / 2);
        assertEq(out, 0.5 ether);
        assertEq(vault.floorPrice(), floorBefore);
    }

    function test_sell_rejectsZeroAmount() public {
        _configure();
        _buy(ALICE, 1 ether);
        vm.prank(ALICE);
        vm.expectRevert(RisingFloorVault.ZeroAmount.selector);
        vault.sell(0, 0);
    }

    function test_sell_rejectsMoreThanTheBackedSupply() public {
        _configure();
        uint256 bought = _buy(ALICE, 1 ether);
        // Bob holds tokens that never passed through the vault: they are not backed.
        token.mint(BOB, bought);
        vm.startPrank(BOB);
        token.approve(address(vault), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.ExceedsBackedSupply.selector, bought, bought + 1));
        vault.sell(bought + 1, 0);
        vm.stopPrank();
    }

    function test_sell_revertsBeforeAnythingWasSold() public {
        _configure();
        token.mint(ALICE, 1e18);
        vm.startPrank(ALICE);
        token.approve(address(vault), 1e18);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.ExceedsBackedSupply.selector, 0, 1e18));
        vault.sell(1e18, 0);
        vm.stopPrank();
    }

    function test_sell_enforcesMinEthOut() public {
        _configure();
        uint256 bought = _buy(ALICE, 1 ether);
        uint256 quote = vault.quoteSell(bought);
        vm.startPrank(ALICE);
        token.approve(address(vault), bought);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.SlippageExceeded.selector, quote, quote + 1));
        vault.sell(bought, quote + 1);
        vault.sell(bought, quote);
        vm.stopPrank();
    }

    function test_sell_rejectsDustThatPaysNothing() public {
        vm.startPrank(OWNER);
        vault.setToken(address(token));
        vault.setSpreads(0, 0);
        vault.setOpeningPrice(1); // 1 wei per 1e18 base units
        vm.stopPrank();
        token.mint(address(vault), INVENTORY);
        _buy(ALICE, 1); // 1 wei buys 1e18 base units
        vm.startPrank(ALICE);
        token.approve(address(vault), 1);
        vm.expectRevert(RisingFloorVault.ZeroOutput.selector);
        vault.sell(1, 0);
        vm.stopPrank();
    }

    function test_sell_revertsCleanlyWhenReceiverRejectsEth() public {
        _configure();
        RejectingReceiver receiver = new RejectingReceiver(vault, IERC20(address(token)));
        vm.deal(address(receiver), 1 ether);
        vm.prank(address(receiver));
        uint256 bought = vault.buy{value: 1 ether}(0);

        uint256 reserveBefore = vault.reserve();
        uint256 supplyBefore = vault.backedSupply();
        vm.expectRevert(RisingFloorVault.EthTransferFailed.selector);
        receiver.sell(bought);
        assertEq(vault.reserve(), reserveBefore);
        assertEq(vault.backedSupply(), supplyBefore);
        assertEq(token.balanceOf(address(receiver)), bought);
    }

    function test_sell_everythingRatchetsTheOpeningPrice() public {
        _configure();
        uint256 aliceTokens = _buy(ALICE, 1 ether);
        uint256 bobTokens = _buy(BOB, 1 ether); // pays the premium: floor rises above OPENING
        uint256 floorBefore = vault.floorPrice();
        assertGt(floorBefore, OPENING);

        _sell(ALICE, aliceTokens);
        uint256 floorMid = vault.floorPrice();
        assertGe(floorMid, floorBefore);

        vm.startPrank(BOB);
        token.approve(address(vault), bobTokens);
        vm.expectEmit(false, false, false, true, address(vault));
        emit OpeningPriceSet(floorMid);
        vault.sell(bobTokens, 0);
        vm.stopPrank();

        assertEq(vault.backedSupply(), 0);
        assertEq(vault.openingPrice(), floorMid);
        assertEq(vault.minOpeningPrice(), floorMid);
        assertEq(vault.floorPrice(), floorMid);
        // Fees stayed behind as reserve for the next buyers.
        assertGt(vault.reserve(), 0);

        // The owner may not reopen below the reached floor, but may go higher.
        vm.startPrank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(RisingFloorVault.OpeningPriceBelowFloor.selector, floorMid - 1, floorMid)
        );
        vault.setOpeningPrice(floorMid - 1);
        vault.setOpeningPrice(floorMid + 1);
        vm.stopPrank();
        assertEq(vault.openingPrice(), floorMid + 1);

        // The next buyer pays at least that and the leftover reserve lifts the floor further.
        uint256 out = _buy(ALICE, 1 ether);
        assertEq(out, 1 ether * WAD / (floorMid + 1));
        assertGt(vault.floorPrice(), floorMid + 1);
    }

    // ------------------------------------------------------------------ donations

    function test_receive_donationRaisesFloorAndEmits() public {
        _configure();
        _buy(ALICE, 1 ether);
        uint256 floorBefore = vault.floorPrice();

        vm.expectEmit(true, false, false, true, address(vault));
        emit ReserveDonated(BOB, 0.5 ether);
        vm.prank(BOB);
        (bool ok,) = address(vault).call{value: 0.5 ether}("");
        assertTrue(ok);

        assertEq(vault.reserve(), 1.5 ether);
        assertEq(vault.floorPrice(), floorBefore * 15 / 10);
        // Donated ETH is redeemable by holders, never by the owner.
        assertEq(vault.quoteSell(vault.backedSupply()), 1.5 ether * (BPS - FEE) / BPS);
    }

    function test_noFunctionLetsTheOwnerWithdrawEth() public {
        _configure();
        _buy(ALICE, 5 ether);
        // Every owner function either moves tokens or sets configuration; the reserve is untouched.
        vm.startPrank(OWNER);
        vault.setBuysPaused(true);
        vault.setBuysPaused(false);
        vault.setSpreads(0, 0);
        vault.withdrawInventory(OWNER, 1e18);
        vm.stopPrank();
        assertEq(vault.reserve(), 5 ether);
        assertEq(OWNER.balance, 0);
    }

    // ------------------------------------------------------------------ reentrancy

    function test_reentrancy_sellCannotReenterSell() public {
        _reentrancyCase(0);
    }

    function test_reentrancy_sellCannotReenterBuy() public {
        _reentrancyCase(1);
    }

    function test_reentrancy_sellCannotReenterDeposit() public {
        _reentrancyCase(2);
    }

    function _reentrancyCase(uint8 mode) internal {
        _configure();
        ReentrantSeller attacker = new ReentrantSeller(vault, IERC20(address(token)));
        vm.deal(address(attacker), 2 ether);
        vm.prank(address(attacker));
        uint256 bought = vault.buy{value: 2 ether}(0);

        uint256 half = bought / 2;
        uint256 expected = vault.quoteSell(half);
        uint256 floorBefore = vault.floorPrice();

        attacker.attack(half, half, mode);

        assertFalse(attacker.reentrySucceeded(), "re-entrant call must fail");
        assertEq(bytes4(attacker.reentryError()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        // Exactly one redemption settled.
        assertEq(address(attacker).balance, expected);
        assertEq(vault.backedSupply(), bought - half);
        assertEq(token.balanceOf(address(attacker)), bought - half);
        assertGe(vault.floorPrice(), floorBefore);
    }

    // ------------------------------------------------------------------ ownership

    function test_ownership_twoStepTransferAndDeployerNeverGainsRights() public {
        vm.prank(OWNER);
        vault.transferOwnership(ALICE);
        assertEq(vault.owner(), OWNER);
        assertEq(vault.pendingOwner(), ALICE);

        _expectOnlyOwner(BOB);
        vm.prank(BOB);
        vault.acceptOwnership();

        vm.prank(ALICE);
        vault.acceptOwnership();
        assertEq(vault.owner(), ALICE);

        _expectOnlyOwner(OWNER);
        vm.prank(OWNER);
        vault.setToken(address(token));

        _expectOnlyOwner(DEPLOYER);
        vm.prank(DEPLOYER);
        vault.setToken(address(token));
    }

    function test_ownership_renounceFreezesAdminButTradingContinues() public {
        _configure();
        uint256 bought = _buy(ALICE, 1 ether);
        vm.prank(OWNER);
        vault.renounceOwnership();
        assertEq(vault.owner(), address(0));

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OWNER));
        vault.setBuysPaused(true);

        _buy(BOB, 1 ether);
        _sell(ALICE, bought);
    }

    // ------------------------------------------------------------------ fuzz: the floor never falls

    function testFuzz_buyNeverLowersFloor(uint256 seedEth, uint256 ethIn, uint256 premium, uint256 fee) public {
        seedEth = bound(seedEth, 1, 100 ether);
        ethIn = bound(ethIn, 1, 100 ether);
        premium = bound(premium, 0, 2_000);
        fee = bound(fee, 0, 1_000);
        vm.startPrank(OWNER);
        vault.setToken(address(token));
        vault.setSpreads(premium, fee);
        vault.setOpeningPrice(OPENING);
        vm.stopPrank();
        token.mint(address(vault), type(uint128).max);

        _buy(ALICE, seedEth);
        uint256 floorBefore = vault.floorPrice();
        uint256 supplyBefore = vault.backedSupply();
        uint256 quote = vault.quoteBuy(ethIn);
        if (quote == 0) {
            vm.prank(BOB);
            vm.expectRevert(RisingFloorVault.ZeroOutput.selector);
            vault.buy{value: ethIn}(0);
            return;
        }
        uint256 out = _buy(BOB, ethIn);
        assertEq(out, quote);
        assertGe(vault.floorPrice(), floorBefore);
        assertEq(vault.backedSupply(), supplyBefore + out);
        assertEq(vault.reserve(), seedEth + ethIn);
        // The buyer never pays less than the floor per token.
        assertGe(ethIn.mulDiv(WAD, out), floorBefore);
    }

    function testFuzz_sellNeverLowersFloor(uint256 seedEth, uint256 sellFraction, uint256 premium, uint256 fee) public {
        seedEth = bound(seedEth, 1 gwei, 100 ether);
        sellFraction = bound(sellFraction, 1, BPS);
        premium = bound(premium, 0, 2_000);
        fee = bound(fee, 0, 1_000);
        vm.startPrank(OWNER);
        vault.setToken(address(token));
        vault.setSpreads(premium, fee);
        vault.setOpeningPrice(OPENING);
        vm.stopPrank();
        token.mint(address(vault), type(uint128).max);

        uint256 bought = _buy(ALICE, seedEth);
        uint256 amount = bought * sellFraction / BPS;
        if (amount == 0) return;
        uint256 floorBefore = vault.floorPrice();
        uint256 reserveBefore = vault.reserve();
        uint256 quote = vault.quoteSell(amount);
        if (quote == 0) {
            vm.startPrank(ALICE);
            token.approve(address(vault), amount);
            vm.expectRevert(RisingFloorVault.ZeroOutput.selector);
            vault.sell(amount, 0);
            vm.stopPrank();
            return;
        }
        uint256 out = _sell(ALICE, amount);
        assertEq(out, quote);
        assertLe(out, amount.mulDiv(floorBefore, WAD) + 1); // never above the floor
        assertEq(vault.reserve(), reserveBefore - out);
        assertEq(vault.backedSupply(), bought - amount);
        assertGe(vault.floorPrice(), floorBefore);
        if (vault.backedSupply() == 0) {
            assertGe(vault.openingPrice(), floorBefore);
            assertGe(vault.minOpeningPrice(), floorBefore);
        }
    }

    function testFuzz_roundTripNeverProfitsAgainstTheReserve(uint256 ethIn, uint256 premium, uint256 fee) public {
        ethIn = bound(ethIn, 1 gwei, 100 ether);
        premium = bound(premium, 0, 2_000);
        fee = bound(fee, 0, 1_000);
        vm.startPrank(OWNER);
        vault.setToken(address(token));
        vault.setSpreads(premium, fee);
        vault.setOpeningPrice(OPENING);
        vm.stopPrank();
        token.mint(address(vault), type(uint128).max);

        _buy(ALICE, 1 ether);
        uint256 bobBefore = BOB.balance;
        uint256 bought = _buy(BOB, ethIn);
        _sell(BOB, bought);
        assertLe(BOB.balance, bobBefore, "buy then sell must not extract ETH");
        // Alice's floor only went up through Bob's round trip.
        assertGe(vault.floorPrice(), OPENING);
    }
}
