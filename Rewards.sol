pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./PlantToken.sol";

contract Rewards is Ownable {
    /// @notice The PLANT TOKEN
    PlantToken public plant;

    constructor(
        PlantToken _plant
    ) public {
        plant = _plant;
    }

    /// @notice Safe plant transfer function, just in case if rounding error causes pool to not have enough PLANTs.
    function safePlantTransfer(address _to, uint256 _amount) public onlyOwner {
        uint256 plantBal = plant.balanceOf(address(this));
        if (_amount > plantBal) {
            plant.transfer(_to, plantBal);
        } else {
            plant.transfer(_to, _amount);
        }
    }
}