//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICofferBondNft} from "./interfaces/ICofferBondNft.sol";
import {ICoffer} from "./interfaces/ICoffer.sol";
import {IWETH} from "./interfaces/IWETH.sol";

/// @title CofferMarketplace
/// @author Coffer
/// @notice Secondary marketplace for Coffer bond NFTs — listings (ETH) and offers (WETH).
/// @notice Fees are charged on the six primary actions (list, cancelListing, buy, makeOffer,
///         cancelOffer, acceptOffer). See defining_fees.md for the fee philosophy.
contract CofferMarketplace is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ───── Errors ─────

    error ZeroAddress();
    error ZeroPrice();
    error ZeroAmount();
    error NotSeller();
    error NotBuyer();
    error NotOwner();
    error ListingNotFound();
    error ListingExpired();
    error OfferNotFound();
    error OfferExpired();
    error PriceMismatch();
    error AmountMismatch();
    error BondNotOutstanding();
    error SellerNoLongerOwnsNft();
    error MarketplaceNotApproved();
    error ExpirationNotInFuture();
    error CannotBuyOwnListing();
    error InsufficientWethBalance();
    error InsufficientWethAllowance();
    error InsufficientPayment();
    error ArrayLengthMismatch();
    error InsufficientFee();
    error FeeExceedsMax();
    error FeeTooHigh();
    error NothingToClaim();
    error NothingToClaimWeth();

    // ───── Structs ─────

    struct Listing {
        address seller;
        uint128 price;
        uint64 expiration;
    }

    struct Offer {
        address buyer; // 20 bytes ─┐ slot 0
        uint64 expiration; //  8 bytes ─┘ (28B used, 4B padding)
        uint128 wethAmount; // 16 bytes ─┐ slot 1
        uint128 fee; // 16 bytes ─┘ (32B used) — WETH fee locked at makeOffer
    }

    struct FunctionFee {
        uint128 fixedFee;
        uint16 percentageBps;
    }

    // ───── Constants ─────

    /// @notice Basis points denominator (100% = 10000)
    uint16 public constant BPS_DENOMINATOR = 10000;

    // ───── State ─────

    /// @notice Immutable WETH token contract address
    address public immutable I_WETH;
    /// @notice Immutable CofferBondNft contract address
    address public immutable I_COFFER_BOND_NFT;

    /// @notice The address that receives collected fees on claim
    address public sFeeRecipient;
    /// @notice Per-selector fee configuration
    mapping(bytes4 selector => FunctionFee) public sFunctionFees;

    /// @notice Active listings indexed by bond ID
    mapping(uint256 bondId => Listing) public sListings;
    /// @notice Active offers indexed by bond ID and buyer
    mapping(uint256 bondId => mapping(address buyer => Offer)) public sOffers;

    // ───── Events ─────

    /// @notice Emitted when a bond NFT is listed for sale
    /// @param bondId The bond token ID
    /// @param seller The seller address
    /// @param price The listing price in wei
    /// @param expiration The listing expiration timestamp
    event Listed(uint256 indexed bondId, address indexed seller, uint128 indexed price, uint64 expiration);
    /// @notice Emitted when a listing is cancelled
    /// @param bondId The bond token ID
    /// @param seller The seller address
    event ListingCancelled(uint256 indexed bondId, address indexed seller);
    /// @notice Emitted when a listed bond NFT is purchased
    /// @param bondId The bond token ID
    /// @param buyer The buyer address
    /// @param seller The seller address
    /// @param price The purchase price in wei
    /// @param fee The ETH fee collected by the marketplace
    event ListingPurchased(
        uint256 indexed bondId, address indexed buyer, address indexed seller, uint128 price, uint256 fee
    );

    /// @notice Emitted when a WETH offer is made on a bond NFT
    /// @param bondId The bond token ID
    /// @param buyer The buyer address
    /// @param wethAmount The WETH offer amount
    /// @param expiration The offer expiration timestamp
    event OfferMade(uint256 indexed bondId, address indexed buyer, uint128 indexed wethAmount, uint64 expiration);
    /// @notice Emitted when an offer is cancelled
    /// @param bondId The bond token ID
    /// @param buyer The buyer address
    event OfferCancelled(uint256 indexed bondId, address indexed buyer);
    /// @notice Emitted when a WETH offer is accepted by the NFT owner
    /// @param bondId The bond token ID
    /// @param buyer The buyer address
    /// @param seller The seller address
    /// @param wethAmount The WETH amount of the accepted offer
    /// @param fee The WETH fee collected by the marketplace (locked at makeOffer time)
    event OfferAccepted(
        uint256 indexed bondId, address indexed buyer, address indexed seller, uint128 wethAmount, uint256 fee
    );

    /// @notice Emitted when the fee recipient is updated
    /// @param recipient The new fee recipient address
    event FeeRecipientSet(address indexed recipient);
    /* solhint-disable gas-indexed-events */
    /// @notice Emitted when a function fee is configured
    /// @param selector The function selector
    /// @param fixedFee The fixed fee amount
    /// @param percentageBps The percentage fee in basis points
    event FunctionFeeSet(bytes4 indexed selector, uint128 fixedFee, uint16 percentageBps);
    /* solhint-enable gas-indexed-events */
    /// @notice Emitted when ETH fees are claimed
    /// @param recipient The address that received the fees
    /// @param amount The amount of ETH claimed
    event FeesClaimed(address indexed recipient, uint256 amount);
    /// @notice Emitted when WETH fees are claimed
    /// @param recipient The address that received the fees
    /// @param amount The amount of WETH claimed
    event WethFeesClaimed(address indexed recipient, uint256 amount);

    // ───── Constructor ─────

    constructor(address _weth, address _cofferBondNft, address _owner, address _feeRecipient) Ownable(_owner) {
        require(_weth != address(0), ZeroAddress());
        require(_cofferBondNft != address(0), ZeroAddress());
        require(_feeRecipient != address(0), ZeroAddress());
        I_WETH = _weth;
        I_COFFER_BOND_NFT = _cofferBondNft;
        sFeeRecipient = _feeRecipient;
        emit FeeRecipientSet(_feeRecipient);
    }

    // ───── Admin ─────

    /// @notice Update the fee recipient address
    /// @param _recipient The new fee recipient address
    function setFeeRecipient(address _recipient) external onlyOwner {
        require(_recipient != address(0), ZeroAddress());
        sFeeRecipient = _recipient;
        emit FeeRecipientSet(_recipient);
    }

    /// @notice Configure the fee for a specific function selector
    /// @param _selector The function selector to configure
    /// @param _fixedFee The fixed fee amount in wei
    /// @param _percentageBps The percentage fee in basis points
    function setFunctionFee(bytes4 _selector, uint128 _fixedFee, uint16 _percentageBps) external onlyOwner {
        require(_percentageBps < BPS_DENOMINATOR, FeeTooHigh());
        sFunctionFees[_selector] = FunctionFee({fixedFee: _fixedFee, percentageBps: _percentageBps});
        emit FunctionFeeSet(_selector, _fixedFee, _percentageBps);
    }

    /// @notice Claim accumulated ETH fees to the fee recipient
    function claimFees() external onlyOwner {
        uint256 amount = address(this).balance;
        require(amount > 0, NothingToClaim());
        address recipient = sFeeRecipient;
        Address.sendValue(payable(recipient), amount);
        emit FeesClaimed(recipient, amount);
    }

    /// @notice Claim accumulated WETH fees to the fee recipient
    function claimWethFees() external onlyOwner {
        uint256 amount = IERC20(I_WETH).balanceOf(address(this));
        require(amount > 0, NothingToClaimWeth());
        address recipient = sFeeRecipient;
        IERC20(I_WETH).safeTransfer(recipient, amount);
        emit WethFeesClaimed(recipient, amount);
    }

    // ───── Listing Functions ─────

    /// @notice List a bond NFT for sale
    /// @param _bondId The bond token ID to list
    /// @param _price The listing price in wei
    /// @param _expiration The listing expiration timestamp
    /// @param _maxFee The maximum ETH fee the caller is willing to pay for this action
    function list(uint256 _bondId, uint128 _price, uint64 _expiration, uint256 _maxFee) external payable {
        uint256 fee = _list(msg.sender, _bondId, _price, _expiration, _maxFee);
        require(msg.value == fee, InsufficientFee());
    }

    /// @notice Cancel an active listing
    /// @param _bondId The bond token ID to cancel
    /// @param _maxFee The maximum ETH fee the caller is willing to pay for this action
    function cancelListing(uint256 _bondId, uint256 _maxFee) external payable {
        uint256 fee = _cancelListing(msg.sender, _bondId, _maxFee);
        require(msg.value == fee, InsufficientFee());
    }

    /// @notice Purchase a listed bond NFT
    /// @param _bondId The bond token ID to purchase
    /// @param _expectedPrice The expected listing price to prevent front-running
    /// @param _maxFee The maximum ETH fee the caller is willing to pay for this action
    function buy(uint256 _bondId, uint128 _expectedPrice, uint256 _maxFee) external payable nonReentrant {
        uint256 fee = _buy(msg.sender, _bondId, _expectedPrice, msg.value, _maxFee);
        uint256 used = uint256(_expectedPrice) + fee;
        // _buy already validated msg.value >= used; any overpay is refunded here
        uint256 excess = msg.value - used;
        if (excess > 0) {
            require(_safeTransferETH(msg.sender, excess), InsufficientPayment());
        }
    }

    // ───── Offer Functions ─────

    /// @notice Make a WETH offer on a bond NFT
    /// @param _bondId The bond token ID to make an offer on
    /// @param _wethAmount The WETH amount to offer
    /// @param _expiration The offer expiration timestamp
    /// @param _maxFee The maximum ETH fee the caller is willing to pay for this action
    function makeOffer(uint256 _bondId, uint128 _wethAmount, uint64 _expiration, uint256 _maxFee)
        external
        payable
    {
        uint256 fee = _makeOffer(msg.sender, _bondId, _wethAmount, _expiration, _maxFee);
        require(msg.value == fee, InsufficientFee());
    }

    /// @notice Cancel an active offer
    /// @param _bondId The bond token ID to cancel the offer for
    /// @param _maxFee The maximum ETH fee the caller is willing to pay for this action
    function cancelOffer(uint256 _bondId, uint256 _maxFee) external payable {
        uint256 fee = _cancelOffer(msg.sender, _bondId, _maxFee);
        require(msg.value == fee, InsufficientFee());
    }

    /// @notice Accept a WETH offer on a bond NFT you own
    /// @dev The WETH fee was locked into the Offer struct at makeOffer time and is pulled from the offerer.
    /// @param _bondId The bond token ID
    /// @param _buyer The address of the offer maker
    /// @param _expectedAmount The expected WETH amount to prevent front-running
    function acceptOffer(uint256 _bondId, address _buyer, uint128 _expectedAmount) external nonReentrant {
        _acceptOffer(msg.sender, _bondId, _buyer, _expectedAmount);
    }

    // ───── Batch Functions ─────

    /// @notice Batch list multiple bond NFTs
    /// @param _bondIds The bond token IDs to list
    /// @param _prices The listing prices in wei
    /// @param _expirations The listing expiration timestamps
    /// @param _maxFees The per-item maximum ETH fees
    function batchList(
        uint256[] calldata _bondIds,
        uint128[] calldata _prices,
        uint64[] calldata _expirations,
        uint256[] calldata _maxFees
    ) external payable nonReentrant {
        uint256 len = _bondIds.length;
        require(
            len == _prices.length && len == _expirations.length && len == _maxFees.length, ArrayLengthMismatch()
        );

        uint256 totalFee;
        for (uint256 i; i < len; ++i) {
            totalFee += _list(msg.sender, _bondIds[i], _prices[i], _expirations[i], _maxFees[i]);
        }
        require(msg.value == totalFee, InsufficientFee());
    }

    /// @notice Batch buy multiple listed bond NFTs
    /// @param _bondIds The bond token IDs to purchase
    /// @param _expectedPrices The expected listing prices to prevent front-running
    /// @param _maxFees The per-item maximum ETH fees
    function batchBuy(
        uint256[] calldata _bondIds,
        uint128[] calldata _expectedPrices,
        uint256[] calldata _maxFees
    ) external payable nonReentrant {
        uint256 len = _bondIds.length;
        require(len == _expectedPrices.length && len == _maxFees.length, ArrayLengthMismatch());

        uint256 totalRemaining = msg.value;
        for (uint256 i; i < len; ++i) {
            uint256 feeCharged = _buy(msg.sender, _bondIds[i], _expectedPrices[i], totalRemaining, _maxFees[i]);
            // _buy asserts totalRemaining >= price + feeCharged, so this subtraction is safe
            totalRemaining -= (uint256(_expectedPrices[i]) + feeCharged);
        }

        if (totalRemaining > 0) {
            // slither-disable-next-line arbitrary-send-eth
            require(_safeTransferETH(msg.sender, totalRemaining), InsufficientPayment());
        }
    }

    /// @notice Batch cancel multiple listings
    /// @param _bondIds The bond token IDs to cancel
    /// @param _maxFees The per-item maximum ETH fees
    function batchCancelListings(uint256[] calldata _bondIds, uint256[] calldata _maxFees)
        external
        payable
        nonReentrant
    {
        uint256 len = _bondIds.length;
        require(len == _maxFees.length, ArrayLengthMismatch());

        uint256 totalFee;
        for (uint256 i; i < len; ++i) {
            totalFee += _cancelListing(msg.sender, _bondIds[i], _maxFees[i]);
        }
        require(msg.value == totalFee, InsufficientFee());
    }

    /// @notice Batch make multiple WETH offers
    /// @param _bondIds The bond token IDs to make offers on
    /// @param _wethAmounts The WETH amounts to offer
    /// @param _expirations The offer expiration timestamps
    /// @param _maxFees The per-item maximum ETH fees
    function batchMakeOffers(
        uint256[] calldata _bondIds,
        uint128[] calldata _wethAmounts,
        uint64[] calldata _expirations,
        uint256[] calldata _maxFees
    ) external payable nonReentrant {
        uint256 len = _bondIds.length;
        require(
            len == _wethAmounts.length && len == _expirations.length && len == _maxFees.length,
            ArrayLengthMismatch()
        );

        uint256 totalFee;
        for (uint256 i; i < len; ++i) {
            totalFee += _makeOffer(msg.sender, _bondIds[i], _wethAmounts[i], _expirations[i], _maxFees[i]);
        }
        require(msg.value == totalFee, InsufficientFee());
    }

    /// @notice Batch cancel multiple offers
    /// @param _bondIds The bond token IDs to cancel offers for
    /// @param _maxFees The per-item maximum ETH fees
    function batchCancelOffers(uint256[] calldata _bondIds, uint256[] calldata _maxFees)
        external
        payable
        nonReentrant
    {
        uint256 len = _bondIds.length;
        require(len == _maxFees.length, ArrayLengthMismatch());

        uint256 totalFee;
        for (uint256 i; i < len; ++i) {
            totalFee += _cancelOffer(msg.sender, _bondIds[i], _maxFees[i]);
        }
        require(msg.value == totalFee, InsufficientFee());
    }

    /// @notice Batch accept multiple WETH offers
    /// @dev Fees are read from each Offer struct (locked at makeOffer). No ETH required.
    /// @param _bondIds The bond token IDs
    /// @param _buyers The addresses of the offer makers
    /// @param _expectedAmounts The expected WETH amounts to prevent front-running
    function batchAcceptOffers(
        uint256[] calldata _bondIds,
        address[] calldata _buyers,
        uint128[] calldata _expectedAmounts
    ) external nonReentrant {
        uint256 len = _bondIds.length;
        require(len == _buyers.length && len == _expectedAmounts.length, ArrayLengthMismatch());

        for (uint256 i; i < len; ++i) {
            _acceptOffer(msg.sender, _bondIds[i], _buyers[i], _expectedAmounts[i]);
        }
    }

    // ───── View Functions ─────

    /// @notice Check if a listing is currently valid
    /// @param _bondId The bond token ID
    /// @return Whether the listing is valid
    function isListingValid(uint256 _bondId) external view returns (bool) {
        Listing memory listing = sListings[_bondId];
        if (listing.seller == address(0)) return false;
        if (block.timestamp > listing.expiration) return false;
        if (ICofferBondNft(I_COFFER_BOND_NFT).ownerOf(_bondId) != listing.seller) return false;
        if (!_isBondOutstanding(_bondId)) return false;
        return true;
    }

    /// @notice Check if an offer is currently valid (balance and allowance must cover amount + locked fee)
    /// @param _bondId The bond token ID
    /// @param _buyer The address of the offer maker
    /// @return Whether the offer is valid
    function isOfferValid(uint256 _bondId, address _buyer) external view returns (bool) {
        Offer memory o = sOffers[_bondId][_buyer];
        if (o.buyer == address(0)) return false;
        if (block.timestamp > o.expiration) return false;
        uint256 totalWeth = uint256(o.wethAmount) + uint256(o.fee);
        if (IWETH(I_WETH).balanceOf(_buyer) < totalWeth) return false;
        if (IWETH(I_WETH).allowance(_buyer, address(this)) < totalWeth) return false;
        return true;
    }

    /// @notice Get bond data from the associated Coffer
    /// @param _bondId The bond token ID
    /// @return maturityValue The bond maturity value
    /// @return duration The bond duration in seconds
    /// @return startTimestamp The bond start timestamp
    /// @return cofferAddress The Coffer address
    function getBondData(uint256 _bondId)
        external
        view
        returns (uint128 maturityValue, uint32 duration, uint32 startTimestamp, address cofferAddress)
    {
        cofferAddress = ICofferBondNft(I_COFFER_BOND_NFT).cofferOf(_bondId);
        (maturityValue, duration, startTimestamp,) = ICoffer(cofferAddress).sHolderConditions(_bondId);
    }

    // ───── Internal: Fee Math ─────

    /// @notice Compute a profit-based fee: fixedFee + profit * bps / BPS_DENOMINATOR.
    /// @dev Returns zero if the selector has no configured fee.
    function _calculateFeeOnProfit(bytes4 _selector, uint256 _profit, uint256 _maxFee)
        internal
        view
        returns (uint256 fee)
    {
        FunctionFee memory ff = sFunctionFees[_selector];
        if (ff.fixedFee == 0 && ff.percentageBps == 0) return 0;
        uint256 percentageFee = (_profit * uint256(ff.percentageBps)) / BPS_DENOMINATOR;
        fee = uint256(ff.fixedFee) + percentageFee;
        // solhint-disable-next-line gas-strict-inequalities
        require(fee <= _maxFee, FeeExceedsMax());
    }

    /// @notice Compute a flat fee: fixedFee only (percentage ignored).
    /// @dev Returns zero if the selector has no configured fixed fee.
    function _calculateFlatFee(bytes4 _selector, uint256 _maxFee) internal view returns (uint256 fee) {
        FunctionFee memory ff = sFunctionFees[_selector];
        if (ff.fixedFee == 0) return 0;
        fee = uint256(ff.fixedFee);
        // solhint-disable-next-line gas-strict-inequalities
        require(fee <= _maxFee, FeeExceedsMax());
    }

    // ───── Internal: Listing Logic ─────

    function _list(address _seller, uint256 _bondId, uint128 _price, uint64 _expiration, uint256 _maxFee)
        internal
        returns (uint256 fee)
    {
        require(_price > 0, ZeroPrice());
        require(_expiration > block.timestamp, ExpirationNotInFuture());
        // slither-disable-next-line calls-loop
        require(ICofferBondNft(I_COFFER_BOND_NFT).ownerOf(_bondId) == _seller, NotOwner());
        require(_isBondOutstanding(_bondId), BondNotOutstanding());
        // slither-disable-next-line calls-loop
        require(ICofferBondNft(I_COFFER_BOND_NFT).isApprovedForAll(_seller, address(this)), MarketplaceNotApproved());

        fee = _calculateFlatFee(this.list.selector, _maxFee);

        // Emit cancellation if overwriting a stale listing from a different seller
        Listing memory existing = sListings[_bondId];
        if (existing.seller != address(0) && existing.seller != _seller) {
            emit ListingCancelled(_bondId, existing.seller);
        }

        // slither-disable-next-line reentrancy-no-eth
        sListings[_bondId] = Listing({seller: _seller, price: _price, expiration: _expiration});

        emit Listed(_bondId, _seller, _price, _expiration);
    }

    function _cancelListing(address _caller, uint256 _bondId, uint256 _maxFee) internal returns (uint256 fee) {
        Listing memory listing = sListings[_bondId];
        require(listing.seller == _caller, NotSeller());

        fee = _calculateFlatFee(this.cancelListing.selector, _maxFee);

        // slither-disable-next-line costly-loop
        delete sListings[_bondId];
        emit ListingCancelled(_bondId, _caller);
    }

    function _buy(
        address _buyer,
        uint256 _bondId,
        uint128 _expectedPrice,
        uint256 _payment,
        uint256 _maxFee
    ) internal returns (uint256 fee) {
        Listing memory listing = sListings[_bondId];
        require(listing.seller != address(0), ListingNotFound());
        // solhint-disable-next-line gas-strict-inequalities
        require(block.timestamp <= listing.expiration, ListingExpired());
        require(_isBondOutstanding(_bondId), BondNotOutstanding());

        // Check seller still owns NFT
        // slither-disable-next-line calls-loop
        require(ICofferBondNft(I_COFFER_BOND_NFT).ownerOf(_bondId) == listing.seller, SellerNoLongerOwnsNft());

        require(listing.price == _expectedPrice, PriceMismatch());
        require(_buyer != listing.seller, CannotBuyOwnListing());

        // Compute profit-based fee (buyer's gain = maturityValue - listingPrice)
        uint128 maturityValue = _getBondMaturity(_bondId);
        uint256 profit = maturityValue > listing.price ? uint256(maturityValue) - uint256(listing.price) : 0;
        fee = _calculateFeeOnProfit(this.buy.selector, profit, _maxFee);

        // solhint-disable-next-line gas-strict-inequalities
        require(_payment >= uint256(listing.price) + fee, InsufficientPayment());

        // CEI: delete listing before external calls
        // slither-disable-next-line reentrancy-no-eth,costly-loop
        delete sListings[_bondId];

        // Transfer NFT from seller to buyer (seller approved marketplace in _list)
        // slither-disable-next-line arbitrary-send-erc20,calls-loop
        ICofferBondNft(I_COFFER_BOND_NFT).safeTransferFrom(listing.seller, _buyer, _bondId);

        // Send price to seller — fall back to WETH if seller rejects ETH
        // slither-disable-next-line arbitrary-send-eth,calls-loop
        bool okSeller = _safeTransferETH(listing.seller, listing.price);
        if (!okSeller) {
            IWETH(I_WETH).deposit{value: listing.price}();
            IERC20(I_WETH).safeTransfer(listing.seller, listing.price);
        }

        // Fee stays in contract balance; caller (external or batch) handles any buyer-side refund
        emit ListingPurchased(_bondId, _buyer, listing.seller, listing.price, fee);
    }

    // ───── Internal: Offer Logic ─────

    function _makeOffer(
        address _buyer,
        uint256 _bondId,
        uint128 _wethAmount,
        uint64 _expiration,
        uint256 _maxFee
    ) internal returns (uint256 fee) {
        require(_wethAmount > 0, ZeroAmount());
        require(_expiration > block.timestamp, ExpirationNotInFuture());
        require(_isBondOutstanding(_bondId), BondNotOutstanding());

        // App-usage flat fee (paid in ETH right now)
        fee = _calculateFlatFee(this.makeOffer.selector, _maxFee);

        // Lock the WETH fee for acceptOffer using CURRENT fee config (revenue-based on offerer profit)
        uint128 maturityValue = _getBondMaturity(_bondId);
        uint256 revenue = maturityValue > _wethAmount ? uint256(maturityValue) - uint256(_wethAmount) : 0;
        uint256 lockedFeeFull =
            _calculateFeeOnProfit(this.acceptOffer.selector, revenue, type(uint256).max);
        require(lockedFeeFull <= type(uint128).max, FeeExceedsMax());
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 lockedFee = uint128(lockedFeeFull);

        uint256 totalWeth = uint256(_wethAmount) + uint256(lockedFee);
        // slither-disable-next-line calls-loop
        // solhint-disable-next-line gas-strict-inequalities
        require(IWETH(I_WETH).balanceOf(_buyer) >= totalWeth, InsufficientWethBalance());
        // slither-disable-next-line calls-loop
        // solhint-disable-next-line gas-strict-inequalities
        require(IWETH(I_WETH).allowance(_buyer, address(this)) >= totalWeth, InsufficientWethAllowance());

        // slither-disable-next-line reentrancy-no-eth
        sOffers[_bondId][_buyer] =
            Offer({buyer: _buyer, expiration: _expiration, wethAmount: _wethAmount, fee: lockedFee});

        emit OfferMade(_bondId, _buyer, _wethAmount, _expiration);
    }

    function _cancelOffer(address _caller, uint256 _bondId, uint256 _maxFee) internal returns (uint256 fee) {
        Offer memory o = sOffers[_bondId][_caller];
        require(o.buyer == _caller, NotBuyer());

        fee = _calculateFlatFee(this.cancelOffer.selector, _maxFee);

        delete sOffers[_bondId][_caller];
        emit OfferCancelled(_bondId, _caller);
    }

    function _acceptOffer(address _seller, uint256 _bondId, address _buyer, uint128 _expectedAmount)
        internal
        returns (uint256 fee)
    {
        Offer memory o = sOffers[_bondId][_buyer];
        require(o.buyer != address(0), OfferNotFound());
        // solhint-disable-next-line gas-strict-inequalities
        require(block.timestamp <= o.expiration, OfferExpired());
        require(_isBondOutstanding(_bondId), BondNotOutstanding());
        // slither-disable-next-line calls-loop
        require(ICofferBondNft(I_COFFER_BOND_NFT).ownerOf(_bondId) == _seller, NotOwner());
        require(_buyer != _seller, CannotBuyOwnListing());
        // slither-disable-next-line calls-loop
        require(ICofferBondNft(I_COFFER_BOND_NFT).isApprovedForAll(_seller, address(this)), MarketplaceNotApproved());
        require(o.wethAmount == _expectedAmount, AmountMismatch());

        fee = uint256(o.fee);
        uint256 totalWeth = uint256(o.wethAmount) + fee;

        // Verify buyer still has sufficient WETH for amount + locked fee
        // slither-disable-next-line calls-loop
        // solhint-disable-next-line gas-strict-inequalities
        require(IWETH(I_WETH).balanceOf(_buyer) >= totalWeth, InsufficientWethBalance());
        // slither-disable-next-line calls-loop
        // solhint-disable-next-line gas-strict-inequalities
        require(IWETH(I_WETH).allowance(_buyer, address(this)) >= totalWeth, InsufficientWethAllowance());

        // CEI: delete offer before external calls
        delete sOffers[_bondId][_buyer];

        // Transfer WETH offer amount from buyer to seller
        // slither-disable-next-line arbitrary-send-erc20
        IERC20(I_WETH).safeTransferFrom(_buyer, _seller, o.wethAmount);
        // Transfer WETH fee from buyer to this contract
        if (fee > 0) {
            // slither-disable-next-line arbitrary-send-erc20
            IERC20(I_WETH).safeTransferFrom(_buyer, address(this), fee);
        }

        // Transfer NFT from seller to buyer
        // slither-disable-next-line calls-loop
        ICofferBondNft(I_COFFER_BOND_NFT).safeTransferFrom(_seller, _buyer, _bondId);

        emit OfferAccepted(_bondId, _buyer, _seller, o.wethAmount, fee);
    }

    // ───── Internal: Helpers ─────

    /// @notice Read the maturity value of a bond from its associated Coffer
    /// @param _bondId The bond token ID
    /// @return maturityValue The bond maturity value in wei
    function _getBondMaturity(uint256 _bondId) internal view returns (uint128 maturityValue) {
        // slither-disable-next-line calls-loop
        address cofferAddr = ICofferBondNft(I_COFFER_BOND_NFT).cofferOf(_bondId);
        // slither-disable-next-line unused-return,calls-loop
        (maturityValue,,,) = ICoffer(cofferAddr).sHolderConditions(_bondId);
    }

    /// @notice Check if a bond is outstanding (maturityValue != 0)
    /// @param _bondId The bond token ID
    /// @return Whether the bond is outstanding
    function _isBondOutstanding(uint256 _bondId) internal view returns (bool) {
        return _getBondMaturity(_bondId) != 0;
    }

    /// @notice Transfer ETH without copying returndata, preventing returndata bomb gas griefing.
    /// @dev Solidity's `addr.call{value: amount}("")` copies ALL returndata into memory.
    ///      A malicious recipient can exploit this by returning a large payload (e.g., 300KB)
    ///      from their receive/fallback function, causing quadratic memory expansion gas costs
    ///      charged to the caller. Using assembly with returndatasize 0 (the last two zeros in
    ///      the call opcode: `call(gas, to, amount, 0, 0, 0, 0)`) tells the EVM to skip the
    ///      returndata copy entirely, making the gas cost constant regardless of what the
    ///      recipient returns.
    /// @param _to The address to transfer ETH to
    /// @param _amount The amount of ETH to transfer in wei
    /// @return success Whether the transfer succeeded
    // slither-disable-next-line assembly
    function _safeTransferETH(address _to, uint256 _amount) internal returns (bool success) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // call(gasLimit, to, value, inputOffset, inputSize, outputOffset, outputSize)
            // The final two zeros (outputOffset=0, outputSize=0) are critical:
            // they prevent the EVM from copying any returndata into memory,
            // which is what makes this immune to returndata bomb attacks.
            success := call(gas(), _to, _amount, 0, 0, 0, 0)
        }
    }
}
