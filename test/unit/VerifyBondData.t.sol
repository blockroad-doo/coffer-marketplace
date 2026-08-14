//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

// Durable regression for getBondData, the signing-path view.
//
// The marketplace reads a bond through the hand-maintained declaration in src/interfaces/ICoffer.sol.
// This file pins the four-return shape of getBondData and its revert behavior for a bond that does
// not exist.
//
// Run: forge test --match-path "test/unit/VerifyBondData.t.sol" -vv

import {Test} from "forge-std/Test.sol";
import {CofferMarketplace} from "../../src/CofferMarketplace.sol";
import {MockBondNft, MockCoffer, MockWETH} from "./CofferMarketplace.t.sol";

contract VerifyBondDataTest is Test {
    CofferMarketplace internal marketplace;
    MockBondNft internal bondNft;
    MockCoffer internal coffer;
    MockWETH internal weth;

    address internal holder = makeAddr("holder");
    address internal mpOwner = makeAddr("mpOwner");
    address internal feeRecipient = makeAddr("feeRecipient");

    uint256 internal bondId;

    function setUp() public {
        vm.warp(100_000); // MockCoffer's constructor dates the bond start before now
        weth = new MockWETH();
        bondNft = new MockBondNft();
        coffer = new MockCoffer();
        marketplace = new CofferMarketplace(address(weth), address(bondNft), mpOwner, feeRecipient);

        bondId = bondNft.mintTo(holder, address(coffer));
    }

    /// @notice getBondData keeps its four returns for the signing path.
    function test_getBondDataShape() public view {
        (uint128 mv, uint32 dur, uint32 start, address cofferAddr) = marketplace.getBondData(bondId);
        assertEq(mv, 1 ether, "getBondData returns maturity");
        assertEq(dur, 86400, "getBondData returns duration");
        assertGt(uint256(start), 0, "getBondData returns start timestamp");
        assertEq(cofferAddr, address(coffer), "getBondData returns the coffer");
    }

    /// @notice A never-minted bond reverts. cofferOf returns address(0) and the call into it yields
    ///         empty returndata that the ABI decoder rejects. Every error the contract declares is
    ///         parameterless, so a named revert is exactly 4 bytes. A decode failure is not, which is
    ///         how a caller can tell there is no sentinel to catch.
    function test_nonexistentBondReverts() public view {
        uint256 ghostId = bondId + 1;
        assertEq(bondNft.cofferOf(ghostId), address(0), "unminted bond has no coffer");

        (bool okData, bytes memory rdData) =
            address(marketplace).staticcall(abi.encodeCall(CofferMarketplace.getBondData, (ghostId)));

        assertFalse(okData, "getBondData reverts");
        assertTrue(rdData.length != 4, "no named marketplace error, no sentinel");
    }
}
