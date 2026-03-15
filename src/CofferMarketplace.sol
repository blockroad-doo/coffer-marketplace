//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.33;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICofferBondNft} from "./interfaces/ICofferBondNft.sol";
import {ICoffer} from "./interfaces/ICoffer.sol";
import {IWETH} from "./interfaces/IWETH.sol";

/// @title CofferMarketplace
/// @author Coffer
/// @notice Secondary marketplace for Coffer bond NFTs — listings (ETH) and offers (WETH)
contract CofferMarketplace is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ───── Errors ─────

    error ZeroAddress();
    error ZeroPrice();
    error ZeroAmount();
    error InsufficientFee();
    error NotSeller();
    error NotBuyer();
    error NotOwner();
    error ListingNotFound();
    error ListingExpired();
    error OfferNotFound();
    error OfferExpired();
    error PriceMismatch();
    error AmountMismatch();
    error BondNotActive();
    error SellerNoLongerOwnsNft();
    error MarketplaceNotApproved();
    error ExpirationNotInFuture();
    error CannotBuyOwnListing();
    error InsufficientWethBalance();
    error InsufficientWethAllowance();
    error InsufficientPayment();
    error ArrayLengthMismatch();

    // ───── Structs ─────

    struct FunctionFee {
        uint128 fixedFee;
        uint16 percentageBps;
    }

    struct Listing {
        address seller;
        uint128 price;
        uint64 expiration;
        address nftContract;
    }

    struct Offer {
        address buyer;
        uint128 wethAmount;
        uint64 expiration;
    }

    // ───── State ─────

    /// @notice Immutable WETH token contract address
    address public immutable I_WETH;

    /// @notice Address that receives collected fees
    address public sFeeRecipient;
    /// @notice Fee configuration for each function selector
    mapping(bytes4 => FunctionFee) public sFunctionFees;

    /// @notice Active listings indexed by NFT contract and bond ID
    mapping(address nftContract => mapping(uint256 bondId => Listing)) public sListings;
    /// @notice Active offers indexed by NFT contract, bond ID, and buyer
    mapping(address nftContract => mapping(uint256 bondId => mapping(address buyer => Offer))) public sOffers;

    // ───── Events ─────

    /// @notice Emitted when the fee recipient is updated
    /// @param recipient The new fee recipient address
    event FeeRecipientSet(address indexed recipient);
    /// @notice Emitted when a function fee is configured
    /// @param selector The function selector the fee applies to
    /// @param fixedFee The fixed fee amount in wei
    /// @param percentageBps The percentage fee in basis points
    event FunctionFeeSet(bytes4 indexed selector, uint128 indexed fixedFee, uint16 indexed percentageBps);
    /// @notice Emitted when a fee is collected and sent to the fee recipient
    /// @param selector The function selector the fee was collected for
    /// @param fee The fee amount collected
    event FeeCollected(bytes4 indexed selector, uint256 indexed fee);

    /// @notice Emitted when a bond NFT is listed for sale
    /// @param nftContract The NFT contract address
    /// @param bondId The bond token ID
    /// @param seller The seller address
    /// @param price The listing price in wei
    /// @param expiration The listing expiration timestamp
    event Listed(
        address indexed nftContract, uint256 indexed bondId, address indexed seller, uint128 price, uint64 expiration
    );
    /// @notice Emitted when a listing is cancelled
    /// @param nftContract The NFT contract address
    /// @param bondId The bond token ID
    /// @param seller The seller address
    event ListingCancelled(address indexed nftContract, uint256 indexed bondId, address indexed seller);
    /// @notice Emitted when a listed bond NFT is purchased
    /// @param nftContract The NFT contract address
    /// @param bondId The bond token ID
    /// @param buyer The buyer address
    /// @param seller The seller address
    /// @param price The purchase price in wei
    event ListingPurchased(
        address indexed nftContract, uint256 indexed bondId, address buyer, address indexed seller, uint128 price
    );

    /// @notice Emitted when a WETH offer is made on a bond NFT
    /// @param nftContract The NFT contract address
    /// @param bondId The bond token ID
    /// @param buyer The buyer address
    /// @param wethAmount The WETH offer amount
    /// @param expiration The offer expiration timestamp
    event OfferMade(
        address indexed nftContract,
        uint256 indexed bondId,
        address indexed buyer,
        uint128 wethAmount,
        uint64 expiration
    );
    /// @notice Emitted when an offer is cancelled
    /// @param nftContract The NFT contract address
    /// @param bondId The bond token ID
    /// @param buyer The buyer address
    event OfferCancelled(address indexed nftContract, uint256 indexed bondId, address indexed buyer);
    /// @notice Emitted when a WETH offer is accepted by the NFT owner
    /// @param nftContract The NFT contract address
    /// @param bondId The bond token ID
    /// @param buyer The buyer address
    /// @param seller The seller address
    /// @param wethAmount The WETH amount of the accepted offer
    event OfferAccepted(
        address indexed nftContract, uint256 indexed bondId, address indexed buyer, address seller, uint128 wethAmount
    );

    // ───── Constructor ─────

    constructor(address _owner, address _feeRecipient, address _weth) Ownable(_owner) {
        require(_feeRecipient != address(0), ZeroAddress());
        require(_weth != address(0), ZeroAddress());
        sFeeRecipient = _feeRecipient;
        I_WETH = _weth;
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
        sFunctionFees[_selector] = FunctionFee({fixedFee: _fixedFee, percentageBps: _percentageBps});
        emit FunctionFeeSet(_selector, _fixedFee, _percentageBps);
    }

    // ───── Listing Functions ─────

    /// @notice List a bond NFT for sale
    /// @param _nftContract The NFT contract address
    /// @param _bondId The bond token ID to list
    /// @param _price The listing price in wei
    /// @param _expiration The listing expiration timestamp
    function list(address _nftContract, uint256 _bondId, uint128 _price, uint64 _expiration) external payable {
        uint256 remaining = _collectFee(this.list.selector, msg.value);
        require(remaining == 0, InsufficientPayment());
        _list(msg.sender, _nftContract, _bondId, _price, _expiration);
    }

    /// @notice Cancel an active listing
    /// @param _nftContract The NFT contract address
    /// @param _bondId The bond token ID to cancel
    function cancelListing(address _nftContract, uint256 _bondId) external {
        _cancelListing(msg.sender, _nftContract, _bondId);
    }

    /// @notice Purchase a listed bond NFT
    /// @param _nftContract The NFT contract address
    /// @param _bondId The bond token ID to purchase
    /// @param _expectedPrice The expected listing price to prevent front-running
    function buy(address _nftContract, uint256 _bondId, uint128 _expectedPrice) external payable nonReentrant {
        _buy(msg.sender, _nftContract, _bondId, _expectedPrice, msg.value);
    }

    // ───── Offer Functions ─────

    /// @notice Make a WETH offer on a bond NFT
    /// @param _nftContract The NFT contract address
    /// @param _bondId The bond token ID to make an offer on
    /// @param _wethAmount The WETH amount to offer
    /// @param _expiration The offer expiration timestamp
    function makeOffer(address _nftContract, uint256 _bondId, uint128 _wethAmount, uint64 _expiration)
        external
        payable
    {
        uint256 remaining = _collectFee(this.makeOffer.selector, msg.value);
        require(remaining == 0, InsufficientPayment());
        _makeOffer(msg.sender, _nftContract, _bondId, _wethAmount, _expiration);
    }

    /// @notice Cancel an active offer
    /// @param _nftContract The NFT contract address
    /// @param _bondId The bond token ID to cancel the offer for
    function cancelOffer(address _nftContract, uint256 _bondId) external {
        _cancelOffer(msg.sender, _nftContract, _bondId);
    }

    /// @notice Accept a WETH offer on a bond NFT you own
    /// @param _nftContract The NFT contract address
    /// @param _bondId The bond token ID
    /// @param _buyer The address of the offer maker
    /// @param _expectedAmount The expected WETH amount to prevent front-running
    function acceptOffer(address _nftContract, uint256 _bondId, address _buyer, uint128 _expectedAmount)
        external
        payable
        nonReentrant
    {
        _acceptOffer(msg.sender, _nftContract, _bondId, _buyer, _expectedAmount, msg.value);
    }

    // ───── Batch Functions ─────

    /// @notice Batch list multiple bond NFTs
    /// @param _nftContracts The NFT contract addresses
    /// @param _bondIds The bond token IDs to list
    /// @param _prices The listing prices in wei
    /// @param _expirations The listing expiration timestamps
    function batchList(
        address[] calldata _nftContracts,
        uint256[] calldata _bondIds,
        uint128[] calldata _prices,
        uint64[] calldata _expirations
    ) external payable nonReentrant {
        uint256 len = _nftContracts.length;
        require(len == _bondIds.length && len == _prices.length && len == _expirations.length, ArrayLengthMismatch());

        uint256 totalRemaining = msg.value;
        for (uint256 i; i < len; ++i) {
            FunctionFee memory ff = sFunctionFees[this.list.selector];
            uint256 feeForThis = _calculateFeeAmount(ff, 0);
            // solhint-disable-next-line gas-strict-inequalities
            require(totalRemaining >= feeForThis, InsufficientFee());
            totalRemaining -= feeForThis;
            _distributeFee(this.list.selector, feeForThis);
            _list(msg.sender, _nftContracts[i], _bondIds[i], _prices[i], _expirations[i]);
        }
    }

    /// @notice Batch buy multiple listed bond NFTs
    /// @param _nftContracts The NFT contract addresses
    /// @param _bondIds The bond token IDs to purchase
    /// @param _expectedPrices The expected listing prices to prevent front-running
    function batchBuy(address[] calldata _nftContracts, uint256[] calldata _bondIds, uint128[] calldata _expectedPrices)
        external
        payable
        nonReentrant
    {
        uint256 len = _nftContracts.length;
        require(len == _bondIds.length && len == _expectedPrices.length, ArrayLengthMismatch());

        uint256 totalRemaining = msg.value;
        for (uint256 i; i < len; ++i) {
            uint256 gross = _grossForPrice(this.buy.selector, _expectedPrices[i]);
            // solhint-disable-next-line gas-strict-inequalities
            require(totalRemaining >= gross, InsufficientPayment());
            _buy(msg.sender, _nftContracts[i], _bondIds[i], _expectedPrices[i], gross);
            totalRemaining -= gross;
        }

        // Refund excess
        if (totalRemaining > 0) {
            // slither-disable-next-line arbitrary-send-eth
            (bool ok,) = msg.sender.call{value: totalRemaining}("");
            require(ok, InsufficientPayment());
        }
    }

    /// @notice Batch cancel multiple listings
    /// @param _nftContracts The NFT contract addresses
    /// @param _bondIds The bond token IDs to cancel
    function batchCancelListings(address[] calldata _nftContracts, uint256[] calldata _bondIds) external {
        uint256 len = _nftContracts.length;
        require(len == _bondIds.length, ArrayLengthMismatch());

        for (uint256 i; i < len; ++i) {
            _cancelListing(msg.sender, _nftContracts[i], _bondIds[i]);
        }
    }

    /// @notice Batch make multiple WETH offers
    /// @param _nftContracts The NFT contract addresses
    /// @param _bondIds The bond token IDs to make offers on
    /// @param _wethAmounts The WETH amounts to offer
    /// @param _expirations The offer expiration timestamps
    function batchMakeOffers(
        address[] calldata _nftContracts,
        uint256[] calldata _bondIds,
        uint128[] calldata _wethAmounts,
        uint64[] calldata _expirations
    ) external payable nonReentrant {
        uint256 len = _nftContracts.length;
        require(
            len == _bondIds.length && len == _wethAmounts.length && len == _expirations.length, ArrayLengthMismatch()
        );

        uint256 totalRemaining = msg.value;
        for (uint256 i; i < len; ++i) {
            FunctionFee memory ff = sFunctionFees[this.makeOffer.selector];
            uint256 feeForThis = _calculateFeeAmount(ff, 0);
            // solhint-disable-next-line gas-strict-inequalities
            require(totalRemaining >= feeForThis, InsufficientFee());
            totalRemaining -= feeForThis;
            _distributeFee(this.makeOffer.selector, feeForThis);
            _makeOffer(msg.sender, _nftContracts[i], _bondIds[i], _wethAmounts[i], _expirations[i]);
        }
    }

    /// @notice Batch cancel multiple offers
    /// @param _nftContracts The NFT contract addresses
    /// @param _bondIds The bond token IDs to cancel offers for
    function batchCancelOffers(address[] calldata _nftContracts, uint256[] calldata _bondIds) external {
        uint256 len = _nftContracts.length;
        require(len == _bondIds.length, ArrayLengthMismatch());

        for (uint256 i; i < len; ++i) {
            _cancelOffer(msg.sender, _nftContracts[i], _bondIds[i]);
        }
    }

    /// @notice Batch accept multiple WETH offers
    /// @param _nftContracts The NFT contract addresses
    /// @param _bondIds The bond token IDs
    /// @param _buyers The addresses of the offer makers
    /// @param _expectedAmounts The expected WETH amounts to prevent front-running
    function batchAcceptOffers(
        address[] calldata _nftContracts,
        uint256[] calldata _bondIds,
        address[] calldata _buyers,
        uint128[] calldata _expectedAmounts
    ) external payable nonReentrant {
        uint256 len = _nftContracts.length;
        require(
            len == _bondIds.length && len == _buyers.length && len == _expectedAmounts.length, ArrayLengthMismatch()
        );

        uint256 totalRemaining = msg.value;
        for (uint256 i; i < len; ++i) {
            FunctionFee memory ff = sFunctionFees[this.acceptOffer.selector];
            uint256 acceptFeeEth = _calculateFeeAmount(ff, 0);
            // solhint-disable-next-line gas-strict-inequalities
            require(totalRemaining >= acceptFeeEth, InsufficientFee());
            totalRemaining -= acceptFeeEth;
            _acceptOffer(msg.sender, _nftContracts[i], _bondIds[i], _buyers[i], _expectedAmounts[i], acceptFeeEth);
        }
    }

    // ───── View Functions ─────

    /// @notice Check if a listing is currently valid
    /// @param _nftContract The NFT contract address
    /// @param _bondId The bond token ID
    /// @return Whether the listing is valid
    function isListingValid(address _nftContract, uint256 _bondId) external view returns (bool) {
        Listing memory listing = sListings[_nftContract][_bondId];
        if (listing.seller == address(0)) return false;
        if (block.timestamp > listing.expiration) return false;
        if (ICofferBondNft(_nftContract).ownerOf(_bondId) != listing.seller) return false;
        if (!_isBondActive(_nftContract, _bondId)) return false;
        return true;
    }

    /// @notice Check if an offer is currently valid
    /// @param _nftContract The NFT contract address
    /// @param _bondId The bond token ID
    /// @param _buyer The address of the offer maker
    /// @return Whether the offer is valid
    function isOfferValid(address _nftContract, uint256 _bondId, address _buyer) external view returns (bool) {
        Offer memory o = sOffers[_nftContract][_bondId][_buyer];
        if (o.buyer == address(0)) return false;
        if (block.timestamp > o.expiration) return false;
        if (IWETH(I_WETH).balanceOf(_buyer) < o.wethAmount) return false;
        if (IWETH(I_WETH).allowance(_buyer, address(this)) < o.wethAmount) return false;
        return true;
    }

    /// @notice Get bond data from the associated Coffer vault
    /// @param _nftContract The NFT contract address
    /// @param _bondId The bond token ID
    /// @return maturityValue The bond maturity value
    /// @return duration The bond duration in seconds
    /// @return startTimestamp The bond start timestamp
    /// @return cofferAddress The Coffer vault address
    function getBondData(address _nftContract, uint256 _bondId)
        external
        view
        returns (uint128 maturityValue, uint32 duration, uint32 startTimestamp, address cofferAddress)
    {
        cofferAddress = ICofferBondNft(_nftContract).cofferOf(_bondId);
        (maturityValue, duration, startTimestamp) = ICoffer(cofferAddress).sHolderConditions(_bondId);
    }

    // ───── Internal: Fee Infrastructure ─────

    /// @notice Calculate fee and remaining value from a total value for a given selector
    /// @param _selector The function selector to calculate the fee for
    /// @param _value The total value to split into fee and remaining
    /// @return fee The calculated fee amount
    /// @return remaining The remaining value after fee deduction
    function _calculateFee(bytes4 _selector, uint256 _value) internal view returns (uint256 fee, uint256 remaining) {
        FunctionFee memory ff = sFunctionFees[_selector];

        if (ff.fixedFee == 0 && ff.percentageBps == 0) {
            return (0, _value);
        }

        // solhint-disable-next-line gas-strict-inequalities
        require(_value >= ff.fixedFee, InsufficientFee());

        uint256 afterFixed = _value - ff.fixedFee;
        uint256 operationalValue = (afterFixed * 10000) / (10000 + uint256(ff.percentageBps));

        fee = _value - operationalValue;
        remaining = operationalValue;
    }

    /// @notice Calculate fee amount only (no remaining), for a known operational amount
    /// @param _ff The function fee configuration
    /// @param _operationalValue The operational value to calculate percentage fee on
    /// @return fee The calculated fee amount
    function _calculateFeeAmount(FunctionFee memory _ff, uint256 _operationalValue)
        internal
        pure
        returns (uint256 fee)
    {
        fee = _ff.fixedFee;
        if (_ff.percentageBps > 0 && _operationalValue > 0) {
            fee += (_operationalValue * uint256(_ff.percentageBps)) / 10000;
        }
    }

    /// @notice Forward calculation: given a listing price, compute gross ETH needed (price + fees)
    /// @param _selector The function selector to calculate fees for
    /// @param _price The listing price
    /// @return gross The total gross amount including fees
    function _grossForPrice(bytes4 _selector, uint128 _price) internal view returns (uint256 gross) {
        FunctionFee memory ff = sFunctionFees[_selector];
        gross = uint256(ff.fixedFee) + (uint256(_price) * (10000 + uint256(ff.percentageBps)) + 9999) / 10000;
    }

    /// @notice Calculate WETH fee from a WETH amount for a given selector
    /// @param _selector The function selector to calculate the fee for
    /// @param _wethAmount The WETH amount to calculate the fee on
    /// @return fee The calculated WETH fee amount
    /// @return sellerProceeds The remaining WETH after fee deduction
    function _calculateWethFee(bytes4 _selector, uint256 _wethAmount)
        internal
        view
        returns (uint256 fee, uint256 sellerProceeds)
    {
        FunctionFee memory ff = sFunctionFees[_selector];

        if (ff.fixedFee == 0 && ff.percentageBps == 0) {
            return (0, _wethAmount);
        }

        fee = uint256(ff.fixedFee);
        if (ff.percentageBps > 0) {
            fee += (_wethAmount * uint256(ff.percentageBps)) / 10000;
        }

        require(_wethAmount > fee, InsufficientFee());
        sellerProceeds = _wethAmount - fee;
    }

    /// @notice Collect fee from msg.value and send to fee recipient. Returns remaining value.
    /// @param _selector The function selector to collect the fee for
    /// @param _value The total value to collect the fee from
    /// @return remaining The remaining value after fee collection
    function _collectFee(bytes4 _selector, uint256 _value) internal returns (uint256 remaining) {
        uint256 fee;
        (fee, remaining) = _calculateFee(_selector, _value);
        _distributeFee(_selector, fee);
    }

    /// @notice Send fee to fee recipient if non-zero
    /// @param _selector The function selector the fee is associated with
    /// @param _fee The fee amount to distribute
    function _distributeFee(bytes4 _selector, uint256 _fee) internal {
        if (_fee > 0) {
            // slither-disable-next-line arbitrary-send-eth,calls-loop
            (bool ok,) = sFeeRecipient.call{value: _fee}("");
            require(ok, InsufficientFee());
            emit FeeCollected(_selector, _fee);
        }
    }

    // ───── Internal: Listing Logic ─────

    function _list(address _seller, address _nftContract, uint256 _bondId, uint128 _price, uint64 _expiration)
        internal
    {
        require(_price > 0, ZeroPrice());
        require(_expiration > block.timestamp, ExpirationNotInFuture());
        // slither-disable-next-line calls-loop
        require(ICofferBondNft(_nftContract).ownerOf(_bondId) == _seller, NotOwner());
        require(_isBondActive(_nftContract, _bondId), BondNotActive());
        // slither-disable-next-line calls-loop
        require(ICofferBondNft(_nftContract).isApprovedForAll(_seller, address(this)), MarketplaceNotApproved());

        // slither-disable-next-line reentrancy-no-eth
        sListings[_nftContract][_bondId] =
            Listing({seller: _seller, price: _price, expiration: _expiration, nftContract: _nftContract});

        emit Listed(_nftContract, _bondId, _seller, _price, _expiration);
    }

    function _cancelListing(address _caller, address _nftContract, uint256 _bondId) internal {
        Listing memory listing = sListings[_nftContract][_bondId];
        require(listing.seller == _caller, NotSeller());

        delete sListings[_nftContract][_bondId];
        emit ListingCancelled(_nftContract, _bondId, _caller);
    }

    function _buy(address _buyer, address _nftContract, uint256 _bondId, uint128 _expectedPrice, uint256 _payment)
        internal
    {
        Listing memory listing = sListings[_nftContract][_bondId];
        require(listing.seller != address(0), ListingNotFound());
        // solhint-disable-next-line gas-strict-inequalities
        require(block.timestamp <= listing.expiration, ListingExpired());
        require(_isBondActive(_nftContract, _bondId), BondNotActive());

        // Check seller still owns NFT
        // slither-disable-next-line calls-loop
        require(ICofferBondNft(_nftContract).ownerOf(_bondId) == listing.seller, SellerNoLongerOwnsNft());

        require(listing.price == _expectedPrice, PriceMismatch());
        require(_buyer != listing.seller, CannotBuyOwnListing());

        // Calculate fee from payment
        (uint256 fee, uint256 remaining) = _calculateFee(this.buy.selector, _payment);
        // solhint-disable-next-line gas-strict-inequalities
        require(remaining >= listing.price, InsufficientPayment());

        // CEI: delete listing before external calls
        // slither-disable-next-line reentrancy-no-eth
        delete sListings[_nftContract][_bondId];

        // Transfer NFT from seller to buyer (seller approved marketplace in _list)
        // slither-disable-next-line arbitrary-send-erc20,calls-loop
        ICofferBondNft(_nftContract).transferFrom(listing.seller, _buyer, _bondId);

        // Send price to seller
        // slither-disable-next-line arbitrary-send-eth,calls-loop
        (bool okSeller,) = listing.seller.call{value: listing.price}("");
        require(okSeller, InsufficientPayment());

        // Send fee to fee recipient
        if (fee > 0) {
            // slither-disable-next-line arbitrary-send-eth,calls-loop
            (bool okFee,) = sFeeRecipient.call{value: fee}("");
            require(okFee, InsufficientPayment());
            emit FeeCollected(this.buy.selector, fee);
        }

        // Refund any excess to buyer
        uint256 excess = remaining - listing.price;
        if (excess > 0) {
            // slither-disable-next-line arbitrary-send-eth,calls-loop
            (bool okRefund,) = _buyer.call{value: excess}("");
            require(okRefund, InsufficientPayment());
        }

        emit ListingPurchased(_nftContract, _bondId, _buyer, listing.seller, listing.price);
    }

    // ───── Internal: Offer Logic ─────

    function _makeOffer(address _buyer, address _nftContract, uint256 _bondId, uint128 _wethAmount, uint64 _expiration)
        internal
    {
        require(_wethAmount > 0, ZeroAmount());
        require(_expiration > block.timestamp, ExpirationNotInFuture());
        require(_isBondActive(_nftContract, _bondId), BondNotActive());
        // slither-disable-next-line calls-loop
        // solhint-disable-next-line gas-strict-inequalities
        require(IWETH(I_WETH).balanceOf(_buyer) >= _wethAmount, InsufficientWethBalance());
        // slither-disable-next-line calls-loop
        // solhint-disable-next-line gas-strict-inequalities
        require(IWETH(I_WETH).allowance(_buyer, address(this)) >= _wethAmount, InsufficientWethAllowance());

        // slither-disable-next-line reentrancy-no-eth
        sOffers[_nftContract][_bondId][_buyer] =
            Offer({buyer: _buyer, wethAmount: _wethAmount, expiration: _expiration});

        emit OfferMade(_nftContract, _bondId, _buyer, _wethAmount, _expiration);
    }

    function _cancelOffer(address _caller, address _nftContract, uint256 _bondId) internal {
        Offer memory o = sOffers[_nftContract][_bondId][_caller];
        require(o.buyer == _caller, NotBuyer());

        delete sOffers[_nftContract][_bondId][_caller];
        emit OfferCancelled(_nftContract, _bondId, _caller);
    }

    function _acceptOffer(
        address _seller,
        address _nftContract,
        uint256 _bondId,
        address _buyer,
        uint128 _expectedAmount,
        uint256 _ethPayment
    ) internal {
        Offer memory o = sOffers[_nftContract][_bondId][_buyer];
        require(o.buyer != address(0), OfferNotFound());
        // solhint-disable-next-line gas-strict-inequalities
        require(block.timestamp <= o.expiration, OfferExpired());
        require(_isBondActive(_nftContract, _bondId), BondNotActive());
        // slither-disable-next-line calls-loop
        require(ICofferBondNft(_nftContract).ownerOf(_bondId) == _seller, NotOwner());
        require(o.wethAmount == _expectedAmount, AmountMismatch());
        // Verify buyer still has sufficient WETH
        // slither-disable-next-line calls-loop
        // solhint-disable-next-line gas-strict-inequalities
        require(IWETH(I_WETH).balanceOf(_buyer) >= o.wethAmount, InsufficientWethBalance());
        // slither-disable-next-line calls-loop
        // solhint-disable-next-line gas-strict-inequalities
        require(IWETH(I_WETH).allowance(_buyer, address(this)) >= o.wethAmount, InsufficientWethAllowance());
        // Calculate WETH fee
        (uint256 wethFee, uint256 sellerProceeds) = _calculateWethFee(this.acceptOffer.selector, o.wethAmount);

        // CEI: delete offer before external calls
        delete sOffers[_nftContract][_bondId][_buyer];

        // Collect optional ETH fee for acceptOffer action itself
        if (_ethPayment > 0) {
            _collectFee(this.acceptOffer.selector, _ethPayment);
        }

        // Pull WETH from buyer (buyer approved marketplace in _makeOffer)
        // slither-disable-next-line arbitrary-send-erc20
        IERC20(I_WETH).safeTransferFrom(_buyer, address(this), o.wethAmount);

        // Send WETH fee to fee recipient
        if (wethFee > 0) {
            IERC20(I_WETH).safeTransfer(sFeeRecipient, wethFee);
            emit FeeCollected(this.acceptOffer.selector, wethFee);
        }

        // Send WETH proceeds to seller
        IERC20(I_WETH).safeTransfer(_seller, sellerProceeds);
        // Transfer NFT from seller to buyer
        // slither-disable-next-line calls-loop
        ICofferBondNft(_nftContract).transferFrom(_seller, _buyer, _bondId);

        emit OfferAccepted(_nftContract, _bondId, _buyer, _seller, o.wethAmount);
    }

    // ───── Internal: Helpers ─────

    /// @notice Check if a bond is active (maturityValue != 0)
    /// @param _nftContract The NFT contract address
    /// @param _bondId The bond token ID
    /// @return Whether the bond is active
    function _isBondActive(address _nftContract, uint256 _bondId) internal view returns (bool) {
        // slither-disable-next-line calls-loop
        address cofferAddr = ICofferBondNft(_nftContract).cofferOf(_bondId);
        // slither-disable-next-line unused-return,calls-loop
        (uint128 maturityValue,,) = ICoffer(cofferAddr).sHolderConditions(_bondId);
        return maturityValue != 0;
    }
}
