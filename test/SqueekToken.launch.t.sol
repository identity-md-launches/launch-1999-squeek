// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SqueekToken} from "../src/SqueekToken.sol";

/// @notice Stands in for `ProjectFactory.launchCustom`: deploys the token and pays the supply out in
///         the same transaction, the way the launch does on chain. One call, because forge 1.8 makes
///         each top-level call of a test its own transaction.
contract LaunchFlowProbe {
    uint256 public constant SWARM_BPS = 1_000;

    SqueekToken public token;

    /// @dev Deploys with CREATE2, then forwards the swarm share, the pool share and the remainder.
    ///      Reverts if any flow arrives short, as the factory's own checks would.
    function launch(bytes32 salt, address distributor, address poolManager, address requester, uint256 poolBps)
        external
        returns (uint256 swarm, uint256 pool, uint256 remainder)
    {
        bytes memory code = type(SqueekToken).creationCode;
        address deployed;
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0) && deployed.code.length > 0, "token constructor failed");
        token = SqueekToken(deployed);

        uint256 supply = token.totalSupply();
        require(token.balanceOf(address(this)) == supply, "supply not minted to the factory");

        swarm = (supply * SWARM_BPS) / 10_000;
        pool = (supply * poolBps) / 10_000;
        remainder = supply - swarm - pool;

        require(token.transfer(distributor, swarm), "distributor transfer returned false");
        require(token.balanceOf(distributor) == swarm, "the swarm's share arrived short");
        require(token.transfer(poolManager, pool), "pool transfer returned false");
        require(token.balanceOf(poolManager) == pool, "the pool share arrived short");
        require(token.transfer(requester, remainder), "remainder transfer returned false");
        require(token.balanceOf(requester) == remainder, "the remainder arrived short");
        require(token.balanceOf(address(this)) == 0, "the factory kept something back");
    }

    function predict(bytes32 salt) external view returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(type(SqueekToken).creationCode))
                    )
                )
            )
        );
    }
}

/// @notice The launch flows end to end, the ERC-20 edges the unit suite left open, and stateless
///         property tests pinned at the boundaries (zero, one wei, the full supply, the maximum).
/// forge-config: default.fuzz.runs = 1000
contract SqueekTokenLaunchTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant SWARM_BPS = 1_000;

    SqueekToken internal token;
    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    address internal distributor = makeAddr("distributor");
    address internal poolManager = makeAddr("poolManager");
    address internal requester = makeAddr("requester");

    function setUp() public {
        vm.prank(deployer);
        token = new SqueekToken();
    }

    // ---------------------------------------------------------------- launch flows, one transaction

    /// @dev Deploy, then 10% to the distributor, 80% to the pool and 10% to the requester, all in the
    ///      deploying transaction. Every flow must arrive whole and the factory must end empty.
    function test_launchFlowsArriveWholeInOneTransaction() public {
        LaunchFlowProbe factory = new LaunchFlowProbe();
        address predicted = factory.predict(bytes32(uint256(7)));
        (uint256 swarm, uint256 pool, uint256 remainder) =
            factory.launch(bytes32(uint256(7)), distributor, poolManager, requester, 8_000);
        SqueekToken launched = factory.token();

        assertEq(address(launched), predicted, "CREATE2 address is not predictable from the creation code");
        assertEq(swarm, SUPPLY / 10);
        assertEq(pool, SUPPLY * 8 / 10);
        assertEq(remainder, SUPPLY / 10);
        assertEq(swarm + pool + remainder, SUPPLY, "the split does not cover the supply");
        assertEq(launched.balanceOf(distributor), swarm);
        assertEq(launched.balanceOf(poolManager), pool);
        assertEq(launched.balanceOf(requester), remainder);
        assertEq(launched.balanceOf(address(factory)), 0);
        assertEq(launched.totalSupply(), SUPPLY, "launch flows changed the supply");
    }

    /// @dev Whatever pool share the economics choose, the three flows cover the supply exactly.
    function testFuzz_launchSplitCoversSupplyForAnyPoolShare(uint256 poolBps, bytes32 salt) public {
        poolBps = bound(poolBps, 0, 10_000 - SWARM_BPS);
        LaunchFlowProbe factory = new LaunchFlowProbe();
        (uint256 swarm, uint256 pool, uint256 remainder) =
            factory.launch(salt, distributor, poolManager, requester, poolBps);
        SqueekToken launched = factory.token();
        assertEq(swarm + pool + remainder, SUPPLY);
        assertEq(
            launched.balanceOf(distributor) + launched.balanceOf(poolManager) + launched.balanceOf(requester), SUPPLY
        );
        assertEq(launched.balanceOf(address(factory)), 0);
    }

    /// @dev The distributor pays claims out to many claimants; the last claim empties it exactly, so
    ///      nobody is shorted by dust and no claim is paid twice.
    function testFuzz_distributorClaimsSumToTheSwarmShare(uint8 claimantCount) public {
        uint256 n = bound(claimantCount, 1, 64);
        uint256 swarm = SUPPLY * SWARM_BPS / 10_000;
        vm.prank(deployer);
        token.transfer(distributor, swarm);

        uint256 share = swarm / n;
        uint256 paid;
        for (uint256 i; i < n; ++i) {
            address claimant = address(uint160(0xC1A1_0000 + i));
            uint256 amount = i == n - 1 ? swarm - paid : share;
            vm.prank(distributor);
            assertTrue(token.transfer(claimant, amount));
            assertEq(token.balanceOf(claimant), amount, "a claim arrived short");
            paid += amount;
        }
        assertEq(paid, swarm);
        assertEq(token.balanceOf(distributor), 0, "the distributor kept something back");

        // A second claim by anyone, even one wei, fails: the distributor is empty.
        vm.prank(distributor);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, distributor, 0, 1));
        token.transfer(address(0xC1A1_0000), 1);
    }

    /// @dev Two deployments from the same creation code have byte-identical runtime, so the launch's
    ///      prediction of the token address and the floor's scan of the runtime both hold.
    function test_runtimeIsDeterministicAcrossDeployments() public {
        vm.prank(alice);
        SqueekToken second = new SqueekToken();
        assertEq(address(token).code, address(second).code);
        assertEq(address(token).code.length, address(second).code.length);
        assertEq(second.balanceOf(alice), SUPPLY);
        assertEq(second.balanceOf(deployer), 0);
        // Two tokens are independent: one's supply is not the other's.
        assertEq(token.balanceOf(alice), 0);
    }

    // ---------------------------------------------------------------- ERC-20 edges the unit suite left open

    /// @dev `approve` overwrites; it does not accumulate.
    function testFuzz_approveOverwritesInsteadOfAccumulating(uint256 first, uint256 second) public {
        vm.prank(deployer);
        token.approve(alice, first);
        vm.prank(deployer);
        token.approve(alice, second);
        assertEq(token.allowance(deployer, alice), second);
    }

    /// @dev Revoking to zero closes the door: the spender's next transferFrom reverts.
    function test_revokedAllowanceBlocksSpender() public {
        vm.prank(deployer);
        token.approve(alice, 100 ether);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1 ether);
        vm.prank(deployer);
        token.approve(alice, 0);
        assertEq(token.allowance(deployer, alice), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
        assertEq(token.balanceOf(bob), 1 ether);
    }

    /// @dev Only exactly `type(uint256).max` is the infinite marker; one below it is a finite
    ///      allowance and is decremented like any other.
    function test_maxMinusOneAllowanceIsFinite() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max - 1);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1);
        assertEq(token.allowance(deployer, alice), type(uint256).max - 2);
    }

    /// @dev Holding tokens is not an allowance: the owner cannot `transferFrom` itself unapproved.
    function test_ownerCannotTransferFromSelfWithoutAllowance() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(deployer, alice, 1);
    }

    /// @dev A self-approval makes `transferFrom(self, ...)` work and is decremented like any other.
    function test_selfApprovalAllowsTransferFromSelf() public {
        vm.prank(deployer);
        token.approve(deployer, 5 ether);
        vm.prank(deployer);
        assertTrue(token.transferFrom(deployer, alice, 2 ether));
        assertEq(token.balanceOf(alice), 2 ether);
        assertEq(token.allowance(deployer, deployer), 3 ether);
    }

    function test_transferFromToZeroAddressReverts() public {
        vm.prank(deployer);
        token.approve(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(deployer, address(0), 1);
        assertEq(token.allowance(deployer, alice), 1 ether, "a failed transferFrom spent allowance");
    }

    /// @dev Nobody can pull from the zero address: it has no allowance to grant and no balance.
    function test_transferFromZeroAddressReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(address(0), alice, 1);
        assertEq(token.balanceOf(address(0)), 0);
    }

    /// @dev A transferFrom of zero needs no allowance and moves nothing.
    function test_transferFromZeroAmountNeedsNoAllowance() public {
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 0));
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(bob), 0);
    }

    /// @dev Full-amount boundary: the whole balance moves, then one wei more fails.
    function test_fullBalanceTransferThenOneWeiReverts() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, 0, 1));
        token.transfer(bob, 1);
    }

    /// @dev One wei is a valid amount and is accounted exactly.
    function test_oneWeiTransfer() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 1));
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(deployer), SUPPLY - 1);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 1));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 1);
    }

    /// @dev The maximum amount cannot be moved by anyone: the balance check fires, not an overflow.
    function test_maxUintTransferReverts() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, type(uint256).max)
        );
        token.transfer(alice, type(uint256).max);
    }

    /// @dev Transfer events carry the exact amount, including zero, and nothing else is emitted.
    function test_zeroTransferEmitsZeroEvent() public {
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(alice, bob, 0);
        token.transfer(bob, 0);
    }

    /// @dev The same call twice has the same effect each time: a transfer is not idempotent, but an
    ///      approve is, and both are exact.
    function test_repeatedCallsAreExact() public {
        vm.startPrank(deployer);
        token.transfer(alice, 3 ether);
        token.transfer(alice, 3 ether);
        token.approve(bob, 9 ether);
        token.approve(bob, 9 ether);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 6 ether);
        assertEq(token.allowance(deployer, bob), 9 ether);
    }

    // ---------------------------------------------------------------- unknown surface

    /// @dev Every selector outside the ERC-20 ABI reverts, from any caller, with any arguments, and
    ///      leaves balances and supply as they were.
    function testFuzz_unknownSelectorReverts(bytes4 selector, address caller, bytes calldata args) public {
        bytes4[13] memory known = [
            IERC20.totalSupply.selector,
            IERC20.balanceOf.selector,
            IERC20.transfer.selector,
            IERC20.allowance.selector,
            IERC20.approve.selector,
            IERC20.transferFrom.selector,
            token.name.selector,
            token.symbol.selector,
            token.decimals.selector,
            token.TOKEN_NAME.selector,
            token.TOKEN_SYMBOL.selector,
            token.DECIMALS.selector,
            token.INITIAL_SUPPLY.selector
        ];
        for (uint256 i; i < known.length; ++i) {
            if (selector == known[i]) selector = bytes4(uint32(selector) ^ 0x80000001);
        }
        for (uint256 i; i < known.length; ++i) {
            if (selector == known[i]) return; // the flip landed on another known selector; nothing to test
        }
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(token).call(abi.encodePacked(selector, args));
        assertFalse(ok, "unknown selector did not revert");
        assertEq(ret.length, 0, "unknown selector returned data");
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    /// @dev Short calldata (fewer than four bytes) hits the missing fallback and reverts.
    function testFuzz_shortCalldataReverts(bytes calldata data) public {
        bytes memory short;
        if (data.length > 3) short = data[:3];
        else short = data;
        (bool ok, bytes memory ret) = address(token).call(short);
        assertFalse(ok);
        assertEq(ret.length, 0);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    // ---------------------------------------------------------------- stateless properties at the edges

    /// @dev Splitting the supply across many recipients in one shot conserves it to the wei.
    function testFuzz_splitAmongManyConservesSupply(uint256[8] memory weights) public {
        uint256 total;
        for (uint256 i; i < 8; ++i) {
            weights[i] = bound(weights[i], 0, SUPPLY / 8);
            total += weights[i];
        }
        uint256 sum;
        for (uint256 i; i < 8; ++i) {
            address to = address(uint160(0xA11CE_0000 + i));
            vm.prank(deployer);
            assertTrue(token.transfer(to, weights[i]));
            sum += token.balanceOf(to);
        }
        assertEq(sum, total);
        assertEq(token.balanceOf(deployer), SUPPLY - total);
        assertEq(sum + token.balanceOf(deployer), SUPPLY);
    }

    /// @dev Round trip: send and send back, and both parties are where they started.
    function testFuzz_roundTripRestoresBalances(address a, uint256 amount) public {
        if (a == address(0) || a == deployer) a = alice;
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(a, amount);
        vm.prank(a);
        token.transfer(deployer, amount);
        assertEq(token.balanceOf(a), 0);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    /// @dev Exactly the balance succeeds; exactly one more fails. Pins the comparison as `<`, not `<=`.
    function testFuzz_balanceBoundaryIsExact(uint256 funded) public {
        funded = bound(funded, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, funded);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, funded, funded + 1)
        );
        token.transfer(bob, funded + 1);

        vm.prank(alice);
        assertTrue(token.transfer(bob, funded));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), funded);
    }

    /// @dev Exactly the allowance succeeds; exactly one more fails, and the failed attempt spends nothing.
    function testFuzz_allowanceBoundaryIsExact(uint256 allowed) public {
        allowed = bound(allowed, 0, SUPPLY - 1);
        vm.prank(deployer);
        token.approve(alice, allowed);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, allowed, allowed + 1)
        );
        token.transferFrom(deployer, bob, allowed + 1);
        assertEq(token.allowance(deployer, alice), allowed, "a failed transferFrom spent allowance");

        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, allowed));
        assertEq(token.allowance(deployer, alice), 0);
        assertEq(token.balanceOf(bob), allowed);
    }

    /// @dev Approvals never move tokens, whatever the value, and never touch anyone else's allowance.
    function testFuzz_approveMovesNothing(address spender, uint256 amount) public {
        if (spender == address(0)) spender = alice;
        vm.prank(deployer);
        assertTrue(token.approve(spender, amount));
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.allowance(deployer, spender), amount);
        assertEq(token.allowance(spender, deployer), 0);
        assertEq(token.allowance(deployer, carol), spender == carol ? amount : 0);
    }

    /// @dev Whoever deploys gets the whole supply, and no one else gets anything.
    function testFuzz_anyDeployerReceivesWholeSupply(address who) public {
        if (who == address(0)) who = alice;
        vm.assume(who.code.length == 0);
        vm.prank(who);
        SqueekToken fresh = new SqueekToken();
        assertEq(fresh.totalSupply(), SUPPLY);
        assertEq(fresh.balanceOf(who), SUPPLY);
        assertEq(fresh.balanceOf(deployer), who == deployer ? SUPPLY : 0);
    }
}
