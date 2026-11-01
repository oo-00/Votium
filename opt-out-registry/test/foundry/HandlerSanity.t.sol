// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {OptOutRegistry} from "../../contracts/OptOutRegistry.sol";
import {IvlCVX} from "../../contracts/interfaces/IvlCVX.sol";
import {Handler, IERC20} from "./Handler.sol";

/// Confirms the handler's actions actually land before trusting a campaign that uses them.
/// An invariant suite whose handler silently no-ops passes everything and proves nothing.
contract HandlerSanity is Test {
    address constant VLCVX = 0x72a19342e8F1838460eBFCCEf09F6585e32db86E;
    address constant CVX = 0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B;
    address constant CURVE_REGISTRY = 0x96b24E0534B0cA31D8523D4be4904747Fd579D95;
    address constant FX_REGISTRY = 0xC2F99261d84D1665Df7e50F46813497A737AfB20;

    OptOutRegistry registry;
    Handler handler;
    address owner = address(0xA11CE);
    address[] actors;
    address[] gauges;

    function setUp() public {
        vm.createSelectFork(vm.envOr("FORK_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
        for (uint256 i; i < 3; ++i) {
            (, bytes memory d) =
                CURVE_REGISTRY.staticcall(abi.encodeWithSignature("activeGauges(uint256)", i));
            gauges.push(abi.decode(d, (address)));
        }
        registry = new OptOutRegistry("sanity", owner, VLCVX, CURVE_REGISTRY, 1e18);
        for (uint256 i; i < 5; ++i) {
            address a = address(uint160(0xACC0 + i));
            actors.push(a);
            if (i == 4) continue;
            deal(CVX, a, 1000e18);
            vm.startPrank(a);
            IERC20(CVX).approve(VLCVX, 1000e18);
            IvlCVX(VLCVX).lock(a, 1000e18, 0);
            vm.stopPrank();
        }
        handler = new Handler(
            registry, IvlCVX(VLCVX), IERC20(CVX), owner, actors, gauges, CURVE_REGISTRY, FX_REGISTRY
        );
    }

    function test_actorsAreFunded() public view {
        uint256 next = IvlCVX(VLCVX).epochCount() - 1;
        console.log("balanceAtEpochOf(next, actor0)", IvlCVX(VLCVX).balanceAtEpochOf(next, actors[0]));
        assertGt(IvlCVX(VLCVX).balanceAtEpochOf(next, actors[0]), 1e18, "actor not funded");
    }

    function test_handlerOptOutLands() public {
        handler.optOut(0, 7); // all three gauges
        console.log("optOuts", handler.optOuts());
        console.log("members on gauge0", registry.gaugeMemberCount(gauges[0]));
        assertGt(handler.optOuts(), 0, "optOut did not land");
        assertEq(registry.gaugeMemberCount(gauges[0]), 1, "member not recorded");
    }

    function test_handlerWarpLands() public {
        uint256 before = registry.currentEpoch();
        handler.warp(1);
        assertGt(registry.currentEpoch(), before, "warp did not advance the epoch");
        assertEq(handler.warps(), 1, "warp counter did not persist");
    }

    function test_handlerOptInLands() public {
        handler.optOut(0, 7);
        handler.warp(1); // let it take effect so this is the keep path, not the prune path
        handler.optIn(0, 7);

        assertGt(handler.optIns(), 0, "optIn did not land");

        // The close takes effect next epoch, so the current epoch still shows them excluded.
        assertEq(registry.optOutCount(gauges[0]), 1, "current epoch must be unchanged");
        assertEq(
            registry.optOutCountAtEpoch(gauges[0], registry.maxQueryableEpoch()),
            0,
            "opt-out was not closed at the pending epoch"
        );
        assertTrue(registry.isGaugeMember(gauges[0], actors[0]), "member wrongly dropped");
    }

    function test_handlerOptOutThenInLandsAndPrunes() public {
        handler.optOutThenIn(0, 0);

        assertGt(handler.prunes(), 0, "prune path never reached");
        assertEq(registry.gaugeMemberCount(gauges[0]), 0, "member not discarded");
        assertFalse(registry.isGaugeMember(gauges[0], actors[0]), "member still registered");
    }

    function test_handlerForceOptOutLands() public {
        handler.forceOptOut(0, 0);
        assertGt(handler.forcedOuts(), 0, "forceOptOut did not land");
        assertTrue(registry.isGaugeMember(gauges[0], actors[0]), "member not recorded");

        // And the owner-side round trip closes again.
        handler.forceOptIn(0, 0);
        assertGt(handler.forcedIns(), 0, "forceOptIn did not land");
    }

    function test_handlerForceOptInLands() public {
        handler.optOut(0, 1);
        handler.warp(1);
        // 18 epochs of jumps age every lock out, which is the only state forceOptIn accepts.
        for (uint256 i; i < 18; ++i) handler.warp(3);

        handler.forceOptIn(0, 0);
        assertGt(handler.forcedIns(), 0, "forceOptIn never landed");
    }

    function test_handlerRelockAndSetFloorLand() public {
        // The fifth actor never locks in setUp, so a successful relock is observable.
        assertEq(vlcvxBalanceNext(actors[4]), 0, "actor 4 should start powerless");
        handler.relock(4);
        assertGt(vlcvxBalanceNext(actors[4]), 0, "relock did not land");

        handler.setFloor(1); // 1 % 3 != 0, so this sets a nonzero floor
        assertGt(registry.minOptOutBalance(), 0, "setFloor did not land");
    }

    function test_handlerTogglePauseLandsAndBlocks() public {
        handler.togglePause(3); // 3 % 5 == 3 -> paused
        assertTrue(registry.optOutsPaused(), "pause did not land");
        assertGt(handler.pauses(), 0, "pause not counted");

        // And it actually stops the handler's opt-out, which is what makes the campaign's
        // prediction of a revert meaningful rather than accidental.
        uint256 before = handler.optOuts();
        handler.optOut(0, 7);
        assertEq(handler.optOuts(), before, "optOut landed while paused");

        handler.togglePause(1); // 1 % 5 != 3 -> unpaused
        assertFalse(registry.optOutsPaused(), "unpause did not land");
        assertGt(handler.unpauses(), 0, "unpause not counted");

        handler.optOut(0, 7);
        assertGt(handler.optOuts(), before, "optOut did not resume after unpause");
    }

    function test_handlerSwapRegistryLandsAndGates() public {
        handler.swapRegistry(2); // 2 % 5 == 2 -> alternate registry
        assertEq(address(registry.gaugeRegistry()), FX_REGISTRY, "swap did not land");
        assertGt(handler.swapsToAlt(), 0, "swap not counted");

        // The Curve gauges are not listed by the f(x) registry, so opting out of them is
        // refused while swapped — the handler predicts exactly this.
        uint256 before = handler.optOuts();
        handler.optOut(0, 7);
        assertEq(handler.optOuts(), before, "optOut landed on an unlisted gauge");

        handler.swapRegistry(1); // 1 % 5 != 2 -> back to the primary
        assertEq(address(registry.gaugeRegistry()), CURVE_REGISTRY, "swap back did not land");
        assertGt(handler.swapsToPrimary(), 0, "swap back not counted");

        handler.optOut(0, 7);
        assertGt(handler.optOuts(), before, "optOut did not resume after swapping back");
    }

    function vlcvxBalanceNext(address who) internal returns (uint256) {
        IvlCVX(VLCVX).checkpointEpoch();
        return IvlCVX(VLCVX).balanceAtEpochOf(IvlCVX(VLCVX).epochCount() - 1, who);
    }
}
