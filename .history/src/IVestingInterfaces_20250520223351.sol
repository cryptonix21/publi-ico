// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IVestingWalletWithIntervals
 * @dev Interface for VestingWalletWithIntervals
 */
interface IVestingWalletWithIntervals {
    function release() external;

    function release(address token) external;

    function releasable() external view returns (uint256);

    function releasable(address token) external view returns (uint256);

    function released() external view returns (uint256);

    function released(address token) external view returns (uint256);

    function start() external view returns (uint256);

    function duration() external view returns (uint256);

    function cliff() external view returns (uint256);

    function releaseInterval() external view returns (uint256);

    function getReleaseTimestamps() external view returns (uint256[] memory);

    function owner() external view returns (address);

    function vestedAmount(uint64 timestamp) external view returns (uint256);

    function vestedAmount(
        address token,
        uint64 timestamp
    ) external view returns (uint256);
}

/**
 * @title IVestingFactory
 * @dev Interface for VestingFactory
 */
interface IVestingFactory {
    function createVestingWallet(
        address beneficiary,
        uint64 startTimestamp,
        uint64 durationSeconds,
        uint64 cliffSeconds,
        uint64 releaseIntervalSeconds
    ) external returns (address);
}
