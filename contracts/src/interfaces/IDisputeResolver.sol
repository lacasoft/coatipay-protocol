// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

interface IDisputeResolver {
    enum DisputeStatus {
        Open,
        NodeResponded,
        Resolved,
        Expired
    }
    enum DisputeOutcome {
        None,
        MerchantWins,
        NodeWins
    }

    function openDispute(bytes32 paymentIntentId, address nodeOperator, string calldata evidenceCid)
        external
        returns (bytes32 disputeId);

    function respondToDispute(bytes32 disputeId, string calldata counterEvidenceCid) external;

    function vote(bytes32 disputeId, DisputeOutcome outcome) external;

    function expireDispute(bytes32 disputeId) external;
}
