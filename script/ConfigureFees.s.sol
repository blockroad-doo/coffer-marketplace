//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {CofferMarketplace} from "../src/CofferMarketplace.sol";

/// @title ConfigureFees
/// @author Coffer
/// @notice Configures the profit-based fee basis points on the deployed CofferMarketplace
/// @dev Only buySignedListing (ETH) and acceptSignedOffer (WETH) charge a fee. Signing and cancelling are free.
contract ConfigureFees is Script {
    /// @notice Apply default fee tiers to the marketplace
    function run() external {
        address marketplaceAddr = vm.envAddress("HOODI_COFFER_MARKETPLACE_ADDRESS");
        CofferMarketplace marketplace = CofferMarketplace(payable(marketplaceAddr));

        vm.startBroadcast();

        // Profit-based fees, in basis points, charged only on a completed trade.
        // buySignedListing fee is paid in ETH, acceptSignedOffer fee is paid in WETH.
        // Signing and cancelling are free (gas only).
        marketplace.setFeeBps(800, 800);

        vm.stopBroadcast();

        console.log("Fees set at:", marketplaceAddr);
    }
}
