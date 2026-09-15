// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ICustodianProvider} from "./interfaces/ICustodianProvider.sol";
import {IMeshBridgeAdapter} from "./interfaces/IMeshBridgeAdapter.sol";

/// @title MeshCustodian
/// @notice Destination-side receiver. Accepts bridged assets, optionally deploys
///         them into local yield providers, and can return principal + yield back
///         through the bridge.
///
///         One custodian per (chain, node-pair). Governance configures which
///         bridge adapters are trusted and which providers may receive deposits.
///
///         Provider integration uses delegatecall with ICustodianProvider — a
///         simplified interface that does not require vault context. Existing
///         vault IProvider implementations (AaveV3, CompoundV3, Morpho) are NOT
///         compatible; dedicated custodian providers must be deployed.
contract MeshCustodian is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable asset;
    address public governance;
    address public executor;
    address public guardian;
    bool public paused;

    mapping(address => bool) public trustedAdapters;
    mapping(address => bool) public allowedProviders;

    uint256 public totalHeld;
    uint256 public totalDeployed;
    mapping(address => uint256) public heldByProvider;

    error Unauthorized();
    error InvalidConfiguration();
    error UnknownSource();
    error ZeroAmount();
    error Paused();
    error UnexpectedTokenAmount();

    event GovernanceUpdated(address indexed governance);
    event RolesUpdated(address indexed executor, address indexed guardian);
    event PauseUpdated(bool paused);
    event AdapterTrusted(address indexed adapter, bool trusted);
    event ProviderAllowed(address indexed provider, bool allowed);
    event BridgeInReceived(uint64 indexed srcChainId, uint256 amount, bytes32 indexed transferId);
    event DeployedToProvider(address indexed provider, uint256 amount);
    event WithdrawnFromProvider(address indexed provider, uint256 actual);
    event BridgeOutInitiated(uint64 indexed destChainId, uint256 spent, bytes32 indexed transferId);

    constructor(address asset_, address governance_, address executor_, address guardian_) {
        if (asset_.code.length == 0 || governance_.code.length == 0) revert InvalidConfiguration();
        asset = asset_;
        governance = governance_;
        _setRoles(executor_, guardian_);
    }

    modifier onlyGovernance() {
        if (msg.sender != governance) revert Unauthorized();
        _;
    }

    modifier onlyExecutor() {
        if (msg.sender != executor) revert Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    function _setRoles(address executor_, address guardian_) internal {
        if (executor_ == address(0) || guardian_ == address(0)) revert InvalidConfiguration();
        executor = executor_;
        guardian = guardian_;
        emit RolesUpdated(executor_, guardian_);
    }

    function setRoles(address executor_, address guardian_) external onlyGovernance nonReentrant {
        _setRoles(executor_, guardian_);
    }

    function setGovernance(address governance_) external onlyGovernance {
        if (governance_.code.length == 0) revert InvalidConfiguration();
        governance = governance_;
        emit GovernanceUpdated(governance_);
    }

    /// @notice Guardian can pause; only governance can unpause.
    function setPaused(bool value) external nonReentrant {
        if (msg.sender != governance && (msg.sender != guardian || !value)) revert Unauthorized();
        paused = value;
        emit PauseUpdated(value);
    }

    function trustAdapter(address adapter, bool trusted) external onlyGovernance nonReentrant {
        if (adapter.code.length == 0) revert InvalidConfiguration();
        trustedAdapters[adapter] = trusted;
        emit AdapterTrusted(adapter, trusted);
    }

    function allowProvider(address provider, bool allowed) external onlyGovernance nonReentrant {
        if (provider.code.length == 0) revert InvalidConfiguration();
        allowedProviders[provider] = allowed;
        emit ProviderAllowed(provider, allowed);
    }

    /// @notice Called by a trusted bridge adapter after authenticating the remote sender.
    ///         Pulls tokens from the adapter (which received them from the bridge).
    function onBridgeIn(uint64 srcChainId, uint256 amount, bytes32 transferId) external nonReentrant whenNotPaused {
        if (!trustedAdapters[msg.sender]) revert UnknownSource();
        if (amount == 0) revert ZeroAmount();

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        totalHeld += amount;

        emit BridgeInReceived(srcChainId, amount, transferId);
    }

    /// @notice Deploy held assets into a local yield provider.
    /// @dev Transfers tokens to the provider, then calls deposit. The provider
    ///      is responsible for deploying into the actual yield protocol.
    function deployToProvider(ICustodianProvider provider, uint256 amount) external onlyExecutor nonReentrant whenNotPaused {
        if (!allowedProviders[address(provider)]) revert Unauthorized();
        if (amount == 0) revert ZeroAmount();

        uint256 held = IERC20(asset).balanceOf(address(this)) - heldByProvider[address(provider)];
        if (amount > held) revert ZeroAmount();

        IERC20(asset).safeTransfer(address(provider), amount);
        provider.deposit(amount);

        heldByProvider[address(provider)] += amount;
        totalHeld -= amount;
        totalDeployed += amount;

        emit DeployedToProvider(address(provider), amount);
    }

    /// @notice Withdraw assets from a local yield provider.
    /// @dev Calls provider.withdraw which should transfer tokens back to custodian.
    function withdrawFromProvider(ICustodianProvider provider, uint256 amount)
        external
        onlyExecutor
        nonReentrant
        returns (uint256 actual)
    {
        if (!allowedProviders[address(provider)]) revert Unauthorized();

        uint256 balBefore = IERC20(asset).balanceOf(address(this));
        provider.withdraw(amount);
        uint256 balAfter = IERC20(asset).balanceOf(address(this));

        actual = balAfter - balBefore;
        if (actual > heldByProvider[address(provider)]) {
            actual = heldByProvider[address(provider)];
        }
        heldByProvider[address(provider)] -= actual;
        totalHeld += actual;
        totalDeployed -= actual;

        emit WithdrawnFromProvider(address(provider), actual);
    }

    function getProviderBalance(ICustodianProvider provider) external view returns (uint256) {
        return heldByProvider[address(provider)];
    }

    /// @notice Total value = liquid holdings (accounting) + deployed provider assets.
    /// @dev Pure accounting view: totalHeld tracks liquid principal, totalDeployed
    ///      tracks deployed principal. Does not include yield or losses at providers.
    function getTotalValue() external view returns (uint256) {
        return totalHeld + totalDeployed;
    }

    /// @notice Liquid value = principal not deployed to providers.
    function getLiquidValue() external view returns (uint256) {
        return totalHeld;
    }

    /// @notice Send assets back through the bridge to the source node.
    function bridgeBack(
        IMeshBridgeAdapter adapter,
        bytes32 transferId,
        uint256 amount,
        uint64 destChainId,
        bytes32 destPeer,
        uint256 minAmountOut
    ) external payable onlyExecutor nonReentrant whenNotPaused returns (uint256 amountOut) {
        if (!trustedAdapters[address(adapter)]) revert UnknownSource();
        if (amount == 0) revert ZeroAmount();
        if (amount > totalHeld) revert UnexpectedTokenAmount();

        IERC20 token = IERC20(asset);
        uint256 balBefore = token.balanceOf(address(this));
        token.forceApprove(address(adapter), amount);
        amountOut = adapter.send{value: msg.value}(transferId, asset, amount, destChainId, destPeer, minAmountOut);
        token.forceApprove(address(adapter), 0);

        uint256 spent = balBefore - token.balanceOf(address(this));
        totalHeld -= spent;

        emit BridgeOutInitiated(destChainId, spent, transferId);
    }

    receive() external payable {}
}
