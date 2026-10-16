// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title RisingFloorVault
/// @notice An ETH reserve that gives a token a redemption price which can only go up.
///
/// The vault holds two things: an ETH reserve and an inventory of the project token. It sells
/// inventory for ETH at an ask price *above* the floor and buys tokens back at the floor (minus an
/// optional fee), where
///
///     floorPrice = reserve * 1e18 / backedSupply        (wei per 1e18 token base units)
///
/// and `backedSupply` is the amount of token the vault has sold and not yet bought back. Every buy
/// credits the buyer with the right to redeem exactly the tokens it sold them (`redeemable`), and
/// only that credit can be redeemed: tokens that never passed through a vault sale, including
/// inventory the owner withdraws, have no claim on the reserve. While any backed token is
/// outstanding every operation keeps the inequality `floorAfter >= floorBefore`:
///   * a buy adds ETH at or above the floor, so the average backing per token rises;
///   * a sell removes ETH at or below the floor, so the average backing per token rises;
///   * a donation adds ETH and removes nothing.
/// Nobody, including the owner, can withdraw ETH from the reserve: the only way ETH leaves is a
/// redemption by a credited holder. Redemptions can never be paused. The redemption that returns
/// the backed supply to zero pays out the whole reserve, so the reserve is empty whenever nothing
/// is outstanding and ETH is refused in that state: nothing is ever priced into nobody's tokens.
/// The owner sets the opening price of each epoch and can never set it below an opening price at
/// which the vault has already sold.
///
/// The token is launched after this contract, so its address is set once by the owner through
/// `setToken`; every token feature is disabled until then.
///
/// Prices are quoted in wei per 1e18 token base units, independent of the token's decimals. For an
/// 18-decimal token that is simply wei per whole token.
contract RisingFloorVault is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ---------------------------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------------------------

    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;
    /// @notice Price scale: prices are wei per `WAD` token base units.
    uint256 public constant WAD = 1e18;
    /// @notice Highest buy premium over the floor the owner may configure (20%).
    uint256 public constant MAX_BUY_PREMIUM_BPS = 2_000;
    /// @notice Highest redemption fee under the floor the owner may configure (10%).
    uint256 public constant MAX_SELL_FEE_BPS = 1_000;

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    IERC20 private _token;

    /// @notice Ask price used while no backed token is outstanding (wei per 1e18 base units).
    uint256 public openingPrice;
    /// @notice Lowest value `openingPrice` may be set to: the highest opening price at which the
    ///         vault has actually sold. Only owner-set values ever land here, so nobody can inflate it.
    uint256 public minOpeningPrice;
    /// @notice Premium charged over the floor on buys, in basis points.
    uint256 public buyPremiumBps;
    /// @notice Fee kept in the reserve on redemptions, in basis points of the floor payout.
    uint256 public sellFeeBps;
    /// @notice True once the owner has configured the spreads (a zero spread is a valid choice).
    bool public spreadsSet;
    /// @notice True while the owner has paused new sales. Redemptions are never pausable.
    bool public buysPaused;
    /// @notice Token base units sold by the vault and not yet redeemed; what the reserve backs.
    uint256 public backedSupply;
    /// @notice Token base units each account may redeem: credited by `buy`, spent by `sell`,
    ///         movable with `transferRedeemable`. The credits always sum to `backedSupply`.
    mapping(address account => uint256) public redeemable;

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

    event TokenSet(address indexed token);
    event OpeningPriceSet(uint256 price);
    event SpreadsSet(uint256 buyPremiumBps, uint256 sellFeeBps);
    event BuysPausedSet(bool paused);
    event Bought(address indexed buyer, uint256 ethIn, uint256 tokensOut, uint256 floorAfter);
    event Sold(address indexed seller, uint256 tokensIn, uint256 ethOut, uint256 floorAfter);
    event RedeemableTransferred(address indexed from, address indexed to, uint256 amount);
    event ReserveDonated(address indexed from, uint256 amount);
    event InventoryDeposited(address indexed from, uint256 amount);
    event InventoryWithdrawn(address indexed to, uint256 amount);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error ZeroOutput();
    error NotAContract(address token);
    error TokenAlreadySet();
    error TokenNotSet();
    error NothingOutstanding();
    error OpeningPriceNotSet();
    error SpreadsNotSet();
    error BuysArePaused();
    error PremiumTooHigh(uint256 requested, uint256 max);
    error FeeTooHigh(uint256 requested, uint256 max);
    error SupplyOutstanding(uint256 backedSupply);
    error OpeningPriceBelowMinimum(uint256 requested, uint256 min);
    error InsufficientInventory(uint256 available, uint256 requested);
    error ExceedsRedeemable(uint256 redeemable, uint256 requested);
    error SlippageExceeded(uint256 actual, uint256 min);
    error NonStandardTokenTransfer(uint256 expected, uint256 received);
    error EthTransferFailed();
    error UseWithdrawInventory();

    // ---------------------------------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------------------------------

    /// @param owner_ The owner of the vault. Never the deployer: the launch factory deploys this.
    constructor(address owner_) Ownable(owner_) {}

    /// @notice Plain ETH transfers are donations to the reserve and raise the floor for the holders
    ///         credited at that moment. Refused while nothing is outstanding: ETH held with no
    ///         backed token would otherwise be captured by the next buyer, whatever they pay.
    receive() external payable {
        if (backedSupply == 0) revert NothingOutstanding();
        emit ReserveDonated(msg.sender, msg.value);
    }

    // ---------------------------------------------------------------------------------------------
    // Owner configuration
    // ---------------------------------------------------------------------------------------------

    /// @notice Sets the project token once. Reverts if already set, if `token_` is zero or if
    ///         `token_` has no code: the slot is one-shot, so a wrong address would be permanent.
    function setToken(address token_) external onlyOwner {
        if (token_ == address(0)) revert ZeroAddress();
        if (token_.code.length == 0) revert NotAContract(token_);
        if (address(_token) != address(0)) revert TokenAlreadySet();
        _token = IERC20(token_);
        emit TokenSet(token_);
    }

    /// @notice Sets the ask price used while nothing is outstanding, in wei per 1e18 base units.
    /// @dev Only while `backedSupply == 0`, and never below an opening price the vault has already
    ///      sold at (`minOpeningPrice`), so the vault's own sale price never goes down across epochs.
    function setOpeningPrice(uint256 price) external onlyOwner {
        if (price == 0) revert ZeroAmount();
        if (backedSupply != 0) revert SupplyOutstanding(backedSupply);
        if (price < minOpeningPrice) revert OpeningPriceBelowMinimum(price, minOpeningPrice);
        openingPrice = price;
        emit OpeningPriceSet(price);
    }

    /// @notice Renouncing before the token slot is filled would leave the slot empty forever, so
    ///         it is refused until `setToken` has been called.
    function renounceOwnership() public override onlyOwner {
        _requireToken();
        super.renounceOwnership();
    }

    /// @notice Sets the buy premium and the redemption fee, both in basis points and both capped.
    function setSpreads(uint256 buyPremiumBps_, uint256 sellFeeBps_) external onlyOwner {
        if (buyPremiumBps_ > MAX_BUY_PREMIUM_BPS) revert PremiumTooHigh(buyPremiumBps_, MAX_BUY_PREMIUM_BPS);
        if (sellFeeBps_ > MAX_SELL_FEE_BPS) revert FeeTooHigh(sellFeeBps_, MAX_SELL_FEE_BPS);
        buyPremiumBps = buyPremiumBps_;
        sellFeeBps = sellFeeBps_;
        spreadsSet = true;
        emit SpreadsSet(buyPremiumBps_, sellFeeBps_);
    }

    /// @notice Pauses or resumes new sales. Redemptions are unaffected.
    function setBuysPaused(bool paused) external onlyOwner {
        buysPaused = paused;
        emit BuysPausedSet(paused);
    }

    /// @notice Moves unsold inventory out of the vault. Inventory is not part of the backing, so
    ///         this never changes the floor, and withdrawn tokens carry no redemption credit, so
    ///         they cannot be turned into reserve ETH.
    function withdrawInventory(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        IERC20 token_ = _requireToken();
        token_.safeTransfer(to, amount);
        emit InventoryWithdrawn(to, amount);
    }

    /// @notice Recovers an unrelated ERC-20 sent here by mistake. The project token itself is
    ///         inventory and leaves only through `withdrawInventory`.
    function rescueERC20(IERC20 erc20, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (address(erc20) == address(_token)) revert UseWithdrawInventory();
        erc20.safeTransfer(to, amount);
        emit ERC20Rescued(address(erc20), to, amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Public actions
    // ---------------------------------------------------------------------------------------------

    /// @notice Adds project tokens to the inventory the vault may sell. Anyone may call.
    function depositInventory(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        IERC20 token_ = _requireToken();
        _pullExact(token_, msg.sender, amount);
        emit InventoryDeposited(msg.sender, amount);
    }

    /// @notice Buys tokens from the inventory with the ETH sent, at the current ask price.
    /// @param minTokensOut Slippage guard: revert if fewer base units would be received.
    /// @return tokensOut Token base units transferred to the caller.
    function buy(uint256 minTokensOut) external payable nonReentrant returns (uint256 tokensOut) {
        IERC20 token_ = _requireToken();
        if (!spreadsSet) revert SpreadsNotSet();
        if (openingPrice == 0) revert OpeningPriceNotSet();
        if (buysPaused) revert BuysArePaused();
        if (msg.value == 0) revert ZeroAmount();

        uint256 supply = backedSupply;
        uint256 reserveBefore = address(this).balance - msg.value;
        tokensOut = _tokensOut(msg.value, reserveBefore, supply);
        if (tokensOut == 0) revert ZeroOutput();
        if (tokensOut < minTokensOut) revert SlippageExceeded(tokensOut, minTokensOut);
        uint256 available = token_.balanceOf(address(this));
        if (tokensOut > available) revert InsufficientInventory(available, tokensOut);

        if (supply == 0) {
            // An epoch opens at `openingPrice`; the vault may never reopen below a price it sold at.
            uint256 opening = openingPrice;
            if (opening > minOpeningPrice) minOpeningPrice = opening;
        }
        backedSupply = supply + tokensOut;
        redeemable[msg.sender] += tokensOut;
        token_.safeTransfer(msg.sender, tokensOut);
        emit Bought(msg.sender, msg.value, tokensOut, floorPrice());
    }

    /// @notice Redeems tokens for ETH at the floor price minus the redemption fee. The redemption
    ///         that returns the backed supply to zero pays the whole reserve with no fee: there is
    ///         no remaining holder for a fee to stay behind for.
    /// @param amount Token base units to redeem; at most `redeemable(msg.sender)`.
    /// @param minEthOut Slippage guard: revert if less ETH would be paid.
    /// @return ethOut Wei paid to the caller.
    function sell(uint256 amount, uint256 minEthOut) external nonReentrant returns (uint256 ethOut) {
        IERC20 token_ = _requireToken();
        if (amount == 0) revert ZeroAmount();
        uint256 credit = redeemable[msg.sender];
        if (amount > credit) revert ExceedsRedeemable(credit, amount);
        uint256 supply = backedSupply; // >= credit >= amount: credits always sum to the supply

        uint256 reserve_ = address(this).balance;
        ethOut = _ethOut(amount, reserve_, supply);
        if (ethOut == 0) revert ZeroOutput();
        if (ethOut < minEthOut) revert SlippageExceeded(ethOut, minEthOut);

        uint256 remaining = supply - amount;
        redeemable[msg.sender] = credit - amount;
        backedSupply = remaining;

        _pullExact(token_, msg.sender, amount);
        // All state is final here; the floor reported is the one after this redemption settles.
        emit Sold(msg.sender, amount, ethOut, _floorAfterPayout(reserve_ - ethOut, remaining));
        (bool ok,) = msg.sender.call{value: ethOut}("");
        if (!ok) revert EthTransferFailed();
    }

    /// @notice Moves redemption credit to another account, for a holder who passes tokens on and
    ///         wants the floor guarantee to travel with them. Moves no tokens.
    function transferRedeemable(address to, uint256 amount) external {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 credit = redeemable[msg.sender];
        if (amount > credit) revert ExceedsRedeemable(credit, amount);
        redeemable[msg.sender] = credit - amount;
        redeemable[to] += amount;
        emit RedeemableTransferred(msg.sender, to, amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice The project token, or the zero address until `setToken` is called.
    function token() public view returns (address) {
        return address(_token);
    }

    /// @notice ETH backing the outstanding supply, in wei.
    function reserve() public view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Token base units held by the vault and available for sale.
    function inventory() public view returns (uint256) {
        if (address(_token) == address(0)) return 0;
        return _token.balanceOf(address(this));
    }

    /// @notice True once the token, the spreads and the opening price are all set.
    function isConfigured() public view returns (bool) {
        return address(_token) != address(0) && spreadsSet && openingPrice != 0;
    }

    /// @notice Guaranteed redemption price before fee, in wei per 1e18 base units.
    /// @dev While nothing is outstanding this is the opening price the next buyer pays, which is
    ///      the floor their tokens will have; nothing is redeemable in that state (see `bidPrice`).
    function floorPrice() public view returns (uint256) {
        uint256 supply = backedSupply;
        if (supply == 0) return openingPrice;
        return address(this).balance.mulDiv(WAD, supply);
    }

    /// @notice Price a buyer pays, in wei per 1e18 base units: floor plus premium, or the opening
    ///         price with no premium while nothing is outstanding.
    function askPrice() public view returns (uint256) {
        uint256 supply = backedSupply;
        if (supply == 0) return openingPrice;
        return address(this).balance.mulDiv(WAD * (BPS + buyPremiumBps), supply * BPS);
    }

    /// @notice Price a seller receives, in wei per 1e18 base units (floor minus fee); 0 while
    ///         nothing is outstanding, since nothing can be redeemed then.
    function bidPrice() public view returns (uint256) {
        if (backedSupply == 0) return 0;
        return floorPrice().mulDiv(BPS - sellFeeBps, BPS);
    }

    /// @notice Token base units `ethIn` wei would buy right now, ignoring inventory limits.
    function quoteBuy(uint256 ethIn) external view returns (uint256) {
        if (openingPrice == 0 && backedSupply == 0) return 0;
        return _tokensOut(ethIn, address(this).balance, backedSupply);
    }

    /// @notice Wei the caller would receive for redeeming `amount` base units right now; 0 if the
    ///         caller's credit does not cover it. Off-chain readers pass the account as `from`, or
    ///         use `quoteSellFor`.
    function quoteSell(uint256 amount) external view returns (uint256) {
        return quoteSellFor(msg.sender, amount);
    }

    /// @notice Wei `account` would receive for redeeming `amount` base units right now; 0 if the
    ///         account's credit does not cover it.
    function quoteSellFor(address account, uint256 amount) public view returns (uint256) {
        if (amount == 0 || amount > redeemable[account]) return 0;
        return _ethOut(amount, address(this).balance, backedSupply);
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    /// @dev Tokens for `ethIn` given the reserve *before* `ethIn` was added. Rounds down, so the
    ///      buyer never receives more than `ethIn / ask`, which is what keeps the floor monotone.
    function _tokensOut(uint256 ethIn, uint256 reserveBefore, uint256 supply) internal view returns (uint256) {
        if (supply == 0) return ethIn.mulDiv(WAD, openingPrice);
        return (ethIn * BPS).mulDiv(supply, reserveBefore * (BPS + buyPremiumBps));
    }

    /// @dev ETH for `amount` tokens at the floor minus the fee. Rounds down in favour of the reserve.
    ///      Redeeming the entire backed supply pays the entire reserve: fees and rounding residue
    ///      belong to the remaining holders, and there are none.
    function _ethOut(uint256 amount, uint256 reserve_, uint256 supply) internal view returns (uint256) {
        if (amount == supply) return reserve_;
        return (amount * (BPS - sellFeeBps)).mulDiv(reserve_, supply * BPS);
    }

    /// @dev Floor for a given reserve and supply; the opening price when nothing is outstanding.
    function _floorAfterPayout(uint256 reserve_, uint256 supply) internal view returns (uint256) {
        if (supply == 0) return openingPrice;
        return reserve_.mulDiv(WAD, supply);
    }

    function _requireToken() internal view returns (IERC20 token_) {
        token_ = _token;
        if (address(token_) == address(0)) revert TokenNotSet();
    }

    /// @dev Pulls exactly `amount` base units; rejects fee-on-transfer or rebasing behaviour.
    function _pullExact(IERC20 token_, address from, uint256 amount) internal {
        uint256 before = token_.balanceOf(address(this));
        token_.safeTransferFrom(from, address(this), amount);
        uint256 received = token_.balanceOf(address(this)) - before;
        if (received != amount) revert NonStandardTokenTransfer(amount, received);
    }
}
