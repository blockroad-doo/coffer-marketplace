//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {CofferMarketplace} from "../src/CofferMarketplace.sol";

/// @title DeployCofferMarketplace
/// @author Coffer
/// @notice Deploys CofferMarketplace
contract DeployCofferMarketplace is Script {
    /// @notice Deploy the marketplace contract using environment variables
    function run() external {
        address weth = vm.envAddress("WETH_ADDRESS");
        address bondNft = vm.envAddress("BOND_NFT_ADDRESS");
        address marketplaceOwner = vm.envAddress("MARKETPLACE_OWNER");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");

        vm.startBroadcast();

        CofferMarketplace marketplace = new CofferMarketplace(weth, bondNft, marketplaceOwner, feeRecipient);

        vm.stopBroadcast();

        console.log("CofferMarketplace:", address(marketplace));
    }
}
