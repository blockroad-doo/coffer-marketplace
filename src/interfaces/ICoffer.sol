//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/**
 * @title ICoffer
 * @author Blockroad Ltd
 * @notice Minimal interface for reading bond data from a Coffer contract
 */
interface ICoffer {
    /// @notice Returns the bond conditions for a given bond ID
    /// @param bondId The ID of the bond to query
    /// @return bondMaturityValue The value the bond pays at maturity
    /// @return duration The duration of the bond in seconds
    /// @return startTimestamp The timestamp when the bond was created
    /// @return consensusWithdrawClosed Whether the consensus path has been closed for this bond (either an EIP-7002
    /// request was issued or funds were reserved in-place via the cover-in-place fallback). A closed bond claims
    /// against the Coffer's whole balance, an open one must leave totalConsensusReserved behind
    function sHolderConditions(uint256 bondId)
        external
        view
        returns (uint128 bondMaturityValue, uint32 duration, uint32 startTimestamp, bool consensusWithdrawClosed);

    /// @notice Total value the Coffer holds back for bonds whose consensus withdrawal has been closed
    /// @return The reserved amount in wei, senior to every bond whose own consensusWithdrawClosed is false
    function totalConsensusReserved() external view returns (uint128);

    /// @notice Returns the first part of the validator public key
    /// @return The first 32 bytes of the validator public key
    function iPublicKeyPart1() external view returns (bytes32);

    /// @notice Returns the second part of the validator public key
    /// @return The remaining 16 bytes of the validator public key
    function iPublicKeyPart2() external view returns (bytes16);
}
