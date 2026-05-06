//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {CofferMarketplace} from "../src/CofferMarketplace.sol";

/// @title ConfigureFees
/// @author Coffer
/// @notice Configures per-function fees on the deployed CofferMarketplace
/// @dev Values match the global defining_fees.md
contract ConfigureFees is Script {
    /// @notice Apply default fee tiers to the marketplace
    function run() external {
        address marketplaceAddr = vm.envAddress("MARKETPLACE_ADDRESS");
        CofferMarketplace marketplace = CofferMarketplace(payable(marketplaceAddr));

        vm.startBroadcast();

        // ── Profit-Based Fees (0.00005 ETH/WETH + 8%) ──
        marketplace.setFunctionFee(marketplace.buy.selector, 0.00005 ether, 800);
        marketplace.setFunctionFee(marketplace.acceptOffer.selector, 0.00005 ether, 800);

        // ── Fixed Fees (0.0005 ETH) ──
        marketplace.setFunctionFee(marketplace.list.selector, 0.0005 ether, 0);
        marketplace.setFunctionFee(marketplace.makeOffer.selector, 0.0005 ether, 0);

        // ── App Usage Fees (0.00005 ETH) ──
        marketplace.setFunctionFee(marketplace.cancelListing.selector, 0.00005 ether, 0);
        marketplace.setFunctionFee(marketplace.cancelOffer.selector, 0.00005 ether, 0);

        vm.stopBroadcast();

        console.log("Marketplace fees configured at:", marketplaceAddr);
    }
}
