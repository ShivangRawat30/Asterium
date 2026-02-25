// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Strategy, EpochData, UserEpochEntry} from "./Types.sol";

/// @notice Minimal read interface for the Vault — used by Tournament to
///         retrieve epoch metrics and user snapshots without importing the
///         full Vault contract.
interface IVault {
    function getEpochData(uint256 epoch)
        external view returns (EpochData memory);

    function getUserEpochEntry(address user, uint256 epoch)
        external view returns (UserEpochEntry memory);

    function currentEpoch() external view returns (uint256);
    function sharePrice()   external view returns (uint256);
    function totalShares()  external view returns (uint256);
    function userShares(address user) external view returns (uint256);
}

/// @title  Tournament — Self-Driving Yield Tournament Engine
/// @author AsterPilot
///
/// @notice Trustless, self-claim scoring system.  After each 30-day epoch
///         participants call `claimPoints(epoch)` to receive points computed as:
///
///             Points = ROI × StrategyMultiplier × (1 − VaultDrawdown)
///
///         ▸ No admin keys, no owner, no keeper.
///         ▸ No iteration over user arrays — each user claims individually.
///         ▸ Reads all required data from the Vault's public view functions.
///
/// @dev    Multiplier encoding: Conservative = 10, Balanced = 13, Aggressive = 16
///         (denominator 10 → 1.0×, 1.3×, 1.6×).
///         All intermediate math uses 1e18 precision to avoid truncation.
contract Tournament {
    // ═══════════════════════════════════════════════════════
    //                       CONSTANTS
    // ═══════════════════════════════════════════════════════

    /// @notice Fixed-point precision (1.0 = 1e18)
    uint256 public constant PRECISION = 1e18;

    /// @notice Denominator for the strategy multiplier (10 → 1.0, 1.3, 1.6)
    uint256 public constant MULTIPLIER_DENOM = 10;

    // ═══════════════════════════════════════════════════════
    //                      IMMUTABLES
    // ═══════════════════════════════════════════════════════

    /// @notice The Vault this tournament scores against
    IVault public immutable vault;

    // ═══════════════════════════════════════════════════════
    //                        STATE
    // ═══════════════════════════════════════════════════════

    /// @notice Cumulative points per user across all epochs
    mapping(address => uint256) public totalPoints;

    /// @notice Claim guard: user → epoch → claimed?
    mapping(address => mapping(uint256 => bool)) public claimed;

    /// @notice Global counter for total points ever distributed
    uint256 public totalPointsDistributed;

    // ═══════════════════════════════════════════════════════
    //                        EVENTS
    // ═══════════════════════════════════════════════════════

    event PointsClaimed(
        address indexed user,
        uint256 indexed epoch,
        uint256 points
    );

    // ═══════════════════════════════════════════════════════
    //                     CONSTRUCTOR
    // ═══════════════════════════════════════════════════════

    /// @param _vault Address of the deployed Vault contract
    constructor(address _vault) {
        require(_vault != address(0), "T: zero vault");
        vault = IVault(_vault);
    }

    // ═══════════════════════════════════════════════════════
    //                    CLAIM POINTS
    // ═══════════════════════════════════════════════════════

    /// @notice Claim tournament points for a finalized epoch
    /// @param epoch Epoch index to claim
    /// @return points Points earned (1e18-scaled)
    function claimPoints(uint256 epoch) external returns (uint256 points) {
        require(!claimed[msg.sender][epoch], "T: already claimed");
        require(epoch < vault.currentEpoch(),  "T: epoch not ended");

        // ── Read epoch data ─────────────────────────────────
        EpochData memory ep = vault.getEpochData(epoch);
        require(ep.finalized, "T: epoch not finalized");

        // ── Read user entry ─────────────────────────────────
        UserEpochEntry memory entry = vault.getUserEpochEntry(msg.sender, epoch);
        require(entry.registered, "T: not registered");
        require(entry.shares > 0, "T: no shares");

        // Mark claimed early to prevent reentrancy-style double claims
        claimed[msg.sender][epoch] = true;

        // ── ROI ─────────────────────────────────────────────
        if (ep.endSharePrice <= entry.entrySharePrice) {
            // Negative or zero ROI → zero points
            emit PointsClaimed(msg.sender, epoch, 0);
            return 0;
        }

        uint256 roi = ((ep.endSharePrice - entry.entrySharePrice) * PRECISION)
            / entry.entrySharePrice;

        // ── Vault Drawdown ──────────────────────────────────
        uint256 drawdown = 0;
        if (ep.peak > 0 && ep.peak > ep.low) {
            drawdown = ((ep.peak - ep.low) * PRECISION) / ep.peak;
        }

        // ── Multiplier ──────────────────────────────────────
        uint256 multiplier = _strategyMultiplier(entry.strategy);

        // ── Points = ROI × Multiplier × (1 − Drawdown) ─────
        //    roi            : 1e18-scaled
        //    multiplier     : raw {10, 13, 16}
        //    (P - drawdown) : 1e18-scaled
        //    Result         : 1e18-scaled after dividing by (DENOM × 1e18)
        points = (roi * multiplier * (PRECISION - drawdown))
            / (MULTIPLIER_DENOM * PRECISION);

        totalPoints[msg.sender] += points;
        totalPointsDistributed  += points;

        emit PointsClaimed(msg.sender, epoch, points);
    }

    // ═══════════════════════════════════════════════════════
    //                    VIEW HELPERS
    // ═══════════════════════════════════════════════════════

    /// @notice Preview points for a given user and epoch (read-only)
    /// @return points Estimated points (0 if ineligible or already claimed)
    function previewPoints(
        address user,
        uint256 epoch
    ) external view returns (uint256 points) {
        if (claimed[user][epoch])        return 0;
        if (epoch >= vault.currentEpoch()) return 0;

        EpochData memory ep = vault.getEpochData(epoch);
        if (!ep.finalized) return 0;

        UserEpochEntry memory entry = vault.getUserEpochEntry(user, epoch);
        if (!entry.registered || entry.shares == 0) return 0;
        if (ep.endSharePrice <= entry.entrySharePrice) return 0;

        uint256 roi = ((ep.endSharePrice - entry.entrySharePrice) * PRECISION)
            / entry.entrySharePrice;

        uint256 drawdown = 0;
        if (ep.peak > 0 && ep.peak > ep.low) {
            drawdown = ((ep.peak - ep.low) * PRECISION) / ep.peak;
        }

        uint256 multiplier = _strategyMultiplier(entry.strategy);

        points = (roi * multiplier * (PRECISION - drawdown))
            / (MULTIPLIER_DENOM * PRECISION);
    }

    // ═══════════════════════════════════════════════════════
    //                      INTERNAL
    // ═══════════════════════════════════════════════════════

    /// @dev Map Strategy enum → tournament multiplier (denominator = 10)
    ///      Conservative = 1.0× (10)
    ///      Balanced     = 1.3× (13)
    ///      Aggressive   = 1.6× (16)
    function _strategyMultiplier(Strategy s) internal pure returns (uint256) {
        if (s == Strategy.Conservative) return 10;
        if (s == Strategy.Balanced)     return 13;
        return 16; // Aggressive
    }
}
