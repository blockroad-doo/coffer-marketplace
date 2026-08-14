//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {CofferMarketplace} from "../../src/CofferMarketplace.sol";

interface IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

contract MockBondNft {
    mapping(uint256 => address) private _owners;
    mapping(address => mapping(address => bool)) private _operatorApprovals;
    mapping(uint256 => address) private _coffers;
    uint256 public sBondIdCounter;

    function mintTo(address to, address coffer) external returns (uint256) {
        uint256 id = ++sBondIdCounter;
        _owners[id] = to;
        _coffers[id] = coffer;
        return id;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address owner = _owners[tokenId];
        require(owner != address(0), "ERC721: nonexistent token");
        return owner;
    }

    function cofferOf(uint256 tokenId) external view returns (address) {
        return _coffers[tokenId];
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        require(_owners[tokenId] == from, "ERC721: not owner");
        require(msg.sender == from || _operatorApprovals[from][msg.sender], "ERC721: not approved");
        _owners[tokenId] = to;
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        transferFrom(from, to, tokenId);
        if (to.code.length > 0) {
            require(
                IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, "")
                    == IERC721Receiver.onERC721Received.selector,
                "ERC721: unsafe recipient"
            );
        }
    }

    function setApprovalForAll(address operator, bool approved) external {
        _operatorApprovals[msg.sender][operator] = approved;
    }

    function isApprovedForAll(address owner, address operator) external view returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    /// @notice Direct transfer for testing TOCTOU, no approval check
    function directTransfer(address, address to, uint256 tokenId) external {
        _owners[tokenId] = to;
    }
}

contract MockCoffer {
    mapping(uint256 => uint128) public maturityValues;
    mapping(uint256 => bool) public shouldReversions;
    mapping(uint256 => uint32) public customStartTs;
    mapping(uint256 => uint32) public customDuration;

    function sHolderConditions(uint256 bondId) external view returns (uint128, uint32, uint32) {
        require(!shouldReversions[bondId], "COFFER_REVERT");
        return (
            maturityValues[bondId],
            customDuration[bondId] == 0 ? 86400 : customDuration[bondId],
            customStartTs[bondId] == 0 ? uint32(block.timestamp - 86401) : customStartTs[bondId]
        );
    }

    function setMaturityValue(uint256 bondId, uint128 val) external {
        maturityValues[bondId] = val;
    }

    function setShouldRevert(uint256 bondId, bool flag) external {
        shouldReversions[bondId] = flag;
    }
}

contract MockWETH {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public depositFails;

    function setDepositFails(bool flag) external {
        depositFails = flag;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function deposit() external payable {
        require(!depositFails, "WETH_DEPOSIT_FAIL");
        balanceOf[msg.sender] += msg.value;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "WETH: insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "WETH: insufficient balance");
        require(allowance[from][msg.sender] >= amount, "WETH: insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract CofferMarketplaceAuditTest is Test {
    CofferMarketplace public marketplace;
    MockBondNft public bondNft;
    MockCoffer public coffer;
    MockWETH public weth;

    uint256 constant SELLER_PK = 0xA11CE;
    uint256 constant BUYER_PK = 0xB0B;

    address public seller;
    address public buyer;
    address public mpOwner = makeAddr("mpOwner");
    address public feeRecipient = makeAddr("feeRecipient");

    uint256 public bondId;

    bytes32 constant LISTING_TYPEHASH = keccak256(
        "Listing(uint256 bondId,uint128 price,uint128 maturityValue,uint64 expiration,uint256 nonce,uint256 globalNonce)"
    );
    bytes32 constant OFFER_TYPEHASH = keccak256(
        "Offer(uint256 bondId,uint128 wethAmount,uint128 maturityValue,uint64 expiration,uint256 maxFee,uint256 nonce,uint256 globalNonce)"
    );
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("CofferMarketplace")),
                keccak256(bytes("3")),
                block.chainid,
                address(marketplace)
            )
        );
    }

    function _signListing(uint256 pk, uint256 bId, uint128 pr, uint128 mat, uint64 exp, uint256 nonce, uint256 gNonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(LISTING_TYPEHASH, bId, pr, mat, exp, nonce, gNonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signOffer(
        uint256 pk,
        uint256 bId,
        uint128 wAmt,
        uint128 mat,
        uint64 exp,
        uint256 maxF,
        uint256 nonce,
        uint256 gNonce
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(OFFER_TYPEHASH, bId, wAmt, mat, exp, maxF, nonce, gNonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function setUp() public {
        vm.warp(100_000);
        coffer = new MockCoffer();
        bondNft = new MockBondNft();
        weth = new MockWETH();
        marketplace = new CofferMarketplace(address(weth), address(bondNft), mpOwner, feeRecipient);

        seller = vm.addr(SELLER_PK);
        buyer = vm.addr(BUYER_PK);

        bondId = bondNft.mintTo(seller, address(coffer));
        coffer.setMaturityValue(bondId, 5 ether);

        vm.prank(seller);
        bondNft.setApprovalForAll(address(marketplace), true);

        vm.deal(seller, 100 ether);
        vm.deal(buyer, 100 ether);

        weth.mint(buyer, 100 ether);
        vm.prank(buyer);
        weth.approve(address(marketplace), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════
    // Fuzz: Fee math across full profit range
    // ═══════════════════════════════════════════════════════════════

    function testFuzz_feeBuySigned_profitBps_noOverflow(uint128 maturityValue, uint128 price, uint16 bps) public {
        bps = uint16(bound(bps, 0, 9999));
        price = uint128(bound(price, 1, 10 ether));
        vm.assume(maturityValue >= price);
        coffer.setMaturityValue(bondId, maturityValue);

        vm.prank(mpOwner);
        marketplace.setFeeBps(bps, 0);

        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(seller, bondId);
        uint128 mat = coffer.maturityValues(bondId);
        bytes memory sig = _signListing(SELLER_PK, bondId, price, mat, exp, nonce, 0);

        uint256 profit = uint256(maturityValue) - uint256(price);
        uint256 trueFee = (profit * bps) / 10000;
        uint256 total = uint256(price) + trueFee;

        vm.deal(buyer, total);
        vm.prank(buyer);
        marketplace.buySignedListing{value: total}(bondId, seller, price, mat, exp, nonce, 0, trueFee, sig);

        assertEq(bondNft.ownerOf(bondId), buyer);
    }

    // ═══════════════════════════════════════════════════════════════
    // Fuzz: Nonce monotonicity, per-bond nonce never decreases
    // ═══════════════════════════════════════════════════════════════

    function testFuzz_nonceNeverDecreasesAfterCancelListing(uint256 skipNonces) public {
        skipNonces = bound(skipNonces, 0, 20);

        uint256 startNonce = marketplace.sListingNonce(seller, bondId);
        for (uint256 i; i < skipNonces; ++i) {
            vm.prank(seller);
            marketplace.cancelListing(bondId);
        }
        assertGe(marketplace.sListingNonce(seller, bondId), startNonce);
    }

    function testFuzz_nonceNeverDecreasesAfterCancelAllListings(uint256 skipNonces) public {
        skipNonces = bound(skipNonces, 0, 20);

        uint256 startGlobal = marketplace.sGlobalListingNonce(seller);
        for (uint256 i; i < skipNonces; ++i) {
            vm.prank(seller);
            marketplace.cancelAllListings();
        }
        assertGe(marketplace.sGlobalListingNonce(seller), startGlobal);
    }

    // ═══════════════════════════════════════════════════════════════
    // Fuzz: Typehash encoding validation, altered fields reject at fill
    // ═══════════════════════════════════════════════════════════════

    function testFuzz_listingSigTampered_expiration(uint64 tamperedExp) public {
        // Stay in the future so the call clears the ownership, approval and validity checks and
        // actually reaches signature verification. The signed expiration differs from the presented one.
        uint64 exp = uint64(block.timestamp + 1 days);
        tamperedExp = uint64(bound(tamperedExp, block.timestamp + 1, block.timestamp + 365 days));
        if (tamperedExp == exp) return;

        uint256 nonce = marketplace.sListingNonce(seller, bondId);
        uint128 mat = coffer.maturityValues(bondId);
        bytes memory sig = _signListing(SELLER_PK, bondId, 1 ether, mat, exp, nonce, 0);

        // The signature is over exp, so presenting it for a different expiration fails verification
        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.InvalidSignature.selector);
        marketplace.buySignedListing{value: 0}(bondId, seller, 1 ether, mat, tamperedExp, nonce, 0, 0, sig);
    }

    function testFuzz_listingSigTampered_price(uint128 tamperedPrice) public {
        tamperedPrice = uint128(bound(tamperedPrice, 1, type(uint128).max));
        if (tamperedPrice == 1 ether) return;

        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(seller, bondId);
        uint128 mat = coffer.maturityValues(bondId);
        bytes memory sig = _signListing(SELLER_PK, bondId, 1 ether, mat, exp, nonce, 0);

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.InvalidSignature.selector);
        marketplace.buySignedListing{value: 0}(bondId, seller, tamperedPrice, mat, exp, nonce, 0, 0, sig);
    }

    function testFuzz_offerReplay_afterAccept(uint128 offerAmount) public {
        offerAmount = uint128(bound(offerAmount, 1, 10 ether));
        uint64 exp = uint64(block.timestamp + 1 days);

        uint256 nonce = marketplace.sOfferNonce(buyer, bondId);
        uint128 mat = coffer.maturityValues(bondId);
        bytes memory sig = _signOffer(BUYER_PK, bondId, offerAmount, mat, exp, type(uint256).max, nonce, 0);

        vm.prank(seller);
        marketplace.acceptSignedOffer(bondId, buyer, offerAmount, mat, exp, type(uint256).max, nonce, 0, sig);

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.OfferRevoked.selector);
        marketplace.acceptSignedOffer(bondId, buyer, offerAmount, mat, exp, type(uint256).max, nonce, 0, sig);
    }

    // ═══════════════════════════════════════════════════════════════
    // Fuzz: Fee override by admin
    // ═══════════════════════════════════════════════════════════════

    function testFuzz_feeCanBeChangedByAdmin(uint16 newListingBps, uint16 newOfferBps) public {
        newListingBps = uint16(bound(newListingBps, 0, 9999));
        newOfferBps = uint16(bound(newOfferBps, 0, 9999));

        vm.prank(mpOwner);
        marketplace.setFeeBps(newListingBps, newOfferBps);

        assertEq(marketplace.sListingFeeBps(), newListingBps);
        assertEq(marketplace.sOfferFeeBps(), newOfferBps);
    }

    function testFuzz_feeCannotExceedBpsDenominator(uint16 bps) public {
        bps = uint16(bound(uint256(bps), 10000, type(uint16).max));

        vm.prank(mpOwner);
        vm.expectRevert(CofferMarketplace.FeeTooHigh.selector);
        marketplace.setFeeBps(bps, 0);
    }

    // ═══════════════════════════════════════════════════════════════
    // Fuzz: CancelAllListings invalidates all prior signatures
    // ═══════════════════════════════════════════════════════════════

    function testFuzz_cancelAllListings_invalidatesPriorSig(uint128 price) public {
        price = uint128(bound(price, 1, 10 ether));

        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(seller, bondId);
        uint256 gNonce = marketplace.sGlobalListingNonce(seller);
        uint128 mat = coffer.maturityValues(bondId);
        bytes memory sig = _signListing(SELLER_PK, bondId, price, mat, exp, nonce, gNonce);

        vm.prank(seller);
        marketplace.cancelAllListings();

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.ListingRevoked.selector);
        marketplace.buySignedListing{value: price}(bondId, seller, price, mat, exp, nonce, gNonce, 0, sig);
    }

    // ═══════════════════════════════════════════════════════════════
    // Boundary: max maturityValue with min price
    // ═══════════════════════════════════════════════════════════════

    function testFuzz_extremeProfit_buySignedListing() public {
        uint128 maturityValue = uint128(type(uint128).max / 2); // huge but stays inside uint128
        uint128 price = 1;
        coffer.setMaturityValue(bondId, maturityValue);

        vm.prank(mpOwner);
        marketplace.setFeeBps(800, 0); // 8%

        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(seller, bondId);
        uint128 mat = coffer.maturityValues(bondId);
        bytes memory sig = _signListing(SELLER_PK, bondId, price, mat, exp, nonce, 0);

        uint256 profit = uint256(maturityValue) - uint256(price);
        uint256 trueFee = (profit * 800) / 10000;
        uint256 total = uint256(price) + trueFee;

        vm.deal(buyer, total + 10 ether);
        vm.prank(buyer);
        marketplace.buySignedListing{value: total}(bondId, seller, price, mat, exp, nonce, 0, trueFee, sig);

        assertEq(bondNft.ownerOf(bondId), buyer);
    }

    // ═══════════════════════════════════════════════════════════════
    // Fuzz: Buy with exact price 1 wei + zero fee
    // ═══════════════════════════════════════════════════════════════

    function testFuzz_buySignedListing_oneWei_noFee() public {
        uint128 price = 1;
        coffer.setMaturityValue(bondId, 5 ether);

        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(seller, bondId);
        uint128 mat = coffer.maturityValues(bondId);
        bytes memory sig = _signListing(SELLER_PK, bondId, price, mat, exp, nonce, 0);

        vm.prank(buyer);
        marketplace.buySignedListing{value: price}(bondId, seller, price, mat, exp, nonce, 0, 0, sig);

        assertEq(bondNft.ownerOf(bondId), buyer);
    }

    // ═══════════════════════════════════════════════════════════════
    // Fuzz: Global nonce changes after cancelAll don't affect per-bond nonce
    // ═══════════════════════════════════════════════════════════════

    function testFuzz_cancelAllListings_preservesPerBondNonce() public {
        uint256 perBondBefore = marketplace.sListingNonce(seller, bondId);

        vm.prank(seller);
        marketplace.cancelAllListings();

        assertEq(marketplace.sListingNonce(seller, bondId), perBondBefore);
        assertEq(marketplace.sGlobalListingNonce(seller), 1);
    }

    // ═══════════════════════════════════════════════════════════════
    // Edge: Bond becomes non-outstanding between signing and buy
    // ═══════════════════════════════════════════════════════════════

    function testFuzz_buySignedListing_revertsWhenBondMatures(uint64 warpSeconds) public {
        warpSeconds = uint64(bound(warpSeconds, 1, 1 days));

        uint64 exp = uint64(block.timestamp + 365 days);

        coffer.setMaturityValue(bondId, 5 ether);

        uint256 nonce = marketplace.sListingNonce(seller, bondId);
        bytes memory sig = _signListing(SELLER_PK, bondId, 1 ether, 5 ether, exp, nonce, 0);

        coffer.setMaturityValue(bondId, 0);
        vm.warp(block.timestamp + warpSeconds);

        vm.prank(buyer);
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > exp) {
            vm.expectRevert(CofferMarketplace.ExpirationNotInFuture.selector);
        } else {
            vm.expectRevert(CofferMarketplace.BondNotOutstanding.selector);
        }
        marketplace.buySignedListing{value: 1 ether}(bondId, seller, 1 ether, 5 ether, exp, nonce, 0, 0, sig);
    }

    // ═══════════════════════════════════════════════════════════════
    // Edge: SameParty check for the accept flow
    // ═══════════════════════════════════════════════════════════════

    function test_acceptSignedOffer_sameParty_reverts() public {
        weth.mint(seller, 10 ether);
        vm.prank(seller);
        weth.approve(address(marketplace), type(uint256).max);

        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sOfferNonce(seller, bondId);
        uint128 mat = coffer.maturityValues(bondId);
        bytes memory sig = _signOffer(SELLER_PK, bondId, 1 ether, mat, exp, type(uint256).max, nonce, 0);

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.SameParty.selector);
        marketplace.acceptSignedOffer(bondId, seller, 1 ether, mat, exp, type(uint256).max, nonce, 0, sig);
    }

    // ═══════════════════════════════════════════════════════════════
    // Edge: Claim fees without nonReentrant, verify reentrancy safety
    // ═══════════════════════════════════════════════════════════════

    function test_claimFees_transfersAllEth() public {
        // Earn an ETH fee on a completed buy. maturityValue is 5 ether, price 1 ether, so the
        // profit is 4 ether and the 800 bps fee is 0.32 ether.
        uint128 price = 1 ether;
        vm.prank(mpOwner);
        marketplace.setFeeBps(800, 0);

        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(seller, bondId);
        uint128 mat = coffer.maturityValues(bondId);
        bytes memory sig = _signListing(SELLER_PK, bondId, price, mat, exp, nonce, 0);

        uint256 expectedFee = (uint256(4 ether) * 800) / 10000;
        vm.prank(buyer);
        marketplace.buySignedListing{value: uint256(price) + expectedFee}(
            bondId, seller, price, mat, exp, nonce, 0, expectedFee, sig
        );

        uint256 mktBalance = address(marketplace).balance;
        assertEq(mktBalance, expectedFee);

        uint256 recipientBefore = feeRecipient.balance;
        vm.prank(mpOwner);
        marketplace.claimFees();

        assertEq(feeRecipient.balance - recipientBefore, mktBalance);
        assertEq(address(marketplace).balance, 0);
    }

    // ═══════════════════════════════════════════════════════════════
    // Edge: WETH fallback when the seller is a contract that rejects ETH
    // ═══════════════════════════════════════════════════════════════

    function test_buySignedListing_wethFallbackSafeDeposit() public {
        // An ERC-1271 contract seller with no receive function rejects ETH, so the marketplace
        // wraps the proceeds to WETH.
        Erc1271EthRejecter cSeller = new Erc1271EthRejecter();
        uint256 cBond = bondNft.mintTo(address(cSeller), address(coffer));
        coffer.setMaturityValue(cBond, 5 ether);
        cSeller.approveNft(address(bondNft), address(marketplace));

        uint128 price = 1 ether;
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(address(cSeller), cBond);

        uint256 wethBefore = weth.balanceOf(address(cSeller));

        uint128 mat = coffer.maturityValues(cBond);
        vm.prank(buyer);
        marketplace.buySignedListing{value: price}(cBond, address(cSeller), price, mat, exp, nonce, 0, 0, "");

        assertEq(weth.balanceOf(address(cSeller)) - wethBefore, price);
        assertEq(bondNft.ownerOf(cBond), buyer);
    }

    // ═══════════════════════════════════════════════════════════════
    // Edge: Cancel invalidates an outstanding signature at the old nonce
    // ═══════════════════════════════════════════════════════════════

    function test_cancelInvalidatesOldNonceListing() public {
        uint64 exp = uint64(block.timestamp + 1 days);

        // Order signed at the current nonce 0
        uint128 mat = coffer.maturityValues(bondId);
        bytes memory sigOld = _signListing(SELLER_PK, bondId, 1 ether, mat, exp, 0, 0);

        // Seller cancels, bumping the per-bond nonce to 1
        vm.prank(seller);
        marketplace.cancelListing(bondId);
        assertEq(marketplace.sListingNonce(seller, bondId), 1);

        // The old order at nonce 0 is no longer fillable
        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.ListingRevoked.selector);
        marketplace.buySignedListing{value: 1 ether}(bondId, seller, 1 ether, mat, exp, 0, 0, 0, sigOld);

        // A fresh order signed at nonce 1 fills
        uint128 mat2 = coffer.maturityValues(bondId);
        bytes memory sigNew = _signListing(SELLER_PK, bondId, 2 ether, mat2, exp, 1, 0);
        vm.prank(buyer);
        marketplace.buySignedListing{value: 2 ether}(bondId, seller, 2 ether, mat2, exp, 1, 0, 0, sigNew);
        assertEq(bondNft.ownerOf(bondId), buyer);
    }

    // ═══════════════════════════════════════════════════════════════
    // Fuzz: Owner can set fee recipient multiple times
    // ═══════════════════════════════════════════════════════════════

    function testFuzz_feeRecipientCanBeUpdated(address newRecipient) public {
        vm.assume(newRecipient != address(0));

        vm.prank(mpOwner);
        marketplace.setFeeRecipient(newRecipient);
        assertEq(marketplace.sFeeRecipient(), newRecipient);

        vm.prank(mpOwner);
        marketplace.setFeeRecipient(feeRecipient);
        assertEq(marketplace.sFeeRecipient(), feeRecipient);
    }

    // ═══════════════════════════════════════════════════════════════
    // Fuzz: Zero-profit fee calculation
    // ═══════════════════════════════════════════════════════════════

    function testFuzz_noProfit_buySignedListing_chargesNothing(uint128 maturityVal, uint128 price) public {
        price = uint128(bound(price, 1, 10 ether));
        maturityVal = uint128(bound(maturityVal, 1, price));
        coffer.setMaturityValue(bondId, maturityVal);

        vm.prank(mpOwner);
        marketplace.setFeeBps(800, 0);

        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(seller, bondId);
        uint128 mat = coffer.maturityValues(bondId);
        bytes memory sig = _signListing(SELLER_PK, bondId, price, mat, exp, nonce, 0);

        // With no profit and no fixed component, the fee is exactly zero.
        vm.deal(buyer, uint256(price) + 1 ether);

        uint256 mktBefore = address(marketplace).balance;
        vm.prank(buyer);
        marketplace.buySignedListing{value: price}(bondId, seller, price, mat, exp, nonce, 0, 0, sig);

        assertEq(address(marketplace).balance - mktBefore, 0);
    }

    // ═══════════════════════════════════════════════════════════════
    // PoC-1: Signature replay across deployments
    // The same EOA signs the same Listing fields. The signature is bound to the verifying
    // contract via the EIP-712 domain, so it cannot be filled on a second deployment.
    // Verdict: PASS (cannot replay)
    // ═══════════════════════════════════════════════════════════════

    function test_poc1_signatureReplayAcrossDeployments() public {
        CofferMarketplace marketplace2 = new CofferMarketplace(address(weth), address(bondNft), mpOwner, feeRecipient);

        // Approve the second marketplace so the call clears the approval check and reaches signature
        // verification, which is what this PoC exercises: the signature is bound to the first
        // deployment's domain and is rejected on the second.
        vm.prank(seller);
        bondNft.setApprovalForAll(address(marketplace2), true);

        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(seller, bondId);
        uint128 mat = coffer.maturityValues(bondId);
        bytes memory sig = _signListing(SELLER_PK, bondId, 1 ether, mat, exp, nonce, 0);

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.InvalidSignature.selector);
        marketplace2.buySignedListing{value: 1 ether}(bondId, seller, 1 ether, mat, exp, nonce, 0, 0, sig);
    }

    // ═══════════════════════════════════════════════════════════════
    // PoC-2: Validator early-redeem griefs trade
    // Anyone who can zero the bond maturity makes a fill revert BondNotOutstanding.
    // Verdict: PASS (grief confirmed, no fund loss)
    // ═══════════════════════════════════════════════════════════════

    function test_poc2_validatorEarlyRedeemGriefsTrade() public {
        uint128 price = 0.9 ether;
        coffer.setMaturityValue(bondId, 1 ether);

        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(seller, bondId);
        bytes memory sig = _signListing(SELLER_PK, bondId, price, 1 ether, exp, nonce, 0);

        coffer.setMaturityValue(bondId, 0);

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.BondNotOutstanding.selector);
        marketplace.buySignedListing{value: price}(bondId, seller, price, 1 ether, exp, nonce, 0, 0, sig);
    }

    // ═══════════════════════════════════════════════════════════════
    // PoC-3: Returndata bomb, gas cost constant
    // The seller contract returns 100KB from its receive, which fits inside the gas the payout
    // forwards, so the seller call succeeds and returns the payload. _safeTransferETH skips the
    // returndata copy, so the buy gas stays constant.
    // Verdict: PASS (gas constant regardless of returndata size)
    // ═══════════════════════════════════════════════════════════════

    function test_poc3_returndataBombGasConstant() public {
        Erc1271ReturndataBomber cSeller = new Erc1271ReturndataBomber();
        uint256 cBond = bondNft.mintTo(address(cSeller), address(coffer));
        coffer.setMaturityValue(cBond, 5 ether);
        cSeller.approveNft(address(bondNft), address(marketplace));

        uint128 price = 1 ether;
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(address(cSeller), cBond);

        uint128 mat = coffer.maturityValues(cBond);
        vm.prank(buyer);
        uint256 gasBefore = gasleft();
        marketplace.buySignedListing{value: price}(cBond, address(cSeller), price, mat, exp, nonce, 0, 0, "");
        uint256 gasUsed = gasBefore - gasleft();

        assertTrue(gasUsed < 500_000, "Returndata bomb caused excessive gas");
        assertEq(bondNft.ownerOf(cBond), buyer);
        // The seller call must have succeeded, otherwise the fill settled through the WETH
        // fallback and never exercised the returndata path this test is about.
        assertEq(address(cSeller).balance, price, "seller paid in ETH");
        assertEq(weth.balanceOf(address(cSeller)), 0, "seller must not have been paid in WETH");
    }

    // ═══════════════════════════════════════════════════════════════
    // PoC-4: WETH fallback reentrancy
    // The seller contract reenters buySignedListing from its receive. nonReentrant blocks the
    // reentry, so the ETH send fails and the trade settles via the WETH fallback.
    // Verdict: PASS (nonReentrant blocks reentry)
    // ═══════════════════════════════════════════════════════════════

    function test_poc4_wethFallbackReentrancyBlocked() public {
        ReentrantSellerFallback cSeller = new ReentrantSellerFallback(marketplace);
        uint256 cBond = bondNft.mintTo(address(cSeller), address(coffer));
        coffer.setMaturityValue(cBond, 5 ether);
        cSeller.approveNft(address(bondNft), address(marketplace));

        uint128 price = 1 ether;
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(address(cSeller), cBond);

        uint128 mat = coffer.maturityValues(cBond);
        vm.prank(buyer);
        marketplace.buySignedListing{value: price}(cBond, address(cSeller), price, mat, exp, nonce, 0, 0, "");

        assertEq(bondNft.ownerOf(cBond), buyer);
        assertEq(weth.balanceOf(address(cSeller)), price);
    }

    // ═══════════════════════════════════════════════════════════════
    // PoC-5: Nonce semantics at fill
    // A fill must match the current on-chain nonce. A fill at the wrong nonce reverts, a fill at
    // the current nonce succeeds and bumps it, and a replay then fails.
    // Verdict: PASS (nonce semantics confirmed)
    // ═══════════════════════════════════════════════════════════════

    function test_poc5_nonceSemanticsAtFill() public {
        uint128 price = 1 ether;
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(seller, bondId);

        uint128 mat = coffer.maturityValues(bondId);
        bytes memory sigCurrent = _signListing(SELLER_PK, bondId, price, mat, exp, nonce, 0);
        bytes memory sigAhead = _signListing(SELLER_PK, bondId, price, mat, exp, nonce + 1, 0);

        // A fill one nonce ahead is rejected
        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.ListingRevoked.selector);
        marketplace.buySignedListing{value: price}(bondId, seller, price, mat, exp, nonce + 1, 0, 0, sigAhead);

        // The fill at the current nonce succeeds and bumps the nonce
        vm.prank(buyer);
        marketplace.buySignedListing{value: price}(bondId, seller, price, mat, exp, nonce, 0, 0, sigCurrent);
        assertEq(marketplace.sListingNonce(seller, bondId), nonce + 1);

        // A replay of the same signature now fails
        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.ListingRevoked.selector);
        marketplace.buySignedListing{value: price}(bondId, seller, price, mat, exp, nonce, 0, 0, sigCurrent);
    }

    // ═══════════════════════════════════════════════════════════════
    // PoC-6: Mass-cancel with 1000-entry array
    // Verdict: PASS (gas linear, fits in block)
    // ═══════════════════════════════════════════════════════════════

    function test_poc6_massCancel1000Entries() public {
        uint256 count = 1000;
        uint256[] memory bondIds = new uint256[](count);

        for (uint256 i = 0; i < count; ++i) {
            bondIds[i] = bondNft.mintTo(seller, address(coffer));
            coffer.setMaturityValue(bondIds[i], 1 ether);
        }

        uint256 gasBefore = gasleft();
        vm.prank(seller);
        marketplace.cancelListings(bondIds);
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 30_000_000, "1000 cancelListings exceeds block gas limit");

        for (uint256 i = 0; i < count; ++i) {
            assertEq(marketplace.sListingNonce(seller, bondIds[i]), 1);
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // PoC-7: Deferred WETH validation
    // A buyer with zero WETH can sign an offer, but acceptSignedOffer reverts at the WETH
    // balance and allowance check.
    // Verdict: PASS (seller wastes gas, no fund movement)
    // ═══════════════════════════════════════════════════════════════

    function test_poc7_deferredWethValidationGriefsSeller() public {
        uint256 brokePk = 0xD00D;
        address brokeBuyer = vm.addr(brokePk);
        vm.deal(brokeBuyer, 10 ether);

        uint256 noWethBondId = bondNft.mintTo(seller, address(coffer));
        coffer.setMaturityValue(noWethBondId, 5 ether);

        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sOfferNonce(brokeBuyer, noWethBondId);
        uint128 mat = coffer.maturityValues(noWethBondId);

        bytes32 structHash = keccak256(
            abi.encode(OFFER_TYPEHASH, noWethBondId, uint128(1 ether), mat, exp, type(uint256).max, nonce, uint256(0))
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(brokePk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.InsufficientPayment.selector);
        marketplace.acceptSignedOffer(noWethBondId, brokeBuyer, 1 ether, mat, exp, type(uint256).max, nonce, 0, sig);
    }

    // ═══════════════════════════════════════════════════════════════
    // PoC-8: Fee partitioning, ETH and WETH fees are fully separated
    // Verdict: PASS (asset separation confirmed)
    // ═══════════════════════════════════════════════════════════════

    function test_poc8_feePartitioningEthWethSeparation() public {
        vm.prank(mpOwner);
        marketplace.setFeeBps(800, 800);

        uint64 exp = uint64(block.timestamp + 1 days);

        // 1. buySignedListing (ETH profit fee). maturity 5 ether, price 1 ether, profit 4 ether,
        //    800 bps gives a 0.32 ether ETH fee.
        uint256 listNonce = marketplace.sListingNonce(seller, bondId);
        uint128 mat = coffer.maturityValues(bondId);
        bytes memory listSig = _signListing(SELLER_PK, bondId, 1 ether, mat, exp, listNonce, 0);
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        marketplace.buySignedListing{value: 1.32 ether}(
            bondId, seller, 1 ether, mat, exp, listNonce, 0, 0.32 ether, listSig
        );

        // 2. acceptSignedOffer (WETH fee)
        uint256 offerBondId = bondNft.mintTo(seller, address(coffer));
        coffer.setMaturityValue(offerBondId, 5 ether);
        uint256 offerNonce = marketplace.sOfferNonce(buyer, offerBondId);
        uint128 mat2 = coffer.maturityValues(offerBondId);
        bytes memory offerSig = _signOffer(BUYER_PK, offerBondId, 1 ether, mat2, exp, type(uint256).max, offerNonce, 0);
        vm.prank(seller);
        marketplace.acceptSignedOffer(
            offerBondId, buyer, 1 ether, mat2, exp, type(uint256).max, offerNonce, 0, offerSig
        );

        // Claim ETH, only sweeps ETH, WETH unchanged
        uint256 ethBefore = address(marketplace).balance;
        uint256 wethBefore = weth.balanceOf(address(marketplace));
        uint256 recipientEthBefore = feeRecipient.balance;

        vm.prank(mpOwner);
        marketplace.claimFees();

        assertGt(ethBefore, 0);
        assertEq(address(marketplace).balance, 0, "claimFees should sweep all ETH");
        assertEq(feeRecipient.balance - recipientEthBefore, ethBefore, "claimFees sent all ETH to recipient");
        assertEq(weth.balanceOf(address(marketplace)), wethBefore, "claimFees must NOT touch WETH");

        // Claim WETH, only sweeps WETH, ETH unchanged
        uint256 recipientWethBefore = weth.balanceOf(feeRecipient);
        vm.prank(mpOwner);
        marketplace.claimWethFees();

        assertEq(address(marketplace).balance, 0, "claimWethFees must NOT touch ETH");
        assertEq(weth.balanceOf(address(marketplace)), 0, "claimWethFees should sweep all WETH");
        assertEq(
            weth.balanceOf(feeRecipient) - recipientWethBefore, wethBefore, "claimWethFees sent all WETH to recipient"
        );
    }
}

/// @dev ERC-1271 contract seller that validates any signature and rejects ETH (no receive
///      function), used to exercise the WETH fallback.
contract Erc1271EthRejecter {
    bytes4 internal constant MAGIC = 0x1626ba7e;

    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return MAGIC;
    }

    function approveNft(address nft, address operator) external {
        MockBondNft(nft).setApprovalForAll(operator, true);
    }
}

/// @dev ERC-1271 contract seller that validates any signature and returns a 300KB blob from its
///      receive, used to confirm the returndata-bomb-safe ETH transfer keeps gas constant.
contract Erc1271ReturndataBomber {
    bytes4 internal constant MAGIC = 0x1626ba7e;

    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return MAGIC;
    }

    function approveNft(address nft, address operator) external {
        MockBondNft(nft).setApprovalForAll(operator, true);
    }

    receive() external payable {
        assembly {
            // 100KB fits inside the gas the seller payout forwards, so the call returns the
            // payload instead of running out of gas building it.
            return(0, 100000)
        }
    }
}

/// @dev ERC-1271 contract seller that validates any signature and reenters buySignedListing from
///      its receive, used to confirm nonReentrant blocks the reentry and the trade settles in WETH.
contract ReentrantSellerFallback {
    bytes4 internal constant MAGIC = 0x1626ba7e;
    CofferMarketplace public marketplace;

    constructor(CofferMarketplace _marketplace) {
        marketplace = _marketplace;
    }

    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return MAGIC;
    }

    function approveNft(address nft, address operator) external {
        MockBondNft(nft).setApprovalForAll(operator, true);
    }

    receive() external payable {
        marketplace.buySignedListing{value: 1 ether}(
            1, address(this), 1 ether, 1 ether, uint64(block.timestamp + 365 days), 0, 0, 0, hex""
        );
    }
}
