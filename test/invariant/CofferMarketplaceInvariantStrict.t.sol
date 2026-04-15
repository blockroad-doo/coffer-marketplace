// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {CofferMarketplaceInvariantTest} from "./CofferMarketplaceInvariant.t.sol";
import {CofferMarketplaceHandler} from "./CofferMarketplaceHandler.sol";

/// @title CofferMarketplaceInvariantStrictTest
/// @notice Strict variant (fail_on_revert = true).
///         Excludes handlers that intentionally cause reverts so any unexpected
///         revert signals a bug in handler logic.
///         Run with: FOUNDRY_PROFILE=strict forge test --match-path "test/invariant/*"
contract CofferMarketplaceInvariantStrictTest is CofferMarketplaceInvariantTest {
    function setUp() public override {
        super.setUp();

        // Exclude handlers that intentionally create invalid state (causing reverts)
        bytes4[] memory excluded = new bytes4[](2);
        excluded[0] = CofferMarketplaceHandler.handlerSetNonOutstanding.selector;
        excluded[1] = CofferMarketplaceHandler.handlerTransferNft.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: new bytes4[](0)}));
        excludeSelector(FuzzSelector({addr: address(handler), selectors: excluded}));
    }
}
