// SPDX-License-Identifier: GPL-3.0

/// @title Stream Escrow

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

pragma solidity ^0.8.19;

import { IStreamEscrow } from './interfaces/IStreamEscrow.sol';
import { INounsToken } from './interfaces/INounsToken.sol';

contract StreamEscrow is IStreamEscrow {
    struct Stream {
        uint256 ethPerAuction;
        bool canceled;
        uint256 streamEndId;
    }

    address public daoTreasury;
    address public auctionHouse;
    INounsToken public nounsToken; // TODO immutable?

    uint256 public ethStreamedPerAuction;
    uint256 public ethStreamedToDAO;
    uint256 public ethWithdrawn;
    mapping(uint256 streamEndId => uint256[] streamIds) public streamEndIds;
    mapping(uint256 streamId => Stream) streams;
    uint256 public auctionsCounter;

    constructor(address daoTreasury_, address auctionHouse_, address nounsToken_) {
        daoTreasury = daoTreasury_;
        auctionHouse = auctionHouse_;
        nounsToken = INounsToken(nounsToken_);
    }

    function createStreamAndForwardAll(uint256 nounId, uint16 streamLengthInAuctions) external payable {
        require(msg.sender == auctionHouse, 'only auction house');

        // register new stream
        uint256 streamEndId = auctionsCounter + streamLengthInAuctions + 1;
        streamEndIds[streamEndId].push(nounId);

        // TODO: check for rounding issues. probably best to immediately vest the rounded down amount
        uint256 ethPerAuction = msg.value / streamLengthInAuctions;
        ethStreamedPerAuction += ethPerAuction;
        streams[nounId] = Stream({ ethPerAuction: ethPerAuction, canceled: false, streamEndId: streamEndId });

        forwardAll();
    }

    // used for example when there were no bids on a noun
    function forwardAll() public {
        require(msg.sender == auctionHouse, 'only auction house');

        auctionsCounter++;
        finishStreams();
        ethStreamedToDAO += ethStreamedPerAuction;
    }

    // TODO add versions with uint256[] nounIds?
    function cancelStream(uint256 nounId) external {
        // transfer noun to treasury
        nounsToken.transferFrom(msg.sender, daoTreasury, nounId);

        // cancel stream
        require(!streams[nounId].canceled, 'already canceled');
        streams[nounId].canceled = true;
        ethStreamedPerAuction -= streams[nounId].ethPerAuction;

        // calculate how much needs to be refunded
        // TODO: assuming lastSeenNounId < streamEndId, but need to handle the other case
        uint256 auctionsLeft = streams[nounId].streamEndId - auctionsCounter - 1;
        uint256 amountToRefund = streams[nounId].ethPerAuction * auctionsLeft;
        (bool sent, ) = msg.sender.call{ value: amountToRefund }('');
        require(sent, 'failed to send eth');
    }

    function withdrawToTreasury(uint256 amount) external {
        require(msg.sender == daoTreasury);
        require(amount >= (ethStreamedToDAO - ethWithdrawn), 'not enough to withdraw');
        ethWithdrawn += amount;
        (bool sent, ) = daoTreasury.call{ value: amount }('');
        require(sent, 'failed to send eth');
    }

    function setDAOTreasuryAddress(address newAddress) external {
        require(msg.sender == daoTreasury);
        daoTreasury = newAddress;
    }

    function finishStreams() internal {
        uint256[] storage endingStreams = streamEndIds[auctionsCounter];
        for (uint256 i; i < endingStreams.length; i++) {
            uint256 streamId = endingStreams[i];
            if (!streams[streamId].canceled) {
                ethStreamedPerAuction -= streams[streamId].ethPerAuction;
            }
        }
    }
}
