//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

// Durable regression for getBondCollateral, the view that exposes what backs a bond's claim.
//
// A trade is gated on maturity value alone, which is a claim size and says nothing about whether the
// Coffer can pay it or when. getBondCollateral adds the Coffer state that answers those questions:
// the balance available to claim against now, the reserve held for bonds whose consensus withdrawal
// has been closed, and whether this bond is itself one of those. A closed bond claims against the
// whole balance, an open one must leave the reserve behind, so the reserve is the senior claim ahead
// of any open bond and is what decides how much an open holder actually receives.
//
// getBondData is deliberately untouched by this view. It stays on the signing path with its original
// four returns and its original two external calls.
//
// Run: forge test --match-path "test/unit/VerifyBondCollateral.t.sol" -vv

import {Test} from "forge-std/Test.sol";
import {CofferMarketplace} from "../../src/CofferMarketplace.sol";
import {MockBondNft, MockCoffer, MockWETH} from "./CofferMarketplace.t.sol";

/// @dev Coffer that answers both reads with byte-for-byte payloads captured from a deployed Coffer,
///      so the marketplace's ICoffer declaration is decoded against real chain data rather than
///      against a mock written from the same reading of the source that produced the declaration.
///      A declaration whose shape drifted from the deployed contract fails here.
///
///      Captured with `cast call` from Coffer 0x0429f2724aeab93e179a8a3a84cffa125be37029 on Hoodi
///      at block 3311751:
///        sHolderConditions(1)     -> 1002739726027397260, 4320000, 1778784624, false
///        totalConsensusReserved() -> 0
contract LiveBlobCoffer {
    bytes internal constant HOLDER_CONDITIONS = hex"0000000000000000000000000000000000000000000000000dea7277d409188c"
        hex"000000000000000000000000000000000000000000000000000000000041eb00"
        hex"000000000000000000000000000000000000000000000000000000006a061970"
        hex"0000000000000000000000000000000000000000000000000000000000000000";

    bytes internal constant CONSENSUS_RESERVED = hex"0000000000000000000000000000000000000000000000000000000000000000";

    function sHolderConditions(uint256) external pure {
        bytes memory out = HOLDER_CONDITIONS;
        assembly {
            return(add(out, 0x20), mload(out))
        }
    }

    function totalConsensusReserved() external pure {
        bytes memory out = CONSENSUS_RESERVED;
        assembly {
            return(add(out, 0x20), mload(out))
        }
    }
}

contract VerifyBondCollateralTest is Test {
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

    /// @notice The view reports the bond's claim size together with the Coffer state behind it.
    function test_reportsClaimSizeAndBacking() public {
        coffer.setMaturityValue(10 ether);
        coffer.setTotalConsensusReserved(3 ether);
        vm.deal(address(coffer), 4 ether);

        (
            uint128 maturityValue,
            bool consensusWithdrawClosed,
            address cofferAddress,
            uint256 cofferBalance,
            uint128 totalConsensusReserved
        ) = marketplace.getBondCollateral(bondId);

        assertEq(maturityValue, 10 ether, "claim size");
        assertFalse(consensusWithdrawClosed, "bond has not closed its consensus withdrawal");
        assertEq(cofferAddress, address(coffer), "coffer address");
        assertEq(cofferBalance, 4 ether, "balance available to claim against");
        assertEq(totalConsensusReserved, 3 ether, "reserve held for closed bonds");
    }

    /// @notice The consensus flag is surfaced here and still absent from getBondData, which keeps its
    ///         original four returns for the signing path.
    function test_consensusFlagSurfaced_getBondDataUnchanged() public {
        coffer.setConsensusWithdrawClosed(true);

        (, bool consensusWithdrawClosed,,,) = marketplace.getBondCollateral(bondId);
        assertTrue(consensusWithdrawClosed, "closed flag reaches the caller");

        (uint128 mv, uint32 dur, uint32 start, address cofferAddr) = marketplace.getBondData(bondId);
        assertEq(mv, 1 ether, "getBondData still returns maturity");
        assertEq(dur, 86400, "getBondData still returns duration");
        assertGt(uint256(start), 0, "getBondData still returns start timestamp");
        assertEq(cofferAddr, address(coffer), "getBondData still returns the coffer");
    }

    /// @notice The reserve is senior to an open bond, so an open holder can only draw against the
    ///         balance above it. A closed bond draws against the whole balance. This is the number a
    ///         buyer needs before quoting a price, and the reason the reserve is in the view.
    function test_reserveIsSeniorToAnOpenBond() public {
        coffer.setMaturityValue(10 ether);
        coffer.setTotalConsensusReserved(9 ether);
        vm.deal(address(coffer), 12 ether);

        (uint128 maturityValue,,, uint256 balanceOpen, uint128 reservedOpen) = marketplace.getBondCollateral(bondId);
        assertEq(balanceOpen - reservedOpen, 3 ether, "an open bond can draw 3 of its 10 ether claim");
        assertLt(balanceOpen - reservedOpen, maturityValue, "the open holder is short despite a funded coffer");

        coffer.setConsensusWithdrawClosed(true);
        (,,, uint256 balanceClosed,) = marketplace.getBondCollateral(bondId);
        assertEq(balanceClosed, 12 ether, "a closed bond draws against the whole balance");
    }

    /// @notice A never-minted bond reverts the same way getBondData does, so the two views agree.
    ///         cofferOf returns address(0) and the call into it yields empty returndata that the ABI
    ///         decoder rejects. The size of that revert is not asserted, because forge injects a
    ///         message payload for a call to a codeless address when gas reporting is on. The two
    ///         properties below hold whatever the runner does with the payload.
    function test_nonexistentBond_revertsLikeGetBondData() public view {
        uint256 ghostId = bondId + 1;
        assertEq(bondNft.cofferOf(ghostId), address(0), "unminted bond has no coffer");

        (bool okCollateral, bytes memory rdCollateral) =
            address(marketplace).staticcall(abi.encodeCall(CofferMarketplace.getBondCollateral, (ghostId)));
        (bool okData, bytes memory rdData) =
            address(marketplace).staticcall(abi.encodeCall(CofferMarketplace.getBondData, (ghostId)));

        assertFalse(okCollateral, "getBondCollateral reverts");
        assertFalse(okData, "getBondData reverts");
        // Byte for byte, so a sentinel added to one view and not the other fails here.
        assertEq(keccak256(rdCollateral), keccak256(rdData), "both views fail identically");
        // Every error the contract declares is parameterless, so a named revert is exactly 4 bytes.
        // A decode failure is not, which is how a caller can tell there is no sentinel to catch.
        assertTrue(rdCollateral.length != 4, "no named marketplace error, no sentinel");
    }

    /// @notice The ICoffer declaration decodes payloads captured from a deployed Coffer. A shape that
    ///         drifted from the deployed contract would revert here rather than in production.
    function test_decodesPayloadsFromADeployedCoffer() public {
        LiveBlobCoffer live = new LiveBlobCoffer();
        uint256 liveBondId = bondNft.mintTo(holder, address(live));
        vm.deal(address(live), 1 ether); // the captured Coffer held 1 ether at that block

        (
            uint128 maturityValue,
            bool consensusWithdrawClosed,
            address cofferAddress,
            uint256 cofferBalance,
            uint128 totalConsensusReserved
        ) = marketplace.getBondCollateral(liveBondId);

        assertEq(maturityValue, 1002739726027397260, "maturity decoded from the captured payload");
        assertFalse(consensusWithdrawClosed, "flag decoded from the captured payload");
        assertEq(cofferAddress, address(live), "coffer address");
        assertEq(cofferBalance, 1 ether, "balance");
        assertEq(totalConsensusReserved, 0, "reserve decoded from the captured payload");
    }
}
