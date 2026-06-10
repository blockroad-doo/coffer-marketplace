//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {CofferMarketplace} from "../../src/CofferMarketplace.sol";

/// @notice Regression test for audit finding M-01: renounceOwnership must be permanently disabled,
///         while the two-step ownership transfer must still work. The constructor only needs
///         non-zero WETH and bond-NFT addresses, so placeholders suffice (no trading here).
contract VerifyRenounceDisabledTest is Test {
    CofferMarketplace public marketplace;
    address public mpOwner = makeAddr("mpOwner");
    address public feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
        marketplace = new CofferMarketplace(makeAddr("weth"), makeAddr("bondNft"), mpOwner, feeRecipient);
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
