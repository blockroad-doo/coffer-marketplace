//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

// Durable regression for the seller payout on buySignedListing.
//
// The ETH leg of a listing fill forwards all remaining gas to the seller. A seller whose receive
// reverts, burns everything it is given or runs out of gas fails the whole fill with
// SellerPaymentFailed, so nothing moves, the nonce bump reverts with the fill and the listing stays
// live. There is no second asset, so a fill that settles always paid the seller in ETH.
//
// The costly receives here end with the write of one new storage slot, the bookkeeping a contract
// wallet does when it is paid. Every fill below runs at FILL_GAS, which settles each of them under
// the Osaka and the Amsterdam gas rules.
//
// The fuzz at the end pins that the taker's gas limit decides only whether a fill settles, never
// what the seller is paid in.
//
// Run: forge test --match-path "test/unit/VerifySellerPayout.t.sol" -vv

import {Test} from "forge-std/Test.sol";
import {CofferMarketplace} from "../../src/CofferMarketplace.sol";
import {MockBondNft, MockCoffer, MockWETH} from "./CofferMarketplace.t.sol";

/// @dev ERC-1271 contract seller with a toggleable burn-everything receive.
contract GasBurnSeller {
    bytes4 internal constant MAGIC = 0x1626ba7e;

    bool public burn;

    function setBurn(bool _burn) external {
        burn = _burn;
    }

    function approveNft(address _nft, address _operator) external {
        MockBondNft(_nft).setApprovalForAll(_operator, true);
    }

    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return MAGIC;
    }

    receive() external payable {
        if (burn) {
            // Consume everything forwarded, so the outer call returns false on callee OOG.
            while (true) {}
        }
    }
}

/// @dev ERC-1271 contract seller whose receive costs a configurable amount of gas, modelling a
///      contract wallet that does bookkeeping when it is paid.
contract CostlyReceiveSeller {
    bytes4 internal constant MAGIC = 0x1626ba7e;

    uint256 public immutable I_SPEND;
    bytes32 private _sink;

    constructor(uint256 _spend) {
        I_SPEND = _spend;
    }

    function approveNft(address _nft, address _operator) external {
        MockBondNft(_nft).setApprovalForAll(_operator, true);
    }

    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return MAGIC;
    }

    receive() external payable {
        uint256 start = gasleft();
        bytes32 acc = _sink;
        while (start - gasleft() < I_SPEND) {
            acc = keccak256(abi.encode(acc));
        }
        _sink = acc;
    }
}

contract VerifySellerPayoutTest is Test {
    CofferMarketplace internal marketplace;
    MockBondNft internal bondNft;
    MockCoffer internal coffer;
    MockWETH internal weth;

    uint256 internal constant SELLER_PK = 0xA11CE;

    address internal buyer = makeAddr("buyer");
    address internal mpOwner = makeAddr("mpOwner");
    address internal feeRecipient = makeAddr("feeRecipient");

    uint128 internal constant PRICE = 1 ether;
    uint128 internal constant MATURITY = 2 ether;
    uint256 internal constant FEE = 0.09 ether; // 9% of (2 - 1)
    uint256 internal constant TOTAL = 1.09 ether; // exact payment, so the refund leg is skipped
    uint256 internal constant EXCESS = 0.25 ether;
    // The gas limit every fill in this file runs at, enough to settle each receive here
    uint256 internal constant FILL_GAS = 1_000_000;

    uint64 internal expiration;

    bytes32 constant LISTING_TYPEHASH = keccak256(
        "Listing(address seller,uint256 bondId,uint128 price,uint128 maturityValue,uint64 expiration,uint256 nonce,uint256 globalNonce)"
    );
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function setUp() public {
        vm.warp(100_000); // MockCoffer's constructor dates the bond start before now
        weth = new MockWETH();
        bondNft = new MockBondNft();
        coffer = new MockCoffer();
        marketplace = new CofferMarketplace(address(weth), address(bondNft), mpOwner, feeRecipient);

        coffer.setMaturityValue(MATURITY);
        expiration = uint64(block.timestamp + 1 days);
        vm.deal(address(this), 100 ether);
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

    function _signListing(uint256 _pk, address _seller, uint256 _bondId) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(LISTING_TYPEHASH, _seller, _bondId, PRICE, MATURITY, expiration, uint256(0), uint256(0))
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Give a contract seller a bond and marketplace approval.
    function _listFrom(address _seller) internal returns (uint256 bondId) {
        bondId = bondNft.mintTo(_seller, address(coffer));
        (bool ok,) =
            _seller.call(abi.encodeWithSignature("approveNft(address,address)", address(bondNft), address(marketplace)));
        require(ok, "approveNft failed");
    }

    /// @dev Fill the listing as `buyer` under an explicit gas limit, returning success and the revert data.
    function _fill(address _seller, uint256 _bondId, bytes memory _sig, uint256 _gasLimit)
        internal
        returns (bool ok, bytes memory ret)
    {
        return _fillPaying(_seller, _bondId, _sig, _gasLimit, TOTAL);
    }

    /// @dev Like _fill, but sending an explicit ETH value so a test can exercise the refund leg.
    function _fillPaying(address _seller, uint256 _bondId, bytes memory _sig, uint256 _gasLimit, uint256 _value)
        internal
        returns (bool ok, bytes memory ret)
    {
        bytes memory data = abi.encodeCall(
            CofferMarketplace.buySignedListing, (_bondId, _seller, PRICE, MATURITY, expiration, 0, 0, _sig)
        );
        vm.prank(buyer);
        (ok, ret) = address(marketplace).call{gas: _gasLimit, value: _value}(data);
    }

    /// @notice A seller whose receive burns everything it is given fails the whole fill with
    ///         SellerPaymentFailed. The EVM keeps 1/64 of the gas in the marketplace, which raises the
    ///         error. Nothing moves, so the same listing fills once the receive takes ETH again.
    function test_burningSeller_revertsWholeAndListingStaysLive() public {
        GasBurnSeller seller = new GasBurnSeller();
        uint256 bondId = _listFrom(address(seller));
        seller.setBurn(true);
        uint256 buyerBefore = buyer.balance;

        (bool ok, bytes memory ret) = _fillPaying(address(seller), bondId, "", FILL_GAS, TOTAL + EXCESS);

        assertFalse(ok, "a burning seller fails the fill");
        assertEq(ret, abi.encodeWithSelector(CofferMarketplace.SellerPaymentFailed.selector), "SellerPaymentFailed");
        assertEq(buyer.balance, buyerBefore, "buyer keeps the price, the fee and the excess");
        assertEq(address(seller).balance, 0, "seller received no ETH");
        assertEq(weth.balanceOf(address(seller)), 0, "seller received no WETH");
        assertEq(address(marketplace).balance, 0, "marketplace kept nothing");
        assertEq(bondNft.ownerOf(bondId), address(seller), "seller keeps the bond");
        assertEq(marketplace.sListingNonce(address(seller), bondId), 0, "nonce not consumed");

        seller.setBurn(false);
        (ok,) = _fillPaying(address(seller), bondId, "", FILL_GAS, TOTAL + EXCESS);

        assertTrue(ok, "the same listing fills once the receive takes ETH");
        assertEq(address(seller).balance, PRICE, "seller paid the price in ETH");
        assertEq(buyer.balance, buyerBefore - TOTAL, "excess refunded to the buyer");
        assertEq(address(marketplace).balance, FEE, "marketplace retained exactly the fee");
        assertEq(bondNft.ownerOf(bondId), buyer, "buyer received the bond");
        assertEq(marketplace.sListingNonce(address(seller), bondId), 1, "nonce bumped once");
    }

    /// @notice A contract wallet whose receive does some bookkeeping, a 14,000 gas loop and one new
    ///         storage slot, is paid in ETH.
    function test_normalContractWalletSeller_paidInEth() public {
        CostlyReceiveSeller seller = new CostlyReceiveSeller(14_000);
        uint256 bondId = _listFrom(address(seller));

        (bool ok,) = _fill(address(seller), bondId, "", FILL_GAS);

        assertTrue(ok, "fill must succeed");
        assertEq(address(seller).balance, PRICE, "seller paid in ETH");
        assertEq(weth.balanceOf(address(seller)), 0, "no WETH paid");
        assertEq(address(marketplace).balance, FEE, "marketplace retained exactly the fee");
    }

    /// @notice A receive that costs 200,000 gas is paid in ETH as well. Its cost comes out of the taker's
    ///         gas limit like any other step of the fill.
    function test_expensiveContractWalletSeller_paidInEth() public {
        CostlyReceiveSeller seller = new CostlyReceiveSeller(200_000);
        uint256 bondId = _listFrom(address(seller));

        (bool ok,) = _fill(address(seller), bondId, "", FILL_GAS);

        assertTrue(ok, "fill must succeed");
        assertEq(address(seller).balance, PRICE, "seller paid in ETH");
        assertEq(weth.balanceOf(address(seller)), 0, "no WETH paid");
        assertEq(bondNft.ownerOf(bondId), buyer, "buyer received the bond");
    }

    /// @notice A never-funded EOA seller is paid in ETH. The account-creation cost is charged to the
    ///         marketplace frame, not taken out of the gas forwarded to the seller.
    function test_freshEoaSeller_paidInEth() public {
        address seller = vm.addr(SELLER_PK);
        assertEq(seller.balance, 0, "seller starts unfunded");

        uint256 bondId = bondNft.mintTo(seller, address(coffer));
        vm.prank(seller);
        bondNft.setApprovalForAll(address(marketplace), true);
        bytes memory sig = _signListing(SELLER_PK, seller, bondId);

        (bool ok,) = _fill(seller, bondId, sig, FILL_GAS);

        assertTrue(ok, "fill must succeed");
        assertEq(seller.balance, PRICE, "seller paid in ETH");
        assertEq(weth.balanceOf(seller), 0, "no WETH paid");
    }

    // ───── The taker's gas limit decides only whether a fill settles ─────
    //
    // The payout forwards 63/64 of the remaining gas plus the 2300 stipend. A receive that does not fit
    // in it makes the whole fill revert, and a fill that settles always paid the seller in ETH.

    /// @notice Whatever gas limit the taker submits, a settled fill paid the seller in ETH and a failed
    ///         fill changed nothing.
    function testFuzz_sellerPayout_paidInEthOrNothing(uint256 gasLimit, uint32 spend) public {
        spend = uint32(bound(spend, 0, 200_000));
        gasLimit = bound(gasLimit, 0, 1_500_000);
        CostlyReceiveSeller seller = new CostlyReceiveSeller(spend);
        uint256 bondId = _listFrom(address(seller));
        uint256 buyerBefore = buyer.balance;

        (bool ok,) = _fill(address(seller), bondId, "", gasLimit);

        assertEq(weth.balanceOf(address(seller)), 0, "a listing fill never pays WETH");
        if (ok) {
            assertEq(address(seller).balance, PRICE, "a settled fill paid the seller in ETH");
            assertEq(address(marketplace).balance, FEE);
            assertEq(buyer.balance, buyerBefore - TOTAL);
            assertEq(bondNft.ownerOf(bondId), buyer);
            assertEq(marketplace.sListingNonce(address(seller), bondId), 1);
        } else {
            assertEq(address(seller).balance, 0, "a failed fill paid nothing");
            assertEq(address(marketplace).balance, 0);
            assertEq(buyer.balance, buyerBefore);
            assertEq(bondNft.ownerOf(bondId), address(seller));
            assertEq(marketplace.sListingNonce(address(seller), bondId), 0);
        }
        // Not vacuous: FILL_GAS settles every receive in the range
        if (gasLimit >= FILL_GAS) assertTrue(ok, "FILL_GAS must settle every receive in the range");
    }
}
