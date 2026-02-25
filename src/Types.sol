// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Strategy tiers governing AsterDEX / LP allocation and tournament multiplier
enum Strategy {
    Conservative, // 80% AsterDEX Earn · 20% LP — multiplier 1.0×
    Balanced,     // 50% AsterDEX Earn · 50% LP — multiplier 1.3×
    Aggressive    // 20% AsterDEX Earn · 80% LP — multiplier 1.6×
}

/// @notice Per-epoch vault performance snapshot
struct EpochData {
    uint256 startSharePrice; // Share price at epoch start  (1e18-scaled)
    uint256 endSharePrice;   // Share price at epoch end    (1e18-scaled)
    uint256 peak;            // Highest share price in epoch (1e18-scaled)
    uint256 low;             // Lowest  share price in epoch (1e18-scaled)
    bool    finalized;       // True once the epoch has been settled
}

/// @notice User position snapshot captured on first interaction within an epoch
struct UserEpochEntry {
    uint256  shares;          // User's share balance at registration
    uint256  entrySharePrice; // Share price at registration (1e18-scaled)
    Strategy strategy;        // User's strategy at registration
    bool     registered;      // Guard against double-registration
}
