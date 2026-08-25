// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IStakeManager} from "./interfaces/IStakeManager.sol";
import {Pausable} from "./Pausable.sol";

/// @title NodeRegistry
/// @notice Permissionless registry for OpenRelay node operators.
///         Operators must have an active stake of at least `minStake`
///         in StakeManager before they can register.
/// @dev    NodeRegistry intentionally does NOT proxy USDC transfers
///         into StakeManager. Operators stake directly via
///         `stakeManager.deposit(amount)` (which uses `msg.sender` and
///         has no arbitrary-from parameter), and registration just
///         verifies the on-chain state. This eliminates Slither's
///         `arbitrary-send-erc20` finding structurally and removes a
///         trust relationship between the two contracts — least
///         privilege.
contract NodeRegistry is Pausable, ReentrancyGuard {
    // ── State ─────────────────────────────────────────────────

    /// @notice Minimum USDC stake required to register a node (6 decimals).
    ///         Settable by guardian (increase-only) to raise the bar as the
    ///         network grows. Phase 1 testnet default: 40 USDC.
    uint256 public minStake;

    IStakeManager public immutable stakeManager;

    struct Node {
        address operator;
        string endpoint;
        uint256 registeredAt;
        bool active;
    }

    mapping(address => Node) private _nodes;
    address[] private _activeOperators;
    mapping(address => uint256) private _activeIndex;

    // ── Events ───────────────────────────────────────────────

    event NodeRegistered(address indexed operator, string endpoint, uint256 stake);
    event NodeUpdated(address indexed operator, string endpoint);
    event NodeDeactivated(address indexed operator);
    event NodeActivated(address indexed operator);
    event MinStakeIncreased(uint256 previous, uint256 newMin);

    // ── Errors ───────────────────────────────────────────────

    error AlreadyRegistered();
    error AlreadyActive();
    error NotRegistered();
    error StakeTooLow(uint256 staked, uint256 minimum);
    error EmptyEndpoint();
    error MinStakeCannotDecrease(uint256 current, uint256 attempted);

    // ── Constructor ──────────────────────────────────────────

    constructor(address _stakeManager, address _guardian, uint256 _minStake) Pausable(_guardian) {
        stakeManager = IStakeManager(_stakeManager);
        minStake = _minStake;
    }

    // ── External ─────────────────────────────────────────────

    /// @notice Register as a node operator. Caller must have ALREADY staked
    ///         at least `minStake` USDC in StakeManager via
    ///         `stakeManager.deposit(amount)` BEFORE calling this.
    /// @dev Operator flow:
    ///        1. usdc.approve(stakeManager, amount)
    ///        2. stakeManager.deposit(amount)
    ///        3. nodeRegistry.register(endpoint)
    ///      `nonReentrant` is preserved for principle even though the only
    ///      external call is a view (`getStakeInfo`) — defense-in-depth.
    function register(string calldata endpoint) external whenNotPaused nonReentrant {
        if (_nodes[msg.sender].registeredAt != 0) revert AlreadyRegistered();
        if (bytes(endpoint).length == 0) revert EmptyEndpoint();

        IStakeManager.StakeInfo memory info = stakeManager.getStakeInfo(msg.sender);
        if (info.staked < minStake) revert StakeTooLow(info.staked, minStake);

        _nodes[msg.sender] =
            Node({operator: msg.sender, endpoint: endpoint, registeredAt: block.timestamp, active: true});
        _activeIndex[msg.sender] = _activeOperators.length;
        _activeOperators.push(msg.sender);

        emit NodeRegistered(msg.sender, endpoint, info.staked);
    }

    /// @notice Update the node's endpoint URL.
    function updateEndpoint(string calldata endpoint) external {
        // Sentinel check: registeredAt == 0 means the node was never
        // registered. Slither flags both `incorrect-equality` and `timestamp`
        // (block.timestamp is what populates registeredAt) — both are correct
        // by design.
        // slither-disable-next-line incorrect-equality,timestamp
        if (_nodes[msg.sender].registeredAt == 0) revert NotRegistered();
        if (bytes(endpoint).length == 0) revert EmptyEndpoint();

        _nodes[msg.sender].endpoint = endpoint;
        emit NodeUpdated(msg.sender, endpoint);
    }

    /// @notice Deactivate the node. Does not release stake.
    function deactivate() external whenNotPaused {
        if (_nodes[msg.sender].registeredAt == 0) revert NotRegistered();
        _nodes[msg.sender].active = false;
        _removeFromActive(msg.sender);
        emit NodeDeactivated(msg.sender);
    }

    /// @notice Reactivate a previously deactivated node.
    function activate() external whenNotPaused {
        if (_nodes[msg.sender].registeredAt == 0) revert NotRegistered();
        // Without the AlreadyActive guard, calling activate() twice on an
        // already-active node would push a duplicate into _activeOperators
        // and leave _activeIndex pointing only at the latest position —
        // breaking subsequent _removeFromActive (would leave a phantom slot)
        // and producing duplicates in getActiveNodes() consumed by indexers.
        if (_nodes[msg.sender].active) revert AlreadyActive();
        _nodes[msg.sender].active = true;
        _activeIndex[msg.sender] = _activeOperators.length;
        _activeOperators.push(msg.sender);
        emit NodeActivated(msg.sender);
    }

    /// @notice Raise the minimum stake. Guardian-only. Can never decrease —
    ///         this prevents a malicious guardian from devaluing existing stakes.
    function setMinStake(uint256 newMin) external onlyGuardian {
        if (newMin < minStake) revert MinStakeCannotDecrease(minStake, newMin);
        emit MinStakeIncreased(minStake, newMin);
        minStake = newMin;
    }

    // ── Views ─────────────────────────────────────────────────

    function getNode(address operator) external view returns (Node memory) {
        return _nodes[operator];
    }

    function getActiveNodes() external view returns (address[] memory) {
        return _activeOperators;
    }

    function isActive(address operator) external view returns (bool) {
        return _nodes[operator].active;
    }

    // ── Internal ─────────────────────────────────────────────

    function _removeFromActive(address operator) internal {
        uint256 index = _activeIndex[operator];
        uint256 lastIndex = _activeOperators.length - 1;
        if (index != lastIndex) {
            address lastOperator = _activeOperators[lastIndex];
            _activeOperators[index] = lastOperator;
            _activeIndex[lastOperator] = index;
        }
        _activeOperators.pop();
        delete _activeIndex[operator];
    }
}
