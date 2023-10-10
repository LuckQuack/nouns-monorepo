// SPDX-License-Identifier: GPL-3.0

/// @title The Nouns DAO auction house

/*********************************
 * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ *
 * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ *
 * ░░░░░░█████████░░█████████░░░ *
 * ░░░░░░██░░░████░░██░░░████░░░ *
 * ░░██████░░░████████░░░████░░░ *
 * ░░██░░██░░░████░░██░░░████░░░ *
 * ░░██░░██░░░████░░██░░░████░░░ *
 * ░░░░░░█████████░░█████████░░░ *
 * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ *
 * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ *
 *********************************/

// LICENSE
// NounsAuctionHouse.sol is a modified version of Zora's AuctionHouse.sol:
// https://github.com/ourzora/auction-house/blob/54a12ec1a6cf562e49f0a4917990474b11350a2d/contracts/AuctionHouse.sol
//
// AuctionHouse.sol source code Copyright Zora licensed under the GPL-3.0 license.
// With modifications by Nounders DAO.

pragma solidity ^0.8.19;

import { PausableUpgradeable } from '@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol';
import { ReentrancyGuardUpgradeable } from '@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol';
import { OwnableUpgradeable } from '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';
import { IERC20 } from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import { INounsAuctionHouseV2 } from './interfaces/INounsAuctionHouseV2.sol';
import { INounsToken } from './interfaces/INounsToken.sol';
import { IWETH } from './interfaces/IWETH.sol';

/**
 * @dev The contract inherits from PausableUpgradeable & ReentrancyGuardUpgradeable most of all the keep the same
 * storage layout as the NounsAuctionHouse contract
 */
contract NounsAuctionHouseV2 is
    INounsAuctionHouseV2,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable
{
    /// @notice A hard-coded cap on time buffer to prevent accidental auction disabling if set with a very high value.
    uint56 public constant MAX_TIME_BUFFER = 1 days;

    /// @notice The Nouns ERC721 token contract
    INounsToken public immutable nouns;

    /// @notice The address of the WETH contract
    address public immutable weth;

    /// @notice The duration of a single auction
    uint256 public immutable duration;

    /// @notice The minimum price accepted in an auction
    uint192 public reservePrice;

    /// @notice The minimum amount of time left in an auction after a new bid is created
    uint56 public timeBuffer;

    /// @notice The minimum percentage difference between the last bid amount and the current bid
    uint8 public minBidIncrementPercentage;

    /// @notice The active auction
    INounsAuctionHouseV2.AuctionV2 public auctionStorage;

    /// @notice Whether this contract is paused or not
    /// @dev Replaces the state variable from PausableUpgradeable, to bit pack this bool with `auction` and save gas
    bool public __paused;

    /// @notice The Nouns price feed state
    mapping(uint256 => SettlementState) settlementHistory;

    constructor(
        INounsToken _nouns,
        address _weth,
        uint256 _duration
    ) {
        nouns = _nouns;
        weth = _weth;
        duration = _duration;
    }

    /**
     * @notice Initialize the auction house and base contracts,
     * populate configuration values, and pause the contract.
     * @dev This function can only be called once.
     */
    function initialize(
        uint192 _reservePrice,
        uint56 _timeBuffer,
        uint8 _minBidIncrementPercentage
    ) external initializer {
        __Pausable_init();
        __ReentrancyGuard_init();
        __Ownable_init();

        _pause();

        reservePrice = _reservePrice;
        timeBuffer = _timeBuffer;
        minBidIncrementPercentage = _minBidIncrementPercentage;
    }

    /**
     * @notice Settle the current auction, mint a new Noun, and put it up for auction.
     */
    function settleCurrentAndCreateNewAuction() external override whenNotPaused {
        _settleAuction();
        _createAuction();
    }

    /**
     * @notice Settle the current auction.
     * @dev This function can only be called when the contract is paused.
     */
    function settleAuction() external override whenPaused {
        _settleAuction();
    }

    /**
     * @notice Create a bid for a Noun, with a given amount.
     * @dev This contract only accepts payment in ETH.
     */
    function createBid(uint256 nounId) external payable override {
        INounsAuctionHouseV2.AuctionV2 memory _auction = auctionStorage;

        (uint192 _reservePrice, uint56 _timeBuffer, uint8 _minBidIncrementPercentage) = (
            reservePrice,
            timeBuffer,
            minBidIncrementPercentage
        );

        require(_auction.nounId == nounId, 'Noun not up for auction');
        require(block.timestamp < _auction.endTime, 'Auction expired');
        require(msg.value >= _reservePrice, 'Must send at least reservePrice');
        require(
            msg.value >= _auction.amount + ((_auction.amount * _minBidIncrementPercentage) / 100),
            'Must send more than last bid by minBidIncrementPercentage amount'
        );

        auctionStorage.amount = uint128(msg.value);
        auctionStorage.bidder = payable(msg.sender);

        // Extend the auction if the bid was received within `timeBuffer` of the auction end time
        bool extended = _auction.endTime - block.timestamp < _timeBuffer;

        emit AuctionBid(_auction.nounId, msg.sender, msg.value, extended);

        if (extended) {
            auctionStorage.endTime = _auction.endTime = uint40(block.timestamp + _timeBuffer);
            emit AuctionExtended(_auction.nounId, _auction.endTime);
        }

        address payable lastBidder = _auction.bidder;

        // Refund the last bidder, if applicable
        if (lastBidder != address(0)) {
            _safeTransferETHWithFallback(lastBidder, _auction.amount);
        }
    }

    /**
     * @notice Get the current auction.
     */
    function auction() external view returns (AuctionV2 memory) {
        return auctionStorage;
    }

    /**
     * @notice Pause the Nouns auction house.
     * @dev This function can only be called by the owner when the
     * contract is unpaused. While no new auctions can be started when paused,
     * anyone can settle an ongoing auction.
     */
    function pause() external override onlyOwner {
        __paused = true;
        emit Paused(_msgSender());
    }

    /**
     * @notice Unpause the Nouns auction house.
     * @dev This function can only be called by the owner when the
     * contract is paused. If required, this function will start a new auction.
     */
    function unpause() external override onlyOwner {
        __paused = false;
        emit Unpaused(_msgSender());

        if (auctionStorage.startTime == 0 || auctionStorage.settled) {
            _createAuction();
        }
    }

    /**
     * @dev Get whether this contract is paused or not.
     */
    function paused() public view override returns (bool) {
        return __paused;
    }

    /**
     * @notice Set the auction time buffer.
     * @dev Only callable by the owner.
     */
    function setTimeBuffer(uint56 _timeBuffer) external override onlyOwner {
        require(_timeBuffer <= MAX_TIME_BUFFER, 'timeBuffer too large');

        timeBuffer = _timeBuffer;

        emit AuctionTimeBufferUpdated(_timeBuffer);
    }

    /**
     * @notice Set the auction reserve price.
     * @dev Only callable by the owner.
     */
    function setReservePrice(uint192 _reservePrice) external override onlyOwner {
        reservePrice = _reservePrice;

        emit AuctionReservePriceUpdated(_reservePrice);
    }

    /**
     * @notice Set the auction minimum bid increment percentage.
     * @dev Only callable by the owner.
     */
    function setMinBidIncrementPercentage(uint8 _minBidIncrementPercentage) external override onlyOwner {
        minBidIncrementPercentage = _minBidIncrementPercentage;

        emit AuctionMinBidIncrementPercentageUpdated(_minBidIncrementPercentage);
    }

    /**
     * @notice Create an auction.
     * @dev Store the auction details in the `auction` state variable and emit an AuctionCreated event.
     * If the mint reverts, the minter was updated without pausing this contract first. To remedy this,
     * catch the revert and pause this contract.
     */
    function _createAuction() internal {
        try nouns.mint() returns (uint256 nounId) {
            uint40 startTime = uint40(block.timestamp);
            uint40 endTime = startTime + uint40(duration);

            auctionStorage = AuctionV2({
                nounId: uint128(nounId),
                amount: 0,
                startTime: startTime,
                endTime: endTime,
                bidder: payable(0),
                settled: false
            });

            emit AuctionCreated(nounId, startTime, endTime);
        } catch Error(string memory) {
            _pause();
        }
    }

    /**
     * @notice Settle an auction, finalizing the bid and paying out to the owner.
     * @dev If there are no bids, the Noun is burned.
     */
    function _settleAuction() internal {
        INounsAuctionHouseV2.AuctionV2 memory _auction = auctionStorage;

        require(_auction.startTime != 0, "Auction hasn't begun");
        require(!_auction.settled, 'Auction has already been settled');
        require(block.timestamp >= _auction.endTime, "Auction hasn't completed");

        auctionStorage.settled = true;

        if (_auction.bidder == address(0)) {
            nouns.burn(_auction.nounId);
        } else {
            nouns.transferFrom(address(this), _auction.bidder, _auction.nounId);
        }

        if (_auction.amount > 0) {
            _safeTransferETHWithFallback(owner(), _auction.amount);
        }

        settlementHistory[_auction.nounId] = SettlementState({
            blockTimestamp: uint32(block.timestamp),
            amount: ethPriceToUint64(_auction.amount),
            winner: _auction.bidder
        });

        emit AuctionSettled(_auction.nounId, _auction.bidder, _auction.amount);
    }

    /**
     * @notice Transfer ETH. If the ETH transfer fails, wrap the ETH and try send it as WETH.
     */
    function _safeTransferETHWithFallback(address to, uint256 amount) internal {
        if (!_safeTransferETH(to, amount)) {
            IWETH(weth).deposit{ value: amount }();
            IERC20(weth).transfer(to, amount);
        }
    }

    /**
     * @notice Transfer ETH and return the success status.
     * @dev This function only forwards 30,000 gas to the callee.
     */
    function _safeTransferETH(address to, uint256 value) internal returns (bool) {
        bool success;
        assembly {
            success := call(30000, to, value, 0, 0, 0, 0)
        }
        return success;
    }

    /**
     * @notice Set historic prices; only callable by the owner, which in Nouns is the treasury (timelock) contract.
     * @dev This function lowers auction price accuracy from 18 decimals to 10 decimals, as part of the price history
     * bit packing, to save gas.
     * @param settlements The list of historic prices to set.
     */
    function setPrices(Settlement[] memory settlements) external onlyOwner {
        uint256[] memory nounIds = new uint256[](settlements.length);
        uint256[] memory prices_ = new uint256[](settlements.length);

        for (uint256 i = 0; i < settlements.length; ++i) {
            settlementHistory[settlements[i].nounId] = SettlementState({
                blockTimestamp: settlements[i].blockTimestamp,
                amount: ethPriceToUint64(settlements[i].amount),
                winner: settlements[i].winner
            });

            nounIds[i] = settlements[i].nounId;
            prices_[i] = settlements[i].amount;
        }

        emit HistoricPricesSet(nounIds, prices_);
    }

    /**
     * @notice Warm up the settlement state for a list of Noun IDs.
     * @dev Helps lower the gas cost of auction settlement when storing settlement data
     * thanks to the state slot being non-zero.
     * @dev Only writes to slots where blockTimestamp is zero, meaning it will not overwrite existing data.
     * @param nounIds The list of Noun IDs whose settlement slot to warm up.
     */
    function warmUpSettlementState(uint256[] calldata nounIds) external {
        for (uint256 i = 0; i < nounIds.length; ++i) {
            if (settlementHistory[nounIds[i]].blockTimestamp == 0) {
                settlementHistory[nounIds[i]] = SettlementState({ blockTimestamp: 1, amount: 0, winner: address(0) });
            }
        }
    }

    /**
     * @notice Get past auction settlements.
     * @dev Returns settlements in reverse order, meaning settlements[0] will be the most recent auction price.
     * Skips auctions where there was no winner, i.e. no bids.
     * @param auctionCount The number of price observations to get.
     * @return settlements An array of type `Settlement`, where each Settlement includes a timestamp,
     * the Noun ID of that auction, the winning bid amount, and the winner's address.
     */
    function getSettlements(uint256 auctionCount) external view returns (Settlement[] memory settlements) {
        uint256 latestNounId = auctionStorage.nounId;
        if (!auctionStorage.settled && latestNounId > 0) {
            latestNounId -= 1;
        }

        settlements = new Settlement[](auctionCount);
        uint256 actualCount = 0;
        while (actualCount < auctionCount && latestNounId > 0) {
            SettlementState memory settlementState = settlementHistory[latestNounId];
            // Skip Nouner reward Nouns, they have no price
            // Also skips IDs with no price data
            if (settlementState.winner == address(0)) {
                --latestNounId;
                continue;
            }

            settlements[actualCount] = Settlement({
                blockTimestamp: settlementState.blockTimestamp,
                amount: uint64PriceToUint256(settlementState.amount),
                winner: settlementState.winner,
                nounId: latestNounId
            });
            ++actualCount;
            --latestNounId;
        }

        if (auctionCount > actualCount) {
            // this assembly trims the observations array, getting rid of unused cells
            assembly {
                mstore(settlements, actualCount)
            }
        }
    }

    /**
     * @notice Get past auction prices.
     * @dev Returns prices in reverse order, meaning prices[0] will be the most recent auction price.
     * Skips auctions where there was no winner, i.e. no bids.
     * @param auctionCount The number of price observations to get.
     * @return prices An array of uint256 prices.
     */
    function getPrices(uint256 auctionCount) external view returns (uint256[] memory prices) {
        uint256 latestNounId = auctionStorage.nounId;
        if (!auctionStorage.settled && latestNounId > 0) {
            latestNounId -= 1;
        }

        prices = new uint256[](auctionCount);
        uint256 actualCount = 0;
        while (actualCount < auctionCount && latestNounId > 0) {
            SettlementState memory settlementState = settlementHistory[latestNounId];
            // Skip Nouner reward Nouns, they have no price
            // Also skips IDs with no price data
            if (settlementState.winner == address(0)) {
                --latestNounId;
                continue;
            }

            prices[actualCount] = uint64PriceToUint256(settlementState.amount);
            ++actualCount;
            --latestNounId;
        }

        if (auctionCount > actualCount) {
            // this assembly trims the observations array, getting rid of unused cells
            assembly {
                mstore(prices, actualCount)
            }
        }
    }

    /**
     * @notice Get a range of past auction settlements.
     * @dev Returns prices in chronological order, as opposed to `getSettlements(count)` which returns prices in reverse order.
     * Skips auctions where there was no winner, i.e. no bids.
     * @param startId the first Noun ID to get prices for.
     * @param endId end Noun ID (up to, but not including).
     * @return settlements An array of type `Settlement`, where each Settlement includes a timestamp,
     * the Noun ID of that auction, the winning bid amount, and the winner's address.
     */
    function getSettlements(uint256 startId, uint256 endId) external view returns (Settlement[] memory settlements) {
        settlements = new Settlement[](endId - startId);
        uint256 actualCount = 0;
        uint256 currentId = startId;
        while (currentId < endId) {
            SettlementState memory settlementState = settlementHistory[currentId];
            // Skip Nouner reward Nouns, they have no price
            // Also skips IDs with no price data
            if (settlementState.winner == address(0)) {
                ++currentId;
                continue;
            }

            settlements[actualCount] = Settlement({
                blockTimestamp: settlementState.blockTimestamp,
                amount: uint64PriceToUint256(settlementState.amount),
                winner: settlementState.winner,
                nounId: currentId
            });
            ++actualCount;
            ++currentId;
        }

        if (settlements.length > actualCount) {
            // this assembly trims the observations array, getting rid of unused cells
            assembly {
                mstore(settlements, actualCount)
            }
        }
    }

    /**
     * @notice Get a range of past auction prices.
     * @dev Returns prices in chronological order, as opposed to `getPrices(count)` which returns prices in reverse order.
     * Skips auctions where there was no winner, i.e. no bids.
     * @param startId the first Noun ID to get prices for.
     * @param endId end Noun ID (up to, but not including).
     * @return prices An array of uint256 prices.
     */
    function getPrices(uint256 startId, uint256 endId) external view returns (uint256[] memory prices) {
        prices = new uint256[](endId - startId);
        uint256 actualCount = 0;
        uint256 currentId = startId;
        while (currentId < endId) {
            SettlementState memory settlementState = settlementHistory[currentId];
            // Skip Nouner reward Nouns, they have no price
            // Also skips IDs with no price data
            if (settlementState.winner == address(0)) {
                ++currentId;
                continue;
            }

            prices[actualCount] = uint64PriceToUint256(settlementState.amount);
            ++actualCount;
            ++currentId;
        }

        if (prices.length > actualCount) {
            // this assembly trims the observations array, getting rid of unused cells
            assembly {
                mstore(prices, actualCount)
            }
        }
    }

    /**
     * @dev Convert an ETH price of 256 bits with 18 decimals, to 64 bits with 10 decimals.
     * Max supported value is 1844674407.3709551615 ETH.
     *
     */
    function ethPriceToUint64(uint256 ethPrice) internal pure returns (uint64) {
        return uint64(ethPrice / 1e8);
    }

    /**
     * @dev Convert a 64 bit 10 decimal price to a 256 bit 18 decimal price.
     */
    function uint64PriceToUint256(uint64 price) internal pure returns (uint256) {
        return uint256(price) * 1e8;
    }
}
