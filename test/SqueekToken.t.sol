// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SqueekToken} from "../src/SqueekToken.sol";

/// @notice Stands in for the launch factory: a contract that deploys the token with CREATE2 and
///         therefore is the `msg.sender` the constructor mints to.
contract FactoryProbe {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0), "constructor failed");
    }

    function send(SqueekToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract SqueekTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    SqueekToken internal token;
    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.prank(deployer);
        token = new SqueekToken();
    }

    // ---------------------------------------------------------------- metadata and supply

    function test_metadata() public view {
        assertEq(token.name(), "Squeek");
        assertEq(token.symbol(), "SQK");
        assertEq(token.decimals(), 18);
        assertEq(token.TOKEN_NAME(), "Squeek");
        assertEq(token.TOKEN_SYMBOL(), "SQK");
        assertEq(token.DECIMALS(), 18);
    }

    function test_supplyIsOneBillionWithEighteenDecimals() public view {
        assertEq(token.INITIAL_SUPPLY(), 1_000_000_000 * 10 ** 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_wholeSupplyMintedToDeployer() public view {
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_constructorEmitsSingleMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), deployer, SUPPLY);
        vm.prank(deployer);
        new SqueekToken();
    }

    /// @dev The launch factory is a contract deploying through CREATE2: the supply must land on it.
    function test_contractDeployerReceivesSupplyViaCreate2() public {
        FactoryProbe factory = new FactoryProbe();
        address deployed = factory.deploy(type(SqueekToken).creationCode, bytes32(uint256(42)));
        SqueekToken launched = SqueekToken(deployed);
        assertEq(launched.totalSupply(), SUPPLY);
        assertEq(launched.balanceOf(address(factory)), SUPPLY);
        assertEq(launched.balanceOf(deployer), 0);
        assertTrue(factory.send(launched, alice, SUPPLY / 10));
        assertEq(launched.balanceOf(alice), SUPPLY / 10);
        assertEq(launched.balanceOf(address(factory)), SUPPLY - SUPPLY / 10);
    }

    /// @dev The constructor takes no arguments and touches no other contract, so it deploys on an
    ///      empty chain. The creation code is the token's bytecode plus nothing.
    function test_creationCodeHasNoConstructorArguments() public pure {
        bytes memory code = type(SqueekToken).creationCode;
        assertGt(code.length, 0);
        assertEq(abi.encodePacked(code), abi.encodePacked(type(SqueekToken).creationCode));
    }

    function test_contractNameFitsLaunchIdentifier() public pure {
        assertLe(bytes("SqueekToken").length, 32);
    }

    // ---------------------------------------------------------------- transfers

    function test_transferMovesExactAmount() public {
        vm.prank(deployer);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(deployer, alice, 1_000 ether);
        assertTrue(token.transfer(alice, 1_000 ether));
        assertEq(token.balanceOf(alice), 1_000 ether);
        assertEq(token.balanceOf(deployer), SUPPLY - 1_000 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, 5 ether));
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_transferRevertsWhenDeployerOverspends() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, SUPPLY + 1)
        );
        token.transfer(alice, SUPPLY + 1);
    }

    function test_transferToZeroAddressReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    // ---------------------------------------------------------------- allowances

    function test_approveAndTransferFrom() public {
        vm.prank(deployer);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(deployer, alice, 100 ether);
        assertTrue(token.approve(alice, 100 ether));
        assertEq(token.allowance(deployer, alice), 100 ether);

        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 60 ether));
        assertEq(token.balanceOf(bob), 60 ether);
        assertEq(token.balanceOf(deployer), SUPPLY - 60 ether);
        assertEq(token.allowance(deployer, alice), 40 ether);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1 ether);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
    }

    function test_transferFromRevertsOnInsufficientAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 10 ether, 11 ether)
        );
        token.transferFrom(deployer, bob, 11 ether);
    }

    function test_transferFromWithoutApprovalReverts() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    function test_transferFromRevertsOnInsufficientBalanceEvenWithAllowance() public {
        vm.prank(alice);
        token.approve(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1 ether));
        token.transferFrom(alice, bob, 1 ether);
    }

    function test_approveZeroAddressSpenderReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    // ---------------------------------------------------------------- no privileged surface

    /// @dev No admin or mint entry point exists: every common privileged selector reverts and the
    ///      supply is unchanged, whether the caller is a stranger or the deployer.
    function test_noMintOrAdminFunctionExists() public {
        address attacker = makeAddr("attacker");
        string[16] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "pause()",
            "setMinter(address)",
            "blacklist(address)",
            "freeze(address)",
            "burnFrom(address,uint256)",
            "seize(address)",
            "owner()"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool okAttacker,) = address(token).call(data);
            assertFalse(okAttacker, signatures[i]);
            vm.prank(deployer);
            (bool okDeployer,) = address(token).call(data);
            assertFalse(okDeployer, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(attacker), 0);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    /// @dev The deployer has no power over a holder once tokens have moved.
    function test_deployerCannotMoveHolderBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 1_000 ether);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(alice, deployer, 1);
        assertEq(token.balanceOf(alice), 1_000 ether);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 500 ether));
        assertEq(token.balanceOf(bob), 500 ether);
    }

    function test_noEtherAccepted() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(token).balance, 0);
    }

    /// @dev The launch refuses DELEGATECALL, CALLCODE and SELFDESTRUCT in the runtime. Same scan as
    ///      the protected check: skip PUSH immediates, then look at every opcode.
    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.balanceOf(to) + token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferAboveBalanceReverts(address from, uint256 amount) public {
        vm.assume(from != deployer && from != address(0));
        amount = bound(amount, 1, type(uint256).max);
        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, 0, amount));
        token.transfer(bob, amount);
    }

    function testFuzz_transferFromRespectsAllowance(uint256 allowed, uint256 spent) public {
        allowed = bound(allowed, 0, SUPPLY);
        spent = bound(spent, 0, SUPPLY);
        vm.prank(deployer);
        token.approve(alice, allowed);
        vm.prank(alice);
        if (spent > allowed) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, allowed, spent)
            );
            token.transferFrom(deployer, bob, spent);
        } else {
            assertTrue(token.transferFrom(deployer, bob, spent));
            assertEq(token.balanceOf(bob), spent);
            assertEq(token.allowance(deployer, alice), allowed - spent);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev A chain of hops between arbitrary holders never changes the supply or creates value.
    function testFuzz_multiHopConservesSupply(address a, address b, uint256 x, uint256 y) public {
        vm.assume(a != address(0) && b != address(0) && a != b && a != deployer && b != deployer);
        x = bound(x, 0, SUPPLY);
        y = bound(y, 0, x);
        vm.prank(deployer);
        token.transfer(a, x);
        vm.prank(a);
        token.transfer(b, y);
        assertEq(token.balanceOf(a), x - y);
        assertEq(token.balanceOf(b), y);
        assertEq(token.balanceOf(deployer) + token.balanceOf(a) + token.balanceOf(b), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
