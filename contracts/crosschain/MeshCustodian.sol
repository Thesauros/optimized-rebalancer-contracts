// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IProvider} from "../interfaces/IProvider.sol";
import {IRebalancer} from "../interfaces/IRebalancer.sol";
import {IMeshCustodian} from "./interfaces/IMeshCustodian.sol";
import {IMeshBridgeAdapter} from "./interfaces/IMeshBridgeAdapter.sol";

/// @title MeshCustodian
/// @notice Destination-side receiver. Accepts bridged assets, optionally deploys
///         them into local yield providers, and can return principal + yield back
///         through the bridge.
///
///         One custodian per (chain, node-pair). Governance configures which
///         bridge adapters are trusted and which providers may receive deposits.
contract MeshCustodian is IMeshCustodian, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable asset;
    address public governance;
    address public executor;

    mapping(address => bool) public trustedAdapters;
    mapping(address => bool) public allowedProviders;

    uint256 public totalHeld;
    mapping(address => uint256) public heldByProvider;

    event GovernanceUpdated(address indexed governance);
    event ExecutorUpdated(address indexed executor);
    event AdapterTrusted(address indexed adapter, bool trusted);
    event ProviderAllowed(address indexed provider, bool allowed);

    error InvalidConfiguration();
    error ProviderNotDeployed();

    constructor(address asset_, address governance_, address executor_) {
        if (asset_.code.length == 0 || governance_.code.length == 0) revert InvalidConfiguration();
        asset = asset_;
        governance = governance_;
        executor = executor_;
    }

    modifier onlyGovernance() {
        if (msg.sender != governance) revert Unauthorized();
        _;
    }

    modifier onlyExecutor() {
        if (msg.sender != executor) revert Unauthorized();
        _;
    }

    function setGovernance(address governance_) external onlyGovernance {
        if (governance_.code.length == 0) revert InvalidConfiguration();
        governance = governance_;
        emit GovernanceUpdated(governance_);
    }

    function setExecutor(address executor_) external onlyGovernance {
        executor = executor_;
        emit ExecutorUpdated(executor_);
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

    /// @inheritdoc IMeshCustodian
    /// @dev Called by a trusted bridge adapter after authenticating the remote sender.
    ///      Pulls tokens from the adapter (which received them from the bridge).
    function onBridgeIn(uint64, uint256 amount, bytes32) external override nonReentrant {
        if (!trustedAdapters[msg.sender]) revert UnknownSource();
        if (amount == 0) revert ZeroAmount();

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        totalHeld += amount;

        emit BridgeInReceived(0, amount, bytes32(0));
    }

    /// @inheritdoc IMeshCustodian
    /// @dev Deposits held assets into a local yield provider. The provider must be
    ///      pre-approved by governance. The provider's deposit() runs via delegatecall
    ///      in this contract's context (same pattern as the vault).
    function deployToProvider(IProvider provider, uint256 amount) external override onlyExecutor nonReentrant {
        if (!allowedProviders[address(provider)]) revert ProviderNotDeployed();
        if (amount == 0) revert ZeroAmount();

        uint256 held = IERC20(asset).balanceOf(address(this)) - heldByProvider[address(provider)];
        if (amount > held) revert ZeroAmount();

        IERC20(asset).safeTransfer(address(provider), amount);
        provider.deposit(amount, IRebalancer(address(0)));

        heldByProvider[address(provider)] += amount;
        totalHeld -= amount;

        emit DeployedToProvider(address(provider), amount);
    }

    /// @inheritdoc IMeshCustodian
    function withdrawFromProvider(IProvider provider, uint256 amount) external override onlyExecutor nonReentrant returns (uint256 actual) {
        if (!allowedProviders[address(provider)]) revert ProviderNotDeployed();

        uint256 balBefore = IERC20(asset).balanceOf(address(this));
        provider.withdraw(amount, IRebalancer(address(0)));
        uint256 balAfter = IERC20(asset).balanceOf(address(this));

        actual = balAfter - balBefore;
        if (actual > heldByProvider[address(provider)]) {
            actual = heldByProvider[address(provider)];
        }
        heldByProvider[address(provider)] -= actual;
        totalHeld += actual;

        emit WithdrawnFromProvider(address(provider), actual);
    }

    /// @inheritdoc IMeshCustodian
    function getProviderBalance(IProvider provider) external view override returns (uint256) {
        return heldByProvider[address(provider)];
    }

    /// @inheritdoc IMeshCustodian
    function getTotalValue() external view override returns (uint256) {
        uint256 total = IERC20(asset).balanceOf(address(this));
        return total;
    }

    /// @notice Send assets back through the bridge to the source node.
    function bridgeBack(
        IMeshBridgeAdapter adapter,
        bytes32 transferId,
        uint256 amount,
        uint256 destChainId,
        bytes32 destPeer,
        uint256 minAmountOut
    ) external payable onlyExecutor nonReentrant returns (uint256 amountOut) {
        if (!trustedAdapters[address(adapter)]) revert UnknownSource();
        if (amount == 0) revert ZeroAmount();

        IERC20 token = IERC20(asset);
        uint256 balBefore = token.balanceOf(address(this));
        token.forceApprove(address(adapter), amount);
        amountOut = adapter.send{value: msg.value}(transferId, asset, amount, destChainId, destPeer, minAmountOut);
        token.forceApprove(address(adapter), 0);

        uint256 spent = balBefore - token.balanceOf(address(this));
        totalHeld -= spent;

        emit BridgeOutInitiated(uint64(destChainId), spent, transferId);
    }
}
