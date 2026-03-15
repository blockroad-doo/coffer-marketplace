//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {CofferMarketplace} from "../src/CofferMarketplace.sol";

/// @title ConfigureFees
/// @author Coffer
/// @notice Configures fees for CofferMarketplace
contract ConfigureFees is Script {
    /// @notice Configure all function fees for the marketplace
    function run() external {
        address marketplaceAddr = vm.envAddress("MARKETPLACE_ADDRESS");

        CofferMarketplace marketplace = CofferMarketplace(payable(marketplaceAddr));

        vm.startBroadcast();

        // ── Marketplace fees ──
        // list(address,uint256,uint128,uint64)
        marketplace.setFunctionFee(CofferMarketplace.list.selector, 0.001 ether, 0);
        // buy(address,uint256,uint128)
        marketplace.setFunctionFee(CofferMarketplace.buy.selector, 0.001 ether, 100); // 0.001 ETH + 1%
        // makeOffer(address,uint256,uint128,uint64)
        marketplace.setFunctionFee(CofferMarketplace.makeOffer.selector, 0.001 ether, 0);
        // acceptOffer(address,uint256,address,uint128)
        marketplace.setFunctionFee(CofferMarketplace.acceptOffer.selector, 0, 100); // 1% WETH fee

        vm.stopBroadcast();

        console.log("Fees configured");
    }
}
