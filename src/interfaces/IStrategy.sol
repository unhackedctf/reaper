// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IStrategy {
    //vault only - withdraws funds from the strategy
    function withdraw(uint256 _amount) external returns (uint256 loss);

    //claims rewards, charges fees, and re-deposits; returns caller fee amount.
    function harvest() external returns (uint256 callerFee);

    //returns the balance of all tokens managed by the strategy
    function balanceOf() external view returns (uint256);

    //returns the address of the vault that the strategy is serving
    function vault() external view returns (address);

    //returns the address of the token that the strategy needs to operate
    function want() external view returns (address);
}
