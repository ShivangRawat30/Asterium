// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title  Rebalancer — Stateless Rebalancing Calculator
/// @author AsterPilot
/// @notice Pure-function contract that decides whether the vault must rebalance
///         and computes the exact capital movement required.
///         Contains zero mutable state — safe to share across vaults.
contract Rebalancer {
    // ═══════════════════════════════════════════════════════
    //                       CONSTANTS
    // ═══════════════════════════════════════════════════════

    /// @notice Minimum deviation (basis points) before a rebalance triggers
    uint256 public constant DEVIATION_THRESHOLD_BPS = 500; // 5 %

    /// @notice Basis-point denominator
    uint256 public constant BPS = 10_000;

    // ═══════════════════════════════════════════════════════
    //                        STRUCTS
    // ═══════════════════════════════════════════════════════

    /// @notice Describes a single rebalancing action
    /// @param needed   True if the deviation exceeds the threshold
    /// @param moveToLP True → move AsterDEX → LP · False → move LP → AsterDEX
    /// @param amount   USDT quantity to move
    struct RebalanceAction {
        bool    needed;
        bool    moveToLP;
        uint256 amount;
    }

    // ═══════════════════════════════════════════════════════
    //                    PURE FUNCTIONS
    // ═══════════════════════════════════════════════════════

    /// @notice Compute the weighted-average target LP allocation in basis points
    /// @dev    Weights per strategy: Conservative 20 %, Balanced 50 %, Aggressive 80 %
    /// @param conservativeShares Total shares held by Conservative users
    /// @param balancedShares     Total shares held by Balanced users
    /// @param aggressiveShares   Total shares held by Aggressive users
    /// @return Target LP allocation in basis points (0-10 000)
    function computeTargetLPBps(
        uint256 conservativeShares,
        uint256 balancedShares,
        uint256 aggressiveShares
    ) external pure returns (uint256) {
        uint256 total = conservativeShares + balancedShares + aggressiveShares;
        if (total == 0) return 2000; // default 20 % LP when vault is empty
        return
            (conservativeShares * 2000 +
                balancedShares * 5000 +
                aggressiveShares * 8000) / total;
    }

    /// @notice Determine whether a rebalance is needed and what action to take
    /// @param totalAssets    Total USDT value across all positions
    /// @param currentLPAssets Current USDT value held in PancakeSwap LP
    /// @param targetLPBps    Desired LP allocation in basis points
    /// @return action The rebalance instruction (may have `needed == false`)
    function checkRebalance(
        uint256 totalAssets,
        uint256 currentLPAssets,
        uint256 targetLPBps
    ) external pure returns (RebalanceAction memory action) {
        if (totalAssets == 0) return action; // nothing to rebalance

        uint256 currentLPBps  = (currentLPAssets * BPS) / totalAssets;
        uint256 targetLPAmount = (totalAssets * targetLPBps) / BPS;

        // Over-exposed to LP → move excess back to AsterDEX Earn
        if (
            currentLPBps > targetLPBps &&
            currentLPBps - targetLPBps > DEVIATION_THRESHOLD_BPS
        ) {
            action.needed   = true;
            action.moveToLP = false;
            action.amount   = currentLPAssets - targetLPAmount;
        }
        // Under-exposed to LP → move shortfall from AsterDEX to LP
        else if (
            targetLPBps > currentLPBps &&
            targetLPBps - currentLPBps > DEVIATION_THRESHOLD_BPS
        ) {
            action.needed   = true;
            action.moveToLP = true;
            action.amount   = targetLPAmount - currentLPAssets;
        }
        // Within tolerance → no action
    }
}
