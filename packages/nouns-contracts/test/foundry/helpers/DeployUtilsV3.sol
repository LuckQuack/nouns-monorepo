// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import 'forge-std/Test.sol';
import { DeployUtils } from './DeployUtils.sol';
import { INounsDAOLogicV3 } from '../../../contracts/interfaces/INounsDAOLogicV3.sol';
import { NounsDAOLogicV3 } from '../../../contracts/governance/NounsDAOLogicV3.sol';
import { NounsDAOProxyV3 } from '../../../contracts/governance/NounsDAOProxyV3.sol';
import { NounsDAOForkEscrow } from '../../../contracts/governance/fork/NounsDAOForkEscrow.sol';
import { NounsDAOExecutorV2 } from '../../../contracts/governance/NounsDAOExecutorV2.sol';
import { ERC1967Proxy } from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';
import { NounsAuctionHouse } from '../../../contracts/NounsAuctionHouse.sol';
import { NounsAuctionHouseProxy } from '../../../contracts/proxies/NounsAuctionHouseProxy.sol';
import { NounsAuctionHouseProxyAdmin } from '../../../contracts/proxies/NounsAuctionHouseProxyAdmin.sol';
import { NounsToken } from '../../../contracts/NounsToken.sol';
import { NounsSeeder } from '../../../contracts/NounsSeeder.sol';
import { ProxyRegistryMock } from './ProxyRegistryMock.sol';
import { ForkDAODeployer } from '../../../contracts/governance/fork/ForkDAODeployer.sol';
import { NounsTokenFork } from '../../../contracts/governance/fork/newdao/token/NounsTokenFork.sol';
import { NounsAuctionHouseFork } from '../../../contracts/governance/fork/newdao/NounsAuctionHouseFork.sol';
import { NounsDAOLogicV1Fork } from '../../../contracts/governance/fork/newdao/governance/NounsDAOLogicV1Fork.sol';
import { NounsDAOV3Types } from '../../../contracts/governance/NounsDAOInterfaces.sol';
import { INounsDAOLogicV3 } from '../../../contracts/interfaces/INounsDAOLogicV3.sol';

contract DeployUtilsV3 is DeployUtils {
    NounsAuctionHouseProxyAdmin public auctionHouseProxyAdmin;

    function _createDAOV3Proxy(
        address timelock,
        address nounsToken,
        address vetoer,
        NounsDAOV3Types.NounsDAOParams memory daoParams,
        NounsDAOV3Types.DynamicQuorumParams memory dqParams
    ) internal returns (INounsDAOLogicV3 dao) {
        uint256 nonce = vm.getNonce(address(this));
        address predictedForkEscrowAddress = computeCreateAddress(address(this), nonce + 2);
        dao = INounsDAOLogicV3(
            address(
                new NounsDAOProxyV3(
                    timelock,
                    nounsToken,
                    predictedForkEscrowAddress,
                    address(0),
                    vetoer,
                    timelock,
                    address(new NounsDAOLogicV3()),
                    daoParams,
                    dqParams
                )
            )
        );
        address(new NounsDAOForkEscrow(address(dao), address(nounsToken)));
    }

    function _createDAOV3Proxy(
        address timelock,
        address nounsToken,
        address vetoer
    ) internal returns (INounsDAOLogicV3 dao) {
        dao = _createDAOV3Proxy(
            timelock,
            nounsToken,
            vetoer,
            NounsDAOV3Types.NounsDAOParams({
                votingPeriod: VOTING_PERIOD,
                votingDelay: VOTING_DELAY,
                proposalThresholdBPS: PROPOSAL_THRESHOLD,
                lastMinuteWindowInBlocks: LAST_MINUTE_BLOCKS,
                objectionPeriodDurationInBlocks: OBJECTION_PERIOD_BLOCKS,
                proposalUpdatablePeriodInBlocks: 0
            }),
            NounsDAOV3Types.DynamicQuorumParams({
                minQuorumVotesBPS: 200,
                maxQuorumVotesBPS: 2000,
                quorumCoefficient: 10000
            })
        );
    }

    struct Temp {
        NounsDAOExecutorV2 timelock;
        NounsToken nounsToken;
    }

    function _deployDAOV3WithParams(uint256 auctionDuration) public returns (INounsDAOLogicV3) {
        Temp memory t;
        t.timelock = NounsDAOExecutorV2(payable(address(new ERC1967Proxy(address(new NounsDAOExecutorV2()), ''))));
        t.timelock.initialize(address(1), TIMELOCK_DELAY);

        auctionHouseProxyAdmin = new NounsAuctionHouseProxyAdmin();
        NounsAuctionHouseProxy auctionProxy = new NounsAuctionHouseProxy(
            address(new NounsAuctionHouse()),
            address(auctionHouseProxyAdmin),
            ''
        );
        auctionHouseProxyAdmin.transferOwnership(address(t.timelock));

        t.nounsToken = new NounsToken(
            makeAddr('noundersDAO'),
            address(auctionProxy),
            _deployAndPopulateV2(),
            new NounsSeeder(),
            new ProxyRegistryMock()
        );
        t.nounsToken.transferOwnership(address(t.timelock));
        address daoLogicImplementation = address(new NounsDAOLogicV3());

        uint256 nonce = vm.getNonce(address(this));
        address predictedForkEscrowAddress = computeCreateAddress(address(this), nonce + 6);

        ForkDAODeployer forkDeployer = new ForkDAODeployer(
            address(new NounsTokenFork()),
            address(new NounsAuctionHouseFork()),
            address(new NounsDAOLogicV1Fork()),
            address(new NounsDAOExecutorV2()),
            DELAYED_GOV_DURATION,
            FORK_DAO_VOTING_PERIOD,
            FORK_DAO_VOTING_DELAY,
            FORK_DAO_PROPOSAL_THRESHOLD_BPS,
            FORK_DAO_QUORUM_VOTES_BPS
        );

        INounsDAOLogicV3 dao = INounsDAOLogicV3(
            payable(
                new NounsDAOProxyV3(
                    address(t.timelock),
                    address(t.nounsToken),
                    predictedForkEscrowAddress,
                    address(forkDeployer),
                    makeAddr('vetoer'),
                    address(t.timelock),
                    daoLogicImplementation,
                    NounsDAOV3Types.NounsDAOParams({
                        votingPeriod: VOTING_PERIOD,
                        votingDelay: VOTING_DELAY,
                        proposalThresholdBPS: PROPOSAL_THRESHOLD,
                        lastMinuteWindowInBlocks: LAST_MINUTE_BLOCKS,
                        objectionPeriodDurationInBlocks: OBJECTION_PERIOD_BLOCKS,
                        proposalUpdatablePeriodInBlocks: UPDATABLE_PERIOD_BLOCKS
                    }),
                    NounsDAOV3Types.DynamicQuorumParams({
                        minQuorumVotesBPS: 200,
                        maxQuorumVotesBPS: 2000,
                        quorumCoefficient: 10000
                    })
                )
            )
        );

        address(new NounsDAOForkEscrow(address(dao), address(t.nounsToken)));

        vm.prank(address(t.timelock));
        NounsAuctionHouse(address(auctionProxy)).initialize(t.nounsToken, makeAddr('weth'), 2, 0, 1, auctionDuration);

        vm.prank(address(t.timelock));
        t.timelock.setPendingAdmin(address(dao));
        vm.prank(address(dao));
        t.timelock.acceptAdmin();

        vm.startPrank(address(t.timelock));
        dao._setForkPeriod(FORK_PERIOD);
        dao._setForkThresholdBPS(FORK_THRESHOLD_BPS);
        vm.stopPrank();

        return dao;
    }

    function _deployDAOV3() public returns (INounsDAOLogicV3) {
        return _deployDAOV3WithParams(10 minutes);
    }
}
