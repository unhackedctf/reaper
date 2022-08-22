// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IMasterChef {
    function TOTAL_REWARDS() external view returns (uint256);

    function add(
        uint256 _allocPoint,
        address _token,
        bool _withUpdate,
        uint256 _lastRewardTime
    ) external;

    function deposit(uint256 _pid, uint256 _amount) external;

    function emergencyWithdraw(uint256 _pid) external;

    function getGeneratedReward(uint256 _fromTime, uint256 _toTime) external view returns (uint256);

    function governanceRecoverUnsupported(
        address _token,
        uint256 amount,
        address to
    ) external;

    function massUpdatePools() external;

    function operator() external view returns (address);

    function pendingShare(uint256 _pid, address _user) external view returns (uint256);

    function poolEndTime() external view returns (uint256);

    function poolInfo(uint256)
        external
        view
        returns (
            address token,
            uint256 allocPoint,
            uint256 lastRewardTime,
            uint256 accTSharePerShare,
            bool isStarted
        );

    function poolStartTime() external view returns (uint256);

    function runningTime() external view returns (uint256);

    function set(uint256 _pid, uint256 _allocPoint) external;

    function setOperator(address _operator) external;

    function tSharePerSecond() external view returns (uint256);

    function totalAllocPoint() external view returns (uint256);

    function tshare() external view returns (address);

    function updatePool(uint256 _pid) external;

    function userInfo(uint256, address) external view returns (uint256 amount, uint256 rewardDebt);

    function withdraw(uint256 _pid, uint256 _amount) external;
}
