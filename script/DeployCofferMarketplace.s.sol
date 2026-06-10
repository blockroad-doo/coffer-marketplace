//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {CofferMarketplace} from "../src/CofferMarketplace.sol";

/// @title DeployCofferMarketplace
/// @author Coffer
/// @notice Deploys CofferMarketplace and updates root .env with the deployed address
contract DeployCofferMarketplace is Script {
    string private constant ENV_FILE_PATH = "../.env";

    /// @notice Deploy the marketplace contract using environment variables from root .env
    function run() external {
        address weth = vm.envAddress("HOODI_WETH_ADDRESS");
        address bondNft = vm.envAddress("HOODI_COFFER_BOND_NFT_ADDRESS");
        address marketplaceOwner = vm.envAddress("MARKETPLACE_OWNER");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");

        vm.startBroadcast();

        CofferMarketplace marketplace = new CofferMarketplace(weth, bondNft, marketplaceOwner, feeRecipient);

        vm.stopBroadcast();

        address marketplaceAddress = address(marketplace);
        console.log("CofferMarketplace:", marketplaceAddress);

        console.log("\nUpdating .env file...");
        updateEnvVariable("HOODI_COFFER_MARKETPLACE_ADDRESS", addressToString(marketplaceAddress));
    }

    /// @notice Update an environment variable in the root .env file using sed
    /// @param key The environment variable name
    /// @param value The new value to set
    function updateEnvVariable(string memory key, string memory value) internal {
        string[] memory inputs = new string[](4);
        inputs[0] = "sed";
        inputs[1] = "-i";
        inputs[2] = string(abi.encodePacked("s/^", key, "=.*$/", key, "=", value, "/"));
        inputs[3] = ENV_FILE_PATH;

        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.ffi(inputs);
    }

    /// @notice Convert address to string with 0x prefix
    /// @param addr The address to convert
    /// @return The address as a string
    function addressToString(address addr) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory data = abi.encodePacked(addr);
        bytes memory str = new bytes(2 + data.length * 2);

        str[0] = "0";
        str[1] = "x";

        for (uint256 i = 0; i < data.length; ++i) {
            str[2 + i * 2] = alphabet[uint8(data[i] >> 4)];
            str[3 + i * 2] = alphabet[uint8(data[i] & 0x0f)];
        }

        return string(str);
    }
}
