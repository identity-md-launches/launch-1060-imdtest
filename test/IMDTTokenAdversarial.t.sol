// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IMDTToken} from "src/IMDTToken.sol";

contract RejectingTokenRecipient {
    fallback() external {
        revert("recipient does not accept callbacks");
    }
}

contract IMDTTokenAdversarialTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000e18;
    IMDTToken private token;
    address private holder;
    address private spender;
    address private recipient;

    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public {
        token = new IMDTToken();
        holder = makeAddr("adversarial holder");
        spender = makeAddr("authorized spender");
        recipient = makeAddr("unapproved recipient");
        token.transfer(holder, SUPPLY);
    }

    function test_ZeroTransferFromNeedsNoApprovalAndEmitsTransfer() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(holder, recipient, 0);
        vm.prank(spender);
        assertTrue(token.transferFrom(holder, recipient, 0));
        assertEq(token.allowance(holder, spender), 0);
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.balanceOf(recipient), 0);
    }

    function test_RecipientAndHolderCannotBorrowAnotherSpendersAllowance() public {
        vm.prank(holder);
        token.approve(spender, 2);
        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, recipient, 0, 1));
        token.transferFrom(holder, recipient, 1);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, holder, 0, 1));
        token.transferFrom(holder, recipient, 1);
        assertEq(token.allowance(holder, spender), 2);
        assertEq(token.balanceOf(holder), SUPPLY);
        vm.prank(spender);
        assertTrue(token.transferFrom(holder, recipient, 2));
        assertEq(token.balanceOf(recipient), 2);
    }

    function test_ZeroSourceCannotMintEvenThroughZeroTransferFrom() public {
        vm.prank(spender);
        vm.expectRevert();
        token.transferFrom(address(0), recipient, 0);
        vm.prank(spender);
        vm.expectRevert();
        token.transferFrom(address(0), recipient, 1);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function test_TransfersNeedNoRecipientConsentOrCallback() public {
        RejectingTokenRecipient rejecting = new RejectingTokenRecipient();
        vm.prank(holder);
        assertTrue(token.transfer(address(rejecting), 1));
        vm.prank(holder);
        token.approve(spender, 1);
        vm.prank(spender);
        assertTrue(token.transferFrom(holder, address(rejecting), 1));
        assertEq(token.balanceOf(address(rejecting)), 2);
        assertEq(token.balanceOf(holder), SUPPLY - 2);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RevokingInfiniteAllowanceTakesEffectImmediately() public {
        vm.startPrank(holder);
        token.approve(spender, type(uint256).max);
        token.approve(spender, 0);
        vm.stopPrank();
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(holder, recipient, 1);
        assertEq(token.allowance(holder, spender), 0);
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.balanceOf(recipient), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_DelegatedSelfTransferConsumesAuthorizationOnly(uint256 amount) public {
        amount = bound(amount, 1, SUPPLY);
        vm.prank(holder);
        token.approve(spender, amount);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(holder, holder, amount);
        vm.prank(spender);
        assertTrue(token.transferFrom(holder, holder, amount));
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.allowance(holder, spender), 0);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(holder, recipient, 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_MaximumMinusOneAllowanceIsFinite(uint256 amount) public {
        amount = bound(amount, 1, SUPPLY);
        uint256 approved = type(uint256).max - 1;
        vm.prank(holder);
        token.approve(spender, approved);
        vm.prank(spender);
        assertTrue(token.transferFrom(holder, recipient, amount));
        assertEq(token.allowance(holder, spender), approved - amount);
        assertEq(token.balanceOf(holder), SUPPLY - amount);
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_OverdrawWithEnoughAllowanceRollsBackAndCanBeRetried(uint256 balance, bool infinite) public {
        balance = bound(balance, 0, SUPPLY - 1);
        vm.prank(holder);
        token.transfer(address(this), SUPPLY - balance);
        uint256 requested = balance + 1;
        uint256 approved = infinite ? type(uint256).max : requested;
        vm.prank(holder);
        token.approve(spender, approved);

        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, balance, requested)
        );
        token.transferFrom(holder, recipient, requested);
        assertEq(token.allowance(holder, spender), approved, "failed spend consumed authorization");
        assertEq(token.balanceOf(holder), balance);
        assertEq(token.balanceOf(recipient), 0);

        // Adding exactly the missing unit allows the same authorization to work.
        token.transfer(holder, 1);
        vm.prank(spender);
        assertTrue(token.transferFrom(holder, recipient, requested));
        assertEq(token.allowance(holder, spender), infinite ? type(uint256).max : 0);
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(recipient), requested);
        assertEq(token.balanceOf(address(this)), SUPPLY - requested);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
