// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

interface IMasterChef {
    function deposit(uint256 _pid, uint256 _amount) external;

    function withdraw(uint256 _pid, uint256 _amount) external;

    function pendingTokens(
        uint256 _pid,
        address _user
    ) external view returns (uint256, address, string memory, uint256);

    function userInfo(uint256 _pid, address _user) external view returns (uint256, uint256);

    function emergencyWithdraw(uint256 _pid) external;
}

interface IXPlant {
    function deposit(address _user, uint256 _amount) external;

    function withdraw(address _user, uint256 _amount) external;
}

contract LockPLANT is Ownable, Pausable {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    struct UserInfo {
        uint256 shares; // number of shares for a user
        uint256 lastDepositedTime; // keeps track of deposited time for potential penalty
        uint256 PlantAtLastUserAction; // keeps track of Plant deposited at the last user action
        uint256 lastUserActionTime; // keeps track of the last user action time
        uint256 lockStartTime; // lock start time.
        uint256 lockEndTime; // lock end time.
    }

    IERC20 public immutable token; // Plant token

    IMasterChef public immutable masterchef;

    mapping(address => UserInfo) public userInfo;

    uint256 public totalShares;
    address public admin;
    address public treasury;
    address public xplant;
    uint256 public plantPoolPID;

    uint256 public constant LOCK_DURATION = 14 days; // 14 days
    uint256 public constant MIN_DEPOSIT_AMOUNT = 0.00001 ether;
    uint256 public constant MIN_WITHDRAW_AMOUNT = 0.00001 ether;

    event Deposit(address indexed sender, uint256 amount, uint256 shares, uint256 lastDepositedTime);
    event Withdraw(address indexed sender, uint256 amount, uint256 shares);
    event Harvest(address indexed sender, uint256 amount);
    event Pause();
    event Unpause();
    event Init();

    /**
     * @notice Constructor
     * @param _token: Plant token contract
     * @param _masterchef: MasterChef contract
     * @param _admin: address of the admin
     * @param _treasury: address of the treasury (collects fees)
     * @param _pid: cake pool ID in MasterChefV
     */
    constructor(IERC20 _token, IMasterChef _masterchef, address _admin, address _treasury, uint256 _pid) public {
        token = _token;
        masterchef = _masterchef;
        admin = _admin;
        treasury = _treasury;
        plantPoolPID = _pid;
    }

    /**
     * @notice Deposits a dummy token to `MASTER_CHEF`.
     * It will transfer all the `dummyToken` in the tx sender address.
     * @param dummyToken The address of the token to be deposited into MCA.
     */
    function init(IERC20 dummyToken) external onlyOwner {
        uint256 balance = dummyToken.balanceOf(address(this));
        require(balance != 0, "Balance must exceed 0");
        dummyToken.approve(address(masterchef), balance);
        masterchef.deposit(plantPoolPID, balance);
        emit Init();
    }

    /**
     * @notice Checks if the msg.sender is the admin address
     */
    modifier onlyAdmin() {
        require(msg.sender == admin, "admin: wut?");
        _;
    }

    /**
     * @notice Checks if the msg.sender is a contract or a proxy
     */
    modifier notContract() {
        require(!_isContract(msg.sender), "contract not allowed");
        require(msg.sender == tx.origin, "proxy contract not allowed");
        _;
    }

    /**
     * @notice Deposits funds into the Plant Vault
     * @dev Only possible when contract not paused.
     * @param _amount: number of tokens to deposit (in Plant)
     */
    function deposit(uint256 _amount) external whenNotPaused notContract {
        require(_amount > 0, "Nothing to deposit");
        require(_amount > MIN_DEPOSIT_AMOUNT, "Deposit amount must be greater than MIN_DEPOSIT_AMOUNT");

        // Harvest tokens from Masterchef.
        harvest();

        // Handle stock funds.
        if (totalShares == 0) {
            token.safeTransfer(treasury, balanceOf());
        }

        uint256 pool = balanceOf();
        token.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 currentShares = 0;
        if (totalShares != 0) {
            currentShares = (_amount.mul(totalShares)).div(pool);
        } else {
            currentShares = _amount;
        }

        if (xplant != address(0)) {
            IXPlant(xplant).deposit(msg.sender, currentShares);
        }
        UserInfo storage user = userInfo[msg.sender];

        user.shares = user.shares.add(currentShares);
        user.lastDepositedTime = block.timestamp;

        totalShares = totalShares.add(currentShares);

        user.PlantAtLastUserAction = (user.shares.mul(balanceOf())).div(totalShares);
        user.lastUserActionTime = block.timestamp;
        user.lockStartTime = block.timestamp;
        user.lockEndTime = block.timestamp + LOCK_DURATION;

        emit Deposit(msg.sender, _amount, currentShares, block.timestamp);
    }

    /**
     * @notice Withdraws funds from the Plant Vault
     * @param _amount: Number of amount to withdraw
     */
    function withdraw(uint256 _amount) public notContract {
        UserInfo storage user = userInfo[msg.sender];
        require(_amount > 0, "Nothing to withdraw");
        require(_amount > MIN_WITHDRAW_AMOUNT, "Withdraw amount must be greater than MIN_WITHDRAW_AMOUNT");
        require(user.shares > 0, "User share mush greater than zero");
        require(user.lockEndTime < block.timestamp, "Still in lock");

        // Harvest token from Masterchef.
        harvest();

        uint256 pool = balanceOf();
        uint256 currentShare = (_amount.mul(totalShares)).div(pool); // Calculate equivalent shares
        if (currentShare > user.shares) {
            currentShare = user.shares;
        }

        uint256 currentAmount = (balanceOf().mul(currentShare)).div(totalShares);
        user.shares -= currentShare;
        totalShares -= currentShare;

        token.safeTransfer(msg.sender, currentAmount);

        if (user.shares > 0) {
            user.PlantAtLastUserAction = (user.shares.mul(balanceOf())).div(totalShares);
        } else {
            user.PlantAtLastUserAction = 0;
        }

        if (xplant != address(0)) {
            IXPlant(xplant).withdraw(msg.sender, currentShare);
        }

        user.lastUserActionTime = block.timestamp;

        emit Withdraw(msg.sender, currentAmount, currentShare);
    }

    /**
     * @notice Harvest pending PLANT tokens from MasterChef
     */
    function harvest() internal {
        (uint256 pendingPlant, , , ) = masterchef.pendingTokens(plantPoolPID, address(this));
        if (pendingPlant > 0) {
            uint256 balBefore = balanceOf();
            masterchef.withdraw(plantPoolPID, 0);
            uint256 balAfter = balanceOf();
            emit Harvest(msg.sender, (balAfter - balBefore));
        }
    }

    /**
     * @notice Sets admin address
     * @dev Only callable by the contract owner.
     */
    function setAdmin(address _admin) external onlyOwner {
        require(_admin != address(0), "Cannot be zero address");
        admin = _admin;
    }

    /**
     * @notice Sets treasury address
     * @dev Only callable by the contract owner.
     */
    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Cannot be zero address");
        treasury = _treasury;
    }

    /**
     * @notice Sets XPlant address
     * @dev Only callable by the contract owner.
     */
    function setXPlant(address _xplant) external onlyOwner {
        require(_xplant != address(0), "Cannot be zero address");
        xplant = _xplant;
    }

    /**
     * @notice Withdraw unexpected tokens sent to the Plant Vault
     */
    function inCaseTokensGetStuck(address _token) external onlyAdmin {
        require(_token != address(token), "Token cannot be same as deposit token");

        uint256 amount = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransfer(msg.sender, amount);
    }

    /**
     * @notice Triggers stopped state
     * @dev Only possible when contract not paused.
     */
    function pause() external onlyAdmin whenNotPaused {
        _pause();
        emit Pause();
    }

    /**
     * @notice Returns to normal state
     * @dev Only possible when contract is paused.
     */
    function unpause() external onlyAdmin whenPaused {
        _unpause();
        emit Unpause();
    }

    /**
     * @notice Calculates the total pending rewards that can be restaked
     * @return Returns total pending Plant rewards
     */
    function calculateTotalPendingPlantRewards() public view returns (uint256) {
        (uint256 amount, , , ) = masterchef.pendingTokens(plantPoolPID, address(this));
        return amount;
    }

    /**
     * @notice Calculates the price per share
     */
    function getPricePerFullShare() external view returns (uint256) {
        return totalShares == 0 ? 1e18 : (((balanceOf() + calculateTotalPendingPlantRewards()) * (1e18)) / totalShares);
    }

    /**
     * @notice Calculates the total underlying tokens
     * @dev It includes tokens held by the contract
     */
    function balanceOf() public view returns (uint256) {
        return token.balanceOf(address(this));
    }

    /**
     * @notice Checks if address is a contract
     * @dev It prevents contract from being targetted
     */
    function _isContract(address addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }
}
