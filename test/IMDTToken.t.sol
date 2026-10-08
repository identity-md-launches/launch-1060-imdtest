// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IMDTToken} from "../src/IMDTToken.sol";

contract TokenFactoryFixture {
    function deploy() external returns (IMDTToken) {
        return new IMDTToken();
    }
}

contract IMDTTokenTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000e18;
    address private constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    IMDTToken private token;
    address private alice;
    address private bob;
    address private spender;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new IMDTToken();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        spender = makeAddr("spender");
    }

    function test_DeploymentMatchesManifest() public view {
        assertEq(token.name(), "IMDTEST");
        assertEq(token.symbol(), "IMDT");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(MANAGER), 0);
    }

    function test_ConstructorMintsOnlyToImmediateFactoryDeployer() public {
        TokenFactoryFixture factory = new TokenFactoryFixture();
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), address(factory), SUPPLY);
        IMDTToken launched = factory.deploy();
        assertEq(launched.balanceOf(address(factory)), SUPPLY);
        assertEq(launched.balanceOf(address(this)), 0);
        assertEq(launched.balanceOf(address(launched)), 0);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    function test_TransferEntireBalanceEmitsAndHasNoFee() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), alice, SUPPLY);
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ZeroAndSelfTransfersPreserveBalances() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), alice, 0);
        assertTrue(token.transfer(alice, 0));
        assertTrue(token.transfer(address(this), SUPPLY));
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_PoolManagerReceivesAndReturnsExactAmount() public {
        uint256 amount = SUPPLY * 9 / 10;
        assertTrue(token.transfer(MANAGER, amount));
        assertEq(token.balanceOf(MANAGER), amount);
        vm.prank(MANAGER);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(MANAGER), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ApproveOverwriteAndRevoke() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), spender, 100);
        assertTrue(token.approve(spender, 100));
        assertTrue(token.approve(spender, 50));
        assertEq(token.allowance(address(this), spender), 50);
        assertTrue(token.approve(spender, 0));
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(address(this), alice, 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_TransferFromConsumesExactAllowance() public {
        token.approve(spender, 100);
        vm.startPrank(spender);
        assertTrue(token.transferFrom(address(this), alice, 40));
        assertEq(token.allowance(address(this), spender), 60);
        assertTrue(token.transferFrom(address(this), bob, 60));
        assertEq(token.allowance(address(this), spender), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(address(this), bob, 1);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 40);
        assertEq(token.balanceOf(bob), 60);
        assertEq(token.balanceOf(address(this)), SUPPLY - 100);
    }

    function test_InfiniteAllowanceRemainsInfinite() public {
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, SUPPLY));
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        assertEq(token.balanceOf(alice), SUPPLY);
    }

    function test_RevertTransferToZeroIncludingZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_RevertApproveZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_RevertInsufficientBalanceAndMaximumAmount() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1)
        );
        token.transfer(alice, SUPPLY + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        token.transfer(alice, type(uint256).max);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_FailedTransferFromPreservesAllowanceAndBalances() public {
        vm.prank(alice);
        token.approve(spender, 100);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 100));
        token.transferFrom(alice, bob, 100);
        assertEq(token.allowance(alice, spender), 100);
        assertEq(token.balanceOf(bob), 0);

        token.approve(spender, 100);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(address(this), address(0), 100);
        assertEq(token.allowance(address(this), spender), 100);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_DeployerCannotSpendHolderFundsWithoutAllowance() public {
        token.transfer(alice, 100);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(alice, bob, 1);
        assertEq(token.balanceOf(alice), 100);
    }

    function test_NoOwnerMintBurnOrAdminEntryPointsForAnyone() public {
        // Encode valid arguments for each selector: malformed booleans or a
        // burn above the caller's balance could hide an existing admin method.
        bytes[26] memory calls = [
            abi.encodeWithSignature("owner()"),
            abi.encodeWithSignature("mint(address,uint256)", alice, uint256(1)),
            abi.encodeWithSignature("mint(uint256)", uint256(1)),
            abi.encodeWithSignature("mint()"),
            abi.encodeWithSignature("burn(uint256)", uint256(1)),
            abi.encodeWithSignature("burnFrom(address,uint256)", alice, uint256(1)),
            abi.encodeWithSignature("transferOwnership(address)", bob),
            abi.encodeWithSignature("renounceOwnership()"),
            abi.encodeWithSignature("setOwner(address)", bob),
            abi.encodeWithSignature("setMinter(address)", bob),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("unpause()"),
            abi.encodeWithSignature("blacklist(address)", alice),
            abi.encodeWithSignature("freeze(address)", alice),
            abi.encodeWithSignature("seize(address)", alice),
            abi.encodeWithSignature("setFee(uint256)", uint256(12_500)),
            abi.encodeWithSignature("upgradeTo(address)", address(token)),
            abi.encodeWithSignature("initialize(address)", bob),
            abi.encodeWithSignature("grantRole(bytes32,address)", bytes32(0), bob),
            abi.encodeWithSignature("setTransfersEnabled(bool)", false),
            abi.encodeWithSignature("setBlacklist(address,bool)", alice, true),
            abi.encodeWithSignature("setBlocked(address,bool)", alice, true),
            abi.encodeWithSignature("setName(string)", "Changed"),
            abi.encodeWithSignature("setSymbol(string)", "OTHER"),
            abi.encodeWithSignature("setDecimals(uint8)", uint8(6)),
            abi.encodeWithSignature("initialize()")
        ];
        token.transfer(alice, 100);
        token.transfer(bob, 100);
        vm.startPrank(alice);
        token.approve(address(this), 100);
        token.approve(bob, 100);
        vm.stopPrank();
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(token).call(calls[i]);
            assertFalse(ok, string.concat("deployer reached admin selector ", vm.toString(bytes4(calls[i]))));
            vm.prank(bob);
            (ok,) = address(token).call(calls[i]);
            assertFalse(ok, string.concat("holder reached admin selector ", vm.toString(bytes4(calls[i]))));
            assertEq(token.totalSupply(), SUPPLY);
            assertEq(token.balanceOf(alice), 100);
            assertEq(token.balanceOf(bob), 100);
            assertEq(token.allowance(alice, address(this)), 100);
            assertEq(token.allowance(alice, bob), 100);
        }
        assertEq(token.name(), "IMDTEST");
        assertEq(token.symbol(), "IMDT");
        assertEq(token.decimals(), 18);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 100));
    }

    function test_NoFallbackOrPayableEntryPoint() public {
        (bool ok,) = address(token).call(hex"ffffffff");
        assertFalse(ok);
        (ok,) = address(token).call("");
        assertFalse(ok);
        vm.deal(address(this), 1 ether);
        (ok,) = address(token).call{value: 1}(abi.encodeCall(token.transfer, (alice, 1)));
        assertFalse(ok);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_RuntimeContainsNoForbiddenOpcodes() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
            } else {
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
            }
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_TransferRoundTripConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        vm.prank(alice);
        assertTrue(token.transfer(address(this), amount));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_DelegatedTransferCannotExceedAuthorization(uint256 approved, uint256 requested) public {
        approved = bound(approved, 0, SUPPLY - 1);
        requested = bound(requested, approved + 1, SUPPLY);
        token.approve(spender, approved);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, approved, requested)
        );
        token.transferFrom(address(this), alice, requested);
        assertEq(token.allowance(address(this), spender), approved);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }
}
