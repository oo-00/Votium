// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {OptOutRegistry} from "../../../contracts/OptOutRegistry.sol";
import {MockVlCVX, MockGaugeRegistry} from "./Mocks.sol";

/// The rejection paths, which the other tests in this directory cannot reach.
///
/// The mocks here are deliberately permissive — balances never expire, every gauge is listed,
/// and `findEpochId` is exact arithmetic — because the enumeration tests want to spend their
/// budget on interval bookkeeping rather than on bouncing off input validation. The cost is
/// that each guard below is unreachable there: deleting it left every test in this directory
/// passing. These reach them by driving the mocks off their defaults, so the guards are pinned
/// without slowing the enumeration down.
contract GuardsTest is Test {
    OptOutRegistry reg;
    MockVlCVX vl;
    MockGaugeRegistry gr;

    address owner = address(0xA11CE);
    address user = address(0xBEEF);
    address gauge = address(0x2001);
    uint256 constant DUR = 7 days;

    function setUp() public {
        vm.warp(1_700_000_000);
        vl = new MockVlCVX(uint32(block.timestamp - 100 * DUR));
        gr = new MockGaugeRegistry();
        reg = new OptOutRegistry("t", owner, address(vl), address(gr), 1);
        vl.setBal(user, 100e18);
    }

    function _one(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    // --- constructor -----------------------------------------------------------------

    /// The locker's own epoch index must agree with the arithmetic derivation that replaces it.
    /// Nothing else can make this fire: a mock computes the same arithmetic, and on a fork the
    /// two agree unless the locker has gone un-checkpointed across a boundary.
    function test_constructorRejectsEpochDerivationMismatch() public {
        uint256 derived = (block.timestamp - vl.e0()) / DUR;

        vm.mockCall(
            address(vl),
            abi.encodeWithSignature("findEpochId(uint256)", block.timestamp),
            abi.encode(derived - 1)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                OptOutRegistry.EpochDerivationMismatch.selector, derived, derived - 1
            )
        );
        new OptOutRegistry("t", owner, address(vl), address(gr), 1);

        vm.clearMockedCalls();
    }

    /// The registry address is immutable and nothing else in the constructor calls it, so an
    /// address that does not answer as a registry has to be probed for or it deploys cleanly
    /// and leaves every optOut failing in the ABI decoder.
    function test_constructorRejectsNonRegistry() public {
        address notARegistry = address(vl); // no isRegisteredGauge(address)

        vm.expectRevert(
            abi.encodeWithSelector(OptOutRegistry.InvalidGaugeRegistry.selector, notARegistry)
        );
        new OptOutRegistry("t", owner, address(vl), notARegistry, 1);

        vm.expectRevert(
            abi.encodeWithSelector(OptOutRegistry.InvalidGaugeRegistry.selector, address(0))
        );
        new OptOutRegistry("t", owner, address(vl), address(0), 1);
    }

    // --- entry gates -----------------------------------------------------------------

    function test_rejectsUnregisteredGauge() public {
        gr.setBanned(gauge, true);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OptOutRegistry.GaugeNotRegistered.selector, gauge));
        reg.optOut(_one(gauge));

        // And once listed again it goes through, so the guard is the only thing that stopped it.
        gr.setBanned(gauge, false);
        vm.prank(user);
        reg.optOut(_one(gauge));
        assertTrue(reg.isGaugeMember(gauge, user));
    }

    /// A zero balance is refused even when the floor is zero — the two conditions are separate,
    /// and only the floor is visible to a caller reading `minOptOutBalance()`.
    function test_rejectsZeroBalanceEvenAtZeroFloor() public {
        vm.prank(owner);
        reg.setMinOptOutBalance(0);

        address broke = address(0xDEAD);
        vm.prank(broke);
        vm.expectRevert(abi.encodeWithSelector(OptOutRegistry.InsufficientBalance.selector, 0, 0));
        reg.optOut(_one(gauge));
    }

    function test_rejectsBalanceBelowFloor() public {
        vm.prank(owner);
        reg.setMinOptOutBalance(50e18);

        vl.setBal(user, 49e18);
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(OptOutRegistry.InsufficientBalance.selector, 49e18, 50e18)
        );
        reg.optOut(_one(gauge));
    }

    /// The owner paths take no balance and no pause into account — that is what
    /// makes them the fallback for a holder whose vlCVX sits in a contract that cannot call. The
    /// registry still applies; see below.
    function test_ownerPathsIgnoreTheFloorAndThePause() public {
        vm.prank(owner);
        reg.setMinOptOutBalance(type(uint256).max);
        vm.prank(owner);
        reg.setOptOutsPaused(true);

        address[] memory gs = _one(gauge);

        // The public path is refused.
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OptOutRegistry.OptOutsArePaused.selector));
        reg.optOut(gs);

        // The owner path is not — the floor and the pause do not apply to it.
        vm.prank(owner);
        reg.forceOptOut(gs, user);
        assertTrue(reg.isOptedOutAtEpoch(gauge, user, reg.currentEpoch() + 1), "forceOptOut");

        vm.prank(owner);
        reg.forceOptIn(gs, user);
        assertFalse(reg.isOptedOutAtEpoch(gauge, user, reg.currentEpoch() + 1), "forceOptIn");
    }

    /// The registry is the one public gate the owner path does keep.
    function test_forceOptOutStillRequiresARegisteredGauge() public {
        gr.setBanned(gauge, true);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OptOutRegistry.GaugeNotRegistered.selector, gauge));
        reg.forceOptOut(_one(gauge), user);

        gr.setBanned(gauge, false);
        vm.prank(owner);
        reg.forceOptOut(_one(gauge), user);
        assertTrue(reg.isGaugeMember(gauge, user), "not recorded once listed");
    }

    function test_forceOptOutRejectsRepeatAndDuplicate() public {
        address[] memory gs = _one(gauge);

        vm.prank(owner);
        reg.forceOptOut(gs, user);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OptOutRegistry.AlreadyOptedOut.selector, gauge));
        reg.forceOptOut(gs, user);

        // A gauge repeated inside one call is the same conflict.
        address[] memory two = new address[](2);
        two[0] = Gs2();
        two[1] = Gs2();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OptOutRegistry.AlreadyOptedOut.selector, Gs2()));
        reg.forceOptOut(two, user);
    }

    function Gs2() internal pure returns (address) {
        return address(0x2002);
    }

    // --- which mutations checkpoint the locker ----------------------------------------

    /// `optOut` must extend the locker's epoch array so that `epochs[nextEpoch]` exists for the
    /// balance read; `optIn` reads no locker state and must not pay for it. The mock's
    /// `balanceAtEpochOf` ignores the epoch, so dropping the checkpoint is invisible to every
    /// other test here — this asserts the call directly.
    function test_optOutCheckpointsAndOptInDoesNot() public {
        vm.prank(user);
        reg.optOut(_one(gauge));

        vm.warp(block.timestamp + DUR);
        uint256 before = vl.epochCount();

        vm.prank(user);
        reg.optIn(_one(gauge));
        assertEq(vl.epochCount(), before, "optIn checkpointed the locker");

        vm.prank(user);
        reg.optOut(_one(gauge));
        assertGt(vl.epochCount(), before, "optOut did not checkpoint the locker");
    }
}
