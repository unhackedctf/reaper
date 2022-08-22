// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

import './CTokenI.sol';
interface IComptroller {
    function compAccrued(address user) external view returns (uint256 amount);
    function claimComp(address holder, CTokenI[] memory _scTokens) external;
    function claimComp(address holder) external;
    function enterMarkets(address[] memory _scTokens) external;
    function pendingComptrollerImplementation() view external returns (address implementation);
    function markets(address ctoken)
        external
        view
        returns (
            bool,
            uint256,
            bool
        );
    function compSpeeds(address ctoken) external view returns (uint256); // will be deprecated
}