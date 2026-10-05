//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {CofferMarketplace} from "../src/CofferMarketplace.sol";

/// @title DeployCofferMarketplace
/// @author Coffer
/// @notice Deploys CofferMarketplace and prints the address line to record in `../.env`
/// @dev Runbook: `set -a && source ../.env && set +a` first (plain `source` sets shell-local
///      variables that the forge child process never sees; `set -a` auto-exports them), then
///      `forge script script/DeployCofferMarketplace.s.sol --broadcast --rpc-url $HOODI_RPC_URL`.
///      After a successful broadcast, manually copy the printed
///      `HOODI_COFFER_MARKETPLACE_ADDRESS=...` line into `../.env`. The address is also recorded
///      in `broadcast/`.
///      Requires HOODI_MARKETPLACE_OWNER and HOODI_MARKETPLACE_FEE_RECIPIENT to be set and
///      non-zero; the script reverts otherwise (no fallback keys). For mainnet, introduce a
///      MAINNET_* key set and adjust names accordingly.
contract DeployCofferMarketplace is Script {
    /// @notice Deploy the marketplace contract using environment variables from `../.env`
    function run() external {
        address weth = vm.envAddress("HOODI_WETH_ADDRESS");
        address bondNft = vm.envAddress("HOODI_COFFER_BOND_NFT_ADDRESS");
        address marketplaceOwner = vm.envAddress("HOODI_MARKETPLACE_OWNER");
        address feeRecipient = vm.envAddress("HOODI_MARKETPLACE_FEE_RECIPIENT");
        require(marketplaceOwner != address(0), "Deploy: HOODI_MARKETPLACE_OWNER is zero");
        require(feeRecipient != address(0), "Deploy: HOODI_MARKETPLACE_FEE_RECIPIENT is zero");

        vm.startBroadcast();

        CofferMarketplace marketplace = new CofferMarketplace(weth, bondNft, marketplaceOwner, feeRecipient);

        vm.stopBroadcast();

        address marketplaceAddress = address(marketplace);
        console.log("CofferMarketplace:", marketplaceAddress);

        console.log("\nManual step - add/update this line in ../.env:");
        console.log(string.concat("HOODI_COFFER_MARKETPLACE_ADDRESS=", vm.toString(marketplaceAddress)));
    }
}
