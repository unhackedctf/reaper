// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

import "./interfaces/IStrategy.sol";
import "./interfaces/IERC4626.sol";
import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import {FixedPointMathLib} from "./library/FixedPointMathLib.sol";

/**
 * @notice Implementation of a vault to deposit funds for yield optimizing.
 * This is the contract that receives funds and that users interface with.
 * The yield optimizing strategy itself is implemented in a separate 'Strategy.sol' contract.
 */
contract ReaperVaultV2 is IERC4626, ERC20, ReentrancyGuard, AccessControlEnumerable {
    using SafeERC20 for IERC20Metadata;
    using FixedPointMathLib for uint256;

    struct StrategyParams {
        uint256 activation; // Activation block.timestamp
        uint256 allocBPS; // Allocation in BPS of vault's total assets
        uint256 allocated; // Amount of capital allocated to this strategy
        uint256 gains; // Total returns that Strategy has realized for Vault
        uint256 losses; // Total losses that Strategy has realized for Vault
        uint256 lastReport; // block.timestamp of the last time a report occured
    }

    mapping(address => StrategyParams) public strategies;  // mapping strategies to their strategy parameters
    address[] public withdrawalQueue; // Ordering that `withdraw` uses to determine which strategies to pull funds from
    uint256 public constant DEGRADATION_COEFFICIENT = 10 ** 18; // The unit for calculating profit degradation.
    uint256 public constant PERCENT_DIVISOR = 10_000; // Basis point unit, for calculating slippage and strategy allocations
    uint256 public tvlCap; // The maximum amount of assets the vault can hold while still allowing deposits
    uint256 public totalAllocBPS; // Sum of allocBPS across all strategies (in BPS, <= 10k)
    uint256 public totalAllocated; // Amount of tokens that have been allocated to all strategies
    uint256 public lastReport; // block.timestamp of last report from any strategy
    uint256 public constructionTime; // The time the vault was deployed - for front-end
    bool public emergencyShutdown; // Emergency shutdown - when true funds are pulled out of strategies to the vault
    address public immutable asset; // The asset the vault accepts and looks to maximize.
    uint256 public withdrawMaxLoss = 1; // Max slippage(loss) allowed when withdrawing, in BPS (0.01%)
    uint256 public lockedProfitDegradation; // rate per block of degradation. DEGRADATION_COEFFICIENT is 100% per block
    uint256 public  lockedProfit; // how much profit is locked and cant be withdrawn

    /**
     * Reaper Roles in increasing order of privilege.
     * {STRATEGIST} - Role conferred to strategists, allows for tweaking non-critical params.
     * {GUARDIAN} - Multisig requiring 2 signatures for emergency measures such as pausing and panicking.
     * {ADMIN}- Multisig requiring 3 signatures for unpausing and changing TVL cap.
     *
     * The DEFAULT_ADMIN_ROLE (in-built access control role) will be granted to a multisig requiring 4
     * signatures. This role would have the ability to add strategies, as well as the ability to grant any other
     * roles.
     *
     * Also note that roles are cascading. So any higher privileged role should be able to perform all the functions
     * of any lower privileged role.
     */
    bytes32 public constant STRATEGIST = keccak256("STRATEGIST");
    bytes32 public constant GUARDIAN = keccak256("GUARDIAN");
    bytes32 public constant ADMIN = keccak256("ADMIN");
    bytes32[] private cascadingAccess;

    event TvlCapUpdated(uint256 newTvlCap);
    event LockedProfitDegradationUpdated(uint256 degradation);
    event StrategyReported(
        address indexed strategy,
        int256 roi,
        uint256 repayment,
        uint256 gains,
        uint256 losses,
        uint256 allocated,
        uint256 allocBPS 
    );
    event StrategyAdded(address indexed strategy, uint256 allocBPS);
    event StrategyAllocBPSUpdated(address indexed strategy, uint256 allocBPS);
    event StrategyRevoked(address indexed strategy);
    event UpdateWithdrawalQueue(address[] withdrawalQueue);
    event WithdrawMaxLossUpdated(uint256 withdrawMaxLoss);
    event EmergencyShutdown(bool active);
    event InCaseTokensGetStuckCalled(address token, uint256 amount);

    /**
     * @notice Initializes the vault's own 'RF' asset.
     * This asset is minted when someone does a deposit. It is burned in order
     * to withdraw the corresponding portion of the underlying assets.
     * @param _asset the asset to maximize.
     * @param _name the name of the vault asset.
     * @param _symbol the symbol of the vault asset.
     * @param _tvlCap initial deposit cap for scaling TVL safely.
     */
    constructor(
        address _asset,
        string memory _name,
        string memory _symbol,
        uint256 _tvlCap,
        address[] memory _strategists,
        address[] memory _multisigRoles
    ) ERC20(string(_name), string(_symbol)) {
        asset = _asset;
        constructionTime = block.timestamp;
        lastReport = block.timestamp;
        tvlCap = _tvlCap;
        lockedProfitDegradation = DEGRADATION_COEFFICIENT * 46 / 10 ** 6; // 6 hours in blocks

        for (uint256 i = 0; i < _strategists.length; i = _uncheckedInc(i)) {
            _grantRole(STRATEGIST, _strategists[i]);
        }

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(DEFAULT_ADMIN_ROLE, _multisigRoles[0]);
        _grantRole(ADMIN, _multisigRoles[1]);
        _grantRole(GUARDIAN, _multisigRoles[2]);

        cascadingAccess = [DEFAULT_ADMIN_ROLE, ADMIN, GUARDIAN, STRATEGIST];
    }

    /**
     * @notice It calculates the total underlying value of {asset} held by the system.
     * It takes into account the vault contract balance, and the balance deployed across
     * all the strategies.
     * @return totalManagedAssets - the total amount of assets managed by the vault.
     */
    function totalAssets() public view returns (uint256) {
        return IERC20Metadata(asset).balanceOf(address(this)) + totalAllocated;
    }

    /**
     * @notice It calculates the amount of free funds available after profit locking.
     * For calculating share price and making withdrawals.
     * @return freeFunds - the total amount of free funds available.
     */
    function _freeFunds() internal view returns (uint256) {
        return totalAssets() - _calculateLockedProfit();
    }

    /**
     * @notice It calculates the amount of locked profit from recent harvests.
     * @return the amount of locked profit.
     */
    function _calculateLockedProfit() internal view returns (uint256) {
        uint256 lockedFundsRatio = (block.timestamp - lastReport) * lockedProfitDegradation;

        if(lockedFundsRatio < DEGRADATION_COEFFICIENT) {
            return lockedProfit - (
                lockedFundsRatio
                * lockedProfit
                / DEGRADATION_COEFFICIENT
            );
        } else {
            return 0;
        }
    }

    /**
     * @notice The amount of shares that the Vault would exchange for the amount of assets provided,
     * in an ideal scenario where all the conditions are met.
     * @param assets The amount of underlying assets to convert to shares.
     * @return shares - the amount of shares given for the amount of assets.
     */
    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 _totalSupply = totalSupply();
        uint256 freeFunds = _freeFunds();
        if (freeFunds == 0 || _totalSupply == 0) return assets;
        return assets.mulDivDown(_totalSupply, freeFunds);
    }

    /**
     * @notice The amount of assets that the Vault would exchange for the amount of shares provided,
     * in an ideal scenario where all the conditions are met.
     * @param shares The amount of shares to convert to underlying assets.
     * @return assets - the amount of assets given for the amount of shares.
     */
    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 _totalSupply = totalSupply();
        if (_totalSupply == 0) return shares; // Initially the price is 1:1
        return shares.mulDivDown(_freeFunds(), _totalSupply);
    }

    /**
     * @notice Maximum amount of the underlying asset that can be deposited into the Vault for the receiver, 
     * through a deposit call.
     * @param receiver The depositor, unused in this case but here as part of the ERC4626 spec.
     * @return maxAssets - the maximum depositable assets.
     */
    function maxDeposit(address receiver) public view returns (uint256) {
        uint256 _totalAssets = totalAssets();
        if (_totalAssets > tvlCap) {
            return 0;
        }
        return tvlCap - _totalAssets;
    }

    /**
     * @notice Allows an on-chain or off-chain user to simulate the effects of their deposit at the current block, 
     * given current on-chain conditions. 
     * @param assets The amount of assets to deposit.
     * @return shares - the amount of shares given for the amount of assets.
     */
    function previewDeposit(uint256 assets) public view returns (uint256) {
        return convertToShares(assets);
    }

    /**
     * @notice A helper function to call deposit() with all the sender's funds.
     */
    function depositAll() external {
        deposit(IERC20Metadata(asset).balanceOf(msg.sender), msg.sender);
    }

    /**
     * @notice The entrypoint of funds into the system. People deposit with this function
     * into the vault.
     * @param assets The amount of assets to deposit
     * @param receiver The receiver of the minted shares
     * @return shares - the amount of shares issued from the deposit.
     */
    function deposit(uint256 assets, address receiver) public nonReentrant returns (uint256 shares) {
        require(!emergencyShutdown, "Cannot deposit during emergency shutdown");
        require(assets != 0, "please provide amount");
        uint256 _pool = totalAssets();
        require(_pool + assets <= tvlCap, "vault is full!");
        shares = previewDeposit(assets);

        IERC20Metadata(asset).safeTransferFrom(msg.sender, address(this), assets);
        
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /**
     * @notice Maximum amount of shares that can be minted from the Vault for the receiver, through a mint call.
     * @param receiver The minter, unused in this case but here as part of the ERC4626 spec.
     * @return shares - the maximum amount of shares issued from calling mint.
     */
    function maxMint(address receiver) public view virtual returns (uint256) {
        return convertToShares(maxDeposit(address(0)));
    }

    /**
     * @notice Allows an on-chain or off-chain user to simulate the effects of their mint at the current block, 
     * given current on-chain conditions.
     * @param shares The amount of shares to mint.
     * @return assets - the amount of assets given for the amount of shares.
     */
    function previewMint(uint256 shares) public view returns (uint256) {
        uint256 _totalSupply = totalSupply();
        if (_totalSupply == 0) return shares; // Initially the price is 1:1
        return shares.mulDivUp(_freeFunds(), _totalSupply);
    }

    /**
     * @notice Mints exactly shares Vault shares to receiver by depositing amount of underlying tokens.
     * @param shares The amount of shares to mint.
     * @param receiver The receiver of the minted shares.
     * @return assets - the amount of assets transferred from the mint.
     */
    function mint(uint256 shares, address receiver) external nonReentrant returns (uint256) {
        require(!emergencyShutdown, "Cannot mint during emergency shutdown");
        require(shares != 0, "please provide amount");
        uint256 assets = previewMint(shares);
        uint256 _pool = totalAssets();
        require(_pool + assets <= tvlCap, "vault is full!");

        if (_freeFunds() == 0) assets = shares;

        IERC20Metadata(asset).safeTransferFrom(msg.sender, address(this), assets);

        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);

        return assets;
    }

    /**
     * @notice Maximum amount of the underlying asset that can be withdrawn from the owner balance in the Vault,
     * through a withdraw call.
     * @param owner The owner of the shares to withdraw.
     * @return maxAssets - the maximum amount of assets transferred from calling withdraw.
     */
    function maxWithdraw(address owner) external view returns (uint256) {
        return convertToAssets(balanceOf(owner));
    }

    /**
     * @notice Allows an on-chain or off-chain user to simulate the effects of their withdrawal at the current block,
     * given current on-chain conditions.
     * @param assets The amount of assets to withdraw.
     * @return shares - the amount of shares burned for the amount of assets.
     */
    function previewWithdraw(uint256 assets) public view returns (uint256) {
        uint256 _totalSupply = totalSupply();
        if (totalSupply() == 0) return 0;
        uint256 freeFunds = _freeFunds();
        if (freeFunds == 0) return assets;
        return assets.mulDivUp(_totalSupply, freeFunds);
    }

    /**
     * @notice Burns shares from owner and sends exactly assets of underlying tokens to receiver.
     * @param assets The amount of assets to withdraw.
     * @param receiver The receiver of the withdrawn assets.
     * @param owner The owner of the shares to withdraw.
     * @return shares - the amount of shares burned.
     */
    function withdraw(uint256 assets, address receiver, address owner) external nonReentrant returns (uint256 shares) {
        require(assets != 0, "please provide amount");
        shares = previewWithdraw(assets);
        _withdraw(assets, shares, receiver, owner);
        return shares;
    }

    /**
     * @notice Helper function used by both withdraw and redeem to withdraw assets.
     * @param assets The amount of assets to withdraw.
     * @param shares The amount of shares to burn.
     * @param receiver The receiver of the withdrawn assets.
     * @param owner The owner of the shares to withdraw.
     * @return assets - the amount of assets withdrawn.
     */
    function _withdraw(uint256 assets, uint256 shares, address receiver, address owner) internal returns (uint256) {
        _burn(owner, shares);

        if (assets > IERC20Metadata(asset).balanceOf(address(this))) {
            uint256 totalLoss = 0;
            uint256 queueLength = withdrawalQueue.length;
            uint256 vaultBalance = 0;
            
            for (uint256 i = 0; i < queueLength; i = _uncheckedInc(i)) {
                vaultBalance = IERC20Metadata(asset).balanceOf(address(this));
                if (assets <= vaultBalance) {
                    break;
                }

                address stratAddr = withdrawalQueue[i];
                uint256 strategyBal = strategies[stratAddr].allocated;
                if (strategyBal == 0) {
                    continue;
                }

                uint256 remaining = assets - vaultBalance;
                uint256 loss = IStrategy(stratAddr).withdraw(Math.min(remaining, strategyBal));
                uint256 actualWithdrawn = IERC20Metadata(asset).balanceOf(address(this)) - vaultBalance;

                // Withdrawer incurs any losses from withdrawing as reported by strat
                if (loss != 0) {
                    assets -= loss;
                    totalLoss += loss;
                    _reportLoss(stratAddr, loss);
                }

                strategies[stratAddr].allocated -= actualWithdrawn;
                totalAllocated -= actualWithdrawn;
            }

            vaultBalance = IERC20Metadata(asset).balanceOf(address(this));
            if (assets > vaultBalance) {
                assets = vaultBalance;
            }

            require(totalLoss <= ((assets + totalLoss) * withdrawMaxLoss) / PERCENT_DIVISOR, "Cannot exceed the maximum allowed withdraw slippage");
        }

        IERC20Metadata(asset).safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        return assets;
    }

    /**
     * @notice Maximum amount of Vault shares that can be redeemed from the owner balance in the Vault, 
     * through a redeem call.
     * @param owner The owner of the shares to redeem.
     * @return maxShares - the amount of redeemable shares.
     */
    function maxRedeem(address owner) external view returns (uint256) {
        return balanceOf(owner);
    }

    /**
     * @notice Allows an on-chain or off-chain user to simulate the effects of their redeemption at the current block,
     * given current on-chain conditions.
     * @param shares The amount of shares to redeem.
     * @return assets - the amount of assets redeemed from the amount of shares.
     */
    function previewRedeem(uint256 shares) public view returns (uint256) {
        return convertToAssets(shares);
    }

    /**
     * @notice Function for various UIs to display the current value of one of our yield tokens.
     * @return pricePerFullShare - a uint256 of how much underlying asset one vault share represents.
     */
    function getPricePerFullShare() external view returns (uint256) {
        return convertToAssets(10 ** decimals());
    }

    /**
     * @notice A helper function to call redeem() with all the sender's funds.
     */
    function redeemAll() external {
        redeem(balanceOf(msg.sender), msg.sender, msg.sender);
    }

    /**
     * @notice Burns exactly shares from owner and sends assets of underlying tokens to receiver.
     * @param shares The amount of shares to redeem.
     * @param receiver The receiver of the redeemed assets.
     * @param owner The owner of the shares to redeem.
     * @return assets - the amount of assets redeemed.
     */
    function redeem(uint256 shares, address receiver, address owner) public nonReentrant returns (uint256 assets) {
        require(shares != 0, "please provide amount");
        assets = previewRedeem(shares);
        return _withdraw(assets, shares, receiver, owner);
    }

    /**
     * @notice Adds a new strategy to the vault with a given allocation amount in basis points.
     * @param strategy The strategy to add.
     * @param allocBPS The strategy allocation in basis points.
     */
    function addStrategy(address strategy, uint256 allocBPS) external {
        _atLeastRole(DEFAULT_ADMIN_ROLE);
        require(!emergencyShutdown, "Cannot add a strategy during emergency shutdown");
        require(strategy != address(0), "Cannot add the zero address");
        require(strategies[strategy].activation == 0, "Strategy must not be added already");
        require(address(this) == IStrategy(strategy).vault(), "The strategy must use this vault");
        require(asset == IStrategy(strategy).want(), "The strategy must use the same want");
        require(allocBPS + totalAllocBPS <= PERCENT_DIVISOR, "Total allocation points are over 100%");

        strategies[strategy] = StrategyParams({
            activation: block.timestamp,
            allocBPS: allocBPS,
            allocated: 0,
            gains: 0,
            losses: 0,
            lastReport: block.timestamp
        });

        totalAllocBPS += allocBPS;
        withdrawalQueue.push(strategy);
        emit StrategyAdded(strategy, allocBPS);
    }

    /**
     * @notice Updates the allocation points for a given strategy.
     * @param strategy The strategy to update.
     * @param allocBPS The strategy allocation in basis points.
     */
    function updateStrategyAllocBPS(address strategy, uint256 allocBPS) external {
        _atLeastRole(STRATEGIST);
        require(strategies[strategy].activation != 0, "Strategy must be active");
        totalAllocBPS -= strategies[strategy].allocBPS;
        strategies[strategy].allocBPS = allocBPS;
        totalAllocBPS += allocBPS;
        require(totalAllocBPS <= PERCENT_DIVISOR, "Total allocation points are over 100%");
        emit StrategyAllocBPSUpdated(strategy, allocBPS);
    }

    /**
     * @notice Removes any allocation to a given strategy.
     * @param strategy The strategy to revoke.
     */
    function revokeStrategy(address strategy) external {
        if (!(msg.sender == strategy)) {
            _atLeastRole(GUARDIAN);
        }
        
        if (strategies[strategy].allocBPS == 0) {
            return;
        }

        totalAllocBPS -= strategies[strategy].allocBPS;
        strategies[strategy].allocBPS = 0;
        emit StrategyRevoked(strategy);
    }

    /**
     * @notice Called by a strategy to determine the amount of capital that the vault is
     * able to provide it. A positive amount means that vault has excess capital to provide
     * the strategy, while a negative amount means that the strategy has a balance owing to
     * the vault.
     * @return availableCapital - the amount of capital the vault can provide the strategy.
     */
    function availableCapital() public view returns (int256) {
        address stratAddr = msg.sender;
        if (totalAllocBPS == 0 || emergencyShutdown) {
            return -int256(strategies[stratAddr].allocated);
        }

        uint256 stratMaxAllocation = (strategies[stratAddr].allocBPS * totalAssets()) / PERCENT_DIVISOR;
        uint256 stratCurrentAllocation = strategies[stratAddr].allocated;

        if (stratCurrentAllocation > stratMaxAllocation) {
            return -int256(stratCurrentAllocation - stratMaxAllocation);
        } else if (stratCurrentAllocation < stratMaxAllocation) {
            uint256 vaultMaxAllocation = (totalAllocBPS * totalAssets()) / PERCENT_DIVISOR;
            uint256 vaultCurrentAllocation = totalAllocated;

            if (vaultCurrentAllocation >= vaultMaxAllocation) {
                return 0;
            }

            uint256 available = stratMaxAllocation - stratCurrentAllocation;
            available = Math.min(available, vaultMaxAllocation - vaultCurrentAllocation);
            available = Math.min(available, IERC20Metadata(asset).balanceOf(address(this)));

            return int256(available);
        } else {
            return 0;
        }
    }

    /**
     * @notice Updates the withdrawalQueue to match the addresses and order specified.
     * @param _withdrawalQueue The new withdrawalQueue to update to.
     */
    function setWithdrawalQueue(address[] calldata _withdrawalQueue) external {
        _atLeastRole(STRATEGIST);
        uint256 queueLength = _withdrawalQueue.length;
        require(queueLength != 0, "Cannot set an empty withdrawal queue");

        delete withdrawalQueue;
        for (uint256 i = 0; i < queueLength; i = _uncheckedInc(i)) {
            address strategy = _withdrawalQueue[i];
            StrategyParams storage params = strategies[strategy];
            require(params.activation != 0, "Can only use active strategies in the withdrawal queue");
            withdrawalQueue.push(strategy);
        }
        emit UpdateWithdrawalQueue(withdrawalQueue);
    }

    /**
     * @notice Helper function to report a loss by a given strategy.
     * @param strategy The strategy to report the loss for.
     * @param loss The amount lost.
     */
    function _reportLoss(address strategy, uint256 loss) internal {
        StrategyParams storage stratParams = strategies[strategy];
        // Loss can only be up the amount of capital allocated to the strategy
        uint256 allocation = stratParams.allocated;
        require(loss <= allocation, "Strategy cannot loose more than what was allocated to it");

        if (totalAllocBPS != 0) {
            // reduce strat's allocBPS proportional to loss
            uint256 bpsChange = Math.min((loss * totalAllocBPS) / totalAllocated, stratParams.allocBPS);

            // If the loss is too small, bpsChange will be 0
            if (bpsChange != 0) {
                stratParams.allocBPS -= bpsChange;
                totalAllocBPS -= bpsChange;
            }
        }

        // Finally, adjust our strategy's parameters by the loss
        stratParams.losses += loss;
        stratParams.allocated -= loss;
        totalAllocated -= loss;
    }

    /**
     * @notice Helper function to report the strategy returns on a harvest.
     * @param roi The return on investment (positive or negative) given as the total amount
     * gained or lost from the harvest.
     * @param repayment The repayment of debt by the strategy.
     * @return debt - the strategy debt to the vault.
     */
    function report(int256 roi, uint256 repayment) external returns (uint256) {
        address stratAddr = msg.sender;
        StrategyParams storage strategy = strategies[stratAddr];
        require(strategy.activation != 0, "Only active strategies can report");
        uint256 loss = 0;
        uint256 gain = 0;

        if (roi < 0) {
            loss = uint256(-roi);
            _reportLoss(stratAddr, loss);
        } else {
            gain = uint256(roi);
            strategy.gains += uint256(roi);
        }

        int256 available = availableCapital();
        uint256 debt = 0;
        uint256 credit = 0;
        if (available < 0) {
            debt = uint256(-available);
            repayment = Math.min(debt, repayment);

            if (repayment != 0) {
                strategy.allocated -= repayment;
                totalAllocated -= repayment;
                debt -= repayment;
            }
        } else {
            credit = uint256(available);
            strategy.allocated += credit;
            totalAllocated += credit;
        }

        uint256 freeWantInStrat = repayment;
        if (roi > 0) {
            freeWantInStrat += uint256(roi);
        }

        if (credit > freeWantInStrat) {
            IERC20Metadata(asset).safeTransfer(stratAddr, credit - freeWantInStrat);
        } else if (credit < freeWantInStrat) {
            IERC20Metadata(asset).safeTransferFrom(stratAddr, address(this), freeWantInStrat - credit);
        }

        uint256 lockedProfitBeforeLoss = _calculateLockedProfit() + gain;
        if (lockedProfitBeforeLoss > loss) {
            lockedProfit = lockedProfitBeforeLoss - loss;
        } else {
            lockedProfit = 0;
        }

        strategy.lastReport = block.timestamp;
        lastReport = block.timestamp;

        emit StrategyReported(
            stratAddr,
            roi,
            repayment,
            strategy.gains,
            strategy.losses,
            strategy.allocated,
            strategy.allocBPS 
        );

        if (strategy.allocBPS == 0 || emergencyShutdown) {
            return IStrategy(stratAddr).balanceOf();
        }

        return debt;
    }

    /**
     * @notice Updates the withdrawMaxLoss which is the maximum allowed slippage.
     * @param _withdrawMaxLoss The new value, in basis points.
     */
    function updateWithdrawMaxLoss(uint256 _withdrawMaxLoss) external {
        _atLeastRole(STRATEGIST);
        require(_withdrawMaxLoss <= PERCENT_DIVISOR, "withdrawMaxLoss cannot be greater than 100%");
        withdrawMaxLoss = _withdrawMaxLoss;
        emit WithdrawMaxLossUpdated(withdrawMaxLoss);
    }

    /**
     * @notice Updates the vault tvl cap (the max amount of assets held by the vault).
     * @dev pass in max value of uint to effectively remove TVL cap.
     * @param newTvlCap The new tvl cap.
     */
    function updateTvlCap(uint256 newTvlCap) public {
        _atLeastRole(ADMIN);
        tvlCap = newTvlCap;
        emit TvlCapUpdated(tvlCap);
    }

     /**
     * @notice Helper function to remove TVL cap.
     */
    function removeTvlCap() external {
        _atLeastRole(ADMIN);
        updateTvlCap(type(uint256).max);
    }

    /**
     * @notice Activates or deactivates Vault mode where all Strategies go into full
     * withdrawal.
     * During Emergency Shutdown:
     * 1. No Users may deposit into the Vault (but may withdraw as usual.)
     * 2. New Strategies may not be added.
     * 3. Each Strategy must pay back their debt as quickly as reasonable to
     * minimally affect their position.
     *
     * If true, the Vault goes into Emergency Shutdown. If false, the Vault
     * goes back into Normal Operation.
     * @param active If emergencyShutdown is active or not.
     */
    function setEmergencyShutdown(bool active) external {
        if (active == true) {
            _atLeastRole(GUARDIAN);
        } else {
            _atLeastRole(ADMIN);
        }
        emergencyShutdown = active;
        emit EmergencyShutdown(emergencyShutdown);
    }

    /**
     * @notice Rescues random funds stuck that the strat can't handle.
     * @param token address of the asset to rescue.
     */
    function inCaseTokensGetStuck(address token) external {
        _atLeastRole(STRATEGIST);
        require(token != asset, "!asset");

        uint256 amount = IERC20Metadata(token).balanceOf(address(this));
        IERC20Metadata(token).safeTransfer(msg.sender, amount);
        emit InCaseTokensGetStuckCalled(token, amount);
    }

    /**
     * @notice Overrides the default 18 decimals for the vault ERC20 to
     * match the same decimals as the underlying asset used.
     * @return decimals - the amount of decimals used by the vault ERC20.
     */
    function decimals() public view override returns (uint8) {
        return IERC20Metadata(asset).decimals();
    }

    /**
     * @notice Changes the locked profit degradation.
     * match the same decimals as the underlying asset used.
     * @param degradation - The rate of degradation in percent per second scaled to 1e18.
     */
    function setLockedProfitDegradation(uint256 degradation) external {
        _atLeastRole(STRATEGIST);
        require(degradation <= DEGRADATION_COEFFICIENT, "Degradation cannot be more than 100%");
        lockedProfitDegradation = degradation;
        emit LockedProfitDegradationUpdated(degradation);
    }

    /**
     * @notice Internal function that checks cascading role privileges. Any higher privileged role
     * should be able to perform all the functions of any lower privileged role. This is
     * accomplished using the {cascadingAccess} array that lists all roles from most privileged
     * to least privileged.
     * @param role - The role in bytes from the keccak256 hash of the role name
     */
    function _atLeastRole(bytes32 role) internal view {
        uint256 numRoles = cascadingAccess.length;
        uint256 specifiedRoleIndex;
        for (uint256 i = 0; i < numRoles; i = _uncheckedInc(i)) {
            if (role == cascadingAccess[i]) {
                specifiedRoleIndex = i;
                break;
            } else if (i == numRoles - 1) {
                revert();
            }
        }

        for (uint256 i = 0; i <= specifiedRoleIndex; i = _uncheckedInc(i)) {
            if (hasRole(cascadingAccess[i], msg.sender)) {
                break;
            } else if (i == specifiedRoleIndex) {
                revert();
            }
        }
    }

    /**
     * @notice For doing an unchecked increment of an index for gas optimization purposes
     * @param i - The number to increment
     * @return The incremented number
     */
    function _uncheckedInc(uint256 i) internal pure returns (uint256) {
        unchecked {
            return i + 1;
        }
    }
}
