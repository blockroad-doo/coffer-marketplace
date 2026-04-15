//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICofferBondNft} from "./interfaces/ICofferBondNft.sol";
import {ICoffer} from "./interfaces/ICoffer.sol";
import {IWETH} from "./interfaces/IWETH.sol";

/// @title CofferMarketplace
/// @author Coffer
/// @notice Secondary marketplace for Coffer bond NFTs — listings (ETH) and offers (WETH)
contract CofferMarketplace is ReentrancyGuard {
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

    // ───── Structs ─────

    struct Listing {
        address seller;
        uint128 price;
        uint64 expiration;
    }

    struct Offer {
        address buyer;
        uint128 wethAmount;
        uint64 expiration;
    }

    // ───── State ─────

    /// @notice Immutable WETH token contract address
    address public immutable I_WETH;
    /// @notice Immutable CofferBondNft contract address
    address public immutable I_COFFER_BOND_NFT;

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
    event ListingPurchased(uint256 indexed bondId, address indexed buyer, address indexed seller, uint128 price);

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
    event OfferAccepted(uint256 indexed bondId, address indexed buyer, address indexed seller, uint128 wethAmount);

    // ───── Constructor ─────

    constructor(address _weth, address _cofferBondNft) {
        require(_weth != address(0), ZeroAddress());
        require(_cofferBondNft != address(0), ZeroAddress());
        I_WETH = _weth;
        I_COFFER_BOND_NFT = _cofferBondNft;
    }

    // ───── Listing Functions ─────

    /// @notice List a bond NFT for sale
    /// @param _bondId The bond token ID to list
    /// @param _price The listing price in wei
    /// @param _expiration The listing expiration timestamp
    function list(uint256 _bondId, uint128 _price, uint64 _expiration) external {
        _list(msg.sender, _bondId, _price, _expiration);
    }

    /// @notice Cancel an active listing
    /// @param _bondId The bond token ID to cancel
    function cancelListing(uint256 _bondId) external {
        _cancelListing(msg.sender, _bondId);
    }

    /// @notice Purchase a listed bond NFT
    /// @param _bondId The bond token ID to purchase
    /// @param _expectedPrice The expected listing price to prevent front-running
    function buy(uint256 _bondId, uint128 _expectedPrice) external payable nonReentrant {
        _buy(msg.sender, _bondId, _expectedPrice, msg.value);
    }

    // ───── Offer Functions ─────

    /// @notice Make a WETH offer on a bond NFT
    /// @param _bondId The bond token ID to make an offer on
    /// @param _wethAmount The WETH amount to offer
    /// @param _expiration The offer expiration timestamp
    function makeOffer(uint256 _bondId, uint128 _wethAmount, uint64 _expiration) external {
        _makeOffer(msg.sender, _bondId, _wethAmount, _expiration);
    }

    /// @notice Cancel an active offer
    /// @param _bondId The bond token ID to cancel the offer for
    function cancelOffer(uint256 _bondId) external {
        _cancelOffer(msg.sender, _bondId);
    }

    /// @notice Accept a WETH offer on a bond NFT you own
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
    function batchList(uint256[] calldata _bondIds, uint128[] calldata _prices, uint64[] calldata _expirations)
        external
        nonReentrant
    {
        uint256 len = _bondIds.length;
        require(len == _prices.length && len == _expirations.length, ArrayLengthMismatch());

        for (uint256 i; i < len; ++i) {
            _list(msg.sender, _bondIds[i], _prices[i], _expirations[i]);
        }
    }

    /// @notice Batch buy multiple listed bond NFTs
    /// @param _bondIds The bond token IDs to purchase
    /// @param _expectedPrices The expected listing prices to prevent front-running
    function batchBuy(uint256[] calldata _bondIds, uint128[] calldata _expectedPrices) external payable nonReentrant {
        uint256 len = _bondIds.length;
        require(len == _expectedPrices.length, ArrayLengthMismatch());

        uint256 totalRemaining = msg.value;
        for (uint256 i; i < len; ++i) {
            // solhint-disable-next-line gas-strict-inequalities
            require(totalRemaining >= _expectedPrices[i], InsufficientPayment());
            _buy(msg.sender, _bondIds[i], _expectedPrices[i], _expectedPrices[i]);
            totalRemaining -= _expectedPrices[i];
        }

        // Refund excess
        if (totalRemaining > 0) {
            // slither-disable-next-line arbitrary-send-eth
            require(_safeTransferETH(msg.sender, totalRemaining), InsufficientPayment());
        }
    }

    /// @notice Batch cancel multiple listings
    /// @param _bondIds The bond token IDs to cancel
    function batchCancelListings(uint256[] calldata _bondIds) external {
        for (uint256 i; i < _bondIds.length; ++i) {
            _cancelListing(msg.sender, _bondIds[i]);
        }
    }

    /// @notice Batch make multiple WETH offers
    /// @param _bondIds The bond token IDs to make offers on
    /// @param _wethAmounts The WETH amounts to offer
    /// @param _expirations The offer expiration timestamps
    function batchMakeOffers(
        uint256[] calldata _bondIds,
        uint128[] calldata _wethAmounts,
        uint64[] calldata _expirations
    ) external nonReentrant {
        uint256 len = _bondIds.length;
        require(len == _wethAmounts.length && len == _expirations.length, ArrayLengthMismatch());

        for (uint256 i; i < len; ++i) {
            _makeOffer(msg.sender, _bondIds[i], _wethAmounts[i], _expirations[i]);
        }
    }

    /// @notice Batch cancel multiple offers
    /// @param _bondIds The bond token IDs to cancel offers for
    function batchCancelOffers(uint256[] calldata _bondIds) external {
        for (uint256 i; i < _bondIds.length; ++i) {
            _cancelOffer(msg.sender, _bondIds[i]);
        }
    }

    /// @notice Batch accept multiple WETH offers
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

    /// @notice Check if an offer is currently valid
    /// @param _bondId The bond token ID
    /// @param _buyer The address of the offer maker
    /// @return Whether the offer is valid
    function isOfferValid(uint256 _bondId, address _buyer) external view returns (bool) {
        Offer memory o = sOffers[_bondId][_buyer];
        if (o.buyer == address(0)) return false;
        if (block.timestamp > o.expiration) return false;
        if (IWETH(I_WETH).balanceOf(_buyer) < o.wethAmount) return false;
        if (IWETH(I_WETH).allowance(_buyer, address(this)) < o.wethAmount) return false;
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
        (maturityValue, duration, startTimestamp) = ICoffer(cofferAddress).sHolderConditions(_bondId);
    }

    // ───── Internal: Listing Logic ─────

    function _list(address _seller, uint256 _bondId, uint128 _price, uint64 _expiration) internal {
        require(_price > 0, ZeroPrice());
        require(_expiration > block.timestamp, ExpirationNotInFuture());
        // slither-disable-next-line calls-loop
        require(ICofferBondNft(I_COFFER_BOND_NFT).ownerOf(_bondId) == _seller, NotOwner());
        require(_isBondOutstanding(_bondId), BondNotOutstanding());
        // slither-disable-next-line calls-loop
        require(ICofferBondNft(I_COFFER_BOND_NFT).isApprovedForAll(_seller, address(this)), MarketplaceNotApproved());

        // Emit cancellation if overwriting a stale listing from a different seller
        Listing memory existing = sListings[_bondId];
        if (existing.seller != address(0) && existing.seller != _seller) {
            emit ListingCancelled(_bondId, existing.seller);
        }

        // slither-disable-next-line reentrancy-no-eth
        sListings[_bondId] = Listing({seller: _seller, price: _price, expiration: _expiration});

        emit Listed(_bondId, _seller, _price, _expiration);
    }

    function _cancelListing(address _caller, uint256 _bondId) internal {
        Listing memory listing = sListings[_bondId];
        require(listing.seller == _caller, NotSeller());

        // slither-disable-next-line costly-loop
        delete sListings[_bondId];
        emit ListingCancelled(_bondId, _caller);
    }

    function _buy(address _buyer, uint256 _bondId, uint128 _expectedPrice, uint256 _payment) internal {
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
        // solhint-disable-next-line gas-strict-inequalities
        require(_payment >= listing.price, InsufficientPayment());

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

        // Refund any excess to buyer
        uint256 excess = _payment - listing.price;
        if (excess > 0) {
            // slither-disable-next-line arbitrary-send-eth,calls-loop
            require(_safeTransferETH(_buyer, excess), InsufficientPayment());
        }

        emit ListingPurchased(_bondId, _buyer, listing.seller, listing.price);
    }

    // ───── Internal: Offer Logic ─────

    function _makeOffer(address _buyer, uint256 _bondId, uint128 _wethAmount, uint64 _expiration) internal {
        require(_wethAmount > 0, ZeroAmount());
        require(_expiration > block.timestamp, ExpirationNotInFuture());
        require(_isBondOutstanding(_bondId), BondNotOutstanding());
        // slither-disable-next-line calls-loop
        // solhint-disable-next-line gas-strict-inequalities
        require(IWETH(I_WETH).balanceOf(_buyer) >= _wethAmount, InsufficientWethBalance());
        // slither-disable-next-line calls-loop
        // solhint-disable-next-line gas-strict-inequalities
        require(IWETH(I_WETH).allowance(_buyer, address(this)) >= _wethAmount, InsufficientWethAllowance());

        // slither-disable-next-line reentrancy-no-eth
        sOffers[_bondId][_buyer] = Offer({buyer: _buyer, wethAmount: _wethAmount, expiration: _expiration});

        emit OfferMade(_bondId, _buyer, _wethAmount, _expiration);
    }

    function _cancelOffer(address _caller, uint256 _bondId) internal {
        Offer memory o = sOffers[_bondId][_caller];
        require(o.buyer == _caller, NotBuyer());

        delete sOffers[_bondId][_caller];
        emit OfferCancelled(_bondId, _caller);
    }

    function _acceptOffer(address _seller, uint256 _bondId, address _buyer, uint128 _expectedAmount) internal {
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
        // Verify buyer still has sufficient WETH
        // slither-disable-next-line calls-loop
        // solhint-disable-next-line gas-strict-inequalities
        require(IWETH(I_WETH).balanceOf(_buyer) >= o.wethAmount, InsufficientWethBalance());
        // slither-disable-next-line calls-loop
        // solhint-disable-next-line gas-strict-inequalities
        require(IWETH(I_WETH).allowance(_buyer, address(this)) >= o.wethAmount, InsufficientWethAllowance());

        // CEI: delete offer before external calls
        delete sOffers[_bondId][_buyer];

        // Transfer full WETH from buyer to seller (no fee deduction)
        // slither-disable-next-line arbitrary-send-erc20
        IERC20(I_WETH).safeTransferFrom(_buyer, _seller, o.wethAmount);

        // Transfer NFT from seller to buyer
        // slither-disable-next-line calls-loop
        ICofferBondNft(I_COFFER_BOND_NFT).safeTransferFrom(_seller, _buyer, _bondId);

        emit OfferAccepted(_bondId, _buyer, _seller, o.wethAmount);
    }

    // ───── Internal: Helpers ─────

    /// @notice Check if a bond is outstanding (maturityValue != 0)
    /// @param _bondId The bond token ID
    /// @return Whether the bond is outstanding
    function _isBondOutstanding(uint256 _bondId) internal view returns (bool) {
        // slither-disable-next-line calls-loop
        address cofferAddr = ICofferBondNft(I_COFFER_BOND_NFT).cofferOf(_bondId);
        // slither-disable-next-line unused-return,calls-loop
        (uint128 maturityValue,,) = ICoffer(cofferAddr).sHolderConditions(_bondId);
        return maturityValue != 0;
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
