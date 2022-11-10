// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IVerifier {
    function verifyProof(
        uint256[2] memory a,
        uint256[2][2] memory b,
        uint256[2] memory c,
        uint256[4] memory input
    ) external view returns (bool);
}

/// @title Private treasuries
/// @notice Platform for managing treasuries with balance & withdrawal privacy
/// @dev This is a POC that has not undergone any audits.
contract PrivateTreasury {
    address public constant VERIFIER_ADDR =
        0x09635F643e140090A9A8Dcd712eD6285858ceBef;
    IVerifier verifierContract = IVerifier(VERIFIER_ADDR);

    struct Point {
        bytes32 x;
        bytes32 y;
    }

    struct Treasury {
        Point pk;
        string label;
    }

    struct Deposit {
        Point P;
        Point Q;
        uint256 v;
        bool spent;
    }

    /// @dev Directory of treasuries can be stored off-chain
    Treasury[] public directory;

    /// @dev Should be stored in a Merkle Tree instead of an array
    Deposit[] public deposits;

    /// @notice Treasury creation
    /// @param pk Public key generated from Babyjubjub
    /// @param label Name given to treasury, use only as descriptor, not lookup
    function create(Point calldata pk, string calldata label) external {
        directory.push(Treasury(pk, label));
    }

    /// @notice Contribute to a treasury on the platform
    /// @param P Pubkey of contributor (ρ * G, where ρ is contributor's privKey)
    /// @param Q ρ * treasuryPubKey, a val that can only be derived using
    ///          α * P (where α is the treasury's private key)
    function deposit(Point calldata P, Point calldata Q) external payable {
        require(msg.value > 0, "Deposited ether value must be > 0.");
        deposits.push(Deposit(P, Q, msg.value, false));
    }

    /// @notice [TODO]
    function withdraw(
        uint256[2] memory a,
        uint256[2][2] memory b,
        uint256[2] memory c,
        uint256[4] memory publicSignals
    ) external {
        require(
            verifierContract.verifyProof(a, b, c, publicSignals),
            "Invalid withdrawal proof"
        );
    }

    /// @notice Access length of deposits
    function getNumDeposits() external view returns (uint256) {
        return deposits.length;
    }

    /// @notice Access length of directory
    function getDirectoryLength() external view returns (uint256) {
        return directory.length;
    }
}
