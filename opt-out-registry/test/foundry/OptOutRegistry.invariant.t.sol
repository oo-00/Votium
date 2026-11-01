// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {OptOutRegistry} from "../../contracts/OptOutRegistry.sol";
import {IvlCVX} from "../../contracts/interfaces/IvlCVX.sol";
import {Handler, IERC20} from "./Handler.sol";

/// @notice Stateful invariant campaign against the live vlCVX locker and Curve gauge registry.
/// @dev Foundry generates the call sequences here rather than a script choosing them, which is
///      the point of running this alongside the JS campaign: it reaches orderings nobody thought
///      to write down, and shrinks any failure to a minimal reproduction.
contract OptOutRegistryInvariants is StdInvariant, Test {
    address constant VLCVX = 0x72a19342e8F1838460eBFCCEf09F6585e32db86E;
    address constant CVX = 0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B;
    address constant CURVE_REGISTRY = 0x96b24E0534B0cA31D8523D4be4904747Fd579D95;
    address constant FX_REGISTRY = 0xC2F99261d84D1665Df7e50F46813497A737AfB20;
    uint32 constant ACTIVE = type(uint32).max;

    OptOutRegistry internal registry;
    IvlCVX internal vlcvx;
    Handler internal handler;
    address internal owner = address(0xA11CE);

    address[] internal actors;
    address[] internal gauges;

    function setUp() public {
        string memory url = vm.envOr("FORK_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        vm.createSelectFork(url);

        vlcvx = IvlCVX(VLCVX);

        // Three real gauges, read from the live registry rather than hardcoded.
        (bool ok, bytes memory data) =
            CURVE_REGISTRY.staticcall(abi.encodeWithSignature("gaugeLength()"));
        require(ok && abi.decode(data, (uint256)) >= 3, "registry too small");
        for (uint256 i; i < 3; ++i) {
            (ok, data) = CURVE_REGISTRY.staticcall(abi.encodeWithSignature("activeGauges(uint256)", i));
            require(ok, "activeGauges");
            gauges.push(abi.decode(data, (address)));
        }
        // One real f(x) gauge too. Without it a swap to the f(x) registry would make every
        // gauge in the pool unlistable, and the campaign would spend that whole stretch
        // proving only that opt-out refuses.
        (ok, data) = FX_REGISTRY.staticcall(abi.encodeWithSignature("activeGauges(uint256)", uint256(0)));
        require(ok, "fx activeGauges");
        gauges.push(abi.decode(data, (address)));

        registry = new OptOutRegistry("invariant", owner, VLCVX, CURVE_REGISTRY, 1e18);

        // Five actors. Four hold vlCVX; the fifth never locks, so the balance gate stays live.
        for (uint256 i; i < 5; ++i) {
            address a = address(uint160(0xACC0 + i));
            actors.push(a);
            if (i == 4) continue;
            deal(CVX, a, 1000e18);
            vm.startPrank(a);
            IERC20(CVX).approve(VLCVX, 1000e18);
            vlcvx.lock(a, 1000e18, 0);
            vm.stopPrank();
        }

        handler =
            new Handler(registry, vlcvx, IERC20(CVX), owner, actors, gauges, CURVE_REGISTRY, FX_REGISTRY);

        targetContract(address(handler));
        // Only the bounded actions, never the raw registry: unbounded calls would spend the
        // whole campaign bouncing off input validation instead of exploring state.
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = Handler.optOut.selector;
        selectors[1] = Handler.optIn.selector;
        selectors[2] = Handler.forceOptIn.selector;
        selectors[3] = Handler.warp.selector;
        selectors[4] = Handler.relock.selector;
        selectors[5] = Handler.setFloor.selector;
        selectors[6] = Handler.optOutThenIn.selector;
        selectors[7] = Handler.togglePause.selector;
        selectors[8] = Handler.swapRegistry.selector;
        selectors[9] = Handler.forceOptOut.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ------------------------------------------------------------------
    // The guarantee the contract exists to provide.
    // ------------------------------------------------------------------

    /// @notice A settled epoch's answer, once observed, never changes again.
    /// @dev The record is kept by the handler, not here. Foundry discards state written by an
    ///      `invariant_` function, so a ghost accumulated in this contract would re-freeze on
    ///      every evaluation and never compare anything — it would pass unconditionally while
    ///      testing nothing.
    function invariant_settledEpochsAreImmutable() public view {
        uint256 n = handler.frozenCount();
        for (uint256 i; i < n; ++i) {
            (address gauge, uint32 epoch, bytes32 answer) = handler.frozenAt(i);
            assertEq(
                keccak256(abi.encode(registry.optOutAtEpoch(gauge, epoch))),
                answer,
                "settled epoch answer changed"
            );
        }
    }

    /// @notice No call's outcome contradicted what the ghost predicted for it.
    /// @dev The campaign runs with `fail_on_revert = false`, so a call that reverts when it
    ///      should have worked is otherwise silently dropped — and since the ghost is only
    ///      advanced on success, every other invariant here still passes, comparing two
    ///      accounts of a history in which nothing happened.
    function invariant_noUnexpectedOutcomes() public view {
        assertFalse(handler.sawUnexpectedOutcome(), handler.unexpectedOutcome());
    }

    // ------------------------------------------------------------------
    // Internal consistency.
    // ------------------------------------------------------------------

    /// @notice The reported count always equals the length of the list it validates.
    function invariant_countEqualsListLength() public view {
        uint256 current = registry.currentEpoch();
        uint256 deployEpoch = registry.deployEpoch();

        // Walk back from the present rather than forward from deployment. `warp` jumps up to
        // 21 weeks per call, so anchoring at deployEpoch meant this only ever inspected the
        // first few epochs — pre-history by the end of a run.
        uint256 oldest = current + 1 > deployEpoch + 6 ? current + 1 - 6 : deployEpoch;
        for (uint256 g; g < gauges.length; ++g) {
            for (uint256 e = oldest; e <= current + 1; ++e) {
                // NB: structural, not a check of the accounting. The array is allocated at
                // `count` and never resized, so this holds however wrong the count is. The
                // accounting is checked against the handler's ghost in
                // `invariant_pendingEpochMatchesGhost`.
                assertEq(
                    registry.optOutAtEpoch(gauges[g], e).length,
                    registry.optOutCountAtEpoch(gauges[g], e),
                    "count != list length"
                );
            }
        }
    }

    /// @notice A cursor walk reproduces the whole-list read exactly.
    function invariant_cursorWalkMatchesList() public view {
        uint256 e = registry.currentEpoch();
        for (uint256 g; g < gauges.length; ++g) {
            address[] memory full = registry.optOutAtEpoch(gauges[g], e);

            address[] memory walked = new address[](full.length);
            uint256 filled;
            uint256 idx;
            bool done;
            while (!done) {
                (address[] memory part, uint256 next, bool isDone) =
                    registry.optOutAtEpochFrom(gauges[g], e, idx, 2);
                for (uint256 i; i < part.length; ++i) walked[filled++] = part[i];
                idx = next;
                done = isDone;
            }

            assertEq(filled, full.length, "cursor walk length");
            for (uint256 i; i < full.length; ++i) {
                assertEq(walked[i], full[i], "cursor walk order");
            }
        }
    }

    /// @notice Membership bookkeeping: the packed indices never drift from the arrays.
    function invariant_memberBookkeeping() public view {
        for (uint256 g; g < gauges.length; ++g) {
            uint256 members;
            for (uint256 a; a < actors.length; ++a) {
                if (registry.isGaugeMember(gauges[g], actors[a])) members++;
            }
            assertEq(registry.gaugeMemberCount(gauges[g]), members, "gauge member count drift");
        }

        for (uint256 a; a < actors.length; ++a) {
            uint256 owned;
            for (uint256 g; g < gauges.length; ++g) {
                if (registry.isGaugeMember(gauges[g], actors[a])) owned++;
            }
            assertEq(registry.userGaugeCount(actors[a]), owned, "user gauge count drift");
        }
    }

    /// @notice History stays well formed: increasing, non-overlapping, never empty, one tail.
    function invariant_historyWellFormed() public view {
        for (uint256 g; g < gauges.length; ++g) {
            for (uint256 a; a < actors.length; ++a) {
                OptOutRegistry.Membership[] memory h =
                    registry.membershipHistory(gauges[g], actors[a]);

                assertEq(h.length > 0, registry.isGaugeMember(gauges[g], actors[a]), "member/history");

                for (uint256 i; i < h.length; ++i) {
                    assertGt(h[i].endEpoch, h[i].startEpoch, "zero-length interval survived");
                    if (i > 0) {
                        assertGt(h[i].startEpoch, h[i - 1].startEpoch, "starts not increasing");
                        assertGe(h[i].startEpoch, h[i - 1].endEpoch, "intervals overlap");
                    }
                    if (i + 1 < h.length) {
                        assertTrue(h[i].endEpoch != ACTIVE, "non-tail interval left open");
                    }
                }
            }
        }
    }

    /// @notice Count checkpoints stay strictly ordered, which the binary search depends on.
    function invariant_countCheckpointsOrdered() public view {
        for (uint256 g; g < gauges.length; ++g) {
            OptOutRegistry.CountCheckpoint[] memory cps = registry.countHistory(gauges[g]);
            for (uint256 i = 1; i < cps.length; ++i) {
                assertGt(cps[i].epoch, cps[i - 1].epoch, "checkpoints not increasing");
            }
        }
    }

    // ------------------------------------------------------------------
    // Agreement with the handler's ghost record.
    // ------------------------------------------------------------------

    /// @notice What the registry says about the pending epoch is what the actions declared.
    /// @dev The ghost is built only from calls that succeeded, never read back from the
    ///      registry, so this compares two independent accounts of the same history.
    function invariant_pendingEpochMatchesGhost() public view {
        uint256 pending = registry.currentEpoch() + 1;

        for (uint256 g; g < gauges.length; ++g) {
            for (uint256 a; a < actors.length; ++a) {
                assertEq(
                    registry.isOptedOutAtEpoch(gauges[g], actors[a], pending),
                    handler.declared(gauges[g], actors[a]),
                    "pending epoch disagrees with ghost"
                );
            }
        }
    }

    /// @notice Batch counts agree with the single-gauge reads they replace.
    function invariant_batchCountsAgree() public view {
        uint256 e = registry.currentEpoch();
        uint256[] memory batch = registry.optOutCountsAtEpoch(gauges, e);
        for (uint256 g; g < gauges.length; ++g) {
            assertEq(batch[g], registry.optOutCountAtEpoch(gauges[g], e), "batch count mismatch");
        }
    }

    /// @notice Reports what the campaign actually reached. Logging only, deliberately.
    /// @dev A coverage assertion cannot live here, and cannot live in an `invariant_` function
    ///      either. Those are evaluated after every call, so one would fire whenever the first
    ///      generated call happened to be a no-op. And an assertion here is defeated by
    ///      shrinking: on failure Foundry minimises the sequence and replays it, so "the
    ///      campaign did nothing" shrinks to a one-call sequence that trivially satisfies it,
    ///      and the numbers printed would describe the replay rather than the real run.
    ///      Coverage is pinned instead by `HandlerSanity`, which asserts directly that each
    ///      handler action lands.
    function afterInvariant() public view {
        console.log("optOuts   ", handler.optOuts());
        console.log("optIns    ", handler.optIns());
        console.log("forcedIns ", handler.forcedIns());
        console.log("forcedOuts", handler.forcedOuts());
        console.log("warps     ", handler.warps());
        console.log("prunes    ", handler.prunes());
        console.log("frozen    ", handler.frozenCount());
        console.log("pauses    ", handler.pauses());
        console.log("unpauses  ", handler.unpauses());
        console.log("swapsAlt  ", handler.swapsToAlt());
        console.log("swapsPrim ", handler.swapsToPrimary());
    }
}
