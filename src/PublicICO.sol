//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IVestingInterfaces.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/utils/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/Address.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/ReentrancyGuard.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/Pausable.sol";

/**
 * @title TokenICO
 * @dev A token ICO contract that integrates with the VestingWalletWithIntervals contract
 */
contract TokenICO is Ownable, ReentrancyGuard, Pausable {
    using Address for address;
    using SafeERC20 for IERC20;

    IERC20 public token;

    // --- State Variables ---
    uint256 public startTime;
    uint256 public endTime;
    uint256 public tokenPriceInWei = 0.002 ether; // 0.002 ETH per token
    uint256 public hardcapInTokens = 200_000_000 * (10 ** 18); // 200M tokens
    uint256 public minEthPurchase = 0.003 ether; // 0.003 ETH min
    uint256 public maxEthPurchase = 200 ether; // 200 ETH max
    uint256 public tokensSold;
    uint256 public weiRaised;

    // --- Vesting-related variables ---
    IVestingFactory public vestingFactory;
    bool public vestingEnabled;
    uint64 public vestingDuration;
    uint64 public vestingCliff;
    uint64 public releaseInterval; // Time between each token release
    bool public icoFinalized;
    uint256 public unsoldTokensApproved;

    // Mapping of user addresses to their vesting wallet addresses
    mapping(address => address[]) public userVestingWallets;

    // Mapping to track total tokens allocated to vesting per user
    mapping(address => uint256) public userVestedTokens;

    // Mapping to track tokens in each vesting wallet
    mapping(address => uint256) public vestingWalletTokens;

    // **** Events **** ///
    event TokenPurchasedWithEth(
        address indexed purchaser,
        uint256 weiAmount,
        uint256 tokenAmount
    );
    event ICOStartTimeChanged(uint256 newStartTime);
    event ICOEndTimeChanged(uint256 newEndTime);
    event TokenPriceChanged(uint256 newEthPrice);
    event HardCapChanged(uint256 newHardCap);
    event FundsWithdrawn(
        address indexed wallet,
        uint256 amount,
        address indexed token
    );
    event VestingConfigured(uint256 duration, uint256 cliff, uint256 interval);
    event IcoFinalized(uint256 unsoldTokensApproved);
    event UnsoldTokensWithdrawn(address indexed wallet, uint256 amount);
    event VestingWalletCreated(
        address indexed user,
        address indexed vestingWallet,
        uint256 tokenAmount
    );
    event VestingWalletFunded(address indexed vestingWallet, uint256 amount);

    /**
     * @dev Constructor
     * @param _token Address of the token being sold
     * @param _startTime Start time of the ICO
     * @param _endTime End time of the ICO
     * @param _vestingFactory Address of the vesting factory contract
     */
    constructor(
        address _token,
        uint256 _startTime,
        uint256 _endTime,
        address _vestingFactory
    ) Ownable(msg.sender) {
        require(_token != address(0), "Token address cannot be zero");
        require(
            _vestingFactory != address(0),
            "Vesting factory address cannot be zero"
        );
        require(
            _startTime >= block.timestamp,
            "Start time must be in the future"
        );
        require(_endTime > _startTime, "End time must be after start time");

        token = IERC20(_token);
        vestingFactory = IVestingFactory(_vestingFactory);
        startTime = _startTime;
        endTime = _endTime;
        _pause(); // Start paused
    }

    /**
     * @dev Fallback function to handle ETH transfers
     */
    receive() external payable {
        buyTokensWithEth();
    }

    /**
     * @dev Checks if the ICO is open
     * @return bool Whether the ICO is open
     */
    function isOpen() public view returns (bool) {
        return
            block.timestamp >= startTime &&
            block.timestamp <= endTime &&
            tokensSold < hardcapInTokens &&
            !paused();
    }

    /**
     * @dev Allows users to buy tokens with ETH
     */
    function buyTokensWithEth() public payable nonReentrant whenNotPaused {
        require(isOpen(), "ICO is not open");
        require(msg.value >= minEthPurchase, "Amount < min purchase");
        require(msg.value <= maxEthPurchase, "Amount > max purchase");

        uint256 tokens = calculateTokenAmount(msg.value);
        require(tokensSold + tokens <= hardcapInTokens, "Exceeds hardcap");

        tokensSold += tokens;
        weiRaised += msg.value;

        if (vestingEnabled) {
            // Always create a new vesting wallet for each purchase
            address vestingWallet = vestingFactory.createVestingWallet(
                msg.sender, // beneficiary
                uint64(block.timestamp), // startTimestamp - current time for each purchase
                vestingDuration, // durationSeconds
                vestingCliff, // cliffSeconds
                releaseInterval // releaseIntervalSeconds
            );

            // Add to array of user's vesting wallets
            userVestingWallets[msg.sender].push(vestingWallet);

            // Track tokens in this specific wallet
            vestingWalletTokens[vestingWallet] = tokens;

            // Send tokens to the new vesting wallet
            token.safeTransfer(vestingWallet, tokens);
            userVestedTokens[msg.sender] += tokens;

            emit VestingWalletCreated(msg.sender, vestingWallet, tokens);
            emit VestingWalletFunded(vestingWallet, tokens);
        } else {
            // Direct transfer if vesting is not enabled
            token.safeTransfer(msg.sender, tokens);
        }

        emit TokenPurchasedWithEth(msg.sender, msg.value, tokens);
    }

    /**
     * @dev Calculate the amount of tokens for a given amount of ETH
     * @param _amount Amount of ETH (in wei)
     * @return uint256 Number of tokens
     */
    function calculateTokenAmount(
        uint256 _amount
    ) public view returns (uint256) {
        return _amount / tokenPriceInWei;
    }

    // ***** Owner Functions ***** //

    /**
     * @dev Configure vesting parameters
     * @param _duration Duration of vesting in seconds
     * @param _cliff Cliff period in seconds
     * @param _interval Time between each token release in seconds
     */
    function configureVesting(
        uint64 _duration,
        uint64 _cliff,
        uint64 _interval
    ) external onlyOwner {
        require(_cliff <= _duration, "Cliff must be less or equal to duration");
        require(_interval > 0 && _interval <= _duration, "Invalid interval");
        vestingEnabled = true;
        vestingDuration = _duration;
        vestingCliff = _cliff;
        releaseInterval = _interval;
        emit VestingConfigured(_duration, _cliff, _interval);
    }

    /**
     * @dev Disable vesting
     */
    function disableVesting() external onlyOwner {
        vestingEnabled = false;
    }

    /**
     * @dev Update ICO start time
     * @param _startTime New Start time
     */
    function setStartTime(uint256 _startTime) external onlyOwner {
        require(
            _startTime >= block.timestamp,
            "Start time must be in the future"
        );
        require(_startTime < endTime, "Start time must be before end time");
        startTime = _startTime;
        emit ICOStartTimeChanged(_startTime);
    }

    /**
     * @dev Update ICO end time
     * @param _endTime New end time
     */
    function setEndTime(uint256 _endTime) external onlyOwner {
        require(_endTime > block.timestamp, "End time must be in the future");
        require(_endTime > startTime, "End time must be after start time");
        endTime = _endTime;
        emit ICOEndTimeChanged(_endTime);
    }

    /**
     * @dev Update token prices
     * @param _tokenPriceInWei New token price in wei
     */
    function setTokenPrices(uint256 _tokenPriceInWei) external onlyOwner {
        require(
            _tokenPriceInWei > 0,
            "Token price in wei must be greater than 0"
        );

        tokenPriceInWei = _tokenPriceInWei;
        emit TokenPriceChanged(_tokenPriceInWei);
    }

    /**
     * @dev Update hardcap
     * @param _hardcapInTokens New hardcap in tokens
     */
    function setHardcap(uint256 _hardcapInTokens) external onlyOwner {
        require(
            _hardcapInTokens > tokensSold,
            "New hardcap must be greater than tokens sold"
        );
        hardcapInTokens = _hardcapInTokens;
        emit HardCapChanged(_hardcapInTokens);
    }

    /**
     * @dev Update eth purchase limits
     * @param _minEthPurchase New minimum purchase amount
     * @param _maxEthPurchase New maximum purchase amount
     */
    function setEthPurchaseLimits(
        uint256 _minEthPurchase,
        uint256 _maxEthPurchase
    ) external onlyOwner {
        require(_minEthPurchase > 0, "Min purchase must be greater than 0");
        require(
            _maxEthPurchase >= _minEthPurchase,
            "Max purchase must be greater or equal to min purchase"
        );
        minEthPurchase = _minEthPurchase;
        maxEthPurchase = _maxEthPurchase;
    }

    /**
     * @dev Pause the ICO
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Unpause the ICO
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Withdraw collected ETH
     * @param _wallet Address to send ETH to
     */
    function withdrawEth(
        address payable _wallet
    ) external onlyOwner nonReentrant {
        require(_wallet != address(0), "Invalid address");
        uint256 amount = address(this).balance;
        require(amount > 0, "No ETH");

        (bool success, ) = _wallet.call{value: amount}("");
        require(success, "Transfer failed");

        emit FundsWithdrawn(_wallet, amount, address(0));
    }

    /**
     * @dev Finalize the ICO, calculate unsold tokens
     */
    function finalizeIco() external onlyOwner {
        require(
            block.timestamp > endTime || tokensSold >= hardcapInTokens,
            "ICO still active"
        );
        require(!icoFinalized, "Already finalized");

        // Calculate unsold tokens
        unsoldTokensApproved = token.balanceOf(address(this));

        icoFinalized = true;
        emit IcoFinalized(unsoldTokensApproved);
    }

    /**
     * @dev Withdraw unsold tokens after ICO finalization
     * @param _wallet Address to send unsold tokens to
     */
    function withdrawUnsoldTokens(
        address _wallet
    ) external onlyOwner nonReentrant {
        require(_wallet != address(0), "Invalid address");
        require(icoFinalized, "ICO not finalized");
        require(unsoldTokensApproved > 0, "No tokens approved");

        uint256 amount = unsoldTokensApproved;
        unsoldTokensApproved = 0; // Prevent reentrancy and reuse

        token.safeTransfer(_wallet, amount);
        emit UnsoldTokensWithdrawn(_wallet, amount);
    }

    // Update the getVestingDetails function to return data about all wallets
    function getVestingWallets(
        address _user
    ) external view returns (address[] memory) {
        return userVestingWallets[_user];
    }

    // Get details for a specific wallet
    function getVestingWalletDetails(
        address _wallet
    )
        external
        view
        returns (
            uint256 vestedAmount,
            uint256 vestingStart,
            uint256 vestingEnd,
            uint256 vestingCliffEnd,
            uint256[] memory intervals
        )
    {
        require(_wallet != address(0), "Invalid wallet address");

        IVestingWalletWithIntervals vestingWallet = IVestingWalletWithIntervals(
            _wallet
        );
        vestedAmount = vestingWalletTokens[_wallet];
        vestingStart = vestingWallet.start();
        vestingEnd = vestingStart + vestingWallet.duration();
        vestingCliffEnd = vestingStart + vestingWallet.cliff();
        intervals = vestingWallet.getReleaseTimestamps();

        return (
            vestedAmount,
            vestingStart,
            vestingEnd,
            vestingCliffEnd,
            intervals
        );
    }

<<<<<<< HEAD
    // Release tokens from a specific vesting wallet
    function releaseVestedTokens(address vestingWallet) external nonReentrant {
        bool isUsersWallet = false;
        address[] memory userWallets = userVestingWallets[msg.sender];

        for (uint i = 0; i < userWallets.length; i++) {
            if (userWallets[i] == vestingWallet) {
                isUsersWallet = true;
                break;
            }
        }

        require(isUsersWallet, "Not your vesting wallet");

        IVestingWalletWithIntervals wallet = IVestingWalletWithIntervals(
            vestingWallet
        );
        wallet.release(address(token));
    }

    // Release tokens from all of a user's vesting wallets
    function releaseAllVestedTokens() external nonReentrant {
        address[] memory userWallets = userVestingWallets[msg.sender];
        require(userWallets.length > 0, "No vesting wallets found");

        for (uint i = 0; i < userWallets.length; i++) {
            IVestingWalletWithIntervals wallet = IVestingWalletWithIntervals(
                userWallets[i]
            );
            if (wallet.releasable(address(token)) > 0) {
                wallet.release(address(token));
            }
        }
=======

    /**
     * @dev Allows users to release their vested tokens via the ICO contract.
     */
    function releaseVestedTokens() external nonReentrant {
        require(
            userVestingWallets[msg.sender] != address(0),
            "No vesting wallet found"
        );

        IVestingWalletWithIntervals vestingWallet = IVestingWalletWithIntervals(
            userVestingWallets[msg.sender]
        );

        vestingWallet.release(address(token)); // Releases the ICO token
    }

    /**
     * @dev Returns the amount of tokens that have vested for a user at the current block timestamp.
     * @param user The address of the user to check
     * @return The amount of vested tokens (in wei)
     */
    function getVestedTokens(address user) external view returns (uint256) {
        require(
            userVestingWallets[user] != address(0),
            "No vesting wallet found"
        );

        IVestingWalletWithIntervals vestingWallet = IVestingWalletWithIntervals(
            userVestingWallets[user]
        );

        // Returns vested tokens up to current time
        return
            vestingWallet.vestedAmount(address(token), uint64(block.timestamp));
    }

    /**
     * @dev Returns the amount of tokens already claimed by the user.
     * @param user The address of the user to check
     * @return The amount of claimed tokens (in wei)
     */
    function getClaimedTokens(address user) external view returns (uint256) {
        require(
            userVestingWallets[user] != address(0),
            "No vesting wallet found"
        );

        IVestingWalletWithIntervals vestingWallet = IVestingWalletWithIntervals(
            userVestingWallets[user]
        );

        return vestingWallet.released(address(token));
>>>>>>> 466e06ab5654751eb8037beec305b37db954ca7f
    }
}
