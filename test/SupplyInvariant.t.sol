// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMDTToken} from "../src/IMDTToken.sol";

contract TransferHandler is Test {
    IMDTToken public immutable token;
    address[5] public actors;

    constructor() {
        token = new IMDTToken();
        actors = [
            address(this),
            makeAddr("holder one"),
            makeAddr("holder two"),
            makeAddr("distributor fixture"),
            address(0x000000000004444c5dc75cB358380D2e3dE08A90)
        ];
    }

    function move(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
    }

    function approveAndSpend(uint256 fromSeed, uint256 toSeed, uint256 spenderSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        token.approve(spender, amount);
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));
        assertEq(token.allowance(from, spender), 0);
    }

    function overspend(uint256 fromSeed, uint256 toSeed) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 beforeFrom = token.balanceOf(from);
        uint256 beforeTo = token.balanceOf(to);
        vm.prank(from);
        (bool ok,) = address(token).call(abi.encodeCall(token.transfer, (to, beforeFrom + 1)));
        assertFalse(ok);
        assertEq(token.balanceOf(from), beforeFrom);
        assertEq(token.balanceOf(to), beforeTo);
    }
}

contract SupplyInvariantTest is Test {
    TransferHandler private handler;
    IMDTToken private token;

    function setUp() public {
        handler = new TransferHandler();
        token = handler.token();
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = TransferHandler.move.selector;
        selectors[1] = TransferHandler.approveAndSpend.selector;
        selectors[2] = TransferHandler.overspend.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_SupplyIsFixedAndEveryUnitIsAccountedFor() public view {
        uint256 balances;
        for (uint256 i; i < 5; ++i) {
            balances += token.balanceOf(handler.actors(i));
        }
        assertEq(balances, 1_000_000_000e18);
        assertEq(token.totalSupply(), balances);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(0)), 0);
    }
}
