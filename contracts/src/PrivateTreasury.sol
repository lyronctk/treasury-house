// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IncrementalMerkleTree} from "./IncrementalMerkleTree.sol";

/// @title Interface for the solidity verifier produced by verif-manager.circom
interface IVerifier {
    function verifyProof(
        uint256[2] memory a,
        uint256[2][2] memory b,
        uint256[2] memory c,
        uint256[11] memory input
    ) external view returns (bool);
}

/// @title Interface for poseidon hasher where t = 3
interface IHasherT3 {
    function poseidon(uint256[2] memory input) external pure returns (uint256);
}

/// @title Interface for poseidon hasher where t = 6
interface IHasherT6 {
    function poseidon(uint256[5] calldata input)
        external
        pure
        returns (uint256);
}

/// @title Private treasuries
/// @notice Platform for managing treasuries with balance privacy.
/// @dev Do not use in prod. This is a POC that has not undergone any audits. 
contract PrivateTreasury is IncrementalMerkleTree {
    uint256 internal _nMaxWithdraw;
    IVerifier verifierContract;
    IHasherT3 hasherT3 = IHasherT3(0xE41433D3a624C37015e2dE3FD54c0524689E60B2);
    IHasherT6 hasherT6 = IHasherT6(0x020405420661CFAb7Ad9B32bFCc441a04a8003a8);

    struct Point {
        bytes32 x;
        bytes32 y;
    }

    struct Treasury {
        Point pk;
        string label;
    }

    struct Leaf {
        Point P;
        Point Q;
        uint256 v;
    }

    /// @notice Emitted whenever a new leaf is added to the tree
    event NewLeaf(Leaf lf);

    /// @dev Directory of treasuries can be stored off-chain
    Treasury[] public directory;

    /// @notice Keep track of leaves that have been spent
    mapping(uint256 => bool) public spentLeaves;

    /// @notice Inherits from Maci's Incremental Merkle Tree
    constructor(
        uint8 treeDepth,
        uint256 nothingUpMySleeve,
        uint256 nMaxWithdraw,
        address verifier
    ) IncrementalMerkleTree(treeDepth, nothingUpMySleeve) {
        _nMaxWithdraw = nMaxWithdraw;
        verifierContract = IVerifier(verifier);
    }

    /// @notice Treasury creation
    /// @param pk Treasury public key sampled from Babyjubjub
    /// @param label Name given to treasury, use only as descriptor
    function create(Point calldata pk, string calldata label) external {
        directory.push(Treasury(pk, label));
    }

    /// @notice Utility function for creating a leaf, emitting event, and adding
    ///         to merkle tree
    /// @param P Contributor nonce
    /// @param Q Diffie-hellman shard key
    /// @param v Amount of ETH deposited with leaf
    function createLeaf(
        Point calldata P,
        Point calldata Q,
        uint256 v
    ) internal {
        Leaf memory lf = Leaf(P, Q, v);
        emit NewLeaf(lf);
        insertLeaf(_hashLeaf(lf));
    }

    /// @notice Contribute to a treasury on the platform
    /// @param P Contributor nonce (ρ * G)
    /// @param Q ρ * treasuryPubKey, a val that can only be derived using
    ///          α * P (where α is the treasury's private key)
    function deposit(Point calldata P, Point calldata Q) public payable {
        require(msg.value > 0, "Deposited ether value must be > 0.");
        createLeaf(P, Q, msg.value);
    }

    /// @notice Number of filled leaves in Merkle tree
    function getNumDeposits() public view returns (uint256) {
        return nextLeafIndex;
    }

    /// @notice Access length of directory
    function getDirectoryLength() external view returns (uint256) {
        return directory.length;
    }

    /// @notice For managers to withdraw deposits belonging to their treasury.
    ///         Enables withdrawal of exact value via a "change" leaf. Amount
    ///         to withdraw must be greater than the sum of values associated
    ///         with the leaves in the batch. Any remaining ether will be
    ///         stored in a new leaf redeemable by the same private key,
    ///         assuming changeP & changeQ are valid.
    /// @dev Padding currently done by repeating the 0th leaf, which means
    ///      there will be duplicates in indices that are to be withdrawn.
    ///      In the future, the circuit should verify 0-initialized leaves, so
    ///      duplicates don't need to be handled here.
    /// @dev Potential issue with Merkle root updating before the withdraw tx
    ///      is placed in a block. Opens up to front-running attacks to keep
    ///      funds locked.
    /// @param amount amount of ETH to withdraw, specified in wei
    /// @param changeP P for creating the deposit with the change value
    /// @param changeQ Q for creating the deposit with the change value
    /// @param a pi_a in proof
    /// @param b pi_b in proof
    /// @param c pi_c in proof
    /// @param publicSignals Public signals associated with the proof. The first
    ///                      element is the merkle root. The next nMaxWithdraw
    ///                      elements are values associated with the target
    ///                      leaves. The final nMaxWithdraw elements are the
    ///                      corresponding indices of the leaves.
    function withdraw(
        uint256 amount,
        Point calldata changeP,
        Point calldata changeQ,
        uint256[2] memory a,
        uint256[2][2] memory b,
        uint256[2] memory c,
        uint256[11] memory publicSignals
    ) external payable {
        require(
            publicSignals[0] == root,
            "Merkle root associated w/ proof doesn't match on-chain root."
        );
        require(
            verifierContract.verifyProof(a, b, c, publicSignals),
            "Invalid withdrawal proof"
        );

        uint256 totalLeafValue = 0;
        for (uint256 i = 1; i <= _nMaxWithdraw; i++) {
            uint256 v = publicSignals[i];
            uint256 leafIdx = publicSignals[i + _nMaxWithdraw];

            if (i > 1 && leafIdx == publicSignals[1 + _nMaxWithdraw]) {
                // Got to padding region
                break;
            }

            require(!spentLeaves[leafIdx], "Deposit already spent");
            spentLeaves[leafIdx] = true;
            totalLeafValue += v;
        }

        require(
            totalLeafValue >= amount,
            "Withdraw amount > value stored in the specified leaves."
        );
        createLeaf(changeP, changeQ, totalLeafValue - amount);
        payable(msg.sender).transfer(amount);
    }

    /// @notice Produces poseidon hash of two children hashes
    /// @param l Left child value
    /// @param r Right child value
    /// @dev Should be internal, but set to public so tests can run from
    ///      ethers. Not ideal, but foundry tests are being wonky.
    function _hashLeftRight(uint256 l, uint256 r)
        public
        view
        override
        returns (uint256)
    {
        return hasherT3.poseidon([l, r]);
    }

    /// @notice Produces poseidon hash of a leaf
    /// @param lf Leaf to hash
    /// @dev Should be internal, but set to public so tests can run from
    ///      ethers. Not ideal, but foundry tests are being wonky.
    function _hashLeaf(Leaf memory lf) public view returns (uint256) {
        return
            hasherT6.poseidon(
                [
                    uint256(lf.P.x),
                    uint256(lf.P.y),
                    uint256(lf.Q.x),
                    uint256(lf.Q.y),
                    lf.v
                ]
            );
    }
}
