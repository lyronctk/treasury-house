// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/PrivateTreasury.sol";

contract PrivateTreasuryTest is Test {
    PrivateTreasury public privTreasury;
    address manager = address(0x123);
    address contributor = address(0x456);

    PrivateTreasury.Point P =
        PrivateTreasury.Point(
            bytes32(
                hex"0beb072cad1738dae866e6efe0080d086481900dea98d73cc80abdf5ea0d061f"
            ),
            bytes32(
                hex"07c856388448bd7b93c909b4eeb8f6268e6cadac5b3011450593da038dae7945"
            )
        );
    PrivateTreasury.Point Q =
        PrivateTreasury.Point(
            bytes32(
                hex"07d391b607f465e1e8d6bd3e4ff87a24f3a86a5f70a2d825c3a60500e89cf83d"
            ),
            bytes32(
                hex"1fc64b3d1eed248c634469d98ac1b5774711bb2c370cf7775074da5a9c11b591"
            )
        );

    uint256[2] a = [
        0x1494871a35a3a00b313302be5bdf6e8b3e37977254c42dfca3b17c1709807b08,
        0x2f64010109c1e9f4f88ef254a3e419c8afb0ee40bfd3fb2d765b93e22539851b
    ];
    uint256[2][2] b = [
        [
            0x16b8386b74a031e9ea462d31c5f3345f2b798bfea4adffba35fb9a6ab97f4e68,
            0x18e9745d078f999093db2266cdb147a956e6c44880e88884119e07fcdc9789f3
        ],
        [
            0xea2db8f65c49e9c5f2c8b1ea04c682d0b837974724213f20f9206e0e58cf21f,
            0x82e1ac74769e80726385a39ac598913af3e2446cbc580c6cf21b903fedcb72d
        ]
    ];
    uint256[2] c = [
        0x2d790d2703b967efb5b5a5083ba4e4ba53b56f0a6b23d2936fbafa1b6e20708b,
        0x1fa91eb8ca52b9df25f71fa7535506ef413580e48198cf54011347f50161b147
    ];
    uint256[4] publicSignals = [
        0x0beb072cad1738dae866e6efe0080d086481900dea98d73cc80abdf5ea0d061f,
        0x07c856388448bd7b93c909b4eeb8f6268e6cadac5b3011450593da038dae7945,
        0x07d391b607f465e1e8d6bd3e4ff87a24f3a86a5f70a2d825c3a60500e89cf83d,
        0x1fc64b3d1eed248c634469d98ac1b5774711bb2c370cf7775074da5a9c11b591
    ];

    function setUp() public {
        privTreasury = new PrivateTreasury();
        vm.deal(contributor, 10 ether);
    }

    function testCreate() public {
        PrivateTreasury.Point memory pk = PrivateTreasury.Point(
            bytes32("123"),
            bytes32("456")
        );
        privTreasury.create(pk, "t1");
        assertEq(privTreasury.getDirectoryLength(), 1);
    }

    function testDeposit() public {
        PrivateTreasury.Point memory P = PrivateTreasury.Point(
            bytes32("111"),
            bytes32("222")
        );
        PrivateTreasury.Point memory Q = PrivateTreasury.Point(
            bytes32("333"),
            bytes32("444")
        );
        privTreasury.deposit{value: 555}(P, Q);
        assertEq(privTreasury.getNumDeposits(), 1);
    }

    ///@dev Only passes when verifierContract.verifyProof() is commented out in
    ///@dev withdraw. Not sure why, but proof verification works correctly
    ///@dev when it is sent through ethers.
    function testWithdraw() public {
        vm.prank(contributor);
        privTreasury.deposit{value: 0.5 ether}(P, Q);

        // Deposit at index 5 doesn't exist
        vm.expectRevert();
        privTreasury.withdraw(5, a, b, c, publicSignals);

        // P & Q must match deposit that is targeted for withdrawal
        publicSignals[0] = 0x0;
        vm.expectRevert();
        privTreasury.withdraw(0, a, b, c, publicSignals);
        publicSignals[
            0
        ] = 0x0beb072cad1738dae866e6efe0080d086481900dea98d73cc80abdf5ea0d061f;

        // Valid withdrawal by manager
        vm.prank(manager);
        privTreasury.withdraw(0, a, b, c, publicSignals);
        assertEq(manager.balance, 0.5 ether);

        // Can't withdraw the same deposit twice
        vm.expectRevert();
        privTreasury.withdraw(0, a, b, c, publicSignals);
    }
}
