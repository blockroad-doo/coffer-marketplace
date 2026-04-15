//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.33;

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

        vm.startBroadcast();

        CofferMarketplace marketplace = new CofferMarketplace(weth, bondNft);

        vm.stopBroadcast();

        console.log("CofferMarketplace:", address(marketplace));
    }
}
