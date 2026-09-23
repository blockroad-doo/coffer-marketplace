// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {CofferMarketplace} from "../../src/CofferMarketplace.sol";
import {IERC721Receiver, MockBondNft, MockCoffer, MockWETH} from "./CofferMarketplace.t.sol";

// Gap row MG-04 (ADV-09), lead L4: claimFees carries no guard while a fill custodies the taker's ETH, and
// an owner who is also a party can call it from inside the fill. Every ordering that still holds the taker's
// ETH reverts as a whole, so nothing of the taker's reaches the recipient. Owner as seller sweeping in
// receive with an excess to refund: the refund finds no balance, InsufficientPayment. Owner as buyer
// sweeping in the ERC-721 hook: the seller payout and the fallback deposit both find no balance, and the
// deposit's failure carries no data. The one ordering that settles, owner as seller with no excess, is
// documented: the price has already left, so the sweep takes the accrued fees plus this fill's fee, which
// belong to the recipient anyway.

/// @dev ERC-1271 seller that validates any signature and, as the owner, sweeps from its receive.
contract OwnerSellerSweeper {
    bytes4 internal constant MAGIC = 0x1626ba7e;
    CofferMarketplace public marketplace;

    function setMarketplace(CofferMarketplace _marketplace) external {
        marketplace = _marketplace;
    }

    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return MAGIC;
    }

    function approveNft(address _nft, address _operator) external {
        MockBondNft(_nft).setApprovalForAll(_operator, true);
    }

    receive() external payable {
        marketplace.claimFees();
    }
}

/// @dev Contract buyer that, as the owner, sweeps from the receiver hook, before the payout runs.
contract OwnerBuyerSweeper is IERC721Receiver {
    CofferMarketplace public marketplace;

    function setMarketplace(CofferMarketplace _marketplace) external {
        marketplace = _marketplace;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        marketplace.claimFees();
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract VerifyOwnerPartySweepTest is Test {
    CofferMarketplace internal marketplace;
    MockBondNft internal bondNft;
    MockCoffer internal coffer;
    MockWETH internal weth;

    uint256 internal constant SELLER_PK = 0xA11CE;
    address internal buyer = makeAddr("buyer");
    address internal feeRecipient = makeAddr("feeRecipient");

    uint128 internal constant PRICE = 1 ether;
    uint128 internal constant MATURITY = 2 ether;
    uint256 internal constant FEE = 0.09 ether;
    uint256 internal constant TOTAL = 1.09 ether;
    uint256 internal constant ACCRUED = 0.5 ether; // fees custodied before the fill
    uint256 internal constant EXCESS = 0.25 ether;

    uint64 internal expiration;

    bytes32 constant LISTING_TYPEHASH = keccak256(
        "Listing(address seller,uint256 bondId,uint128 price,uint128 maturityValue,uint64 expiration,uint256 nonce,uint256 globalNonce)"
    );
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function setUp() public {
        vm.warp(100_000);
        weth = new MockWETH();
        bondNft = new MockBondNft();
        coffer = new MockCoffer();
        coffer.setMaturityValue(MATURITY);
        expiration = uint64(block.timestamp + 1 days);
        vm.deal(buyer, 100 ether);
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("CofferMarketplace")),
                keccak256(bytes("5")),
                block.chainid,
                address(marketplace)
            )
        );
    }

    function _signListing(uint256 pk, address seller_, uint256 bondId) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(LISTING_TYPEHASH, seller_, bondId, PRICE, MATURITY, expiration, uint256(0), uint256(0))
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Deploy the marketplace owned by `owner` with fees already accrued.
    function _deployOwnedBy(address owner) internal {
        marketplace = new CofferMarketplace(address(weth), address(bondNft), owner, feeRecipient);
        vm.deal(address(marketplace), ACCRUED);
    }

    function _sellerSweeperListing() internal returns (OwnerSellerSweeper sweeper, uint256 bondId) {
        sweeper = new OwnerSellerSweeper();
        _deployOwnedBy(address(sweeper));
        sweeper.setMarketplace(marketplace);
        bondId = bondNft.mintTo(address(sweeper), address(coffer));
        sweeper.approveNft(address(bondNft), address(marketplace));
    }

    function test_ownerSellerSweepsInReceive_withExcess_revertsInsufficientPayment() public {
        (OwnerSellerSweeper sweeper, uint256 bondId) = _sellerSweeperListing();
        uint256 buyerBefore = buyer.balance;
        uint256 recipientBefore = feeRecipient.balance;

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.InsufficientPayment.selector);
        marketplace.buySignedListing{value: TOTAL + EXCESS}(
            bondId, address(sweeper), PRICE, MATURITY, expiration, 0, 0, ""
        );

        assertEq(address(marketplace).balance, ACCRUED, "accrued fees untouched");
        assertEq(feeRecipient.balance, recipientBefore, "nothing reached the recipient");
        assertEq(buyer.balance, buyerBefore, "taker's ETH untouched");
        assertEq(address(sweeper).balance, 0, "seller unpaid");
        assertEq(bondNft.ownerOf(bondId), address(sweeper));
        assertEq(marketplace.sListingNonce(address(sweeper), bondId), 0);
    }

    function test_ownerSellerSweepsInReceive_noExcess_settlesAndSweepsOnlyFees() public {
        (OwnerSellerSweeper sweeper, uint256 bondId) = _sellerSweeperListing();
        uint256 buyerBefore = buyer.balance;
        uint256 recipientBefore = feeRecipient.balance;

        // The sweep runs inside the payout, after the price has left, so it sees accrued plus fee
        vm.expectEmit(true, true, true, true, address(marketplace));
        emit CofferMarketplace.FeesClaimed(feeRecipient, ACCRUED + FEE);
        vm.prank(buyer);
        marketplace.buySignedListing{value: TOTAL}(bondId, address(sweeper), PRICE, MATURITY, expiration, 0, 0, "");

        assertEq(address(sweeper).balance, PRICE, "seller paid the price in ETH before the sweep");
        assertEq(weth.balanceOf(address(sweeper)), 0, "no fallback");
        assertEq(feeRecipient.balance - recipientBefore, ACCRUED + FEE, "the sweep took the fees and nothing else");
        assertEq(address(marketplace).balance, 0);
        assertEq(buyer.balance, buyerBefore - TOTAL, "taker charged exactly price + fee");
        assertEq(bondNft.ownerOf(bondId), buyer);
        assertEq(marketplace.sListingNonce(address(sweeper), bondId), 1);
    }

    function test_ownerBuyerSweepsInHook_revertsWholeWithNoData() public {
        OwnerBuyerSweeper sweeper = new OwnerBuyerSweeper();
        _deployOwnedBy(address(sweeper));
        sweeper.setMarketplace(marketplace);
        address seller = vm.addr(SELLER_PK);
        uint256 bondId = bondNft.mintTo(seller, address(coffer));
        vm.prank(seller);
        bondNft.setApprovalForAll(address(marketplace), true);
        bytes memory sig = _signListing(SELLER_PK, seller, bondId);
        vm.deal(address(sweeper), TOTAL);
        uint256 recipientBefore = feeRecipient.balance;

        // The hook's sweep empties the contract. The bounded payout then fails on balance, and the fallback
        // deposit is a value call above the balance, which fails at the CALL opcode with no returndata, so the
        // taker's revert carries none.
        bytes memory data = abi.encodeCall(
            CofferMarketplace.buySignedListing, (bondId, seller, PRICE, MATURITY, expiration, 0, 0, sig)
        );
        vm.prank(address(sweeper));
        (bool ok, bytes memory ret) = address(marketplace).call{value: TOTAL}(data);

        assertFalse(ok, "fill must revert as a whole");
        assertEq(ret.length, 0, "the deposit's failure bubbles no data");
        assertEq(address(marketplace).balance, ACCRUED, "accrued fees untouched");
        assertEq(feeRecipient.balance, recipientBefore, "nothing reached the recipient");
        assertEq(address(sweeper).balance, TOTAL, "taker's ETH untouched");
        assertEq(seller.balance, 0);
        assertEq(weth.balanceOf(seller), 0);
        assertEq(bondNft.ownerOf(bondId), seller);
        assertEq(marketplace.sListingNonce(seller, bondId), 0);
    }
}
