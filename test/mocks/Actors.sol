// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RisingFloorVault} from "../../src/RisingFloorVault.sol";

/// @dev Seller whose ETH receive hook tries to re-enter the vault; records whether that worked.
contract ReentrantSeller {
    RisingFloorVault public immutable vault;
    IERC20 public immutable token;
    uint256 public reenterAmount;
    bool public reentrySucceeded;
    bytes public reentryError;
    uint8 public mode; // 0 = sell again, 1 = buy, 2 = depositInventory

    constructor(RisingFloorVault vault_, IERC20 token_) {
        vault = vault_;
        token = token_;
    }

    function attack(uint256 amount, uint256 reenterAmount_, uint8 mode_) external {
        reenterAmount = reenterAmount_;
        mode = mode_;
        token.approve(address(vault), type(uint256).max);
        vault.sell(amount, 0);
    }

    receive() external payable {
        if (reenterAmount == 0) return;
        uint256 amount = reenterAmount;
        reenterAmount = 0;
        if (mode == 0) {
            try vault.sell(amount, 0) {
                reentrySucceeded = true;
            } catch (bytes memory err) {
                reentryError = err;
            }
        } else if (mode == 1) {
            try vault.buy{value: msg.value}(0) {
                reentrySucceeded = true;
            } catch (bytes memory err) {
                reentryError = err;
            }
        } else {
            try vault.depositInventory(amount) {
                reentrySucceeded = true;
            } catch (bytes memory err) {
                reentryError = err;
            }
        }
    }
}

/// @dev A contract that refuses ETH, so a redemption paying it must revert cleanly.
contract RejectingReceiver {
    RisingFloorVault public immutable vault;
    IERC20 public immutable token;

    constructor(RisingFloorVault vault_, IERC20 token_) {
        vault = vault_;
        token = token_;
    }

    function sell(uint256 amount) external {
        token.approve(address(vault), amount);
        vault.sell(amount, 0);
    }

    receive() external payable {
        revert("no ETH");
    }
}
