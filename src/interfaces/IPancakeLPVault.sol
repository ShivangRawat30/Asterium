// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IPancakeLPVault
/// @notice Adapter interface for PancakeSwap LP positions.
///         Implementations handle the actual router / pair interactions.
interface IPancakeLPVault {
    /// @notice Add single-sided USDT liquidity
    /// @param usdtAmount Amount of USDT to supply
    /// @return lpTokens LP tokens received
    function addLiquidity(uint256 usdtAmount) external returns (uint256 lpTokens);

    /// @notice Remove liquidity and receive USDT
    /// @param usdtAmount Desired USDT amount to receive
    /// @return usdtReturned Actual USDT returned after LP removal
    function removeLiquidity(uint256 usdtAmount) external returns (uint256 usdtReturned);

    /// @notice USDT-equivalent value of LP tokens held by `account`
    /// @param account The account to query
    /// @return USDT value of the LP position
    function getUnderlyingValue(address account) external view returns (uint256);
}
