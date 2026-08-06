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
    /// @dev The target address is a deliberate command-line argument (never read from the
    ///      environment) so a stale shell env can never select the instance being configured.
    ///      Take it from the deploy output or the `broadcast/` record and invoke with:
    ///      `set -a && source ../.env && set +a` (exports the env vars read below; plain `source`
    ///      keeps them shell-local and forge never sees them), then
    ///      `forge script script/ConfigureFees.s.sol --sig "run(address)" <MARKETPLACE_ADDRESS>
    ///      --broadcast --rpc-url $HOODI_RPC_URL`.
    ///      Pre-flight guards revert loudly on a wrong target (typo, wrong chain, non-marketplace
    ///      address) instead of silently configuring it.
    /// @param marketplaceAddr The CofferMarketplace instance to configure
    function run(address marketplaceAddr) external {
        CofferMarketplace marketplace = CofferMarketplace(payable(marketplaceAddr));

        address expectedOwner = vm.envAddress("HOODI_MARKETPLACE_OWNER");
        require(expectedOwner != address(0), "ConfigureFees: HOODI_MARKETPLACE_OWNER is zero");
        address bondNft = vm.envAddress("HOODI_COFFER_BOND_NFT_ADDRESS");

        require(marketplaceAddr.code.length > 0, "ConfigureFees: no code at target address");
        require(marketplace.owner() == expectedOwner, "ConfigureFees: unexpected owner (stale target?)");
        require(marketplace.I_COFFER_BOND_NFT() == bondNft, "ConfigureFees: bond NFT mismatch (stale target?)");

        vm.startBroadcast();

        // Profit-based fees, in basis points, charged only on a completed trade.
        // buySignedListing fee is paid in ETH, acceptSignedOffer fee is paid in WETH.
        // Signing and cancelling are free (gas only).
        marketplace.setFeeBps(800, 800);

        vm.stopBroadcast();

        console.log("Fees set at:", marketplaceAddr);
    }
}
