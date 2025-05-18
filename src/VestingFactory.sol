// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./VestingWalletWithIntervals.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/access/Ownable.sol";

/**
 * @title VestingFactory
 * @dev Factory contract to create VestingWalletWithIntervals instances
 */
contract VestingFactory is Ownable {
    event VestingWalletCreated(
        address indexed beneficiary,
        address wallet,
        uint256 startTime,
        uint256 duration,
        uint256 cliff,
        uint256 interval
    );

    /**
     * @dev Constructor with initial owner
     */
    constructor() Ownable(msg.sender) {}

    /**
     * @dev Creates a new VestingWalletWithIntervals for a beneficiary, with specified vesting parameters.
     * @param beneficiary The address that will receive the vested funds
     * @param startTimestamp The timestamp when vesting begins
     * @param durationSeconds The duration of the vesting period in seconds
     * @param cliffSeconds The cliff period in seconds
     * @param releaseIntervalSeconds The interval between token releases in seconds
     * @return address The address of the newly created vesting wallet
     */
    function createVestingWallet(
        address beneficiary,
        uint64 startTimestamp,
        uint64 durationSeconds,
        uint64 cliffSeconds,
        uint64 releaseIntervalSeconds
    ) external returns (address) {
        require(
            beneficiary != address(0),
            "Beneficiary cannot be zero address"
        );

        VestingWalletWithIntervals wallet = new VestingWalletWithIntervals(
            beneficiary,
            startTimestamp,
            durationSeconds,
            cliffSeconds,
            releaseIntervalSeconds
        );

        emit VestingWalletCreated(
            beneficiary,
            address(wallet),
            startTimestamp,
            durationSeconds,
            cliffSeconds,
            releaseIntervalSeconds
        );

        return address(wallet);
    }
}
