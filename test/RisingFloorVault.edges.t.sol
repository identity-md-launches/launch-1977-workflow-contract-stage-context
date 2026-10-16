// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {RisingFloorVault} from "../src/RisingFloorVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Stands in for the launch factory: deploys the vault in one call, as `launchContracts` does,
///      so the constructor sees a contract as `msg.sender` and not the test.
contract FactoryStandIn {
    function deploy(address owner_) external returns (RisingFloorVault) {
        return new RisingFloorVault(owner_);
    }
}

/// @title Edge and failure-path tests for RisingFloorVault
/// @notice Complements `RisingFloorVault.t.sol`: inputs the implementation did not spell out
///         (boundaries, wrong callers, repeated calls, ERC-20 failures, the factory as deployer),
///         and property tests over the pricing arithmetic at its edges.
/// forge-config: default.fuzz.runs = 1000
contract RisingFloorVaultEdgesTest is Test {
    using Math for uint256;

    address internal constant OWNER = 0xD3f26A6Be348440110161dFD5748E7DE7B08cf69;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA201);

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant OPENING = 0.001 ether;
    uint256 internal constant PREMIUM = 500;
    uint256 internal constant FEE = 100;
    uint256 internal constant INVENTORY = 1_000_000e18;

    RisingFloorVault internal vault;
    MockERC20 internal token;

    event Sold(address indexed seller, uint256 tokensIn, uint256 ethOut, uint256 floorAfter);
    event OpeningPriceSet(uint256 price);
    event BuysPausedSet(bool paused);

    function setUp() public {
        vault = new RisingFloorVault(OWNER);
        token = new MockERC20();
        vm.deal(ALICE, 10_000 ether);
        vm.deal(BOB, 10_000 ether);
        vm.deal(CAROL, 10_000 ether);
    }

    // ------------------------------------------------------------------ helpers

    function _configure(uint256 premium, uint256 fee, uint256 opening) internal {
        vm.startPrank(OWNER);
        vault.setToken(address(token));
        vault.setSpreads(premium, fee);
        vault.setOpeningPrice(opening);
        vm.stopPrank();
        token.mint(address(vault), INVENTORY);
    }

    function _configure() internal {
        _configure(PREMIUM, FEE, OPENING);
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

    // ------------------------------------------------------------------ deployment through a factory

    function test_factoryDeployment_factoryKeepsNoRights() public {
        FactoryStandIn factory = new FactoryStandIn();
        RisingFloorVault launched = factory.deploy(OWNER);

        assertEq(launched.owner(), OWNER);
        assertTrue(launched.owner() != address(factory));
        assertEq(launched.pendingOwner(), address(0));
        assertEq(launched.token(), address(0));

        // The factory (msg.sender of the constructor) can do nothing an owner can.
        vm.startPrank(address(factory));
        _expectOnlyOwner(address(factory));
        launched.setToken(address(token));
        _expectOnlyOwner(address(factory));
        launched.setOpeningPrice(OPENING);
        _expectOnlyOwner(address(factory));
        launched.setSpreads(0, 0);
        _expectOnlyOwner(address(factory));
        launched.setBuysPaused(true);
        _expectOnlyOwner(address(factory));
        launched.transferOwnership(address(factory));
        vm.stopPrank();

        // The named owner configures it as on chain.
        vm.prank(OWNER);
        launched.setToken(address(token));
        assertEq(launched.token(), address(token));
    }

    function test_factoryDeployment_rejectsZeroOwnerFromTheFactoryToo() public {
        FactoryStandIn factory = new FactoryStandIn();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        factory.deploy(address(0));
    }

    // ------------------------------------------------------------------ calls the ABI does not have

    function test_unknownCalldataReverts_evenWithValue() public {
        vm.prank(ALICE);
        (bool ok,) = address(vault).call{value: 1 ether}(abi.encodeWithSignature("withdraw(uint256)", 1 ether));
        assertFalse(ok, "no fallback: unknown selectors must revert");
        vm.prank(ALICE);
        (ok,) = address(vault).call(hex"deadbeef");
        assertFalse(ok);
        assertEq(vault.reserve(), 0);
    }

    function test_receive_zeroValueDonationIsAcceptedAndChangesNothing() public {
        _configure();
        _buy(ALICE, 1 ether);
        uint256 floorBefore = vault.floorPrice();
        vm.prank(BOB);
        (bool ok,) = address(vault).call{value: 0}("");
        assertTrue(ok);
        assertEq(vault.floorPrice(), floorBefore);
        assertEq(vault.reserve(), 1 ether);
    }

    // ------------------------------------------------------------------ ownership edge cases

    function test_ownership_pendingOwnerHasNoRightsUntilAccepted() public {
        vm.prank(OWNER);
        vault.transferOwnership(ALICE);
        _expectOnlyOwner(ALICE);
        vm.prank(ALICE);
        vault.setToken(address(token));
        // The current owner keeps full control meanwhile and may cancel by naming someone else.
        vm.prank(OWNER);
        vault.transferOwnership(BOB);
        assertEq(vault.pendingOwner(), BOB);
        _expectOnlyOwner(ALICE);
        vm.prank(ALICE);
        vault.acceptOwnership();
    }

    function test_ownership_strangerCannotTransferOrRenounce() public {
        _expectOnlyOwner(ALICE);
        vm.prank(ALICE);
        vault.transferOwnership(ALICE);
        _expectOnlyOwner(ALICE);
        vm.prank(ALICE);
        vault.renounceOwnership();
        assertEq(vault.owner(), OWNER);
    }

    function test_ownership_renounceBeforeSetTokenFreezesTheVaultForever() public {
        vm.startPrank(OWNER);
        vault.setSpreads(PREMIUM, FEE);
        vault.setOpeningPrice(OPENING);
        vault.renounceOwnership();
        vm.stopPrank();
        assertEq(vault.owner(), address(0));

        // Nobody, not even the previous owner, can fill the slot now; token features stay disabled.
        _expectOnlyOwner(OWNER);
        vm.prank(OWNER);
        vault.setToken(address(token));
        assertEq(vault.token(), address(0));
        assertFalse(vault.isConfigured());
        vm.prank(ALICE);
        vm.expectRevert(RisingFloorVault.TokenNotSet.selector);
        vault.buy{value: 1 ether}(0);
    }

    function test_ownership_newOwnerCanFillTheSlotOnce() public {
        vm.prank(OWNER);
        vault.transferOwnership(ALICE);
        vm.startPrank(ALICE);
        vault.acceptOwnership();
        vault.setToken(address(token));
        vm.expectRevert(RisingFloorVault.TokenAlreadySet.selector);
        vault.setToken(address(token));
        vm.stopPrank();
        assertEq(vault.token(), address(token));
    }

    // ------------------------------------------------------------------ setToken / configuration order

    function test_configuration_orderDoesNotMatterAndSettingsSurviveSetToken() public {
        vm.startPrank(OWNER);
        vault.setOpeningPrice(OPENING);
        vault.setSpreads(PREMIUM, FEE);
        assertFalse(vault.isConfigured());
        vault.setToken(address(token));
        vm.stopPrank();
        assertTrue(vault.isConfigured());
        assertEq(vault.openingPrice(), OPENING);
        assertEq(vault.buyPremiumBps(), PREMIUM);
        assertEq(vault.sellFeeBps(), FEE);
        token.mint(address(vault), 10e18);
        assertEq(vault.inventory(), 10e18);
    }

    function test_setSpreads_canBeRepeatedAndEachCallIsBoundedIndependently() public {
        vm.startPrank(OWNER);
        vault.setSpreads(2_000, 1_000);
        vault.setSpreads(0, 0);
        vault.setSpreads(1, 1);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.PremiumTooHigh.selector, type(uint256).max, 2_000));
        vault.setSpreads(type(uint256).max, 0);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.FeeTooHigh.selector, type(uint256).max, 1_000));
        vault.setSpreads(0, type(uint256).max);
        vm.stopPrank();
        assertEq(vault.buyPremiumBps(), 1);
        assertEq(vault.sellFeeBps(), 1);
    }

    function test_setSpreads_changeMidLifeIsCaughtBySlippageGuards() public {
        _configure(0, 0, OPENING);
        _buy(ALICE, 1 ether);
        uint256 buyQuote = vault.quoteBuy(1 ether);
        uint256 sellQuote = vault.quoteSell(500e18);

        vm.prank(OWNER);
        vault.setSpreads(2_000, 1_000);

        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(RisingFloorVault.SlippageExceeded.selector, vault.quoteBuy(1 ether), buyQuote)
        );
        vault.buy{value: 1 ether}(buyQuote);

        vm.startPrank(ALICE);
        token.approve(address(vault), 500e18);
        vm.expectRevert(
            abi.encodeWithSelector(RisingFloorVault.SlippageExceeded.selector, vault.quoteSell(500e18), sellQuote)
        );
        vault.sell(500e18, sellQuote);
        vm.stopPrank();
    }

    function test_setBuysPaused_isIdempotentAndEmitsEachTime() public {
        vm.startPrank(OWNER);
        vm.expectEmit(false, false, false, true, address(vault));
        emit BuysPausedSet(true);
        vault.setBuysPaused(true);
        vm.expectEmit(false, false, false, true, address(vault));
        emit BuysPausedSet(true);
        vault.setBuysPaused(true);
        assertTrue(vault.buysPaused());
        vault.setBuysPaused(false);
        vm.stopPrank();
        assertFalse(vault.buysPaused());
    }

    function test_setOpeningPrice_acceptsMaxValueWhileNothingIsOutstanding() public {
        vm.prank(OWNER);
        vault.setOpeningPrice(type(uint256).max);
        assertEq(vault.floorPrice(), type(uint256).max);
        // Nothing can be bought at that price: every input rounds to zero tokens.
        vm.prank(OWNER);
        vault.setToken(address(token));
        vm.prank(OWNER);
        vault.setSpreads(0, 0);
        token.mint(address(vault), 1e18);
        assertEq(vault.quoteBuy(1 ether), 0);
        vm.prank(ALICE);
        vm.expectRevert(RisingFloorVault.ZeroOutput.selector);
        vault.buy{value: 1 ether}(0);
    }

    // ------------------------------------------------------------------ sell: token-side failures

    function test_sell_withoutApprovalRevertsAndChangesNothing() public {
        _configure();
        uint256 bought = _buy(ALICE, 1 ether);
        uint256 supplyBefore = vault.backedSupply();
        uint256 reserveBefore = vault.reserve();
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vault), 0, bought)
        );
        vault.sell(bought, 0);
        assertEq(vault.backedSupply(), supplyBefore);
        assertEq(vault.reserve(), reserveBefore);
        assertEq(token.balanceOf(ALICE), bought);
    }

    function test_sell_withoutTokensRevertsEvenWithinBackedSupply() public {
        _configure();
        uint256 bought = _buy(ALICE, 1 ether);
        // Bob never bought: the amount is within the backed supply but he has nothing to hand in.
        vm.startPrank(BOB);
        token.approve(address(vault), bought);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, BOB, 0, bought));
        vault.sell(bought, 0);
        vm.stopPrank();
        assertEq(vault.backedSupply(), bought);
        assertEq(BOB.balance, 10_000 ether);
    }

    function test_sell_tokensAreFungible_transferredTokensRedeemAtTheFloor() public {
        _configure();
        uint256 bought = _buy(ALICE, 1 ether);
        vm.prank(ALICE);
        token.transfer(CAROL, bought);
        uint256 quote = vault.quoteSell(bought);
        uint256 out = _sell(CAROL, bought);
        assertEq(out, quote);
        assertEq(CAROL.balance, 10_000 ether + quote);
        assertEq(vault.backedSupply(), 0);
    }

    function test_sell_outsideHoldersAreFirstComeFirstServed() public {
        _configure();
        uint256 bought = _buy(ALICE, 1 ether);
        // Bob holds minted (unbacked) tokens equal to the whole backed supply and redeems first.
        token.mint(BOB, bought);
        _sell(BOB, bought);
        assertEq(vault.backedSupply(), 0);
        // Alice's genuinely backed tokens can no longer be redeemed: the cap is the backed supply.
        vm.startPrank(ALICE);
        token.approve(address(vault), bought);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.ExceedsBackedSupply.selector, 0, bought));
        vault.sell(bought, 0);
        vm.stopPrank();
    }

    function test_sell_exactlyTheBackedSupplyIsTheBoundary() public {
        _configure();
        uint256 bought = _buy(ALICE, 1 ether);
        token.mint(ALICE, 1); // one extra unbacked unit
        vm.startPrank(ALICE);
        token.approve(address(vault), bought + 1);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.ExceedsBackedSupply.selector, bought, bought + 1));
        vault.sell(bought + 1, 0);
        vault.sell(bought, 0); // the boundary itself is accepted
        vm.stopPrank();
        assertEq(vault.backedSupply(), 0);
    }

    function test_sell_fullRedemptionEmitsTheRatchetedOpeningPriceAsFloorAfter() public {
        _configure();
        uint256 a = _buy(ALICE, 1 ether);
        uint256 b = _buy(BOB, 1 ether);
        _sell(ALICE, a);
        uint256 floorBefore = vault.floorPrice();
        uint256 quote = vault.quoteSell(b);
        vm.startPrank(BOB);
        token.approve(address(vault), b);
        vm.expectEmit(true, false, false, true, address(vault));
        emit Sold(BOB, b, quote, floorBefore);
        vault.sell(b, 0);
        vm.stopPrank();
        assertEq(vault.openingPrice(), floorBefore);
        assertEq(vault.floorPrice(), floorBefore);
        // The fee residue stays; a reopen at exactly the minimum is accepted, one wei under is not.
        assertGt(vault.reserve(), 0);
        vm.startPrank(OWNER);
        vault.setOpeningPrice(floorBefore);
        vm.expectRevert(
            abi.encodeWithSelector(RisingFloorVault.OpeningPriceBelowFloor.selector, floorBefore - 1, floorBefore)
        );
        vault.setOpeningPrice(floorBefore - 1);
        vm.stopPrank();
    }

    function test_sell_withZeroFeeFullRedemptionEmptiesTheReserveExactly() public {
        _configure(PREMIUM, 0, OPENING);
        uint256 a = _buy(ALICE, 1 ether);
        uint256 b = _buy(BOB, 3 ether);
        uint256 outA = _sell(ALICE, a);
        uint256 outB = _sell(BOB, b);
        assertEq(outA + outB, 4 ether);
        assertEq(vault.reserve(), 0);
        assertEq(vault.backedSupply(), 0);
        // Nobody got more than they put in; the premium Bob paid went to Alice.
        assertLe(outB, 3 ether);
        assertGe(outA, 1 ether);
    }

    function test_sell_dustWithSupplyOutstandingReverts() public {
        _configure();
        _buy(ALICE, 1 ether); // floor 0.001 ETH per 1e18 units: one unit is worth 1e-3 wei
        vm.startPrank(ALICE);
        token.approve(address(vault), 999);
        assertEq(vault.quoteSell(999), 0);
        vm.expectRevert(RisingFloorVault.ZeroOutput.selector);
        vault.sell(999, 0);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ buy: boundaries

    function test_buy_dustWithSupplyOutstandingReverts() public {
        _configure(0, 0, 2 * WAD); // 2 wei per base unit
        _buy(ALICE, 10); // 5 units, floor 2 wei per unit
        assertEq(vault.backedSupply(), 5);
        assertEq(vault.quoteBuy(1), 0);
        vm.prank(BOB);
        vm.expectRevert(RisingFloorVault.ZeroOutput.selector);
        vault.buy{value: 1}(0);
    }

    function test_buy_canTakeTheWholeInventoryAndThenNothingMore() public {
        _configure();
        uint256 ethIn = INVENTORY * OPENING / WAD; // 1,000 ETH buys every token at the opening price
        uint256 out = _buy(ALICE, ethIn);
        assertEq(out, INVENTORY);
        assertEq(vault.inventory(), 0);
        assertEq(vault.backedSupply(), INVENTORY);
        uint256 wanted = vault.quoteBuy(1 ether);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.InsufficientInventory.selector, 0, wanted));
        vault.buy{value: 1 ether}(0);
        // Redemption returns tokens to inventory, which reopens sales.
        _sell(ALICE, INVENTORY / 2);
        assertEq(vault.inventory(), INVENTORY / 2);
        _buy(BOB, 1 ether);
    }

    function test_buy_minTokensOutEqualToQuoteIsAccepted_oneMoreIsNot() public {
        _configure();
        _buy(ALICE, 1 ether);
        uint256 quote = vault.quoteBuy(2 ether);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.SlippageExceeded.selector, quote, quote + 1));
        vault.buy{value: 2 ether}(quote + 1);
        vm.prank(BOB);
        assertEq(vault.buy{value: 2 ether}(quote), quote);
    }

    function test_buy_whenOwnerDrainedInventoryRevertsButRedemptionsStillWork() public {
        _configure();
        uint256 bought = _buy(ALICE, 1 ether);
        uint256 unsold = vault.inventory();
        vm.prank(OWNER);
        vault.withdrawInventory(OWNER, unsold);
        assertEq(vault.inventory(), 0);
        uint256 wanted = vault.quoteBuy(1 ether);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorVault.InsufficientInventory.selector, 0, wanted));
        vault.buy{value: 1 ether}(0);
        // The owner cannot block the exit.
        uint256 quote = vault.quoteSell(bought);
        uint256 out = _sell(ALICE, bought);
        assertEq(out, quote);
        assertEq(out, 1 ether * (BPS - FEE) / BPS);
        assertEq(vault.backedSupply(), 0);
    }

    function test_buy_pausedThenUnpausedQuotesAreUnchanged() public {
        _configure();
        _buy(ALICE, 1 ether);
        uint256 quote = vault.quoteBuy(1 ether);
        vm.prank(OWNER);
        vault.setBuysPaused(true);
        assertEq(vault.quoteBuy(1 ether), quote); // quotes ignore the pause; the website shows it separately
        vm.prank(OWNER);
        vault.setBuysPaused(false);
        assertEq(_buy(BOB, 1 ether), quote);
    }

    // ------------------------------------------------------------------ inventory and rescue failures

    function test_withdrawInventory_moreThanHeldReverts() public {
        _configure();
        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(vault), INVENTORY, INVENTORY + 1
            )
        );
        vault.withdrawInventory(OWNER, INVENTORY + 1);
        assertEq(vault.inventory(), INVENTORY);
    }

    function test_withdrawInventory_cannotTakeTokensThatWereNeverInventory() public {
        // Backed tokens live with their holders, so draining inventory never reaches them.
        _configure();
        uint256 bought = _buy(ALICE, 1 ether);
        vm.prank(OWNER);
        vault.withdrawInventory(OWNER, INVENTORY - bought);
        assertEq(token.balanceOf(ALICE), bought);
        assertEq(vault.backedSupply(), bought);
        assertEq(vault.floorPrice(), OPENING);
    }

    function test_rescueERC20_addressWithoutCodeReverts() public {
        _configure();
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, ALICE));
        vault.rescueERC20(IERC20(ALICE), OWNER, 1);
    }

    function test_rescueERC20_moreThanHeldReverts() public {
        _configure();
        MockERC20 stray = new MockERC20();
        stray.mint(address(vault), 5);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(vault), 5, 6));
        vault.rescueERC20(IERC20(address(stray)), OWNER, 6);
    }

    function test_rescueERC20_cannotMoveEthOrTheReserve() public {
        _configure();
        _buy(ALICE, 3 ether);
        MockERC20 stray = new MockERC20();
        stray.mint(address(vault), 1e18);
        vm.prank(OWNER);
        vault.rescueERC20(IERC20(address(stray)), OWNER, 1e18);
        assertEq(vault.reserve(), 3 ether);
        assertEq(OWNER.balance, 0);
        assertEq(vault.floorPrice(), OPENING);
    }

    function test_rescueERC20_refusesTheVaultTokenEvenBeforeAnyInventory() public {
        vm.startPrank(OWNER);
        vault.setToken(address(token));
        vm.expectRevert(RisingFloorVault.UseWithdrawInventory.selector);
        vault.rescueERC20(IERC20(address(token)), OWNER, 1);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ forced ETH

    function test_forcedEthRaisesTheFloorAndIsRedeemableByHolders() public {
        _configure(0, 0, OPENING);
        uint256 bought = _buy(ALICE, 1 ether);
        // ETH that arrives without a call (selfdestruct, coinbase) is reserve like any donation.
        vm.deal(address(vault), 2 ether);
        assertEq(vault.floorPrice(), 2 * OPENING);
        uint256 out = _sell(ALICE, bought);
        assertEq(out, 2 ether);
        assertEq(vault.reserve(), 0);
    }

    // ------------------------------------------------------------------ fuzz: quotes are exact

    function testFuzz_quoteBuyMatchesBuyInAnyState(uint256 seed, uint256 ethIn, uint256 premium, uint256 fee) public {
        seed = bound(seed, 1, 500 ether);
        ethIn = bound(ethIn, 1, 500 ether);
        premium = bound(premium, 0, 2_000);
        fee = bound(fee, 0, 1_000);
        _configure(premium, fee, OPENING);
        token.mint(address(vault), type(uint128).max);
        _buy(ALICE, seed);
        // A partial redemption with fee makes the reserve irregular (skipped when it would be dust).
        uint256 third = vault.backedSupply() / 3;
        if (third > 0 && vault.quoteSell(third) > 0) _sell(ALICE, third);

        uint256 quote = vault.quoteBuy(ethIn);
        uint256 askBefore = vault.askPrice();
        if (quote == 0) {
            vm.prank(BOB);
            vm.expectRevert(RisingFloorVault.ZeroOutput.selector);
            vault.buy{value: ethIn}(0);
            return;
        }
        uint256 out = _buy(BOB, ethIn);
        assertEq(out, quote, "quote must be what the buyer receives");
        // Paid per token is at least the ask (rounding is never in the buyer's favour).
        assertGe(ethIn.mulDiv(WAD, out), askBefore);
    }

    function testFuzz_quoteSellMatchesSellInAnyState(uint256 seed, uint256 amount, uint256 premium, uint256 fee)
        public
    {
        seed = bound(seed, 1 gwei, 500 ether);
        premium = bound(premium, 0, 2_000);
        fee = bound(fee, 0, 1_000);
        _configure(premium, fee, OPENING);
        token.mint(address(vault), type(uint128).max);
        _buy(ALICE, seed);
        _buy(BOB, seed / 2 + 1);
        uint256 held = token.balanceOf(BOB);
        amount = bound(amount, 1, held);

        uint256 quote = vault.quoteSell(amount);
        uint256 bidBefore = vault.bidPrice();
        if (quote == 0) {
            vm.startPrank(BOB);
            token.approve(address(vault), amount);
            vm.expectRevert(RisingFloorVault.ZeroOutput.selector);
            vault.sell(amount, 0);
            vm.stopPrank();
            return;
        }
        uint256 out = _sell(BOB, amount);
        assertEq(out, quote, "quote must be what the seller receives");
        // Received per token is at most the bid (the bid view itself rounds twice, hence the 1 wei).
        assertLe(out.mulDiv(WAD, amount), bidBefore + 1);
    }

    function testFuzz_quoteSellIsZeroAboveTheBackedSupply(uint256 extra) public {
        _configure();
        uint256 bought = _buy(ALICE, 1 ether);
        extra = bound(extra, 1, type(uint256).max - bought);
        assertEq(vault.quoteSell(bought + extra), 0);
        assertGt(vault.quoteSell(bought), 0);
    }

    // ------------------------------------------------------------------ fuzz: round trips and spreads

    function testFuzz_roundTripWithZeroSpreadsLosesOnlyRounding(uint256 seed, uint256 ethIn) public {
        seed = bound(seed, 1 gwei, 100 ether);
        ethIn = bound(ethIn, 1 gwei, 100 ether);
        _configure(0, 0, OPENING);
        token.mint(address(vault), type(uint128).max);
        _buy(ALICE, seed);
        uint256 bobBefore = BOB.balance;
        uint256 bought = _buy(BOB, ethIn);
        uint256 out = _sell(BOB, bought);
        assertLe(out, ethIn);
        // Two downward roundings, each worth at most one token's floor value plus one wei.
        uint256 perUnit = vault.floorPrice() / WAD + 1;
        assertGe(out + 2 * perUnit + 2, ethIn, "round trip lost more than rounding");
        assertEq(BOB.balance, bobBefore - ethIn + out);
    }

    function testFuzz_roundTripAtMaxSpreadsLosesAtLeastTheSpreads(uint256 seed, uint256 ethIn) public {
        seed = bound(seed, 1 ether, 100 ether);
        ethIn = bound(ethIn, 1 gwei, 100 ether);
        _configure(2_000, 1_000, OPENING);
        token.mint(address(vault), type(uint128).max);
        _buy(ALICE, seed);
        uint256 bought = _buy(BOB, ethIn);
        uint256 out = _sell(BOB, bought);
        // Bob pays 1.2x the floor and his own premium lifts the floor he redeems at, so in closed
        // form he gets back 0.9 * e * (seed + e) / (1.2 * seed + e): always under 90% of what he paid.
        uint256 closedForm = (9 * ethIn).mulDiv(seed + ethIn, 12 * seed + 10 * ethIn);
        assertLe(out, ethIn * 9 / 10, "seller must bear at least the redemption fee");
        assertLe(out, closedForm + 1, "round trip must not beat the closed-form spread loss");
    }

    function testFuzz_floorNeverFallsAcrossAnyOpeningPrice(uint256 opening, uint256 ethIn, uint256 premium) public {
        opening = bound(opening, 1, 1e30);
        ethIn = bound(ethIn, 1, 1e24);
        premium = bound(premium, 0, 2_000);
        _configure(premium, 0, opening);
        token.mint(address(vault), type(uint256).max - INVENTORY);
        vm.deal(ALICE, ethIn);
        uint256 quote = vault.quoteBuy(ethIn);
        if (quote == 0) {
            vm.prank(ALICE);
            vm.expectRevert(RisingFloorVault.ZeroOutput.selector);
            vault.buy{value: ethIn}(0);
            return;
        }
        _buy(ALICE, ethIn);
        assertGe(vault.floorPrice(), opening);
        assertGe(vault.askPrice(), vault.floorPrice());
        assertLe(vault.bidPrice(), vault.floorPrice());
    }

    function testFuzz_openingRatchetAfterFullRedemption(uint256 ethA, uint256 ethB, uint256 fee) public {
        ethA = bound(ethA, 1 gwei, 100 ether);
        ethB = bound(ethB, 1 gwei, 100 ether);
        fee = bound(fee, 0, 1_000);
        _configure(PREMIUM, fee, OPENING);
        token.mint(address(vault), type(uint128).max);
        uint256 a = _buy(ALICE, ethA);
        uint256 b = _buy(BOB, ethB);
        _sell(BOB, b);
        uint256 lastFloor = vault.floorPrice();
        assertGe(lastFloor, OPENING);
        _sell(ALICE, a);
        assertEq(vault.backedSupply(), 0);
        assertEq(vault.minOpeningPrice(), lastFloor);
        assertEq(vault.openingPrice(), lastFloor);
        vm.startPrank(OWNER);
        if (lastFloor > 1) {
            vm.expectRevert(
                abi.encodeWithSelector(RisingFloorVault.OpeningPriceBelowFloor.selector, lastFloor - 1, lastFloor)
            );
            vault.setOpeningPrice(lastFloor - 1);
        }
        vault.setOpeningPrice(lastFloor);
        vault.setOpeningPrice(lastFloor + 1);
        vm.stopPrank();
        assertEq(vault.openingPrice(), lastFloor + 1);
    }

    function testFuzz_partialRedemptionNeverEmptiesTheReserve(uint256 ethIn, uint256 keep, uint256 fee) public {
        ethIn = bound(ethIn, 1, 100 ether);
        fee = bound(fee, 0, 1_000);
        _configure(0, fee, 1); // 1 wei per 1e18 units: the most dust-prone configuration
        token.mint(address(vault), type(uint128).max);
        uint256 bought = _buy(ALICE, ethIn);
        keep = bound(keep, 1, bought);
        uint256 amount = bought - keep;
        if (amount == 0 || vault.quoteSell(amount) == 0) return;
        _sell(ALICE, amount);
        assertGt(vault.reserve(), 0, "supply outstanding with an empty reserve");
        assertEq(vault.backedSupply(), keep);
        assertGe(vault.floorPrice(), 1);
        assertLe(vault.quoteSell(keep), vault.reserve());
    }
}
