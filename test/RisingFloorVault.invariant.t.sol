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

    function _recordFloor() internal {
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
        if (balance == 0) return;
        uint256 amount = bound(fraction, 1, balance);
        if (amount > vault.backedSupply()) amount = vault.backedSupply();
        uint256 quote = vault.quoteSell(amount);
        if (quote == 0) return;
        vm.startPrank(who);
        token.approve(address(vault), amount);
        uint256 out = vault.sell(amount, quote);
        vm.stopPrank();
        ethOut += out;
        sells++;
        if (vault.backedSupply() == 0) fullRedemptions++;
        _recordFloor();
    }

    function donate(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        amount = bound(amount, 1, 10 ether);
        vm.deal(who, who.balance + amount);
        vm.prank(who);
        (bool ok,) = address(vault).call{value: amount}("");
        require(ok, "donation failed");
        ethIn += amount;
        _recordFloor();
    }

    function deposit(uint256 amount) external {
        amount = bound(amount, 1, 1_000_000e18);
        token.mint(address(this), amount);
        token.approve(address(vault), amount);
        vault.depositInventory(amount);
        inventoryIn += amount;
    }

    function withdraw(uint256 amount) external {
        uint256 available = vault.inventory();
        if (available == 0) return;
        amount = bound(amount, 1, available);
        vm.prank(owner);
        vault.withdrawInventory(owner, amount);
        inventoryOut += amount;
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

    /// @dev The headline guarantee: the quoted floor never goes below any floor seen before.
    function invariant_floorNeverFalls() public view {
        assertGe(vault.floorPrice(), handler.floorHighWater());
        assertGe(vault.openingPrice(), OPENING);
        assertGe(vault.openingPrice(), vault.minOpeningPrice());
    }

    /// @dev ETH is conserved: the reserve is exactly what came in minus what redemptions paid out.
    function invariant_ethConservation() public view {
        assertEq(vault.reserve(), handler.ethIn() - handler.ethOut());
    }

    /// @dev Every token outside the vault was sold by it: the backed supply is exactly the sum of
    ///      actor balances, and the vault's own balance is the rest.
    function invariant_tokenConservation() public view {
        uint256 outside;
        for (uint256 i; i < handler.actorCount(); ++i) {
            outside += token.balanceOf(handler.actor(i));
        }
        assertEq(vault.backedSupply(), outside);
        assertEq(token.balanceOf(address(vault)) + outside + token.balanceOf(OWNER), token.totalSupply());
        assertEq(token.balanceOf(OWNER), handler.inventoryOut());
    }

    /// @dev The reserve can always pay every backed token at the floor: the floor is defined from it.
    function invariant_reserveCoversRedemptions() public view {
        uint256 supply = vault.backedSupply();
        if (supply == 0) return;
        assertGt(vault.reserve(), 0);
        assertLe(vault.quoteSell(supply), vault.reserve());
    }
}
