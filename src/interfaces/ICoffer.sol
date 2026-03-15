//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.33;

/// @title ICoffer
/// @author Coffer
/// @notice Interface for Coffer vault contracts
interface ICoffer {
    /// @notice Get holder conditions for a specific bond
    /// @param bondId The bond NFT ID
    /// @return bondMaturityValue The bond maturity value
    /// @return duration The bond duration in seconds
    /// @return startTimestamp The bond start timestamp
    function sHolderConditions(uint256 bondId)
        external
        view
        returns (uint128 bondMaturityValue, uint32 duration, uint32 startTimestamp);
}
