//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IVestingInterfaces.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

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
    uint256 public hardcapInTokens = 200_000_000 * (10**18); // 200M tokens
    uint256 public minEthPurchase = 0.003 ether; // 0.003 ETH min
    uint256 public maxEthPurchase = 200 ether; // 200 ETH max
    uint256 public tokensSold;
    uint256 public weiRaised;

    // --- Vesting-related variables ---
    IVestingFactory public vestingFactory;
    bool public vestingEnabled;
    uint64 public vestingDuration;
    uint64 public vestingCliff;
    uint64 public releaseInterval;
    bool public icoFinalized;
    uint256 public unsoldTokensApproved;

    struct VestingBalance {
        address walletAddress;
        uint256 initialAmount;
        uint256 releasedAmount;
        uint64 startTime;
        uint64 duration;
        uint64 cliff;
        uint64 interval;
    }

    mapping(address => VestingBalance[]) public userVestingBalances;
    mapping(address => uint256) public userTotalVestedTokens;

    // **** Events **** ///
    event TokenPurchasedWithEth(
        address indexed purchaser,
        uint256 weiAmount,
        uint256 tokenAmount,
        address indexed vestingWallet
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
        uint256 tokenAmount,
        uint64 startTime,
        uint64 duration,
        uint64 cliff,
        uint64 interval
    );

    constructor(
        address _token,
        uint256 _startTime,
        uint256 _endTime,
        address _vestingFactory
    ) Ownable(msg.sender) {
        require(_token != address(0), "Token address cannot be zero");
        require(_vestingFactory != address(0), "Vesting factory address cannot be zero");
        require(_startTime >= block.timestamp, "Start time must be in the future");
        require(_endTime > _startTime, "End time must be after start time");

        token = IERC20(_token);
        vestingFactory = IVestingFactory(_vestingFactory);
        startTime = _startTime;
        endTime = _endTime;
    }

    receive() external payable {
        buyTokensWithEth();
    }

    function isOpen() public view returns (bool) {
        return block.timestamp >= startTime &&
            block.timestamp <= endTime &&
            tokensSold < hardcapInTokens &&
            !paused();
    }

    function buyTokensWithEth() public payable nonReentrant whenNotPaused {
        require(isOpen(), "ICO is not open");
        require(msg.value >= minEthPurchase, "Amount < min purchase");
        require(msg.value <= maxEthPurchase, "Amount > max purchase");

        uint256 tokens = calculateTokenAmount(msg.value);
        require(tokensSold + tokens <= hardcapInTokens, "Exceeds hardcap");
        require(token.balanceOf(address(this)) >= tokens, "ICO contract has insufficient tokens");

        tokensSold += tokens;
        weiRaised += msg.value;

        if (vestingEnabled) {
            address vestingWallet = vestingFactory.createVestingWallet(
                msg.sender,
                uint64(block.timestamp),
                vestingDuration,
                vestingCliff,
                releaseInterval
            );
            
            require(vestingWallet != address(0), "Vesting wallet creation failed");

            userVestingBalances[msg.sender].push(VestingBalance({
                walletAddress: vestingWallet,
                initialAmount: tokens,
                releasedAmount: 0,
                startTime: uint64(block.timestamp),
                duration: vestingDuration,
                cliff: vestingCliff,
                interval: releaseInterval
            }));

            token.safeTransfer(vestingWallet, tokens);
            userTotalVestedTokens[msg.sender] += tokens;

            emit VestingWalletCreated(
                msg.sender,
                vestingWallet,
                tokens,
                uint64(block.timestamp),
                vestingDuration,
                vestingCliff,
                releaseInterval
            );
            emit TokenPurchasedWithEth(msg.sender, msg.value, tokens, vestingWallet);
        } else {
            uint256 initialRecipientBalance = token.balanceOf(msg.sender);
            token.safeTransfer(msg.sender, tokens);
            require(
                token.balanceOf(msg.sender) == initialRecipientBalance + tokens,
                "Direct transfer failed"
            );
            emit TokenPurchasedWithEth(msg.sender, msg.value, tokens, address(0));
        }
    }

    function calculateTokenAmount(uint256 _amount) public view returns (uint256) {
        return _amount / tokenPriceInWei;
    }

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

    function disableVesting() external onlyOwner {
        vestingEnabled = false;
    }

    function setStartTime(uint256 _startTime) external onlyOwner {
        require(_startTime >= block.timestamp, "Start time must be in the future");
        require(_startTime < endTime, "Start time must be before end time");
        startTime = _startTime;
        emit ICOStartTimeChanged(_startTime);
    }

    function setEndTime(uint256 _endTime) external onlyOwner {
        require(_endTime > block.timestamp, "End time must be in the future");
        require(_endTime > startTime, "End time must be after start time");
        endTime = _endTime;
        emit ICOEndTimeChanged(_endTime);
    }

    function setTokenPrices(uint256 _tokenPriceInWei) external onlyOwner {
        require(_tokenPriceInWei > 0, "Token price in wei must be greater than 0");
        tokenPriceInWei = _tokenPriceInWei;
        emit TokenPriceChanged(_tokenPriceInWei);
    }

    function setHardcap(uint256 _hardcapInTokens) external onlyOwner {
        require(_hardcapInTokens > tokensSold, "New hardcap must be greater than tokens sold");
        hardcapInTokens = _hardcapInTokens;
        emit HardCapChanged(_hardcapInTokens);
    }

    function setEthPurchaseLimits(
        uint256 _minEthPurchase,
        uint256 _maxEthPurchase
    ) external onlyOwner {
        require(_minEthPurchase > 0, "Min purchase must be greater than 0");
        require(_maxEthPurchase >= _minEthPurchase, "Max purchase must be greater or equal to min purchase");
        minEthPurchase = _minEthPurchase;
        maxEthPurchase = _maxEthPurchase;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function withdrawEth(address payable _wallet) external onlyOwner nonReentrant {
        require(_wallet != address(0), "Invalid address");
        uint256 amount = address(this).balance;
        require(amount > 0, "No ETH");

        (bool success, ) = _wallet.call{value: amount}("");
        require(success, "Transfer failed");

        emit FundsWithdrawn(_wallet, amount, address(0));
    }

    function finalizeIco() external onlyOwner {
        require(block.timestamp > endTime || tokensSold >= hardcapInTokens, "ICO still active");
        require(!icoFinalized, "Already finalized");

        unsoldTokensApproved = token.balanceOf(address(this));
        icoFinalized = true;
        emit IcoFinalized(unsoldTokensApproved);
    }

    function withdrawUnsoldTokens(address _wallet) external onlyOwner nonReentrant {
        require(_wallet != address(0), "Invalid address");
        require(icoFinalized, "ICO not finalized");
        require(unsoldTokensApproved > 0, "No tokens approved");

        uint256 amount = unsoldTokensApproved;
        unsoldTokensApproved = 0;

        token.safeTransfer(_wallet, amount);
        emit UnsoldTokensWithdrawn(_wallet, amount);
    }

    function getVestingWalletBalances(address user) public view returns (
        address[] memory wallets,
        uint256[] memory initialAmounts,
        uint256[] memory vestedAmounts,
        uint256[] memory releasableAmounts,
        uint256[] memory remainingAmounts
    ) {
        VestingBalance[] storage balances = userVestingBalances[user];
        uint256 count = balances.length;
        
        wallets = new address[](count);
        initialAmounts = new uint256[](count);
        vestedAmounts = new uint256[](count);
        releasableAmounts = new uint256[](count);
        remainingAmounts = new uint256[](count);
        
        for (uint i = 0; i < count; i++) {
            VestingBalance memory balance = balances[i];
            IVestingWalletWithIntervals wallet = IVestingWalletWithIntervals(balance.walletAddress);
            
            wallets[i] = balance.walletAddress;
            initialAmounts[i] = balance.initialAmount;
            vestedAmounts[i] = wallet.vestedAmount(address(token), uint64(block.timestamp));
            releasableAmounts[i] = wallet.releasable(address(token));
            remainingAmounts[i] = balance.initialAmount - vestedAmounts[i];
        }
    }

    function getVestingWalletCount(address user) external view returns (uint256) {
        return userVestingBalances[user].length;
    }

    function releaseAllVestedTokens() external nonReentrant {
        VestingBalance[] storage balances = userVestingBalances[msg.sender];
        require(balances.length > 0, "No vesting wallets found");

        for (uint256 i = 0; i < balances.length; i++) {
            IVestingWalletWithIntervals wallet = IVestingWalletWithIntervals(balances[i].walletAddress);
            uint256 releasable = wallet.releasable(address(token));
            if (releasable > 0) {
                wallet.release(address(token));
                balances[i].releasedAmount += releasable;
            }
        }
    }

    function releaseVestedTokens(uint256 walletIndex) external nonReentrant {
        VestingBalance[] storage balances = userVestingBalances[msg.sender];
        require(walletIndex < balances.length, "Invalid wallet index");

        IVestingWalletWithIntervals wallet = IVestingWalletWithIntervals(balances[walletIndex].walletAddress);
        uint256 releasable = wallet.releasable(address(token));
        if (releasable > 0) {
            wallet.release(address(token));
            balances[walletIndex].releasedAmount += releasable;
        }
    }

    function getTotalReleasable(address user) external view returns (uint256 totalReleasable) {
        VestingBalance[] storage balances = userVestingBalances[user];
        for (uint256 i = 0; i < balances.length; i++) {
            totalReleasable += IVestingWalletWithIntervals(balances[i].walletAddress)
                .releasable(address(token));
        }
        return totalReleasable;
    }

    function getWalletReleasable(address user, uint256 walletIndex) external view returns (uint256) {
        VestingBalance[] storage balances = userVestingBalances[user];
        require(walletIndex < balances.length, "Invalid wallet index");
        return IVestingWalletWithIntervals(balances[walletIndex].walletAddress)
            .releasable(address(token));
    }
/**
 * @dev Get all release timestamps for a specific vesting wallet
 * @param user The user address
 * @param walletIndex Index of the vesting wallet
 * @return purchaseTime When tokens were purchased/vesting started
 * @return cliffEndTime When cliff period ends
 * @return releaseTimes Array of all release timestamps after cliff
 */
function getVestingReleaseSchedule(address user, uint256 walletIndex)
    public
    view
    returns (
        uint256 purchaseTime,
        uint256 cliffEndTime,
        uint256[] memory releaseTimes
    )
{
    require(walletIndex < userVestingBalances[user].length, "Invalid wallet index");
    
    VestingBalance memory balance = userVestingBalances[user][walletIndex];
    purchaseTime = balance.startTime;
    cliffEndTime = purchaseTime + balance.cliff;
    
    // Calculate total number of releases
    uint256 vestingDurationAfterCliff = balance.duration - balance.cliff;
    uint256 totalReleases = vestingDurationAfterCliff / balance.interval;
    if (vestingDurationAfterCliff % balance.interval != 0) {
        totalReleases += 1;
    }
    
    // Generate all release timestamps
    releaseTimes = new uint256[](totalReleases);
    uint256 currentReleaseTime = cliffEndTime;
    uint256 vestingEnd = purchaseTime + balance.duration;
    
    for (uint256 i = 0; i < totalReleases; i++) {
        releaseTimes[i] = currentReleaseTime;
        if (currentReleaseTime + balance.interval > vestingEnd) {
            currentReleaseTime = vestingEnd;
        } else {
            currentReleaseTime += balance.interval;
        }
    }
}
}
