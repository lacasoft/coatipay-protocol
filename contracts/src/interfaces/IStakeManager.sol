// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

interface IStakeManager {
    struct StakeInfo {
        uint256 staked;
        uint256 pendingWithdrawal;
        uint256 unlockAt;
    }

    function getStakeInfo(address operator) external view returns (StakeInfo memory);
    function treasury() external view returns (address);
}
