// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/utils/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/Address.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/Context.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/access/Ownable.sol";

/**
 * @dev A vesting wallet with interval-based releases inspired by OpenZeppelin's VestingWallet.
 * This contract allows for tokens to be released at specific intervals after the cliff period.
 *
 * The vesting schedule is as follows:
 * 1. No tokens are released before the cliff period ends
 * 2. After the cliff, tokens are released at regular intervals
 * 3. The amount of tokens released at each interval is proportional to the interval duration
 */
contract VestingWalletWithIntervals is Context, Ownable {
    event EtherReleased(uint256 amount);
    event ERC20Released(address indexed token, uint256 amount);

    uint256 private _released;
    mapping(address => uint256) private _erc20Released;
    uint64 private immutable _start;
    uint64 private immutable _duration;
    uint64 private immutable _cliff;
    uint64 private immutable _releaseInterval;

    // Calculated release timestamps based on intervals
    uint256[] private _releaseTimestamps;

    /**
     * @dev Sets the beneficiary (owner), the start timestamp, the cliff period,
     * the vesting duration (in seconds), and the interval between releases of the vesting wallet.
     */
    constructor(
        address beneficiary,
        uint64 startTimestamp,
        uint64 durationSeconds,
        uint64 cliffSeconds,
        uint64 releaseIntervalSeconds
    ) payable Ownable(beneficiary) {
        require(
            cliffSeconds <= durationSeconds,
            "VestingWalletWithIntervals: cliff is longer than duration"
        );
        require(
            releaseIntervalSeconds > 0,
            "VestingWalletWithIntervals: release interval must be greater than 0"
        );

        _start = startTimestamp;
        _duration = durationSeconds;
        _cliff = cliffSeconds;
        _releaseInterval = releaseIntervalSeconds;

        // Calculate and store all release timestamps
        uint256 currentTime = startTimestamp + cliffSeconds;
        uint256 endTime = startTimestamp + durationSeconds;

        while (currentTime <= endTime) {
            _releaseTimestamps.push(currentTime);
            currentTime += releaseIntervalSeconds;
        }

        // Ensure the final timestamp is exactly the end time
        if (
            _releaseTimestamps.length == 0 ||
            _releaseTimestamps[_releaseTimestamps.length - 1] != endTime
        ) {
            _releaseTimestamps.push(endTime);
        }
    }

    /**
     * @dev The contract should be able to receive Eth.
     */
    receive() external payable virtual {}

    /**
     * @dev Getter for the start timestamp.
     */
    function start() public view virtual returns (uint256) {
        return _start;
    }

    /**
     * @dev Getter for the vesting duration.
     */
    function duration() public view virtual returns (uint256) {
        return _duration;
    }

    /**
     * @dev Getter for the cliff period.
     */
    function cliff() public view virtual returns (uint256) {
        return _cliff;
    }

    /**
     * @dev Getter for the release interval.
     */
    function releaseInterval() public view virtual returns (uint256) {
        return _releaseInterval;
    }

    /**
     * @dev Getter for all release timestamps.
     */
    function getReleaseTimestamps() public view returns (uint256[] memory) {
        return _releaseTimestamps;
    }

    /**
     * @dev Getter for the end timestamp.
     */
    function end() public view virtual returns (uint256) {
        return start() + duration();
    }

    /**
     * @dev Amount of eth already released
     */
    function released() public view virtual returns (uint256) {
        return _released;
    }

    /**
     * @dev Amount of token already released
     */
    function released(address token) public view virtual returns (uint256) {
        return _erc20Released[token];
    }

    /**
     * @dev Getter for the amount of releasable eth.
     */
    function releasable() public view virtual returns (uint256) {
        return vestedAmount(uint64(block.timestamp)) - released();
    }

    /**
     * @dev Getter for the amount of releasable `token` tokens. `token` should be the address of an
     * {IERC20} contract.
     */
    function releasable(address token) public view virtual returns (uint256) {
        return vestedAmount(token, uint64(block.timestamp)) - released(token);
    }

    /**
     * @dev Release the native token (ether) that have already vested.
     *
     * Emits a {EtherReleased} event.
     */
    function release() public virtual {
        uint256 amount = releasable();
        _released += amount;
        emit EtherReleased(amount);
        Address.sendValue(payable(owner()), amount);
    }

    /**
     * @dev Release the tokens that have already vested.
     *
     * Emits a {ERC20Released} event.
     */
    function release(address token) public virtual {
        uint256 amount = releasable(token);
        _erc20Released[token] += amount;
        emit ERC20Released(token, amount);
        SafeERC20.safeTransfer(IERC20(token), owner(), amount);
    }

    /**
     * @dev Calculates the amount of ether that has already vested based on the interval-based vesting schedule.
     */
    function vestedAmount(
        uint64 timestamp
    ) public view virtual returns (uint256) {
        return _vestingSchedule(address(this).balance + released(), timestamp);
    }

    /**
     * @dev Calculates the amount of tokens that has already vested based on the interval-based vesting schedule.
     */
    function vestedAmount(
        address token,
        uint64 timestamp
    ) public view virtual returns (uint256) {
        return
            _vestingSchedule(
                IERC20(token).balanceOf(address(this)) + released(token),
                timestamp
            );
    }

    /**
     * @dev Implementation of the vesting formula based on intervals. This returns the amount vested,
     * as a function of time, for an asset given its total historical allocation.
     */
    function _vestingSchedule(
        uint256 totalAllocation,
        uint64 timestamp
    ) internal view virtual returns (uint256) {
        // Before cliff, nothing is vested
        if (timestamp < start() + cliff()) {
            return 0;
        }

        // After end, everything is vested
        if (timestamp >= start() + duration()) {
            return totalAllocation;
        }

        // Find the index of the next release timestamp after the current timestamp
        uint256 nextReleaseIndex = 0;
        while (
            nextReleaseIndex < _releaseTimestamps.length &&
            _releaseTimestamps[nextReleaseIndex] <= timestamp
        ) {
            nextReleaseIndex++;
        }

        // If we're at the beginning, no tokens are released yet
        if (nextReleaseIndex == 0) {
            return 0;
        }

        // Calculate what percentage of the total allocation should be released
        uint256 releasesCompleted = nextReleaseIndex;
        uint256 totalReleases = _releaseTimestamps.length;

        return (totalAllocation * releasesCompleted) / totalReleases;
    }
}
