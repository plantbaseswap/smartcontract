// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./libraries/BoringERC20.sol";
import "./PlantToken.sol";
import "./Rewards.sol";

interface IRewarder {
    function onPlantReward(address user, uint256 newLpAmount) external;

    function pendingTokens(address user) external view returns (uint256 pending);

    function rewardToken() external view returns (IERC20);
}

contract MasterChef is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using BoringERC20 for IERC20;

    /// @notice Info of each user.
    /// `amount` LP token amount the user has provided.
    /// `rewardDebt` The amount of PLANT entitled to the user.
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }

    /// @notice Info of each pool.
    /// `lpToken` Address of LP token contract.
    /// `allocPoint` The amount of allocation points assigned to the pool.
    ///     Also known as the amount of PLANT to distribute per second.
    /// `lastRewardTimestamp` Last timestamp that PLANTs distribution occurs.
    /// `depositFeeBP` Fee in basis points
    /// `accPlantPerShare` Accumulated PLANTs per share.
    struct PoolInfo {
        IERC20 lpToken;
        uint256 allocPoint;
        uint256 lastRewardTimestamp;
        uint256 accPlantPerShare;        
        IRewarder rewarder;
        uint16 depositFeeBP;
    }

    /// @notice The PLANT TOKEN!
    PlantToken public plant;
    /// @notice Address to store PLANT token reward
    Rewards public plantRewardContract;
    /// @notice DEV address.
    address public devAddr;
    /// @notice Treasury address.
    address public treasuryAddr;
    /// @notice Fee address.
    address public feeAddr;
    /// @notice Investor address
    address public investorAddr;
    /// @notice PLANT tokens created per second.
    uint256 public plantPerSec;
    /// @notice Limit plant per sec
    uint256 public plantPerSecLimit;
    /// @notice Percentage of pool rewards that goto the devs.
    uint256 public devPercent;
    /// @notice Percentage of pool rewards that goes to the treasury.
    uint256 public treasuryPercent;
    /// @notice Percentage of pool rewards that goes to the investor.
    uint256 public investorPercent;

    /// @notice Info of each pool.
    PoolInfo[] public poolInfo;
    /// @notice Mapping to check which LP tokens have been added as pools.
    mapping(IERC20 => bool) public isPool;
    /// @notice Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    /// @notice Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint;
    /// @notice The timestamp when PLANT mining starts.
    uint256 public startTimestamp;
    uint256 public constant ACC_PLANT_PRECISION = 1e12;
    /// @notice Maximum deposit fee rate: 10%
    uint16 public constant MAXIMUM_DEPOSIT_FEE_RATE = 1000;

    event Add(uint256 indexed pid, uint256 allocPoint, IERC20 indexed lpToken, uint16 depositFeeBP, IRewarder indexed rewarder);
    event Set(uint256 indexed pid, uint256 allocPoint, uint16 depositFeeBP, IRewarder indexed rewarder, bool overwrite);
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event UpdatePool(uint256 indexed pid, uint256 lastRewardTimestamp, uint256 lpSupply, uint256 accPlantPerShare);
    event Harvest(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event SetDevAddress(address indexed oldAddress, address indexed newAddress);
    event UpdateEmissionRate(address indexed user, uint256 plantPerSec);

    constructor(
        PlantToken _plant,
        Rewards _plantRewardContract,
        address _devAddr,
        address _feeAddr,
        address _treasuryAddr,
        address _investorAddr,
        uint256 _plantPerSec,
        uint256 _devPercent,
        uint256 _treasuryPercent,
        uint256 _investorPercent
    ) public {
        require(0 <= _devPercent && _devPercent <= 300, "constructor: invalid dev percent value");
        require(0 <= _treasuryPercent && _treasuryPercent <= 300, "constructor: invalid treasury percent value");
        require(0 <= _investorPercent && _investorPercent <= 300, "constructor: invalid investor percent value");
        require(_devPercent + _treasuryPercent + _investorPercent <= 300, "constructor: total percent over max");
        plant = _plant;
        plantRewardContract = _plantRewardContract;
        devAddr = _devAddr;
        feeAddr = _feeAddr;
        treasuryAddr = _treasuryAddr;
        investorAddr = _investorAddr;
        plantPerSec = _plantPerSec;
        plantPerSecLimit = _plantPerSec;
        devPercent = _devPercent;
        treasuryPercent = _treasuryPercent;
        investorPercent = _investorPercent;
        totalAllocPoint = 0;

        //StartBlock always many years later from contract const ruct, will be set later in StartFarming function
        startTimestamp = block.timestamp + (60 * 60 * 24 * 365);
    }

    /// @notice Set farming start, can call only once
    function startFarming() public onlyOwner {
        require(block.timestamp < startTimestamp, "start farming: farm started already");

        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            PoolInfo storage pool = poolInfo[pid];
            pool.lastRewardTimestamp = block.timestamp;
        }

        startTimestamp = block.timestamp;
    }

    modifier validatePoolByPid(uint256 _pid) {
        require(_pid < poolInfo.length, "Pool does not exist");
        _;
    }

    /// @notice Returns the number of MasterChef pools.
    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    /// @notice Add a new lp to the pool. Can only be called by the owner.
    /// DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    /// @param _allocPoint AP of the new pool.
    /// @param _lpToken Address of the LP ERC-20 token.
    /// @param _depositFeeBP Deposit fee.
    /// @param _rewarder Address of the rewarder delegate.
    /// @param _withUpdate Whether call "massUpdatePools" operation.
    function add(
        uint256 _allocPoint,
        IERC20 _lpToken,
        uint16 _depositFeeBP,
        IRewarder _rewarder,
        bool _withUpdate
    ) external onlyOwner {
        require(!isPool[_lpToken], "add: LP already added");
        require(_depositFeeBP <= MAXIMUM_DEPOSIT_FEE_RATE, "add: deposit fee too high");
        // Sanity check to ensure _lpToken is an ERC20 token
        _lpToken.balanceOf(address(this));
        // Sanity check if we add a rewarder
        if (address(_rewarder) != address(0)) {
            _rewarder.onPlantReward(address(0), 0);
        }
        if (_withUpdate) {
            _massUpdatePools();
        }

        uint256 lastRewardTimestamp = block.timestamp > startTimestamp ? block.timestamp : startTimestamp;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);

        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardTimestamp: lastRewardTimestamp,
                accPlantPerShare: 0,                
                rewarder: _rewarder,
                depositFeeBP: _depositFeeBP
            })
        );
        isPool[_lpToken] = true;
        emit Add(poolInfo.length.sub(1), _allocPoint, _lpToken, _depositFeeBP, _rewarder);
    }

    /// @notice Update the given pool's PLANT allocation point and `IRewarder` contract. Can only be called by the owner.
    /// @param _pid The index of the pool. See `poolInfo`.
    /// @param _allocPoint New AP of the pool.
    /// @param _depositFeeBP Deposit fee.
    /// @param _rewarder Address of the rewarder delegate.
    /// @param overwrite True if _rewarder should be `set`. Otherwise `_rewarder` is ignored.
    /// @param _withUpdate Whether call "_massUpdatePools" operation.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        uint16 _depositFeeBP,
        IRewarder _rewarder,
        bool overwrite,
        bool _withUpdate
    ) external onlyOwner validatePoolByPid(_pid) {
        require(_depositFeeBP <= MAXIMUM_DEPOSIT_FEE_RATE, "set: deposit fee too high");
        /// No matter _withUpdate is true or false, we need to execute updatePool once before set the pool parameters.
        _updatePool(_pid);

        if (_withUpdate) {
            _massUpdatePools();
        }

        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
        if (overwrite) {
            _rewarder.onPlantReward(address(0), 0); // sanity check
            poolInfo[_pid].rewarder = _rewarder;
        }
        emit Set(_pid, _allocPoint, _depositFeeBP, overwrite ? _rewarder : poolInfo[_pid].rewarder, overwrite);
    }

    /// @notice View function to see pending PLANT on frontend.
    /// @param _pid The index of the pool. See `poolInfo`.
    /// @param _user Address of user.
    /// @return pendingPlant PLANT reward for a given user.
    //          bonusTokenAddress The address of the bonus reward.
    //          bonusTokenSymbol The symbol of the bonus token.
    //          pendingBonusToken The amount of bonus rewards pending.
    function pendingTokens(
        uint256 _pid,
        address _user
    )
        external
        view
        returns (
            uint256 pendingPlant,
            address bonusTokenAddress,
            string memory bonusTokenSymbol,
            uint256 pendingBonusToken
        )
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accPlantPerShare = pool.accPlantPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTimestamp && lpSupply != 0) {
            uint256 timeElapsed = block.timestamp.sub(pool.lastRewardTimestamp);
            uint256 lpPercent = 1000 - devPercent - treasuryPercent - investorPercent;
            uint256 plantReward = timeElapsed
                .mul(plantPerSec)
                .mul(pool.allocPoint)
                .div(totalAllocPoint)
                .mul(lpPercent)
                .div(1000);
            accPlantPerShare = accPlantPerShare.add(plantReward.mul(ACC_PLANT_PRECISION).div(lpSupply));
        }
        pendingPlant = user.amount.mul(accPlantPerShare).div(ACC_PLANT_PRECISION).sub(user.rewardDebt);

        // If it's a double reward farm, we return info about the bonus token
        if (address(pool.rewarder) != address(0)) {
            bonusTokenAddress = address(pool.rewarder.rewardToken());
            bonusTokenSymbol = IERC20(pool.rewarder.rewardToken()).safeSymbol();
            pendingBonusToken = pool.rewarder.pendingTokens(_user);
        }
    }

    /// @notice Update plant reward for all the active pools. Be careful of gas spending!
    function massUpdatePools() external nonReentrant {
        _massUpdatePools();
    }

    /// @notice Internal method for massUpdatePools
    function _massUpdatePools() internal {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            PoolInfo storage pool = poolInfo[pid];
            if (pool.allocPoint != 0) {
                _updatePool(pid);
            }
        }
    }

    /// @notice Update reward variables of the given pool to be up-to-date.
    /// @param _pid The index of the pool. See `poolInfo`.
    function updatePool(uint256 _pid) external nonReentrant {
        _updatePool(_pid);
    }

    /// @notice Internal method for updatePool
    function _updatePool(uint256 _pid) internal validatePoolByPid(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp > pool.lastRewardTimestamp) {
            uint256 lpSupply = pool.lpToken.balanceOf(address(this));
            // gas opt and prevent div by 0
            if (lpSupply > 0 && totalAllocPoint > 0) {
                uint256 timeElapsed = block.timestamp.sub(pool.lastRewardTimestamp);
                uint256 plantReward = timeElapsed.mul(plantPerSec).mul(pool.allocPoint).div(totalAllocPoint);
                uint256 lpPercent = 1000 - devPercent - treasuryPercent - investorPercent;
                plant.mint(devAddr, plantReward.mul(devPercent).div(1000));
                plant.mint(treasuryAddr, plantReward.mul(treasuryPercent).div(1000));
                plant.mint(investorAddr, plantReward.mul(investorPercent).div(1000));
                plant.mint(address(plantRewardContract), plantReward.mul(lpPercent).div(1000));

                pool.accPlantPerShare = pool.accPlantPerShare.add(
                    plantReward.mul(ACC_PLANT_PRECISION).div(lpSupply).mul(lpPercent).div(1000)
                );
            }
            pool.lastRewardTimestamp = block.timestamp;
            emit UpdatePool(_pid, pool.lastRewardTimestamp, lpSupply, pool.accPlantPerShare);
        }
    }

    /// @notice Deposit LP tokens to MasterChef for Plant allocation.
    /// @param _pid The index of the pool. See `poolInfo`.
    /// @param _amount LP token amount to deposit.
    function deposit(uint256 _pid, uint256 _amount) external nonReentrant {
        _deposit(_pid, _amount);
    }

    /// @notice Internal method for deposit
    function _deposit(uint256 _pid, uint256 _amount) internal validatePoolByPid(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        _updatePool(_pid);

        if (user.amount > 0) {
            // Harvest PLANT
            uint256 pending = user.amount.mul(pool.accPlantPerShare).div(ACC_PLANT_PRECISION).sub(user.rewardDebt);
            if (pending > 0) {
                safePlantTransfer(msg.sender, pending);
                emit Harvest(msg.sender, _pid, pending);
            }
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            if (pool.depositFeeBP > 0) {
                uint256 depositFee = (_amount * pool.depositFeeBP) / 10000;
                pool.lpToken.safeTransfer(feeAddr, depositFee);

                _amount = _amount - depositFee;
            }
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accPlantPerShare).div(ACC_PLANT_PRECISION);

        IRewarder rewarder = pool.rewarder;
        if (address(rewarder) != address(0)) {
            rewarder.onPlantReward(msg.sender, user.amount);
        }
        emit Deposit(msg.sender, _pid, _amount);
    }

    /// @notice Withdraw LP tokens from MasterChef.
    /// @param _pid The index of the pool. See `poolInfo`.
    /// @param _amount LP token amount to withdraw.
    function withdraw(uint256 _pid, uint256 _amount) external nonReentrant validatePoolByPid(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: Insufficient");

        _updatePool(_pid);

        // Harvest PLANT
        uint256 pending = user.amount.mul(pool.accPlantPerShare).div(ACC_PLANT_PRECISION).sub(user.rewardDebt);
        if (pending > 0) {
            safePlantTransfer(msg.sender, pending);
            emit Harvest(msg.sender, _pid, pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accPlantPerShare).div(ACC_PLANT_PRECISION);

        IRewarder rewarder = pool.rewarder;
        if (address(rewarder) != address(0)) {
            rewarder.onPlantReward(msg.sender, user.amount);
        }
        emit Withdraw(msg.sender, _pid, _amount);
    }

    /// @notice Withdraw without caring about rewards. EMERGENCY ONLY.
    /// @param _pid The index of the pool. See `poolInfo`.
    function emergencyWithdraw(uint256 _pid) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;

        IRewarder rewarder = pool.rewarder;
        if (address(rewarder) != address(0)) {
            rewarder.onPlantReward(msg.sender, 0);
        }

        // Note: transfer can fail or succeed if `amount` is zero.
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    /// @notice Function to harvest many pools in a single transaction
    function harvestMany(uint256[] calldata _pids) public nonReentrant {
        require(_pids.length <= 30, "harvest many: too many pool ids");
        for (uint256 index = 0; index < _pids.length; ++index) {
            _deposit(_pids[index], 0);
        }
    }

    /// @notice Safe plant transfer function, just in case if rounding error causes pool to not have enough PLANTs.
    function safePlantTransfer(address _to, uint256 _amount) internal {
        plantRewardContract.safePlantTransfer(_to, _amount);
    }

    /// @notice Update dev address by the previous dev.
    function dev(address _devAddr) external {
        require(msg.sender == devAddr, "dev: wut?");
        devAddr = _devAddr;
        emit SetDevAddress(msg.sender, _devAddr);
    }

    /// @notice Update Dev percent
    function setDevPercent(uint256 _newDevPercent) public onlyOwner {
        require(0 <= _newDevPercent && _newDevPercent <= 100, "setDevPercent: invalid percent value");
        require(treasuryPercent + _newDevPercent + investorPercent <= 300, "setDevPercent: total percent over max");
        devPercent = _newDevPercent;
    }

    /// @notice Update treasury address by the previous treasury.
    function setTreasuryAddr(address _treasuryAddr) public {
        require(msg.sender == treasuryAddr, "setTreasuryAddr: wut?");
        treasuryAddr = _treasuryAddr;
    }

    /// @notice Update treasury percent
    function setTreasuryPercent(uint256 _newTreasuryPercent) public onlyOwner {
        require(0 <= _newTreasuryPercent && _newTreasuryPercent <= 100, "setTreasuryPercent: invalid percent value");
        require(
            devPercent + _newTreasuryPercent + investorPercent <= 300,
            "setTreasuryPercent: total percent over max"
        );
        treasuryPercent = _newTreasuryPercent;
    }

    /// @notice Update the investor address by the previous investor.
    function setInvestorAddr(address _investorAddr) public {
        require(msg.sender == investorAddr, "setInvestorAddr: wut?");
        investorAddr = _investorAddr;
    }

    /// @notice Update investor percent
    function setInvestorPercent(uint256 _newInvestorPercent) public onlyOwner {
        require(0 <= _newInvestorPercent && _newInvestorPercent <= 100, "setInvestorPercent: invalid percent value");
        require(
            devPercent + _newInvestorPercent + treasuryPercent <= 300,
            "setInvestorPercent: total percent over max"
        );
        investorPercent = _newInvestorPercent;
    }

    /// @notice Update fee address by owner.
    function setFeeAddr(address _feeAddr) external onlyOwner {
        feeAddr = _feeAddr;
    }

    /// @notice Update plant per second
    function updateEmissionRate(uint256 _plantPerSec) external onlyOwner {
        require(_plantPerSec < plantPerSecLimit, "updateEmissionRate: cannot exceed plantPerSecLimit");
        _massUpdatePools();
        plantPerSec = _plantPerSec;
        emit UpdateEmissionRate(msg.sender, _plantPerSec);
    }
}
