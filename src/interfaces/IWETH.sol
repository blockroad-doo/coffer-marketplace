//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @title IWETH
/// @author Coffer
/// @notice Minimal ERC-20 interface for WETH interactions
interface IWETH {
    /// @notice Transfer tokens from one address to another using an allowance
    /// @param from The address to transfer from
    /// @param to The address to transfer to
    /// @param amount The amount of tokens to transfer
    /// @return Whether the transfer succeeded
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    /// @notice Transfer tokens to a specified address
    /// @param to The address to transfer to
    /// @param amount The amount of tokens to transfer
    /// @return Whether the transfer succeeded
    function transfer(address to, uint256 amount) external returns (bool);

    /// @notice Get the token balance of an account
    /// @param account The address to query the balance of
    /// @return The token balance
    function balanceOf(address account) external view returns (uint256);

    /// @notice Get the spending allowance granted by an owner to a spender
    /// @param owner The address that granted the allowance
    /// @param spender The address that can spend the allowance
    /// @return The remaining allowance
    function allowance(address owner, address spender) external view returns (uint256);

    /// @notice Wrap ETH into WETH
    function deposit() external payable;
}
