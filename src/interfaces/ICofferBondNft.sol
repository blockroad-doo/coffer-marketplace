//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @title ICofferBondNft
/// @author Coffer
/// @notice Interface for Coffer bond NFT contracts
interface ICofferBondNft {
    /// @notice Mint a new bond NFT to the specified holder
    /// @param holderAddress The address to mint the bond to
    /// @return bondId The newly minted bond token ID
    function mintCofferBond(address holderAddress) external returns (uint256 bondId);

    /// @notice Burn a bond NFT
    /// @param bondId The bond token ID to burn
    function burnCofferBond(uint256 bondId) external;

    /// @notice Get the Coffer associated with a bond
    /// @param bondId The bond token ID
    /// @return The Coffer address
    function cofferOf(uint256 bondId) external view returns (address);

    /// @notice Get the owner of a bond NFT
    /// @param bondId The bond token ID
    /// @return The owner address
    function ownerOf(uint256 bondId) external view returns (address);

    /// @notice Transfer a bond NFT between addresses
    /// @param from The current owner
    /// @param to The new owner
    /// @param tokenId The bond token ID
    function transferFrom(address from, address to, uint256 tokenId) external;

    /// @notice Safely transfer a bond NFT, checking receiver support
    /// @param from The current owner
    /// @param to The new owner
    /// @param tokenId The bond token ID
    function safeTransferFrom(address from, address to, uint256 tokenId) external;

    /// @notice Set or revoke approval for an operator to manage all tokens
    /// @param operator The operator address
    /// @param approved Whether to approve or revoke
    function setApprovalForAll(address operator, bool approved) external;

    /// @notice Check if an operator is approved for all tokens of an owner
    /// @param owner The token owner
    /// @param operator The operator to check
    /// @return Whether the operator is approved
    function isApprovedForAll(address owner, address operator) external view returns (bool);
}
