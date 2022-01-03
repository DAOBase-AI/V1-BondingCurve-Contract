// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

interface IAaveIncentivesController {
    function handleAction(
        address asset,
        uint256 userBalance,
        uint256 totalSupply
    ) external;

    function getRewardsBalance(address[] calldata assets, address user)
        external
        view
        returns (uint256);

    /**
     * @dev Claims reward for an user, on all the assets of the lending pool, accumulating the pending rewards
     * @param amount Amount of rewards to claim
     * @param to Address that will be receiving the rewards
     * @return Rewards claimed
     **/
    function claimRewards(
        address[] calldata assets,
        uint256 amount,
        address to
    ) external returns (uint256);
}
