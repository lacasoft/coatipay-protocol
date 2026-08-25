// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

abstract contract Pausable {
    bool private _paused;
    address public guardian;

    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event GuardianTransferred(address indexed previous, address indexed next);

    error EnforcedPause();
    error ExpectedPause();
    error NotGuardian();
    error ZeroGuardian();

    modifier whenNotPaused() {
        if (_paused) revert EnforcedPause();
        _;
    }

    modifier whenPaused() {
        if (!_paused) revert ExpectedPause();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    constructor(address _guardian) {
        // Bricking guard: zero guardian would leave the contract permanently
        // unpausable AND with no rotation path (transferGuardian is onlyGuardian).
        if (_guardian == address(0)) revert ZeroGuardian();
        guardian = _guardian;
    }

    function transferGuardian(address newGuardian) external onlyGuardian {
        if (newGuardian == address(0)) revert ZeroGuardian();
        emit GuardianTransferred(guardian, newGuardian);
        guardian = newGuardian;
    }

    function pause() external onlyGuardian whenNotPaused {
        _paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyGuardian whenPaused {
        _paused = false;
        emit Unpaused(msg.sender);
    }

    function paused() public view returns (bool) {
        return _paused;
    }
}
