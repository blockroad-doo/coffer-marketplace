//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {CofferMarketplace} from "../../src/CofferMarketplace.sol";
import {MockBondNft, MockWETH} from "./CofferMarketplace.t.sol";

/// @notice renounceOwnership is permanently disabled, while the two-step ownership transfer still
///         works. No trading happens here, but the constructor requires code at both token
///         addresses, so the mocks are deployed rather than passing placeholder addresses.
contract VerifyRenounceDisabledTest is Test {
    CofferMarketplace public marketplace;
    address public mpOwner = makeAddr("mpOwner");
    address public feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
        marketplace = new CofferMarketplace(address(new MockWETH()), address(new MockBondNft()), mpOwner, feeRecipient);
    }

    function test_renounceOwnership_revertsForOwner() public {
        vm.prank(mpOwner);
        vm.expectRevert(CofferMarketplace.RenounceOwnershipDisabled.selector);
        marketplace.renounceOwnership();
        assertEq(marketplace.owner(), mpOwner, "owner unchanged");
    }

    function test_twoStepOwnershipTransfer_stillWorks() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(mpOwner);
        marketplace.transferOwnership(newOwner);
        assertEq(marketplace.owner(), mpOwner, "owner not changed until accepted");
        assertEq(marketplace.pendingOwner(), newOwner, "pending owner set");

        vm.prank(newOwner);
        marketplace.acceptOwnership();
        assertEq(marketplace.owner(), newOwner, "ownership transferred");
    }
}
