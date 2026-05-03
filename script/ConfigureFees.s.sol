//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {CofferMarketplace} from "../src/CofferMarketplace.sol";

/// @title ConfigureFees
/// @author Coffer
/// @notice Configures per-function fees on the deployed CofferMarketplace
/// @dev Defaults follow coffer-marketplace/defining_fees.md
contract ConfigureFees is Script {
    /// @notice Apply default fee tiers to the marketplace
    function run() external {
        address marketplaceAddr = vm.envAddress("MARKETPLACE_ADDRESS");
        CofferMarketplace marketplace = CofferMarketplace(payable(marketplaceAddr));

        vm.startBroadcast();

        // ── Profit-Based Fees (0.00005 ETH/WETH + 8%) ──
        // buy: 8% of max(0, maturityValue - listingPrice), paid in ETH
        marketplace.setFunctionFee(marketplace.buy.selector, 0.00005 ether, 800);
        // acceptOffer: 8% of max(0, maturityValue - offerAmount), paid in WETH by the offerer.
        // Fee is locked into the Offer struct at makeOffer time.
        marketplace.setFunctionFee(marketplace.acceptOffer.selector, 0.00005 ether, 800);

        // ── App Usage Fees (0.00005 ETH fixed) ──
        marketplace.setFunctionFee(marketplace.list.selector, 0.00005 ether, 0);
        marketplace.setFunctionFee(marketplace.cancelListing.selector, 0.00005 ether, 0);
        marketplace.setFunctionFee(marketplace.makeOffer.selector, 0.00005 ether, 0);
        marketplace.setFunctionFee(marketplace.cancelOffer.selector, 0.00005 ether, 0);

        vm.stopBroadcast();

        console.log("Marketplace fees configured at:", marketplaceAddr);
    }
}
