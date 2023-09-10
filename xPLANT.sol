pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract xPLANT is ERC20("xPLANT", "xPLANT") {

    address public lockContract;
    /**
     * @notice Checks if the msg.sender is the admin address.
     */
    modifier onlyLockContract() {
        require(msg.sender == lockContract, "lockContract: wut?");
        _;
    }

    constructor(address _lockContract) public {
        lockContract = _lockContract;
    }

     function deposit(address _user, uint256 _amount) external onlyLockContract {
        _mint(_user, _amount);
     }

     function withdraw(address _user, uint256 _amount) external onlyLockContract {
        _burn(_user, _amount);
     }

}