// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
@author Rainbow Code Finance
@title Fee Manager
@notice Manages fee from vaults
*/

contract FeeManager {

    error InsufficientBalance(uint256 requested, uint256 avaible);

    constructor() {}

    mapping(address => uint256) collectableFees;

    function getCollectableFees(address a) public view returns(uint256) {
        return collectableFees[a];
    }

    function deposit(address dest, uint256 amount) external {

    }

    function withdraw(address dest, uint256 amount) external {
        if(_msgSender() != dest)
            revert("Cannot withdraw fees of other users!");
        
        uint256 avaible = getCollectableFees(dest);
        
        if(amount > avaible)
            revert InsufficientBalance(amount, avaible);

        collectableFees[dest] = 0;
        
        //send tokens to user
    }
}