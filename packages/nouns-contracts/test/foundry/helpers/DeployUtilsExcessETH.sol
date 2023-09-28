// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import 'forge-std/Test.sol';
import { DeployUtilsV3 } from './DeployUtilsV3.sol';
import { NounsDAOExecutorV3 } from '../../../contracts/governance/NounsDAOExecutorV3.sol';
import { ExcessETH, INounsAuctionHouseV2, INounsDAOV3 } from '../../../contracts/governance/ExcessETH.sol';
import { WETH } from '../../../contracts/test/WETH.sol';
import { ERC20Mock, RocketETHMock } from './ERC20Mock.sol';
import { ERC1967Proxy } from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';
import { IERC20 } from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

abstract contract DeployUtilsExcessETH is DeployUtilsV3 {
    function _deployExecutorV3(address dao) internal returns (NounsDAOExecutorV3) {
        NounsDAOExecutorV3 executor = NounsDAOExecutorV3(
            payable(address(new ERC1967Proxy(address(new NounsDAOExecutorV3()), '')))
        );
        executor.initialize(dao, TIMELOCK_DELAY);
        return executor;
    }

    function _deployExcessETH(
        NounsDAOExecutorV3 owner,
        INounsAuctionHouseV2 auction,
        uint256 waitingPeriodEnd,
        uint16 pastAuctionCount
    ) internal returns (ExcessETH excessETH) {
        WETH weth = new WETH();
        ERC20Mock stETH = new ERC20Mock();
        RocketETHMock rETH = new RocketETHMock();

        excessETH = new ExcessETH(
            address(owner),
            INounsDAOV3(owner.admin()),
            auction,
            IERC20(address(weth)),
            stETH,
            rETH,
            waitingPeriodEnd,
            pastAuctionCount
        );
    }
}
