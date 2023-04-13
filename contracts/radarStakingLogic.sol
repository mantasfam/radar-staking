// SPDX-License-Identifier: MIT LICENSE

pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/iRadarStakingLogic.sol";
import "./interfaces/iRadarToken.sol";
import "./interfaces/iRadarStake.sol";

contract RadarStakingLogic is iRadarStakingLogic, Ownable, ReentrancyGuard {

    constructor(address rewardAddr, address radarTokenContractAddr, address radarStakeContractAddr) {
        rewardAddress = rewardAddr;
        radarTokenContract = iRadarToken(radarTokenContractAddr);
        radarStakeContract = iRadarStake(radarStakeContractAddr);
    }

    /** EVENTS */
    event TokensStaked(address indexed owner, uint256 amount);
    event TokensHarvested(address indexed owner, uint256 amount);
    event TokensUnstaked(address indexed owner, uint256 amount);
    event TokensUnstakingTriggered(address indexed owner, uint256 cooldownSeconds);

    /** PUBLIC VARS */
    // interface of our ERC20 RADAR token
    iRadarToken public radarTokenContract;
    // interface of the staking contract (stateful)
    iRadarStake public radarStakeContract;
    // the address which holds the reward tokens which get paid out to users when they harvest or unstake
    address public rewardAddress;
    // duration of the cooldown before a user can unstake
    uint256 public cooldownSeconds = 30 days; // e.g. 86_400 = 1 day
    // minimum amount to stake (aka. subscription for the DappRadar PRO subscription)
    uint256 public stakeForDappRadarPro = 5_000 ether;

    /** MODIFIERS */
    modifier requireVariablesSet() {
        require(address(rewardAddress) != address(0), "RadarStakingLogic: Reward Address not set");
        require(address(radarTokenContract) != address(0), "RadarStakingLogic: Token contract not set");
        require(address(radarStakeContract) != address(0), "RadarStakingLogic: Staking contract not set");
        _;
    }

    /** PUBLIC */
    // this contract needs to have permission to move RADAR for the _msgSender() before this function can be called
    function stake(uint256 amount) external nonReentrant {
        require(amount >= 0, "RadarStakingLogic: Amount must be above 0");
        
        iRadarStake.Stake memory myStake = radarStakeContract.getStake(_msgSender());
        require(myStake.totalStaked + amount >= stakeForDappRadarPro, "RadarStakingLogic: You cannot stake less than the minimum");

        // check if the user owns the amount of tokens he wants to stake
        require(radarTokenContract.balanceOf(_msgSender()) >= amount, "RadarStakingLogic: Not enough tokens to stake");
        // check if this contract is allowed to move users RADAR to the staking contract
        require(radarTokenContract.allowance(_msgSender(), address(this)) >= amount, "RadarStakingLogic: This contact is not allowed to move the amount of tokens you want to stake");

        // move tokens from the user to the staking contract
        radarTokenContract.transferFrom(_msgSender(), address(radarStakeContract), amount);
        
        // calculate reward in case the user already had a stake and now added to it
        uint256 tokenReward = calculateReward(_msgSender());
        
        // move additional tokens to the staking contract so it can later pay out the already accrued rewards
        if (tokenReward > 0) {
            radarTokenContract.transferFrom(rewardAddress, address(radarStakeContract), tokenReward);
        }

        // add to stake, which updates totals and timestamps
        radarStakeContract.addToStake(amount + tokenReward, _msgSender());
        
        emit TokensStaked(_msgSender(), amount + tokenReward);
    }

    // there is no cooldown when harvesting token rewards.
    function harvest(bool restake) public nonReentrant {
        iRadarStake.Stake memory myStake = radarStakeContract.getStake(_msgSender());
        require(myStake.totalStaked > 0, "RadarStakingLogic: You don't have tokens staked");

        uint256 tokenReward = calculateReward(_msgSender());
        if (restake) {
            // stake again to reset the clock + add the reward to the stake (this happens automatically in the stake contract)
            radarStakeContract.addToStake(tokenReward, _msgSender());
        } else {
            // stake again to reset the timestamps and cooldown
            radarStakeContract.addToStake(0, _msgSender());

            // pay out the rewards, keep the original stake, reset the clock
            radarTokenContract.transferFrom(rewardAddress, _msgSender(), tokenReward);
        }

        emit TokensHarvested(_msgSender(), tokenReward);
    }

    // trigger the cooldown so you can later on call unstake() to unstake your tokens
    function triggerUnstake() external nonReentrant {
        iRadarStake.Stake memory myStake = radarStakeContract.getStake(_msgSender());
        require(myStake.totalStaked >= 0, "RadarStakingLogic: You have no stake yet");

        if (myStake.cooldownSeconds <= 0) {
            radarStakeContract.triggerUnstake(_msgSender(), cooldownSeconds);
        }

        emit TokensUnstakingTriggered(_msgSender(), cooldownSeconds);
    }

    // unstake your tokens + rewards after the cooldown has passed
    function unstake(uint256 amount) external nonReentrant {
        require(amount >= 0, "RadarStakingLogic: Amount cannot be lower than 0");
        iRadarStake.Stake memory myStake = radarStakeContract.getStake(_msgSender());

        require(myStake.cooldownTriggeredAtTimestamp > 0, "RadarStakingLogic: Cooldown not yet triggered");
        require(block.timestamp >= myStake.cooldownTriggeredAtTimestamp + myStake.cooldownSeconds, "RadarStakingLogic: Can't unstake during the cooldown period");
        
        require(myStake.totalStaked >= amount, "RadarStakingLogic: Amount you want to unstake exceeds your staked amount");
        require((myStake.totalStaked - amount >= stakeForDappRadarPro) || (myStake.totalStaked - amount == 0), "RadarStakingLogic: Either unstake all or keep more than the minimum stake required");
        
        // calculate rewards
        uint256 tokenReward = calculateReward(_msgSender());

        // unstake
        radarStakeContract.removeFromStake(amount, _msgSender());

        // transfer the rewards from the rewardAddress
        radarTokenContract.transferFrom(rewardAddress, _msgSender(), tokenReward);

        // transfer the stake from the radarStakeContract
        radarTokenContract.transferFrom(address(radarStakeContract), _msgSender(), amount);

        emit TokensUnstaked(_msgSender(), amount);
    }

    // calculate the total rewards a user has already earned.
    function calculateReward(address addr) public view returns(uint256 reward) {
        require(addr != address(0), "RadarStakingLogic: Cannot use the null address");

        iRadarStake.Stake memory myStake = radarStakeContract.getStake(addr);
        uint256 totalStaked = myStake.totalStaked;

        // return 0 if the user has no stake
        if (totalStaked <= 0 ) return 0;

        iRadarStake.Apr[] memory allAprs = radarStakeContract.getAllAprs();
        for (uint256 i = 0; i < allAprs.length; i++) {
            iRadarStake.Apr memory currentApr = allAprs[i];

            // jump over APRs, which are in the past for this user/address
            if (currentApr.endTime > 0 && currentApr.endTime < myStake.lastStakedTimestamp) continue;

            uint256 startTime = (myStake.lastStakedTimestamp > currentApr.startTime) ? myStake.lastStakedTimestamp : currentApr.startTime;
            uint256 endTime = (currentApr.endTime < block.timestamp)? currentApr.endTime : block.timestamp;

            // use current timestamp if the APR is still active (aka. has no endTime yet)
            if (endTime <= 0) endTime = block.timestamp;

            // once the cooldown is triggered, don't accrue any further from that point in time
            if (myStake.cooldownTriggeredAtTimestamp > 0) {
                endTime = myStake.cooldownTriggeredAtTimestamp;
            }

            // protect against subtraction errors
            if (endTime <= startTime) continue;

            uint256 secondsWithCurrentApr = endTime - startTime;
            uint256 daysPassed = secondsWithCurrentApr/1 days;

            // calculate accrued reward for each APR period (per second)
            uint256 accruedReward = totalStaked * currentApr.apr/10_000 * secondsWithCurrentApr/(365 days);

            // calculate compounding rewards (per day)
            uint256 compoundingReward = calculateCompoundingReward(accruedReward, currentApr.apr, daysPassed);
            
            // compound the rewards for each APR period
            reward += accruedReward + compoundingReward;
            totalStaked += reward;
        }

        return reward;
    }

    // calculate compounding interest without running into floating point issues
    function calculateCompoundingReward(uint256 principal, uint256 aprToUse, uint256 daysPassed) internal pure returns(uint256 compoundingReward) {
        for (uint256 i = 0; i < daysPassed; i++) {
            compoundingReward += (principal + compoundingReward) * aprToUse/10_000/365;
        }
    }
    
    /** ONLY OWNER */
    // allow to change the cooldown period
    function setCooldownSeconds(uint256 number) external onlyOwner {
        require(number >= 0, "RadarStakingLogic: Amount must be above 0");
        cooldownSeconds = number;
    }

    // allow to change the minimum amount to stake & keep staked to keep the PRO subscription
    function setStakeForDappRadarPro(uint256 number) external onlyOwner {
        require(number >= 0, "RadarStakingLogic: Amount must be above 0");
        stakeForDappRadarPro = number;
    }

    // if someone sends ETH to this contract by accident we want to be able to send it back to them
    function withdraw() external onlyOwner {
        uint256 totalAmount = address(this).balance;

        bool sent;
        (sent, ) = owner().call{value: totalAmount}("");
        require(sent, "RadarStakingLogic: Failed to send funds");
    }
}