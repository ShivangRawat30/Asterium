// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAsterDEXEarn} from "./interfaces/IAsterDEXEarn.sol";
import {IPancakeLPVault} from "./interfaces/IPancakeLPVault.sol";

/// @title  StrategyManager — Protocol Interaction Layer
/// @author AsterPilot
/// @notice Holds all capital deployed to AsterDEX Earn (primary yield engine) and
///         PancakeSwap LP.  Only the bound Vault contract may mutate state.
///
/// @dev    Deployment flow (atomic in a single script / batch tx):
///           1. Deploy StrategyManager(usdt, asterDEX, pancakeLP)
///           2. Deploy Vault(usdt, strategyManager, rebalancer)
///           3. Call strategyManager.bindVault(vaultAddress)
///         After step 3, `vault` is permanently set and no further admin action
///         is possible.
contract StrategyManager {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════
    //                      IMMUTABLES
    // ═══════════════════════════════════════════════════════

    IERC20 public immutable usdt;
    IAsterDEXEarn public immutable asterDEX;
    IPancakeLPVault public immutable pancakeLP;

    // ═══════════════════════════════════════════════════════
    //                   VAULT BINDING
    // ═══════════════════════════════════════════════════════

    /// @notice The Vault address; set exactly once via `bindVault()`
    address public vault;

    // ═══════════════════════════════════════════════════════
    //                       EVENTS
    // ═══════════════════════════════════════════════════════

    event VaultBound(address indexed vault);
    event CapitalDeployed(uint256 amount);
    event CapitalWithdrawn(uint256 requested, uint256 sent);
    event MovedToLP(uint256 amount);
    event MovedToAsterDEX(uint256 amount);

    // ═══════════════════════════════════════════════════════
    //                      MODIFIERS
    // ═══════════════════════════════════════════════════════

    modifier onlyVault() {
        require(msg.sender == vault, "SM: caller != vault");
        _;
    }

    // ═══════════════════════════════════════════════════════
    //                     CONSTRUCTOR
    // ═══════════════════════════════════════════════════════

    /// @param _usdt      BEP-20 USDT address
    /// @param _asterDEX  AsterDEX Earn adapter
    /// @param _pancakeLP PancakeSwap LP adapter
    constructor(address _usdt, address _asterDEX, address _pancakeLP) {
        require(_usdt != address(0) && _asterDEX != address(0) && _pancakeLP != address(0), "SM: zero address");

        usdt = IERC20(_usdt);
        asterDEX = IAsterDEXEarn(_asterDEX);
        pancakeLP = IPancakeLPVault(_pancakeLP);

        // One-time infinite approval to external protocols
        IERC20(_usdt).forceApprove(_asterDEX, type(uint256).max);
        IERC20(_usdt).forceApprove(_pancakeLP, type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════
    //              ONE-TIME VAULT INITIALIZATION
    // ═══════════════════════════════════════════════════════

    /// @notice Permanently bind the Vault address.  Callable exactly once.
    ///         Must be invoked in the same deployment batch as the Vault.
    function bindVault(address _vault) external {
        require(vault == address(0), "SM: vault already bound");
        require(_vault != address(0), "SM: zero vault");
        vault = _vault;
        emit VaultBound(_vault);
    }

    // ═══════════════════════════════════════════════════════
    //               CAPITAL OPERATIONS (VAULT)
    // ═══════════════════════════════════════════════════════

    /// @notice Deploy USDT into AsterDEX Earn (primary yield engine)
    /// @param amount USDT amount to deploy
    function deployCapital(uint256 amount) external onlyVault {
        uint256 bal = usdt.balanceOf(address(this));
        uint256 toDeploy = _min(amount, bal);
        if (toDeploy > 0) {
            asterDEX.deposit(toDeploy);
        }
        emit CapitalDeployed(toDeploy);
    }

    /// @notice Withdraw USDT from protocols and send to Vault
    /// @dev    Draws from AsterDEX first (more liquid), then LP if short
    /// @param amount Desired USDT amount
    function withdrawCapital(uint256 amount) external onlyVault {
        uint256 idle = usdt.balanceOf(address(this));

        if (idle < amount) {
            uint256 needed = amount - idle;

            // 1. AsterDEX Earn (primary, more liquid)
            uint256 dexBal = _asterDEXBalance();
            uint256 fromDex = _min(needed, dexBal);
            if (fromDex > 0) {
                asterDEX.withdraw(fromDex);
                needed -= fromDex;
            }

            // 2. PancakeSwap LP (secondary)
            if (needed > 0) {
                pancakeLP.removeLiquidity(needed);
            }
        }

        uint256 available = usdt.balanceOf(address(this));
        uint256 toSend = _min(available, amount);
        if (toSend > 0) {
            usdt.safeTransfer(vault, toSend);
        }
        emit CapitalWithdrawn(amount, toSend);
    }

    /// @notice Move capital from AsterDEX Earn → PancakeSwap LP
    /// @param amount USDT amount to shift
    function moveToLP(uint256 amount) external onlyVault {
        uint256 dexBal = _asterDEXBalance();
        uint256 toWithdraw = _min(amount, dexBal);
        if (toWithdraw > 0) {
            asterDEX.withdraw(toWithdraw);
        }
        uint256 available = usdt.balanceOf(address(this));
        uint256 toLp = _min(amount, available);
        if (toLp > 0) {
            pancakeLP.addLiquidity(toLp);
        }
        emit MovedToLP(toLp);
    }

    /// @notice Move capital from PancakeSwap LP → AsterDEX Earn
    /// @param amount USDT amount to shift
    function moveToAsterDEX(uint256 amount) external onlyVault {
        uint256 balBefore = usdt.balanceOf(address(this));
        pancakeLP.removeLiquidity(amount);
        uint256 received = usdt.balanceOf(address(this)) - balBefore;
        if (received > 0) {
            asterDEX.deposit(received);
        }
        emit MovedToAsterDEX(received);
    }

    // ═══════════════════════════════════════════════════════
    //                    VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════

    /// @notice Total USDT value under management (AsterDEX + LP + idle)
    function totalAssets() external view returns (uint256) {
        return _asterDEXBalance() + _lpBalance() + usdt.balanceOf(address(this));
    }

    /// @notice USDT value currently in AsterDEX Earn
    function asterDEXAssets() external view returns (uint256) {
        return _asterDEXBalance();
    }

    /// @notice USDT value currently in PancakeSwap LP
    function lpAssets() external view returns (uint256) {
        return _lpBalance();
    }

    // ═══════════════════════════════════════════════════════
    //                   INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════

    function _asterDEXBalance() internal view returns (uint256) {
        return asterDEX.balanceOf(address(this));
    }

    function _lpBalance() internal view returns (uint256) {
        return pancakeLP.getUnderlyingValue(address(this));
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
