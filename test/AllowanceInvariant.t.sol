// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMDTToken} from "src/IMDTToken.sol";

/// @dev Balances and authorizations are modeled independently of token getters.
/// Approvals and spends are separate actions so revocation, reuse, and unrelated
/// spenders can interleave. No token storage is edited by cheatcodes.
contract AllowanceModelHandler is Test {
    uint256 private constant SUPPLY = 1_000_000_000e18;
    IMDTToken public immutable token;
    address[5] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    constructor() {
        token = new IMDTToken();
        actors = [
            address(this),
            makeAddr("model holder"),
            makeAddr("model spender"),
            makeAddr("model distributor"),
            address(0x000000000004444c5dc75cB358380D2e3dE08A90)
        ];
        // Give every actor funds without minting or replacing storage. Keep the
        // real constructor recipient as an actor throughout the campaign.
        expectedBalance[address(this)] = SUPPLY;
        for (uint256 i = 1; i < actors.length; ++i) {
            require(token.transfer(actors[i], SUPPLY / 10));
            expectedBalance[address(this)] -= SUPPLY / 10;
            expectedBalance[actors[i]] = SUPPLY / 10;
        }
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 amount = _edgeAmount(amountSeed, SUPPLY);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function revoke(uint256 ownerSeed, uint256 spenderSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        vm.prank(owner);
        assertTrue(token.approve(spender, 0));
        expectedAllowance[owner][spender] = 0;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = _edgeAmount(amountSeed, expectedBalance[from]);
        bool expectedSuccess = amount <= expectedBalance[from];
        vm.prank(from);
        (bool ok, bytes memory result) = address(token).call(abi.encodeCall(token.transfer, (to, amount)));
        _checkResult(ok, result, expectedSuccess);
        if (ok) _move(from, to, amount);
    }

    function transferFrom(uint256 ownerSeed, uint256 toSeed, uint256 spenderSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        address spender = _actor(spenderSeed);
        uint256 authorized = expectedAllowance[owner][spender];
        uint256 available = expectedBalance[owner];
        uint256 limit = available < authorized ? available : authorized;
        uint256 amount = _edgeAmount(amountSeed, limit);
        bool expectedSuccess = amount <= available && amount <= authorized;
        vm.prank(spender);
        (bool ok, bytes memory result) = address(token).call(abi.encodeCall(token.transferFrom, (owner, to, amount)));
        _checkResult(ok, result, expectedSuccess);
        if (ok) {
            _move(owner, to, amount);
            if (authorized != type(uint256).max) expectedAllowance[owner][spender] = authorized - amount;
        }
    }

    function transferToZero(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed, bool delegated) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 authorized = expectedAllowance[owner][spender];
        uint256 limit = expectedBalance[owner];
        if (delegated && authorized < limit) limit = authorized;
        uint256 amount = bound(amountSeed, 0, limit);
        vm.prank(delegated ? spender : owner);
        (bool ok,) = address(token)
            .call(
                delegated
                    ? abi.encodeCall(token.transferFrom, (owner, address(0), amount))
                    : abi.encodeCall(token.transfer, (address(0), amount))
            );
        assertFalse(ok, "zero recipient accepted");
        // The model is unchanged: even allowance deductions must roll back.
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amountSeed) external {
        vm.prank(_actor(ownerSeed));
        (bool ok,) = address(token).call(abi.encodeCall(token.approve, (address(0), amountSeed)));
        assertFalse(ok, "zero spender accepted");
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function _edgeAmount(uint256 seed, uint256 limit) private pure returns (uint256) {
        uint256 mode = seed % 7;
        if (mode == 0) return 0;
        if (mode == 1) return 1;
        if (mode == 2) return limit;
        if (mode == 3) return limit + 1;
        if (mode == 4) return type(uint256).max;
        if (mode == 5) return type(uint256).max - 1;
        return bound(seed, 0, limit);
    }

    function _move(address from, address to, uint256 amount) private {
        // Self-transfers consume delegated authorization but do not move funds.
        if (from != to) {
            expectedBalance[from] -= amount;
            expectedBalance[to] += amount;
        }
    }

    function _checkResult(bool ok, bytes memory result, bool expectedSuccess) private pure {
        assertEq(ok, expectedSuccess, "call success disagrees with authorization model");
        if (expectedSuccess) {
            assertEq(result.length, 32, "missing ERC-20 boolean");
            assertTrue(abi.decode(result, (bool)), "ERC-20 call returned false");
        }
    }
}

contract AllowanceInvariantTest is Test {
    AllowanceModelHandler private handler;
    IMDTToken private token;

    function setUp() public {
        handler = new AllowanceModelHandler();
        token = handler.token();
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = AllowanceModelHandler.approve.selector;
        selectors[1] = AllowanceModelHandler.revoke.selector;
        selectors[2] = AllowanceModelHandler.transfer.selector;
        selectors[3] = AllowanceModelHandler.transferFrom.selector;
        selectors[4] = AllowanceModelHandler.transferToZero.selector;
        selectors[5] = AllowanceModelHandler.approveZeroSpender.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 96
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_BalancesAndAllowancesMatchIndependentModel() public view {
        uint256 total;
        for (uint256 i; i < 5; ++i) {
            address owner = handler.actors(i);
            uint256 balance = token.balanceOf(owner);
            assertEq(balance, handler.expectedBalance(owner), "holder balance changed unexpectedly");
            total += balance;
            for (uint256 j; j < 5; ++j) {
                address spender = handler.actors(j);
                assertEq(
                    token.allowance(owner, spender),
                    handler.expectedAllowance(owner, spender),
                    "authorization changed unexpectedly"
                );
            }
            assertEq(token.allowance(owner, address(0)), 0);
        }
        assertEq(total, 1_000_000_000e18);
        assertEq(token.totalSupply(), total);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }
}
