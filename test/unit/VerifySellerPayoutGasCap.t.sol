//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

// Durable regression for the bounded seller payout on buySignedListing.
//
// The ETH leg of a listing fill forwards at most SELLER_PAYOUT_GAS_LIMIT to the seller. Without a
// bound, a seller contract whose receive burns gas consumes 63/64 of everything forwarded (EIP-150)
// and leaves the WETH fallback only the retained 1/64, so the whole fill runs out of gas unless the
// taker supplies millions of gas. With the bound, the burn is capped, the fallback always has room,
// and the fill settles in WETH at an ordinary gas limit. Sellers whose receive is merely expensive
// rather than malicious are paid in WETH too, which is a degradation, not a failure.
//
// The two fuzzes at the end pin that the taker's gas limit never picks the asset: a cheap
// receive is paid in ETH by every fill that settles, an expensive one in WETH, and a fill that fails moves nothing.
//
// Run: forge test --match-path "test/unit/VerifySellerPayoutGasCap.t.sol" -vv

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

contract VerifySellerPayoutGasCapTest is Test {
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

    /// @dev Fill the listing as `buyer` under an explicit gas limit, returning success and gas used.
    function _fill(address _seller, uint256 _bondId, bytes memory _sig, uint256 _gasLimit)
        internal
        returns (bool ok, uint256 used)
    {
        return _fillPaying(_seller, _bondId, _sig, _gasLimit, TOTAL);
    }

    /// @dev Like _fill, but sending an explicit ETH value so a test can exercise the refund leg.
    function _fillPaying(address _seller, uint256 _bondId, bytes memory _sig, uint256 _gasLimit, uint256 _value)
        internal
        returns (bool ok, uint256 used)
    {
        bytes memory data = abi.encodeCall(
            CofferMarketplace.buySignedListing, (_bondId, _seller, PRICE, MATURITY, expiration, 0, 0, _sig)
        );
        vm.prank(buyer);
        (ok,) = address(marketplace).call{gas: _gasLimit, value: _value}(data);
        used = vm.lastFrameGas().gasTotalUsed;
    }

    /// @notice A gas-burning seller no longer starves the WETH fallback: the fill settles at an
    ///         ordinary gas limit and the seller is paid in WETH.
    function test_burningSeller_settlesInWethAtOrdinaryGasLimit() public {
        GasBurnSeller seller = new GasBurnSeller();
        uint256 bondId = _listFrom(address(seller));
        seller.setBurn(true);

        (bool ok,) = _fill(address(seller), bondId, "", 500_000);

        assertTrue(ok, "fill must succeed at an ordinary gas limit");
        assertEq(weth.balanceOf(address(seller)), PRICE, "seller paid the full price in WETH");
        assertEq(address(seller).balance, 0, "seller received no ETH");
        assertEq(address(marketplace).balance, FEE, "marketplace retained exactly the fee");
        assertEq(weth.balanceOf(address(marketplace)), 0, "no WETH stranded in the marketplace");
        assertEq(bondNft.ownerOf(bondId), buyer, "buyer received the bond");
        assertEq(marketplace.sListingNonce(address(seller), bondId), 1, "nonce bumped once");
    }

    /// @notice The griefed fill stays within a small multiple of an honest fill. This is the
    ///         property the bound buys, and the one a refactor of the payout would silently break.
    function test_burningSeller_gasStaysBounded() public {
        GasBurnSeller honest = new GasBurnSeller();
        uint256 honestBond = _listFrom(address(honest));
        (bool okHonest, uint256 usedHonest) = _fill(address(honest), honestBond, "", 500_000);
        assertTrue(okHonest, "baseline fill must succeed");

        GasBurnSeller burner = new GasBurnSeller();
        uint256 burnerBond = _listFrom(address(burner));
        burner.setBurn(true);
        (bool okBurn, uint256 usedBurn) = _fill(address(burner), burnerBond, "", 500_000);
        assertTrue(okBurn, "griefed fill must succeed");

        // Measured with these mocks: 63,998 honest against 214,048 griefed.
        assertLt(usedBurn, 400_000, "griefed fill must stay bounded");
        assertLt(usedBurn, usedHonest * 5, "griefed fill must stay within a small multiple of honest");
    }

    /// @notice A contract wallet with a normal receive is still paid in ETH: the bound sits well
    ///         above the cost of a real contract-wallet receive.
    function test_normalContractWalletSeller_paidInEth() public {
        CostlyReceiveSeller seller = new CostlyReceiveSeller(14_000);
        uint256 bondId = _listFrom(address(seller));

        (bool ok,) = _fill(address(seller), bondId, "", 500_000);

        assertTrue(ok, "fill must succeed");
        assertEq(address(seller).balance, PRICE, "seller paid in ETH, not routed to the fallback");
        assertEq(weth.balanceOf(address(seller)), 0, "no WETH paid");
        assertEq(address(marketplace).balance, FEE, "marketplace retained exactly the fee");
    }

    /// @notice A seller whose receive costs more than the bound degrades to WETH rather than
    ///         failing the trade.
    function test_expensiveContractWalletSeller_degradesToWeth() public {
        CostlyReceiveSeller seller = new CostlyReceiveSeller(200_000);
        uint256 bondId = _listFrom(address(seller));

        (bool ok,) = _fill(address(seller), bondId, "", 800_000);

        assertTrue(ok, "fill must succeed");
        assertEq(weth.balanceOf(address(seller)), PRICE, "seller paid in WETH");
        assertEq(address(seller).balance, 0, "seller received no ETH");
        assertEq(bondNft.ownerOf(bondId), buyer, "buyer received the bond");
    }

    /// @notice A never-funded EOA seller is paid in ETH. The account-creation cost is charged to
    ///         the marketplace frame, not taken out of the forwarded gas, so the bound is unaffected.
    function test_freshEoaSeller_paidInEth() public {
        address seller = vm.addr(SELLER_PK);
        assertEq(seller.balance, 0, "seller starts unfunded");

        uint256 bondId = bondNft.mintTo(seller, address(coffer));
        vm.prank(seller);
        bondNft.setApprovalForAll(address(marketplace), true);
        bytes memory sig = _signListing(SELLER_PK, seller, bondId);

        (bool ok,) = _fill(seller, bondId, sig, 500_000);

        assertTrue(ok, "fill must succeed");
        assertEq(seller.balance, PRICE, "seller paid in ETH");
        assertEq(weth.balanceOf(seller), 0, "no WETH paid");
    }

    /// @notice The worst-case composition in one fill: the seller burns the whole payout bound, the
    ///         WETH fallback runs, and the buyer's overpayment is refunded — all at an ordinary gas
    ///         limit. This is the case the bound and the documented fill headroom exist for.
    function test_burningSeller_withRefund_settlesAndRefundsExcess() public {
        GasBurnSeller seller = new GasBurnSeller();
        uint256 bondId = _listFrom(address(seller));
        seller.setBurn(true);

        uint256 excess = 0.25 ether;
        uint256 buyerBefore = buyer.balance;

        (bool ok, uint256 used) = _fillPaying(address(seller), bondId, "", 500_000, TOTAL + excess);

        assertTrue(ok, "fill must succeed at an ordinary gas limit");
        assertEq(weth.balanceOf(address(seller)), PRICE, "seller paid the full price in WETH");
        assertEq(address(seller).balance, 0, "seller received no ETH");
        assertEq(buyer.balance, buyerBefore - TOTAL, "excess fully refunded to the buyer");
        assertEq(address(marketplace).balance, FEE, "marketplace retained exactly the fee");
        assertEq(bondNft.ownerOf(bondId), buyer, "buyer received the bond");
        assertEq(marketplace.sListingNonce(address(seller), bondId), 1, "nonce bumped once");
        assertLt(used, 400_000, "burner plus fallback plus refund must fit an ordinary fill");
    }

    /// @notice The bound is published on-chain so takers can size a fill's gas limit against it.
    function test_gasLimitConstantIsPublished() public view {
        assertEq(marketplace.SELLER_PAYOUT_GAS_LIMIT(), 100_000, "published seller payout gas limit");
    }

    // ───── The taker's gas limit cannot pick the payout asset─────
    //
    // The payout forwards min(SELLER_PAYOUT_GAS_LIMIT, 63/64 of the remaining gas) plus the 2300 stipend. When
    // that is below a cheap receive's cost, the remainder after the callee runs out is at most 1/64 of about 84k,
    // under the fallback's first cold call, so the fill fails whole instead of degrading to WETH. A receive above
    // the bound fails at every gas limit, so a fill that settles pays WETH at every gas limit.

    /// @notice A seller whose receive fits the bound is paid in ETH by every fill that settles, whatever gas
    ///         limit the taker submits. The fills that fail change nothing.
    function testFuzz_sellerPayout_cheapReceive_neverWeth(uint256 gasLimit, uint32 spend) public {
        // spend plus the trailing cold SSTORE (about 22k) plus the loop's overshoot stays under 100k
        spend = uint32(bound(spend, 0, 60_000));
        gasLimit = bound(gasLimit, 0, 1_000_000);
        CostlyReceiveSeller seller = new CostlyReceiveSeller(spend);
        uint256 bondId = _listFrom(address(seller));
        uint256 buyerBefore = buyer.balance;

        (bool ok,) = _fill(address(seller), bondId, "", gasLimit);

        assertEq(weth.balanceOf(address(seller)), 0, "a cheap receive is never routed to WETH");
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
        // Not vacuous: an ordinary gas limit settles every seller of this class
        if (gasLimit >= 400_000) assertTrue(ok, "an ordinary gas limit must settle a cheap receive");
    }

    /// @notice A seller whose receive exceeds the bound is paid in WETH by every fill that settles.
    function testFuzz_sellerPayout_expensiveReceive_alwaysWeth(uint256 gasLimit, uint32 spend) public {
        // The callee never holds more than 102.3k and the loop alone needs spend, so 110k and up never finishes
        spend = uint32(bound(spend, 110_000, 400_000));
        gasLimit = bound(gasLimit, 0, 1_000_000);
        CostlyReceiveSeller seller = new CostlyReceiveSeller(spend);
        uint256 bondId = _listFrom(address(seller));
        uint256 buyerBefore = buyer.balance;

        (bool ok,) = _fill(address(seller), bondId, "", gasLimit);

        assertEq(address(seller).balance, 0, "an expensive receive is never paid in ETH");
        if (ok) {
            assertEq(weth.balanceOf(address(seller)), PRICE, "a settled fill paid the seller in WETH");
            assertEq(weth.balanceOf(address(marketplace)), 0, "no WETH stranded in the marketplace");
            assertEq(address(marketplace).balance, FEE);
            assertEq(buyer.balance, buyerBefore - TOTAL);
            assertEq(bondNft.ownerOf(bondId), buyer);
            assertEq(marketplace.sListingNonce(address(seller), bondId), 1);
        } else {
            assertEq(weth.balanceOf(address(seller)), 0, "a failed fill paid nothing");
            assertEq(address(marketplace).balance, 0);
            assertEq(buyer.balance, buyerBefore);
            assertEq(bondNft.ownerOf(bondId), address(seller));
            assertEq(marketplace.sListingNonce(address(seller), bondId), 0);
        }
        // Measured: burn plus fallback is about 214k at 500k (test_burningSeller_gasStaysBounded)
        if (gasLimit >= 400_000) assertTrue(ok, "an ordinary gas limit must settle through the fallback");
    }
}
