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
    uint256 internal constant MIN_POSITION_VALUE = 0.01 ether;

    RisingFloorVault internal vault;
    MockERC20 internal token;

    event TokenSet(address indexed token);
    event OpeningPriceSet(uint256 price);
    event SpreadsSet(uint256 buyPremiumBps, uint256 sellFeeBps);
    event BuysPausedSet(bool paused);
    event Bought(address indexed buyer, uint256 ethIn, uint256 tokensOut, uint256 floorAfter);
    event Sold(address indexed seller, uint256 tokensIn, uint256 ethOut, uint256 floorAfter);
    event RedeemableTransferred(address indexed from, address indexed to, uint256 amount);
    event ForceRedeemed(address indexed holder, uint256 credit, uint256 ethOut, uint256 floorAfter);
    event PayoutWithdrawn(address indexed holder, address indexed to, uint256 amount);
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
        assertEq(vault.MIN_POSITION_VALUE(), MIN_POSITION_VALUE);
        assertEq(vault.totalPendingPayouts(), 0);
        assertEq(vault.minRemainingCredit(), 0);
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

    function test_setToken_rejectsAddressWithoutCode() public {
        address noCode = address(0x1234);
        assertEq(noCode.code.length, 0);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.NotAContract.selector, noCode));
        vault.setToken(noCode);
        // The slot is still open for the real token.
        vm.prank(OWNER);
        vault.setToken(address(token));
        assertEq(vault.token(), address(token));
    }

    function test_renounceOwnership_refusedUntilTokenIsSet() public {
        vm.prank(OWNER);
        vm.expectRevert(RisingFloorVault.TokenNotSet.selector);
        vault.renounceOwnership();
        assertEq(vault.owner(), OWNER);

        _expectOnlyOwner(ALICE);
        vm.prank(ALICE);
        vault.renounceOwnership();

        vm.startPrank(OWNER);
        vault.setToken(address(token));
        vault.renounceOwnership();
        vm.stopPrank();
        assertEq(vault.owner(), address(0));
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

    /// @dev The first sale of an epoch records its opening price as the minimum for every later
    ///      epoch: the vault's own sale price never goes down, and only owner-set values are recorded.
    function test_openingPrice_neverBelowAPriceTheVaultSoldAt() public {
        _configure();
        assertEq(vault.minOpeningPrice(), 0);
        uint256 bought = _buy(ALICE, 1 ether);
        assertEq(vault.minOpeningPrice(), OPENING);
        _sell(ALICE, bought);
        assertEq(vault.backedSupply(), 0);
        assertEq(vault.openingPrice(), OPENING); // a full redemption does not move the opening price
        assertEq(vault.minOpeningPrice(), OPENING);

        vm.startPrank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(RisingFloorVault.OpeningPriceBelowMinimum.selector, OPENING - 1, OPENING)
        );
        vault.setOpeningPrice(OPENING - 1);
        vault.setOpeningPrice(OPENING); // equal is allowed
        vault.setOpeningPrice(OPENING * 4);
        vm.stopPrank();

        // Raising it is only locked in once somebody buys at the new price.
        assertEq(vault.minOpeningPrice(), OPENING);
        vm.prank(OWNER);
        vault.setOpeningPrice(OPENING * 2);
        uint256 bought2 = _buy(BOB, 1 ether);
        assertEq(bought2, 1 ether * WAD / (OPENING * 2));
        assertEq(vault.minOpeningPrice(), OPENING * 2);
        _sell(BOB, bought2);
        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(RisingFloorVault.OpeningPriceBelowMinimum.selector, OPENING, OPENING * 2)
        );
        vault.setOpeningPrice(OPENING);
    }

    /// @dev A dust buy, a donation against it and a full redemption used to write an astronomic
    ///      floor into `minOpeningPrice` for the price of the fee. Now a donation against a reserve
    ///      below `MIN_POSITION_VALUE` is refused outright, the dust buyer can only leave whole, and
    ///      the minimum stays at the price the griefer actually bought at.
    function test_openingPrice_cannotBeLockedByDonationAgainstDust() public {
        _configure();
        address griefer = address(0xBAD);
        vm.deal(griefer, 1 ether);
        uint256 costBefore = griefer.balance;

        vm.startPrank(griefer);
        uint256 dust = vault.buy{value: 1}(0);
        assertEq(dust, 1000); // 1 wei at 0.001 ETH per token
        (bool ok, bytes memory err) = address(vault).call{value: 0.01 ether}("");
        assertFalse(ok); // refused: the reserve is dust, so the donation would pin the floor
        assertEq(err, abi.encodeWithSelector(RisingFloorVault.ReserveBelowMinimum.selector, 1, MIN_POSITION_VALUE));
        assertEq(vault.floorPrice(), OPENING);
        token.approve(address(vault), dust);
        uint256 out = vault.sell(dust, 0);
        vm.stopPrank();

        assertEq(out, 1); // the final redemption pays everything back, no fee
        assertEq(griefer.balance, costBefore);
        assertEq(vault.reserve(), 0);
        assertEq(vault.minOpeningPrice(), OPENING);
        assertEq(vault.openingPrice(), OPENING);

        vm.prank(OWNER);
        vault.setOpeningPrice(OPENING);
        assertEq(_buy(ALICE, 1 ether), 1_000e18);
    }

    /// @dev The other griefing route: a sole holder sells all but one base unit so the fee residue
    ///      concentrates on it. A partial redemption may not leave a position below the minimum, so
    ///      the residue lands on a position worth at least 0.01 ETH and the floor stays sane; the
    ///      final redemption takes the residue and no activity-derived value is ratcheted.
    function test_openingPrice_cannotBeLockedByConcentratingFeeResidue() public {
        _configure();
        uint256 bought = _buy(ALICE, 1 ether);
        uint256 min = vault.minRemainingCredit();
        assertEq(min, 10e18); // 0.01 ETH at the opening price

        vm.startPrank(ALICE);
        token.approve(address(vault), bought);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.PositionTooSmall.selector, 1, min));
        vault.sell(bought - 1, 0);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.PositionTooSmall.selector, min - 1, min));
        vault.sell(bought - min + 1, 0);
        uint256 out = vault.sell(bought - min, 0);
        vm.stopPrank();

        assertEq(out, (bought - min) * (BPS - FEE) / BPS * OPENING / WAD);
        assertEq(vault.backedSupply(), min);
        // The 1% fee on 990 tokens now backs 10 tokens: the floor roughly doubles, no worse.
        assertLt(vault.floorPrice(), 2 * OPENING);
        assertGe(vault.quoteBuy(1 ether), 400e18);

        uint256 residue = vault.reserve();
        assertEq(_sell(ALICE, min), residue);
        assertEq(vault.reserve(), 0);
        assertEq(vault.minOpeningPrice(), OPENING);
        assertEq(vault.openingPrice(), OPENING);
        assertEq(vault.quoteBuy(1 ether), 1_000e18);
    }

    /// @dev The reviewer's scenario: a 1000 wei position cannot be pared down to a single base unit
    ///      carrying the residue. The buy is allowed; the partial redemption is not; a full one is.
    function test_sell_dustPositionCanOnlyLeaveWhole() public {
        _configure();
        address griefer = address(0xBAD);
        vm.deal(griefer, 1 ether);
        vm.startPrank(griefer);
        uint256 units = vault.buy{value: 1000}(0);
        assertEq(units, 1_000_000);
        token.approve(address(vault), units);
        uint256 min = vault.minRemainingCredit();
        assertEq(min, 1e19); // 0.01 ETH worth of credit, far more than the position
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.PositionTooSmall.selector, 1, min));
        vault.sell(units - 1, 0);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.PositionTooSmall.selector, units / 2, min));
        vault.sell(units / 2, 0);
        assertEq(vault.sell(units, 0), 1000);
        vm.stopPrank();
        assertEq(vault.backedSupply(), 0);
        assertEq(vault.quoteBuy(1 ether), 1_000e18);
        vm.prank(OWNER);
        vault.setOpeningPrice(OPENING);
    }

    /// @dev The minimum is a value at the floor, so it shrinks in token terms as the floor rises
    ///      and never invalidates a position that was once above it.
    function test_minRemainingCredit_tracksTheFloor() public {
        _configure();
        assertEq(vault.minRemainingCredit(), 0);
        uint256 bought = _buy(ALICE, 1 ether);
        assertEq(vault.minRemainingCredit(), 10e18);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(vault.floorPrice(), 2 * OPENING);
        assertEq(vault.minRemainingCredit(), 5e18);
        // Rounds up: 3 ETH over 1000 tokens makes 0.01 ETH worth 3.33.. tokens.
        (ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(vault.minRemainingCredit(), MIN_POSITION_VALUE.mulDiv(bought, 3 ether, Math.Rounding.Ceil));
        assertEq(vault.minRemainingCredit(), 3333333333333333334);
        _sell(ALICE, bought - 4e18); // 4 tokens remain: above the minimum
        assertEq(vault.backedSupply(), 4e18);
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
        assertEq(vault.quoteSellFor(ALICE, amount), expected);

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

    function test_sell_rejectsMoreThanTheCallersCredit() public {
        _configure();
        uint256 bought = _buy(ALICE, 1 ether);
        assertEq(vault.redeemable(ALICE), bought);
        token.mint(ALICE, 1); // one extra base unit from outside the vault
        vm.startPrank(ALICE);
        token.approve(address(vault), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.ExceedsRedeemable.selector, bought, bought + 1));
        vault.sell(bought + 1, 0);
        vm.stopPrank();
    }

    /// @dev Tokens that never passed through a vault sale carry no claim on the reserve, however
    ///      many are outstanding: an outside holder cannot take a vault buyer's backing.
    function test_sell_outsideHolderHasNoCredit() public {
        _configure();
        uint256 bought = _buy(ALICE, 1 ether);
        token.mint(BOB, bought);
        assertEq(vault.redeemable(BOB), 0);
        assertEq(vault.quoteSellFor(BOB, bought), 0);
        assertEq(vault.quoteSellFor(ALICE, bought), 1 ether);
        vm.startPrank(BOB);
        token.approve(address(vault), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.ExceedsRedeemable.selector, 0, bought));
        vault.sell(bought, 0);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.ExceedsRedeemable.selector, 0, 1));
        vault.sell(1, 0);
        vm.stopPrank();
        // Alice's redemption is untouched.
        assertEq(_sell(ALICE, bought), 1 ether);
    }

    /// @dev The owner may move unsold inventory out, but that inventory has no credit, so the move
    ///      is not a two-step ETH withdrawal.
    function test_sell_ownerCannotRedeemWithdrawnInventory() public {
        _configure();
        uint256 aliceTokens = _buy(ALICE, 10 ether);
        assertEq(vault.reserve(), 10 ether);

        vm.startPrank(OWNER);
        vault.withdrawInventory(OWNER, aliceTokens);
        token.approve(address(vault), aliceTokens);
        assertEq(vault.quoteSellFor(OWNER, aliceTokens), 0);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.ExceedsRedeemable.selector, 0, aliceTokens));
        vault.sell(aliceTokens, 0);
        vm.stopPrank();

        assertEq(OWNER.balance, 0);
        assertEq(vault.reserve(), 10 ether);
        assertEq(vault.redeemable(ALICE), aliceTokens);
        assertEq(_sell(ALICE, aliceTokens), 10 ether);
    }

    function test_sell_revertsBeforeAnythingWasSold() public {
        _configure();
        token.mint(ALICE, 1e18);
        vm.startPrank(ALICE);
        token.approve(address(vault), 1e18);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.ExceedsRedeemable.selector, 0, 1e18));
        vault.sell(1e18, 0);
        vm.stopPrank();
    }

    function test_sell_lastRedemptionPaysTheWholeReserveWithoutFee() public {
        _configure();
        uint256 aliceTokens = _buy(ALICE, 1 ether);
        uint256 bobTokens = _buy(BOB, 1 ether);

        // Alice leaves first: she pays the fee, which stays with Bob.
        uint256 floorBefore = vault.floorPrice();
        uint256 aliceOut = _sell(ALICE, aliceTokens);
        assertLt(aliceOut, aliceTokens * floorBefore / WAD);
        uint256 residue = vault.reserve();
        assertEq(residue, 2 ether - aliceOut);
        assertEq(vault.quoteSellFor(BOB, bobTokens), residue);
        assertEq(vault.quoteSellFor(BOB, bobTokens - 1), (bobTokens - 1) * (BPS - FEE) * residue / (bobTokens * BPS));

        // Bob is the last holder: there is nobody left for a fee to stay behind for.
        vm.startPrank(BOB);
        token.approve(address(vault), bobTokens);
        vm.expectEmit(true, false, false, true, address(vault));
        emit Sold(BOB, bobTokens, residue, OPENING);
        uint256 bobOut = vault.sell(bobTokens, 0);
        vm.stopPrank();
        assertEq(bobOut, residue);
        assertEq(vault.reserve(), 0);
        assertEq(vault.backedSupply(), 0);
        assertEq(vault.redeemable(BOB), 0);
        assertEq(vault.floorPrice(), OPENING);
        assertEq(vault.bidPrice(), 0);
    }

    /// @dev The fee is a transfer to whoever still holds credit, the seller included. A sole holder
    ///      who leaves in two steps therefore recovers everything; this documents, not hides, that
    ///      the fee only bites when other holders remain.
    function test_sell_soleHolderTwoStepExitRecoversEverything() public {
        _configure();
        uint256 bought = _buy(ALICE, 1 ether);
        uint256 before = ALICE.balance;
        _sell(ALICE, bought - 10e18);
        assertLt(ALICE.balance, before + 1 ether); // the fee stayed behind for the remaining stake
        _sell(ALICE, 10e18);
        assertEq(ALICE.balance, before + 1 ether);
        assertEq(vault.reserve(), 0);
    }

    /// @dev Credit transfers obey the same minimum on both sides: neither the sender's remainder
    ///      nor the receiver's resulting credit may be dust.
    function test_transferRedeemable_cannotCreateOrLeaveDust() public {
        _configure();
        uint256 bought = _buy(ALICE, 1 ether);
        uint256 min = vault.minRemainingCredit();
        vm.startPrank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.PositionTooSmall.selector, min - 1, min));
        vault.transferRedeemable(BOB, min - 1); // Bob would hold dust
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.PositionTooSmall.selector, min - 1, min));
        vault.transferRedeemable(BOB, bought - min + 1); // Alice would keep dust
        vault.transferRedeemable(BOB, min); // exactly the minimum is fine on both sides
        vault.transferRedeemable(BOB, bought - min); // and so is giving everything away
        vm.stopPrank();
        assertEq(vault.redeemable(ALICE), 0);
        assertEq(vault.redeemable(BOB), bought);
        // A top-up to an existing position that stays above the minimum is fine too.
        uint256 bought2 = _buy(ALICE, 1 ether);
        vm.prank(ALICE);
        vault.transferRedeemable(BOB, 1);
        assertEq(vault.redeemable(BOB), bought + 1);
        // A transfer to oneself changes nothing and creates no credit.
        vm.prank(ALICE);
        vault.transferRedeemable(ALICE, bought2 - 1);
        assertEq(vault.redeemable(ALICE), bought2 - 1);
        assertEq(vault.redeemable(ALICE) + vault.redeemable(BOB), vault.backedSupply());
    }

    function test_transferRedeemable_movesCreditNotTokens() public {
        _configure();
        uint256 bought = _buy(ALICE, 1 ether);

        vm.startPrank(ALICE);
        vm.expectRevert(RisingFloorVault.ZeroAddress.selector);
        vault.transferRedeemable(address(0), 1);
        vm.expectRevert(RisingFloorVault.ZeroAmount.selector);
        vault.transferRedeemable(BOB, 0);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.ExceedsRedeemable.selector, bought, bought + 1));
        vault.transferRedeemable(BOB, bought + 1);

        vm.expectEmit(true, true, false, true, address(vault));
        emit RedeemableTransferred(ALICE, BOB, 400e18);
        vault.transferRedeemable(BOB, 400e18);
        token.transfer(BOB, 400e18);
        vm.stopPrank();

        assertEq(vault.redeemable(ALICE), bought - 400e18);
        assertEq(vault.redeemable(BOB), 400e18);
        assertEq(vault.backedSupply(), bought);
        assertEq(_sell(BOB, 400e18), 0.396 ether);

        // Bob cannot redeem more than he was given, even though Alice still has credit.
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.ExceedsRedeemable.selector, 0, 1));
        vault.sell(1, 0);
    }

    function test_sell_enforcesMinEthOut() public {
        _configure();
        uint256 bought = _buy(ALICE, 1 ether);
        uint256 quote = vault.quoteSellFor(ALICE, bought);
        vm.startPrank(ALICE);
        assertEq(vault.quoteSell(bought), quote); // the caller's own quote
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

    function test_sell_everythingReopensAtTheOwnersOpeningPriceWithAnEmptyReserve() public {
        _configure();
        uint256 aliceTokens = _buy(ALICE, 1 ether);
        uint256 bobTokens = _buy(BOB, 1 ether); // pays the premium: floor rises above OPENING
        uint256 floorBefore = vault.floorPrice();
        assertGt(floorBefore, OPENING);

        uint256 aliceOut = _sell(ALICE, aliceTokens);
        uint256 floorMid = vault.floorPrice();
        assertGe(floorMid, floorBefore);

        uint256 bobOut = _sell(BOB, bobTokens);
        assertEq(bobOut, 2 ether - aliceOut); // everything Alice did not take
        assertEq(vault.backedSupply(), 0);
        assertEq(vault.reserve(), 0);
        // The opening price is the owner's, not the epoch's final floor; its minimum is what sold.
        assertEq(vault.openingPrice(), OPENING);
        assertEq(vault.minOpeningPrice(), OPENING);
        assertEq(vault.floorPrice(), OPENING);
        assertEq(vault.bidPrice(), 0);

        // The next buyer pays exactly the opening price: nothing pre-existing is priced in.
        uint256 out = _buy(ALICE, 1 ether);
        assertEq(out, 1 ether * WAD / OPENING);
        assertEq(vault.floorPrice(), OPENING);
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
        // Donated ETH is redeemable by the credited holders, never by the owner.
        assertEq(vault.quoteSellFor(ALICE, vault.backedSupply()), 1.5 ether);
        assertEq(vault.quoteSellFor(ALICE, vault.backedSupply() / 2), 0.75 ether * (BPS - FEE) / BPS);
    }

    /// @dev ETH held while nothing is outstanding would be captured by the next buyer, so plain
    ///      transfers are refused in that state: before configuration, before the first sale and
    ///      again after a full redemption.
    function test_receive_refusedWhileNothingIsOutstanding() public {
        vm.deal(address(this), 3 ether);
        (bool ok, bytes memory err) = address(vault).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(bytes4(err), RisingFloorVault.NothingOutstanding.selector);

        _configure();
        vm.deal(OWNER, 1 ether);
        vm.prank(OWNER);
        (ok, err) = address(vault).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(bytes4(err), RisingFloorVault.NothingOutstanding.selector);
        assertEq(vault.reserve(), 0);
        assertEq(OWNER.balance, 1 ether);

        uint256 bought = _buy(ALICE, 1 ether);
        (ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
        _sell(ALICE, bought);
        assertEq(vault.reserve(), 0);

        (ok, err) = address(vault).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(bytes4(err), RisingFloorVault.NothingOutstanding.selector);
    }

    /// @dev A donation against a reserve below the minimum would pin the floor for the price of
    ///      the donation, so it is refused; once the reserve is at the minimum it is accepted.
    function test_receive_refusedWhileReserveIsBelowMinimum() public {
        _configure();
        _buy(ALICE, MIN_POSITION_VALUE - 1);
        (bool ok, bytes memory err) = address(vault).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(
            err,
            abi.encodeWithSelector(
                RisingFloorVault.ReserveBelowMinimum.selector, MIN_POSITION_VALUE - 1, MIN_POSITION_VALUE
            )
        );
        assertEq(vault.reserve(), MIN_POSITION_VALUE - 1);

        _buy(BOB, 1); // the reserve reaches the minimum
        assertEq(vault.reserve(), MIN_POSITION_VALUE);
        (ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(vault.reserve(), MIN_POSITION_VALUE + 1 ether);
    }

    // ------------------------------------------------------------------ forced redemption

    /// @dev Alice leaves her fee behind on Bob's dust position, which pins the ask; the owner clears
    ///      it by paying Bob his whole (pro-rata) backing into escrow. Bob keeps his tokens and is
    ///      paid exactly the floor, the epoch reopens and the opening price is free again.
    function test_forceRedeem_clearsAPinnedFloorAndPaysTheHolderTheFloor() public {
        _configure();
        uint256 aliceTokens = _buy(ALICE, 1 ether);
        uint256 bobTokens = _buy(BOB, 1000); // dust: allowed, as any buy is
        _sell(ALICE, aliceTokens);
        uint256 residue = vault.reserve(); // Alice's 1% fee plus Bob's 1000 wei
        assertGt(residue, 0.0099 ether);
        assertEq(vault.backedSupply(), bobTokens);
        assertGt(vault.askPrice(), 1_000 * OPENING); // pinned: 1 ETH buys far less than a token
        assertLt(vault.quoteBuy(1 ether), 1e18);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.SupplyOutstanding.selector, bobTokens));
        vault.setOpeningPrice(OPENING);

        address[] memory holders = new address[](1);
        holders[0] = BOB;
        vm.expectEmit(true, false, false, true, address(vault));
        emit ForceRedeemed(BOB, bobTokens, residue, OPENING);
        vm.prank(OWNER);
        vault.forceRedeem(holders);

        assertEq(vault.backedSupply(), 0);
        assertEq(vault.redeemable(BOB), 0);
        assertEq(vault.reserve(), 0);
        assertEq(vault.pendingPayout(BOB), residue);
        assertEq(vault.totalPendingPayouts(), residue);
        assertEq(address(vault).balance, residue);
        assertEq(token.balanceOf(BOB), bobTokens); // the tokens stay with Bob, uncredited
        assertEq(vault.floorPrice(), OPENING);
        assertEq(vault.askPrice(), OPENING);
        assertEq(vault.quoteBuy(1 ether), 1_000e18);
        vm.prank(OWNER);
        vault.setOpeningPrice(OPENING * 2);

        // Bob's tokens carry no credit any more.
        vm.startPrank(BOB);
        token.approve(address(vault), bobTokens);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.ExceedsRedeemable.selector, 0, bobTokens));
        vault.sell(bobTokens, 0);
        // The escrow is Bob's alone and is not part of what the next buyer gets.
        uint256 bobBefore = BOB.balance;
        vm.expectEmit(true, true, false, true, address(vault));
        emit PayoutWithdrawn(BOB, BOB, residue);
        assertEq(vault.withdrawPayout(BOB), residue);
        vm.stopPrank();
        assertEq(BOB.balance, bobBefore + residue);
        assertEq(address(vault).balance, 0);
        assertEq(vault.pendingPayout(BOB), 0);
        assertEq(vault.totalPendingPayouts(), 0);
    }

    function test_forceRedeem_onlyOwnerAndNeedsCredit() public {
        _configure();
        _buy(ALICE, 1 ether);
        address[] memory holders = new address[](1);
        holders[0] = ALICE;
        _expectOnlyOwner(ALICE);
        vm.prank(ALICE);
        vault.forceRedeem(holders);
        _expectOnlyOwner(DEPLOYER);
        vm.prank(DEPLOYER);
        vault.forceRedeem(holders);

        holders[0] = BOB;
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.NoCredit.selector, BOB));
        vault.forceRedeem(holders);
        // An empty list is a no-op.
        vm.prank(OWNER);
        vault.forceRedeem(new address[](0));
        assertEq(vault.redeemable(ALICE), 1_000e18);
    }

    /// @dev A forced redemption pays a pro-rata share, so the remaining holders' floor never moves
    ///      down; a batch that takes every holder pays exactly the whole reserve.
    function test_forceRedeem_paysProRataAndNeverLowersTheOthersFloor() public {
        _configure();
        uint256 aliceTokens = _buy(ALICE, 1 ether);
        uint256 bobTokens = _buy(BOB, 3 ether);
        uint256 floorBefore = vault.floorPrice();
        uint256 reserveBefore = vault.reserve();
        uint256 expected = aliceTokens.mulDiv(reserveBefore, aliceTokens + bobTokens);
        assertApproxEqAbs(expected, aliceTokens * floorBefore / WAD, aliceTokens / WAD + 1); // the floor, no fee

        address[] memory holders = new address[](1);
        holders[0] = ALICE;
        vm.prank(OWNER);
        vault.forceRedeem(holders);
        assertEq(vault.pendingPayout(ALICE), expected);
        assertEq(vault.reserve(), reserveBefore - expected);
        assertEq(vault.backedSupply(), bobTokens);
        assertGe(vault.floorPrice(), floorBefore);
        assertEq(vault.quoteSellFor(BOB, bobTokens), reserveBefore - expected);

        // Bob trades on normally; Alice's escrow is untouched by it.
        _buy(ALICE, 1 ether);
        _sell(BOB, bobTokens / 2);
        assertEq(vault.pendingPayout(ALICE), expected);
        assertEq(address(vault).balance, vault.reserve() + expected);

        // Taking everyone that is left empties the reserve exactly.
        holders = new address[](2);
        holders[0] = BOB;
        holders[1] = ALICE;
        uint256 reserve = vault.reserve();
        vm.prank(OWNER);
        vault.forceRedeem(holders);
        assertEq(vault.backedSupply(), 0);
        assertEq(vault.reserve(), 0);
        assertEq(vault.totalPendingPayouts(), expected + reserve);
        assertEq(vault.pendingPayout(ALICE) + vault.pendingPayout(BOB), expected + reserve);
        assertEq(address(vault).balance, vault.totalPendingPayouts());
        // Nothing is waiting for the next epoch's first buyer.
        assertEq(_buy(BOB, 1), 1000);
        assertEq(vault.quoteSellFor(BOB, 1000), 1);
    }

    function test_withdrawPayout_validatesAndPaysToAChosenRecipient() public {
        _configure();
        vm.prank(ALICE);
        vm.expectRevert(RisingFloorVault.NothingToWithdraw.selector);
        vault.withdrawPayout(ALICE);

        uint256 aliceTokens = _buy(ALICE, 1 ether);
        address[] memory holders = new address[](1);
        holders[0] = ALICE;
        vm.prank(OWNER);
        vault.forceRedeem(holders);
        assertEq(vault.pendingPayout(ALICE), 1 ether);
        assertEq(token.balanceOf(ALICE), aliceTokens);

        vm.startPrank(ALICE);
        vm.expectRevert(RisingFloorVault.ZeroAddress.selector);
        vault.withdrawPayout(address(0));
        uint256 bobBefore = BOB.balance;
        vault.withdrawPayout(BOB);
        vm.expectRevert(RisingFloorVault.NothingToWithdraw.selector);
        vault.withdrawPayout(ALICE);
        vm.stopPrank();
        assertEq(BOB.balance, bobBefore + 1 ether);
        // Only the holder can withdraw: nothing is credited to the owner or the recipient.
        vm.prank(OWNER);
        vm.expectRevert(RisingFloorVault.NothingToWithdraw.selector);
        vault.withdrawPayout(OWNER);
    }

    /// @dev A holder that refuses ETH cannot block the owner's remedy: the payout waits in escrow
    ///      until the holder withdraws it to an address that accepts it.
    function test_forceRedeem_escrowsForAHolderWhoRefusesEthAndPaysOnWithdraw() public {
        _configure();
        RejectingReceiver receiver = new RejectingReceiver(vault, IERC20(address(token)));
        vm.deal(address(receiver), 1 ether);
        vm.prank(address(receiver));
        vault.buy{value: 1 ether}(0);

        address[] memory holders = new address[](1);
        holders[0] = address(receiver);
        vm.prank(OWNER);
        vault.forceRedeem(holders);
        assertEq(vault.backedSupply(), 0);
        assertEq(vault.pendingPayout(address(receiver)), 1 ether);

        vm.expectRevert(RisingFloorVault.EthTransferFailed.selector);
        receiver.withdrawPayout(address(receiver));
        assertEq(vault.pendingPayout(address(receiver)), 1 ether);
        receiver.withdrawPayout(BOB);
        assertEq(vault.pendingPayout(address(receiver)), 0);
        assertEq(BOB.balance, 1_000 ether + 1 ether);
    }

    function test_withdrawPayout_cannotReenter() public {
        _configure();
        ReentrantSeller attacker = new ReentrantSeller(vault, IERC20(address(token)));
        vm.deal(address(attacker), 2 ether);
        vm.prank(address(attacker));
        uint256 bought = vault.buy{value: 2 ether}(0);
        _buy(ALICE, 1 ether); // somebody stays, so the vault still has a reserve to attack

        address[] memory holders = new address[](1);
        holders[0] = address(attacker);
        vm.prank(OWNER);
        vault.forceRedeem(holders);
        uint256 payout = vault.pendingPayout(address(attacker));
        uint256 reserveBefore = vault.reserve();

        attacker.attackWithdraw(bought / 2, 3); // tries to re-enter sell during the payout
        assertFalse(attacker.reentrySucceeded(), "re-entrant call must fail");
        assertEq(bytes4(attacker.reentryError()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(address(attacker).balance, payout);
        assertEq(vault.reserve(), reserveBefore);
        assertEq(vault.pendingPayout(address(attacker)), 0);
    }

    function testFuzz_forceRedeemNeverLowersTheOthersFloor(uint256 ethA, uint256 ethB, uint256 premium, uint256 fee)
        public
    {
        ethA = bound(ethA, 1, 100 ether);
        ethB = bound(ethB, 1, 100 ether);
        premium = bound(premium, 0, 2_000);
        fee = bound(fee, 0, 1_000);
        vm.startPrank(OWNER);
        vault.setToken(address(token));
        vault.setSpreads(premium, fee);
        vault.setOpeningPrice(OPENING);
        vm.stopPrank();
        token.mint(address(vault), type(uint128).max);

        uint256 a = _buy(ALICE, ethA);
        if (vault.quoteBuy(ethB) == 0) return;
        uint256 b = _buy(BOB, ethB);
        uint256 floorBefore = vault.floorPrice();
        uint256 reserveBefore = vault.reserve();

        address[] memory holders = new address[](1);
        holders[0] = ALICE;
        vm.prank(OWNER);
        vault.forceRedeem(holders);
        uint256 payout = vault.pendingPayout(ALICE);
        assertEq(payout, a.mulDiv(reserveBefore, a + b));
        assertLe(payout, a.mulDiv(floorBefore, WAD) + a / WAD + 2); // the floor (to rounding), never more
        assertEq(vault.backedSupply(), b);
        assertEq(vault.reserve(), reserveBefore - payout);
        assertGe(vault.floorPrice(), floorBefore);
        assertEq(address(vault).balance, vault.reserve() + payout);

        // Bob, now alone, still takes exactly the remaining reserve.
        assertEq(_sell(BOB, b), reserveBefore - payout);
        assertEq(vault.reserve(), 0);
        assertEq(vault.totalPendingPayouts(), payout);
    }

    /// @dev A 1 wei buyer of a fresh epoch gets 1 wei of backing and nothing more, whether the
    ///      previous epoch ended with a fee residue or the owner tried to seed the reserve.
    function test_buy_firstBuyerOfAnEpochCapturesNothing() public {
        _configure();
        uint256 aliceTokens = _buy(ALICE, 1 ether);
        _sell(ALICE, aliceTokens - 10e18); // leaves a fee residue against the smallest allowed position
        assertGt(vault.reserve(), 0);
        _sell(ALICE, 10e18); // ...which the last redemption pays out
        assertEq(vault.reserve(), 0);

        uint256 bobBefore = BOB.balance;
        uint256 bobTokens = _buy(BOB, 1);
        assertEq(bobTokens, 1000);
        assertEq(vault.floorPrice(), OPENING);
        assertEq(vault.quoteSellFor(BOB, bobTokens), 1);
        _sell(BOB, bobTokens);
        assertEq(BOB.balance, bobBefore);
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
        token.approve(address(vault), 1e18);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.ExceedsRedeemable.selector, 0, 1e18));
        vault.sell(1e18, 0);
        vm.stopPrank();
        assertEq(vault.reserve(), 5 ether);
        assertEq(OWNER.balance, 0);
    }

    // ------------------------------------------------------------------ views

    function test_views_whileNothingIsOutstanding() public {
        _configure();
        assertEq(vault.floorPrice(), OPENING);
        assertEq(vault.askPrice(), OPENING); // the opening sale carries no premium
        assertEq(vault.bidPrice(), 0); // nothing is redeemable
        assertEq(vault.quoteSell(1e18), 0);
        assertEq(vault.quoteSellFor(ALICE, 1e18), 0);
        assertEq(vault.quoteBuy(1 ether), 1_000e18);

        uint256 bought = _buy(ALICE, 1 ether);
        assertEq(vault.askPrice(), OPENING * (BPS + PREMIUM) / BPS);
        assertEq(vault.bidPrice(), OPENING * (BPS - FEE) / BPS);
        assertEq(vault.quoteSellFor(ALICE, bought), 1 ether);
        assertEq(vault.quoteSellFor(BOB, 1), 0);
        // quoteSell is the caller's own quote.
        vm.prank(ALICE);
        uint256 aliceQuote = vault.quoteSell(bought / 2);
        assertEq(aliceQuote, vault.quoteSellFor(ALICE, bought / 2));
        assertGt(aliceQuote, 0);
        vm.prank(BOB);
        uint256 bobQuote = vault.quoteSell(1);
        assertEq(bobQuote, 0);
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
        uint256 expected = vault.quoteSellFor(address(attacker), half);
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
        uint256 quote = vault.quoteSellFor(ALICE, amount);
        uint256 remaining = bought - amount;
        uint256 min = vault.minRemainingCredit();
        if (quote == 0 || (remaining != 0 && remaining < min)) {
            vm.startPrank(ALICE);
            token.approve(address(vault), amount);
            if (quote == 0) vm.expectRevert(RisingFloorVault.ZeroOutput.selector);
            else vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.PositionTooSmall.selector, remaining, min));
            vault.sell(amount, 0);
            vm.stopPrank();
            return;
        }
        uint256 out = _sell(ALICE, amount);
        assertEq(out, quote);
        assertLe(out, amount.mulDiv(floorBefore, WAD) + 1); // never above the floor
        assertEq(vault.reserve(), reserveBefore - out);
        assertEq(vault.backedSupply(), bought - amount);
        assertEq(vault.redeemable(ALICE), bought - amount);
        if (vault.backedSupply() == 0) {
            // The last redemption takes everything; the epoch reopens at the owner's price.
            assertEq(out, reserveBefore);
            assertEq(vault.reserve(), 0);
            assertEq(vault.openingPrice(), OPENING);
            assertEq(vault.minOpeningPrice(), OPENING);
        } else {
            assertGe(vault.floorPrice(), floorBefore);
        }
    }

    /// @dev Whatever a holder does, once the backed supply is zero the reserve is zero too: no ETH
    ///      is ever waiting for the next buyer.
    function testFuzz_emptySupplyMeansEmptyReserve(uint256 ethA, uint256 ethB, uint256 donation, uint256 fee) public {
        ethA = bound(ethA, 1, 100 ether);
        ethB = bound(ethB, 1, 100 ether);
        donation = bound(donation, 0, 100 ether);
        fee = bound(fee, 0, 1_000);
        vm.startPrank(OWNER);
        vault.setToken(address(token));
        vault.setSpreads(PREMIUM, fee);
        vault.setOpeningPrice(OPENING);
        vm.stopPrank();
        token.mint(address(vault), type(uint128).max);

        uint256 a = _buy(ALICE, ethA);
        uint256 b;
        if (vault.quoteBuy(ethB) != 0) b = _buy(BOB, ethB);
        if (donation != 0) {
            vm.deal(address(this), donation);
            bool accepted = vault.reserve() >= MIN_POSITION_VALUE;
            (bool ok,) = address(vault).call{value: donation}("");
            assertEq(ok, accepted); // refused only against a reserve below the minimum
        }
        uint256 reserveBefore = vault.reserve();
        uint256 aliceOut;
        uint256 bobOut;
        if (b != 0 && vault.quoteSellFor(ALICE, a) == 0 && vault.quoteSellFor(BOB, b) == 0) {
            // Both positions are wei-sized dust that rounds to nothing: neither can leave first,
            // and a donation against such a reserve is refused. The owner's remedy clears them
            // and the escrow holds exactly the reserve.
            vm.startPrank(ALICE);
            token.approve(address(vault), a);
            vm.expectRevert(RisingFloorVault.ZeroOutput.selector);
            vault.sell(a, 0);
            vm.stopPrank();
            address[] memory holders = new address[](2);
            holders[0] = ALICE;
            holders[1] = BOB;
            vm.prank(OWNER);
            vault.forceRedeem(holders);
            aliceOut = vault.pendingPayout(ALICE);
            bobOut = vault.pendingPayout(BOB);
            assertEq(vault.totalPendingPayouts(), reserveBefore);
        } else if (b != 0 && vault.quoteSellFor(ALICE, a) == 0) {
            // Alice's position is dust next to Bob's and rounds to nothing: Bob leaves first and
            // Alice, as the last holder, takes what is left.
            bobOut = _sell(BOB, b);
            aliceOut = _sell(ALICE, a);
        } else {
            aliceOut = _sell(ALICE, a);
            if (b != 0) bobOut = _sell(BOB, b);
        }
        assertEq(vault.backedSupply(), 0);
        assertEq(vault.reserve(), 0);
        assertEq(aliceOut + bobOut, reserveBefore);
        assertEq(vault.redeemable(ALICE) + vault.redeemable(BOB), 0);
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
