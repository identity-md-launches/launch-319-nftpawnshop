// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {NFTPawnShop} from "../src/NFTPawnShop.sol";

contract FactoryProbe {
    function deploy(bytes memory code, bytes32 salt) external payable returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(callvalue(), add(code, 32), mload(code), salt)
        }
        require(deployed != address(0), "constructor failed");
    }
}

contract DeploymentTest is Test {
    function test_factoryConstructorsNeedNoInitializationOrTokenAllocation() public {
        FactoryProbe factory = new FactoryProbe();
        LaunchToken token = LaunchToken(factory.deploy(type(LaunchToken).creationCode, bytes32(uint256(1))));
        NFTPawnShop shop = NFTPawnShop(factory.deploy(type(NFTPawnShop).creationCode, bytes32(uint256(2))));
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(factory)), 1e27);
        assertEq(token.balanceOf(address(shop)), 0);
        assertEq(shop.loanCount(), 0);
        assertEq(shop.withdrawable(address(factory)), 0);
        _scanRuntime(address(token));
        _scanRuntime(address(shop));
    }

    function test_constructorsRejectETH() public {
        FactoryProbe factory = new FactoryProbe();
        vm.deal(address(this), 2);
        vm.expectRevert("constructor failed");
        factory.deploy{value: 1}(type(LaunchToken).creationCode, bytes32(uint256(1)));
        vm.expectRevert("constructor failed");
        factory.deploy{value: 1}(type(NFTPawnShop).creationCode, bytes32(uint256(2)));
    }

    function _scanRuntime(address deployed) private view {
        bytes memory code = deployed.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 opcode = uint8(code[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
            } else {
                assertTrue(opcode != 0xf4 && opcode != 0xf2 && opcode != 0xff, "forbidden runtime opcode");
            }
        }
    }
}
