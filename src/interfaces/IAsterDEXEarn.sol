// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IAsterDEXEarn
/// @notice Interface for AsterDEX Earn vault — the primary yield engine.
///         Implementations wrap the actual AsterDEX on-chain contracts.
interface IAsterDEXEarn {
    /// @notice Deposit USDT into the earn vault
    /// @param amount Amount of USDT to deposit
    function deposit(uint256 amount) external;

    /// @notice Withdraw USDT from the earn vault
    /// @param amount Desired USDT amount to withdraw (may include accrued yield)
    /// @return withdrawn Actual amount of USDT returned
    function withdraw(uint256 amount) external returns (uint256 withdrawn);

    /// @notice Current balance including accrued yield, denominated in USDT
    /// @param account The account to query
    /// @return USDT-equivalent balance
    function balanceOf(address account) external view returns (uint256);
}
