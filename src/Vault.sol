// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Strategy, EpochData, UserEpochEntry} from "./Types.sol";
import {StrategyManager} from "./StrategyManager.sol";
import {Rebalancer} from "./Rebalancer.sol";

/// @title  Vault — Self-Driving Yield Vault
/// @author AsterPilot
///
/// @notice Pooled vault where users deposit USDT, receive internal shares, and earn
///         yield via AsterDEX Earn (primary engine) and PancakeSwap LP.
///
///         ▸ Fully autonomous — no admin keys, no owner, no multisig, no upgradeability.
///         ▸ No off-chain automation — rebalancing is lazily triggered inside
///           deposit(), withdraw(), changeStrategy(), and ping().
///         ▸ No iteration over user arrays — strategy weights tracked as running sums.
///         ▸ Tournament epochs are tracked on-chain; users self-claim via Tournament.sol.
///
/// @dev    Share price = totalAssets() × 1e18 / totalShares.
///         First depositor mints shares 1:1 with USDT amount.
contract Vault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════
    //                       CONSTANTS
    // ═══════════════════════════════════════════════════════

    /// @notice Duration of one tournament epoch
    uint256 public constant EPOCH_DURATION = 30 days;

    /// @notice Fixed-point precision (1.0 = 1e18)
    uint256 public constant PRECISION = 1e18;

    /// @notice Basis-point denominator
    uint256 public constant BPS = 10_000;

    /// @notice Minimum deposit to prevent dust / share-inflation attacks
    uint256 public constant MIN_DEPOSIT = 1e6;

    // ═══════════════════════════════════════════════════════
    //                      IMMUTABLES
    // ═══════════════════════════════════════════════════════

    /// @notice The deposit / withdrawal token (BEP-20 USDT)
    IERC20 public immutable usdt;

    /// @notice Protocol interaction layer (AsterDEX + PancakeSwap)
    StrategyManager public immutable strategyManager;

    /// @notice Stateless rebalance calculator
    Rebalancer public immutable rebalancer;

    /// @notice Block timestamp when the vault was deployed (epoch 0 starts here)
    uint256 public immutable genesisTimestamp;

    // ═══════════════════════════════════════════════════════
    //                   SHARE ACCOUNTING
    // ═══════════════════════════════════════════════════════

    /// @notice Total vault shares outstanding
    uint256 public totalShares;

    /// @notice Per-user share balance
    mapping(address => uint256) public userShares;

    /// @notice Per-user active strategy
    mapping(address => Strategy) public userStrategy;

    // ═══════════════════════════════════════════════════════
    //          STRATEGY WEIGHT TRACKING (NO ITERATION)
    // ═══════════════════════════════════════════════════════

    /// @notice Aggregate shares for each strategy tier
    uint256 public conservativeShares;
    uint256 public balancedShares;
    uint256 public aggressiveShares;

    // ═══════════════════════════════════════════════════════
    //                   EPOCH TRACKING
    // ═══════════════════════════════════════════════════════

    /// @dev    Epoch data indexed by epoch number (0-based)
    mapping(uint256 => EpochData) internal _epochs;

    /// @notice The highest epoch index that has been finalized
    uint256 public lastFinalizedEpoch;

    // ═══════════════════════════════════════════════════════
    //                 USER EPOCH ENTRIES
    // ═══════════════════════════════════════════════════════

    /// @dev    First-touch snapshot per user per epoch
    mapping(address => mapping(uint256 => UserEpochEntry)) internal _userEpochEntries;

    // ═══════════════════════════════════════════════════════
    //                        EVENTS
    // ═══════════════════════════════════════════════════════

    event Deposited(address indexed user, uint256 amount, uint256 sharesMinted, Strategy strategy);
    event Withdrawn(address indexed user, uint256 sharesBurned, uint256 amountOut);
    event StrategyChanged(address indexed user, Strategy oldStrategy, Strategy newStrategy);
    event Rebalanced(bool moveToLP, uint256 amount);
    event EpochFinalized(uint256 indexed epoch, uint256 endSharePrice, uint256 peak, uint256 low);

    // ═══════════════════════════════════════════════════════
    //                     CONSTRUCTOR
    // ═══════════════════════════════════════════════════════

    /// @param _usdt            BEP-20 USDT address on BNB Chain
    /// @param _strategyManager Deployed StrategyManager (must call bindVault after)
    /// @param _rebalancer      Deployed Rebalancer
    constructor(address _usdt, address _strategyManager, address _rebalancer) {
        require(_usdt != address(0), "V: zero usdt");
        require(_strategyManager != address(0), "V: zero sm");
        require(_rebalancer != address(0), "V: zero rb");

        usdt = IERC20(_usdt);
        strategyManager = StrategyManager(_strategyManager);
        rebalancer = Rebalancer(_rebalancer);
        genesisTimestamp = block.timestamp;
    }

    // ═══════════════════════════════════════════════════════
    //                   CORE OPERATIONS
    // ═══════════════════════════════════════════════════════

    /// @notice Deposit USDT and mint vault shares
    /// @param amount   USDT quantity to deposit
    /// @param strategy Desired yield strategy tier
    function deposit(uint256 amount, Strategy strategy) external nonReentrant {
        require(amount >= MIN_DEPOSIT, "V: below minimum");

        // ── Epoch housekeeping ──────────────────────────────
        _finalizeStaleEpochs();
        _updateEpochMetrics();

        // ── Compute shares BEFORE token transfer (ERC-4626 pattern) ──
        uint256 totalBefore = totalAssets();
        uint256 sharesToMint;
        if (totalShares == 0 || totalBefore == 0) {
            sharesToMint = amount; // 1:1 on first deposit
        } else {
            sharesToMint = (amount * totalShares) / totalBefore;
        }
        require(sharesToMint > 0, "V: zero shares");

        // ── Transfer USDT → StrategyManager ─────────────────
        usdt.safeTransferFrom(msg.sender, address(strategyManager), amount);

        // ── Update strategy weights ─────────────────────────
        if (userShares[msg.sender] > 0) {
            _subtractWeight(msg.sender, userShares[msg.sender]);
        }

        totalShares += sharesToMint;
        userShares[msg.sender] += sharesToMint;
        userStrategy[msg.sender] = strategy;

        _addWeight(msg.sender, userShares[msg.sender]);

        // ── Deploy capital to primary yield engine ──────────
        strategyManager.deployCapital(amount);

        // ── Register for tournament epoch (first-touch) ─────
        _registerUserForEpoch(msg.sender);

        // ── Lazy rebalance ──────────────────────────────────
        _checkAndRebalance();

        emit Deposited(msg.sender, amount, sharesToMint, strategy);
    }

    /// @notice Burn vault shares and withdraw USDT
    /// @param shares Number of shares to redeem
    function withdraw(uint256 shares) external nonReentrant {
        require(shares > 0 && shares <= userShares[msg.sender], "V: invalid shares");

        // ── Epoch housekeeping ──────────────────────────────
        _finalizeStaleEpochs();
        _updateEpochMetrics();

        // ── Compute USDT payout ─────────────────────────────
        uint256 totalBefore = totalAssets();
        uint256 amountOut = (shares * totalBefore) / totalShares;

        // ── Update strategy weights ─────────────────────────
        _subtractWeight(msg.sender, userShares[msg.sender]);

        totalShares -= shares;
        userShares[msg.sender] -= shares;

        if (userShares[msg.sender] > 0) {
            _addWeight(msg.sender, userShares[msg.sender]);
            _registerUserForEpoch(msg.sender);
        }

        // ── Withdraw from protocols → Vault → user ─────────
        strategyManager.withdrawCapital(amountOut);
        usdt.safeTransfer(msg.sender, amountOut);

        // ── Lazy rebalance ──────────────────────────────────
        _checkAndRebalance();

        emit Withdrawn(msg.sender, shares, amountOut);
    }

    /// @notice Switch strategy without depositing or withdrawing
    /// @param newStrategy The new strategy tier to adopt
    function changeStrategy(Strategy newStrategy) external nonReentrant {
        uint256 shares = userShares[msg.sender];
        require(shares > 0, "V: no position");

        _finalizeStaleEpochs();
        _updateEpochMetrics();

        Strategy old = userStrategy[msg.sender];
        require(old != newStrategy, "V: same strategy");

        _subtractWeight(msg.sender, shares);
        userStrategy[msg.sender] = newStrategy;
        _addWeight(msg.sender, shares);

        _registerUserForEpoch(msg.sender);
        _checkAndRebalance();

        emit StrategyChanged(msg.sender, old, newStrategy);
    }

    /// @notice Heartbeat — register for current epoch and trigger rebalance
    ///         without depositing or withdrawing.
    function ping() external nonReentrant {
        require(userShares[msg.sender] > 0, "V: no position");
        _finalizeStaleEpochs();
        _updateEpochMetrics();
        _registerUserForEpoch(msg.sender);
        _checkAndRebalance();
    }

    // ═══════════════════════════════════════════════════════
    //                    VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════

    /// @notice Total USDT value under management
    function totalAssets() public view returns (uint256) {
        return strategyManager.totalAssets();
    }

    /// @notice Current price per share (1e18-scaled; 1e18 = 1.0)
    function sharePrice() public view returns (uint256) {
        if (totalShares == 0) return PRECISION;
        return (totalAssets() * PRECISION) / totalShares;
    }

    /// @notice Current epoch index (0-based, derived from genesis)
    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - genesisTimestamp) / EPOCH_DURATION;
    }

    /// @notice USDT value of a user's position
    function userValue(address user) external view returns (uint256) {
        if (totalShares == 0) return 0;
        return (userShares[user] * totalAssets()) / totalShares;
    }

    /// @notice Weighted-average target LP allocation (basis points)
    function targetLPBps() public view returns (uint256) {
        return rebalancer.computeTargetLPBps(conservativeShares, balancedShares, aggressiveShares);
    }

    /// @notice Read epoch performance data
    function getEpochData(uint256 epoch) external view returns (EpochData memory) {
        return _epochs[epoch];
    }

    /// @notice Read a user's epoch-entry snapshot
    function getUserEpochEntry(address user, uint256 epoch) external view returns (UserEpochEntry memory) {
        return _userEpochEntries[user][epoch];
    }

    // ═══════════════════════════════════════════════════════
    //                  INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════

    /// @dev Trigger a rebalance if LP exposure deviates >5 % from weighted target
    function _checkAndRebalance() internal {
        uint256 total = totalAssets();
        if (total == 0) return;

        uint256 lpVal = strategyManager.lpAssets();
        uint256 _targetBps = targetLPBps();

        Rebalancer.RebalanceAction memory action = rebalancer.checkRebalance(total, lpVal, _targetBps);

        if (action.needed) {
            if (action.moveToLP) {
                strategyManager.moveToLP(action.amount);
            } else {
                strategyManager.moveToAsterDEX(action.amount);
            }
            emit Rebalanced(action.moveToLP, action.amount);
        }
    }

    /// @dev Finalize all epochs that ended since lastFinalizedEpoch.
    ///      Bounded to 12 iterations (one year of catch-up) to cap gas.
    function _finalizeStaleEpochs() internal {
        uint256 current = currentEpoch();
        uint256 start = lastFinalizedEpoch;

        // Bound iteration to prevent excessive gas in degenerate cases
        uint256 end = current;
        if (end > start + 12) {
            end = start + 12;
        }

        uint256 price = sharePrice();

        for (uint256 i = start; i < end;) {
            EpochData storage ep = _epochs[i];
            if (!ep.finalized) {
                ep.endSharePrice = price;
                ep.finalized = true;
                emit EpochFinalized(i, price, ep.peak, ep.low);
            }
            unchecked {
                ++i;
            }
        }

        lastFinalizedEpoch = end;

        // Bootstrap the current epoch if it hasn't been initialized yet
        EpochData storage curr = _epochs[current];
        if (curr.startSharePrice == 0 && totalShares > 0) {
            curr.startSharePrice = price;
            curr.peak = price;
            curr.low = price;
        }
    }

    /// @dev Update peak / low for the current epoch
    function _updateEpochMetrics() internal {
        uint256 current = currentEpoch();
        EpochData storage ep = _epochs[current];
        uint256 price = sharePrice();

        if (price > ep.peak) ep.peak = price;
        if (ep.low == 0 || price < ep.low) ep.low = price;
    }

    /// @dev Record user's position on first interaction within an epoch.
    ///      Subsequent calls in the same epoch are no-ops (preserves entry price).
    function _registerUserForEpoch(address user) internal {
        uint256 current = currentEpoch();
        UserEpochEntry storage entry = _userEpochEntries[user][current];

        if (!entry.registered) {
            entry.shares = userShares[user];
            entry.entrySharePrice = sharePrice();
            entry.strategy = userStrategy[user];
            entry.registered = true;
        }
    }

    /// @dev Add user's shares to the appropriate strategy bucket
    function _addWeight(address user, uint256 shares) internal {
        Strategy s = userStrategy[user];
        if (s == Strategy.Conservative) conservativeShares += shares;
        else if (s == Strategy.Balanced) balancedShares += shares; /* Aggressive */
        else aggressiveShares += shares;
    }

    /// @dev Remove user's shares from the appropriate strategy bucket
    function _subtractWeight(address user, uint256 shares) internal {
        Strategy s = userStrategy[user];
        if (s == Strategy.Conservative) conservativeShares -= shares;
        else if (s == Strategy.Balanced) balancedShares -= shares; /* Aggressive */
        else aggressiveShares -= shares;
    }
}
