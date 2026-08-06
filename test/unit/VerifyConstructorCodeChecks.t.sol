//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

// Durable regression for the constructor's contract checks on the two immutables.
//
// I_WETH and I_COFFER_BOND_NFT are immutable with no setter, so an address that holds no code is
// baked in permanently and leaves a half dead deployment: every offer accept reverts at the WETH
// balance read, any listing whose seller rejects ETH dies at the WETH fallback, and claimWethFees
// is bricked, while plain ETH listing fills keep working. Requiring code at both addresses rejects
// that at construction, and covers address(0) in the same check. The fee recipient is deliberately
// not covered, because it is allowed to be an account rather than a contract.
//
// Run: forge test --match-path "test/unit/VerifyConstructorCodeChecks.t.sol" -vv

import {Test} from "forge-std/Test.sol";
import {CofferMarketplace} from "../../src/CofferMarketplace.sol";
import {MockBondNft, MockWETH} from "./CofferMarketplace.t.sol";

contract VerifyConstructorCodeChecksTest is Test {
    MockBondNft internal bondNft;
    MockWETH internal weth;

    address internal constant MP_OWNER = address(0xA11CE);
    address internal constant FEE_RECIPIENT = address(0xFEE);
    /// @dev An address that holds no code, which is what a typo or a stale env key resolves to.
    address internal constant NO_CODE = address(0xDEAD);

    function setUp() public {
        bondNft = new MockBondNft();
        weth = new MockWETH();
    }

    function test_wethWithoutCode_reverts() public {
        assertEq(NO_CODE.code.length, 0, "the fixture address must hold no code");

        vm.expectRevert(CofferMarketplace.NotAContract.selector);
        new CofferMarketplace(NO_CODE, address(bondNft), MP_OWNER, FEE_RECIPIENT);
    }

    function test_bondNftWithoutCode_reverts() public {
        vm.expectRevert(CofferMarketplace.NotAContract.selector);
        new CofferMarketplace(address(weth), NO_CODE, MP_OWNER, FEE_RECIPIENT);
    }

    /// @notice address(0) holds no code either, so the contract check subsumes a zero-address check.
    function test_zeroWeth_revertsAsNotAContract() public {
        vm.expectRevert(CofferMarketplace.NotAContract.selector);
        new CofferMarketplace(address(0), address(bondNft), MP_OWNER, FEE_RECIPIENT);
    }

    function test_zeroBondNft_revertsAsNotAContract() public {
        vm.expectRevert(CofferMarketplace.NotAContract.selector);
        new CofferMarketplace(address(weth), address(0), MP_OWNER, FEE_RECIPIENT);
    }

    /// @notice The fee recipient keeps its own zero check and is not subject to the contract check.
    function test_zeroFeeRecipient_stillRevertsAsZeroAddress() public {
        vm.expectRevert(CofferMarketplace.ZeroAddress.selector);
        new CofferMarketplace(address(weth), address(bondNft), MP_OWNER, address(0));
    }

    /// @notice Contracts for both immutables and a plain account as fee recipient construct fine,
    ///         which is what proves the check is not tightened past what it is meant to catch.
    function test_contractsConstruct_feeRecipientMayBeAnAccount() public {
        CofferMarketplace marketplace = new CofferMarketplace(address(weth), address(bondNft), MP_OWNER, FEE_RECIPIENT);

        assertEq(FEE_RECIPIENT.code.length, 0, "the fee recipient is a plain account");
        assertEq(marketplace.I_WETH(), address(weth), "WETH immutable");
        assertEq(marketplace.I_COFFER_BOND_NFT(), address(bondNft), "bond NFT immutable");
        assertEq(marketplace.owner(), MP_OWNER, "owner");
        assertEq(marketplace.sFeeRecipient(), FEE_RECIPIENT, "fee recipient");
    }
}
