pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract PlantToken is ERC20("PlantBaseSwap Token", "PLANT"), Ownable {

    /// @notice Total number of tokens
    uint256 public constant maxSupply = 50_000_000e18; // 50_000_000 PLANT

    /// @notice Creates `_amount` token to `_to`. Must only be called by the owner (MasterChef).
    function mint(address _to, uint256 _amount) public onlyOwner {
        if(totalSupply().add(_amount) <= maxSupply){
            _mint(_to, _amount);
        }        
    }
}