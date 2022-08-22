// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/ReaperVaultV2.sol";

interface IERC20Like {
    function balanceOf(address _addr) external view returns (uint);
}

contract CounterTest is Test {
    ReaperVaultV2 reaper = ReaperVaultV2(0x77dc33dC0278d21398cb9b16CbFf99c1B712a87A);
    IERC20Like fantomDai = IERC20Like(0x8D11eC38a3EB5E956B052f67Da8Bdc9bef8Abf3E);

    function testReaperHack() public {
        vm.createSelectFork(vm.envString("FANTOM_RPC"), 44000000);
        console.log("Your Starting Balance:", fantomDai.balanceOf(address(this)));
        
        // INSERT EXPLOIT HERE

        console.log("Your Final Balance:", fantomDai.balanceOf(address(this)));
        assert(fantomDai.balanceOf(address(this)) > 400_000 ether);
    }
}
