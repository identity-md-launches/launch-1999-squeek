// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SqueekToken} from "../src/SqueekToken.sol";

/// @notice Drives the token with bounded inputs from a small cast of actors, in whatever order the
///         invariant runner picks. Every call that is expected to succeed asserts its own
///         postconditions; every call that is expected to fail asserts the exact revert and that
///         nothing moved. Ghost flows record what each address sent and received so the invariants
///         can compare the token's books against an independent ledger.
/// @dev The handler never reverts on its own: expected reverts are caught with try/catch, so the
///      suite runs with fail_on_revert on and any stray revert is a finding, not noise.
contract SqueekHandler is CommonBase, StdAssertions, StdUtils {
    SqueekToken public immutable token;
    uint256 public immutable supply;

    /// @dev actors[0] is the deployer (the launch factory's role), holding the whole supply at start.
    address[] public actors;
    /// @dev Every address that has ever been named as a recipient, including strangers outside `actors`.
    address[] public holders;
    mapping(address => bool) public isHolder;

    // Ghost ledger: per-address flows and a mirror of allowances the handler has set or spent.
    mapping(address => uint256) public ghost_received;
    mapping(address => uint256) public ghost_sent;
    mapping(address => mapping(address => uint256)) public ghost_allowance;

    // Call accounting, so a vacuous run is visible in the summary.
    uint256 public calls_transfer;
    uint256 public calls_transferAll;
    uint256 public calls_transferToStranger;
    uint256 public calls_transferOverBalance;
    uint256 public calls_transferToZero;
    uint256 public calls_approve;
    uint256 public calls_transferFrom;
    uint256 public calls_transferFromOverAllowance;
    uint256 public calls_transferFromOverBalance;
    uint256 public calls_transferFromUnapprovedSelf;
    uint256 public calls_privileged;
    uint256 public calls_sendEther;
    uint256 public successfulTransfers;
    uint256 public successfulTransferFroms;
    uint256 public infiniteAllowanceSpends;

    constructor(SqueekToken token_, address deployer, address[] memory others) {
        token = token_;
        supply = token_.totalSupply();
        actors.push(deployer);
        _trackHolder(deployer);
        for (uint256 i; i < others.length; ++i) {
            actors.push(others[i]);
            _trackHolder(others[i]);
        }
    }

    // ---------------------------------------------------------------- views for the invariants

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    function sumOfHolderBalances() public view returns (uint256 sum) {
        for (uint256 i; i < holders.length; ++i) {
            sum += token.balanceOf(holders[i]);
        }
    }

    // ---------------------------------------------------------------- clamped: expected to succeed

    /// @notice An actor sends part (possibly none) of what it holds to another actor.
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) public {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        calls_transfer++;
        _transfer(from, to, amount);
    }

    /// @notice Full-amount operation: an actor empties its balance into another address.
    function transferAll(uint256 fromSeed, uint256 toSeed) public {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        calls_transferAll++;
        _transfer(from, to, token.balanceOf(from));
        if (from != to) assertEq(token.balanceOf(from), 0, "transferAll left dust");
    }

    /// @notice Unclamped recipient: tokens may leave the cast to any nonzero address. The stranger
    ///         joins the tracked holder set so the conservation invariant still sums everything.
    function transferToStranger(uint256 fromSeed, address to, uint256 amount) public {
        if (to == address(0)) to = address(1);
        address from = _actor(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        calls_transferToStranger++;
        _trackHolder(to);
        _transfer(from, to, amount);
    }

    /// @notice The owner sets a spender's allowance to any value, including zero and the infinite marker.
    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) public {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        // Bias toward values that matter: zero, within supply, or the infinite marker.
        uint256 pick = amount % 4;
        if (pick == 0) amount = 0;
        else if (pick == 1) amount = type(uint256).max;
        else if (pick == 2) amount = bound(amount, 0, supply);
        calls_approve++;
        vm.prank(owner);
        bool ok = token.approve(spender, amount);
        assertTrue(ok, "approve returned false");
        assertEq(token.allowance(owner, spender), amount, "approve did not overwrite the allowance");
        ghost_allowance[owner][spender] = amount;
    }

    /// @notice A spender moves what it is allowed to, within the owner's balance.
    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) public {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        uint256 balance = token.balanceOf(owner);
        amount = bound(amount, 0, allowed < balance ? allowed : balance);
        calls_transferFrom++;

        uint256 ownerBefore = token.balanceOf(owner);
        uint256 toBefore = token.balanceOf(to);
        uint256 spenderBefore = token.balanceOf(spender);

        vm.prank(spender);
        bool ok = token.transferFrom(owner, to, amount);
        assertTrue(ok, "transferFrom returned false");
        successfulTransferFroms++;

        if (allowed == type(uint256).max) {
            infiniteAllowanceSpends++;
            assertEq(token.allowance(owner, spender), type(uint256).max, "infinite allowance was decremented");
        } else {
            assertEq(token.allowance(owner, spender), allowed - amount, "allowance not decremented by amount");
            ghost_allowance[owner][spender] = allowed - amount;
        }
        _recordMove(owner, to, amount, ownerBefore, toBefore);
        if (spender != owner && spender != to) {
            assertEq(token.balanceOf(spender), spenderBefore, "spender balance changed on transferFrom");
        }
    }

    // ---------------------------------------------------------------- unclamped: expected to revert

    /// @notice Spending more than the balance reverts with the exact ERC-6093 error and moves nothing.
    function transferOverBalance(uint256 fromSeed, uint256 toSeed, uint256 excess) public {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = token.balanceOf(from);
        excess = bound(excess, 1, type(uint256).max - balance);
        uint256 amount = balance + excess;
        calls_transferOverBalance++;

        uint256 toBefore = token.balanceOf(to);
        vm.prank(from);
        try token.transfer(to, amount) {
            assertTrue(false, "transfer above balance succeeded");
        } catch (bytes memory reason) {
            assertEq(
                reason,
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount),
                "wrong revert for transfer above balance"
            );
        }
        assertEq(token.balanceOf(from), balance, "failed transfer changed the sender");
        assertEq(token.balanceOf(to), toBefore, "failed transfer changed the recipient");
    }

    /// @notice The zero address can never receive, not even zero tokens.
    function transferToZero(uint256 fromSeed, uint256 amount) public {
        address from = _actor(fromSeed);
        uint256 balance = token.balanceOf(from);
        amount = bound(amount, 0, balance);
        calls_transferToZero++;
        vm.prank(from);
        try token.transfer(address(0), amount) {
            assertTrue(false, "transfer to the zero address succeeded");
        } catch (bytes memory reason) {
            assertEq(
                reason,
                abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)),
                "wrong revert for transfer to zero"
            );
        }
        assertEq(token.balanceOf(from), balance, "failed transfer to zero changed the sender");
        assertEq(token.balanceOf(address(0)), 0, "zero address received tokens");
    }

    /// @notice Spending above a finite allowance reverts and leaves balances and allowance untouched.
    function transferFromOverAllowance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 excess) public {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        if (allowed == type(uint256).max) return; // nothing is above infinity; approve() will lower it later
        excess = bound(excess, 1, type(uint256).max - allowed);
        uint256 amount = allowed + excess;
        calls_transferFromOverAllowance++;

        uint256 ownerBefore = token.balanceOf(owner);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(spender);
        try token.transferFrom(owner, to, amount) {
            assertTrue(false, "transferFrom above allowance succeeded");
        } catch (bytes memory reason) {
            assertEq(
                reason,
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount),
                "wrong revert for transferFrom above allowance"
            );
        }
        assertEq(token.allowance(owner, spender), allowed, "failed transferFrom changed the allowance");
        assertEq(token.balanceOf(owner), ownerBefore, "failed transferFrom changed the owner");
        assertEq(token.balanceOf(to), toBefore, "failed transferFrom changed the recipient");
    }

    /// @notice An allowance larger than the owner's balance does not let the spender overdraw it.
    function transferFromOverBalance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 excess) public {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 balance = token.balanceOf(owner);
        excess = bound(excess, 1, type(uint256).max - balance);
        uint256 amount = balance + excess;
        calls_transferFromOverBalance++;

        vm.prank(owner);
        token.approve(spender, type(uint256).max);
        ghost_allowance[owner][spender] = type(uint256).max;

        uint256 toBefore = token.balanceOf(to);
        vm.prank(spender);
        try token.transferFrom(owner, to, amount) {
            assertTrue(false, "transferFrom above balance succeeded");
        } catch (bytes memory reason) {
            assertEq(
                reason,
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount),
                "wrong revert for transferFrom above balance"
            );
        }
        assertEq(token.balanceOf(owner), balance, "failed transferFrom changed the owner");
        assertEq(token.balanceOf(to), toBefore, "failed transferFrom changed the recipient");
        assertEq(token.allowance(owner, spender), type(uint256).max, "failed transferFrom spent allowance");
    }

    /// @notice Holding tokens is not an allowance: without a self-approval, transferFrom on one's own
    ///         balance reverts like any other spender's would.
    function transferFromUnapprovedSelf(uint256 ownerSeed, uint256 toSeed, uint256 amount) public {
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 balance = token.balanceOf(owner);
        if (balance == 0 || token.allowance(owner, owner) != 0) return;
        amount = bound(amount, 1, balance);
        calls_transferFromUnapprovedSelf++;

        vm.prank(owner);
        try token.transferFrom(owner, to, amount) {
            assertTrue(false, "self transferFrom without allowance succeeded");
        } catch (bytes memory reason) {
            assertEq(
                reason,
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, owner, 0, amount),
                "wrong revert for unapproved self transferFrom"
            );
        }
        assertEq(token.balanceOf(owner), balance, "failed self transferFrom changed the owner");
    }

    /// @notice Any actor, including the deployer, tries a privileged selector. None may exist.
    function callPrivileged(uint256 callerSeed, uint256 sigSeed, address target, uint256 amount) public {
        string[20] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "unpause()",
            "setMinter(address)",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "seize(address)",
            "owner()"
        ];
        address caller = _actor(callerSeed);
        string memory signature = signatures[sigSeed % signatures.length];
        calls_privileged++;
        vm.prank(caller);
        (bool ok,) = address(token).call(abi.encodeWithSignature(signature, target, amount));
        assertFalse(ok, signature);
    }

    /// @notice The token refuses ether on every path: empty calldata and arbitrary calldata alike.
    function sendEther(uint256 callerSeed, uint256 amount, bytes calldata data) public {
        address caller = _actor(callerSeed);
        amount = bound(amount, 1, 1_000 ether);
        calls_sendEther++;
        vm.deal(caller, amount);
        vm.prank(caller);
        (bool ok,) = address(token).call{value: amount}(data);
        assertFalse(ok, "token accepted ether");
        assertEq(address(token).balance, 0, "token holds ether");
    }

    // ---------------------------------------------------------------- internals

    function _transfer(address from, address to, uint256 amount) internal {
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(from);
        bool ok = token.transfer(to, amount);
        assertTrue(ok, "transfer returned false");
        successfulTransfers++;
        _recordMove(from, to, amount, fromBefore, toBefore);
    }

    function _recordMove(address from, address to, uint256 amount, uint256 fromBefore, uint256 toBefore) internal {
        if (from == to) {
            assertEq(token.balanceOf(from), fromBefore, "self transfer changed the balance");
        } else {
            assertEq(token.balanceOf(from), fromBefore - amount, "sender not debited exactly");
            assertEq(token.balanceOf(to), toBefore + amount, "recipient not credited exactly");
        }
        ghost_sent[from] += amount;
        ghost_received[to] += amount;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _trackHolder(address account) internal {
        if (!isHolder[account]) {
            isHolder[account] = true;
            holders.push(account);
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract SqueekTokenInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    SqueekToken internal token;
    SqueekHandler internal handler;
    address internal deployer = makeAddr("deployer");

    function setUp() public {
        vm.prank(deployer);
        token = new SqueekToken();

        address[] memory others = new address[](5);
        others[0] = makeAddr("distributor");
        others[1] = makeAddr("poolManager");
        others[2] = makeAddr("requester");
        others[3] = makeAddr("trader");
        others[4] = makeAddr("claimant");
        handler = new SqueekHandler(token, deployer, others);

        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = SqueekHandler.transfer.selector;
        selectors[1] = SqueekHandler.transferAll.selector;
        selectors[2] = SqueekHandler.transferToStranger.selector;
        selectors[3] = SqueekHandler.approve.selector;
        selectors[4] = SqueekHandler.transferFrom.selector;
        selectors[5] = SqueekHandler.transferOverBalance.selector;
        selectors[6] = SqueekHandler.transferToZero.selector;
        selectors[7] = SqueekHandler.transferFromOverAllowance.selector;
        selectors[8] = SqueekHandler.transferFromOverBalance.selector;
        selectors[9] = SqueekHandler.transferFromUnapprovedSelf.selector;
        selectors[10] = SqueekHandler.callPrivileged.selector;
        selectors[11] = SqueekHandler.sendEther.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev The supply is fixed at construction: no sequence of calls grows or shrinks it.
    function invariant_totalSupplyNeverChanges() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), token.INITIAL_SUPPLY());
    }

    /// @dev Conservation: everything the token owes, summed over every address that ever received,
    ///      equals the fixed supply. Nothing is created, lost or stuck at the zero address.
    function invariant_sumOfBalancesEqualsSupply() public view {
        assertEq(handler.sumOfHolderBalances(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
    }

    /// @dev Each balance equals the independent ledger: initial holding plus received minus sent.
    function invariant_balancesMatchGhostFlows() public view {
        uint256 n = handler.holderCount();
        for (uint256 i; i < n; ++i) {
            address holder = handler.holders(i);
            uint256 initial = holder == deployer ? SUPPLY : 0;
            uint256 expected = initial + handler.ghost_received(holder) - handler.ghost_sent(holder);
            assertEq(token.balanceOf(holder), expected, "balance drifted from the ghost ledger");
            assertLe(token.balanceOf(holder), SUPPLY, "a balance exceeds the supply");
        }
    }

    /// @dev Nobody sends more than they were ever given.
    function invariant_nobodySendsMoreThanReceived() public view {
        uint256 n = handler.holderCount();
        for (uint256 i; i < n; ++i) {
            address holder = handler.holders(i);
            uint256 initial = holder == deployer ? SUPPLY : 0;
            assertLe(handler.ghost_sent(holder), initial + handler.ghost_received(holder), "overspent");
        }
    }

    /// @dev Allowances change only through approve and through transferFrom spending them.
    function invariant_allowancesMatchGhostLedger() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < n; ++j) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.ghost_allowance(owner, spender), "allowance drift");
            }
        }
    }

    /// @dev The token never holds ether and its metadata never changes.
    function invariant_tokenHoldsNoEtherAndMetadataIsFixed() public view {
        assertEq(address(token).balance, 0);
        assertEq(token.decimals(), 18);
        assertEq(token.name(), "Squeek");
        assertEq(token.symbol(), "SQK");
    }

    /// @dev Prints what the sequence exercised, so a run that only hit reverts is visible.
    function afterInvariant() public view {
        console2.log("transfer                  ", handler.calls_transfer());
        console2.log("transferAll               ", handler.calls_transferAll());
        console2.log("transferToStranger        ", handler.calls_transferToStranger());
        console2.log("approve                   ", handler.calls_approve());
        console2.log("transferFrom              ", handler.calls_transferFrom());
        console2.log("transferOverBalance       ", handler.calls_transferOverBalance());
        console2.log("transferToZero            ", handler.calls_transferToZero());
        console2.log("transferFromOverAllowance ", handler.calls_transferFromOverAllowance());
        console2.log("transferFromOverBalance   ", handler.calls_transferFromOverBalance());
        console2.log("transferFromUnapprovedSelf", handler.calls_transferFromUnapprovedSelf());
        console2.log("callPrivileged            ", handler.calls_privileged());
        console2.log("sendEther                 ", handler.calls_sendEther());
        console2.log("successful transfers      ", handler.successfulTransfers());
        console2.log("successful transferFroms  ", handler.successfulTransferFroms());
        console2.log("infinite allowance spends ", handler.infiniteAllowanceSpends());
        console2.log("holders tracked           ", handler.holderCount());
    }
}
