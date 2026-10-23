// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

abstract contract Pausable {
    bool private _paused;
    address public guardian;

    /// @notice Guardian propuesto que aún no ha aceptado (ADR-009 §6). Cero si
    ///         no hay ninguna transferencia en curso.
    address public pendingGuardian;

    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event GuardianTransferStarted(address indexed current, address indexed proposed);
    event GuardianTransferred(address indexed previous, address indexed next);

    error EnforcedPause();
    error ExpectedPause();
    error NotGuardian();
    error NotPendingGuardian();
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

    /// @notice Propone un guardian nuevo. No cambia nada hasta que el propuesto
    ///         llame a `acceptGuardian()`: una dirección mal escrita nunca
    ///         acepta, y el guardian sigue siendo el actual. Proponer la
    ///         dirección cero cancela la propuesta en curso.
    // Cero es a propósito: cancela la propuesta. Nadie puede aceptar desde la
    // dirección cero, así que el guardian nunca queda a cero.
    // slither-disable-next-line missing-zero-check
    function transferGuardian(address newGuardian) external onlyGuardian {
        pendingGuardian = newGuardian;
        emit GuardianTransferStarted(guardian, newGuardian);
    }

    /// @notice El guardian propuesto acepta el cargo.
    function acceptGuardian() external {
        // Con `pendingGuardian` a cero nadie puede aceptar: `msg.sender` nunca
        // es la dirección cero.
        if (msg.sender != pendingGuardian) revert NotPendingGuardian();
        emit GuardianTransferred(guardian, msg.sender);
        guardian = msg.sender;
        pendingGuardian = address(0);
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
