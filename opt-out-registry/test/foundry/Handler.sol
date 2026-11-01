// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {OptOutRegistry} from "../../contracts/OptOutRegistry.sol";
import {IvlCVX} from "../../contracts/interfaces/IvlCVX.sol";
import {IGaugeRegistry} from "../../contracts/interfaces/IGaugeRegistry.sol";

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @notice Bounded action surface for the invariant campaign.
/// @dev Foundry generates the call sequence; this only narrows arguments to the region where
///      something interesting can happen. It keeps a ghost record of who has an opt-out
///      declared for the next epoch, built purely from what the actions *did*, never read back
///      from the registry — so agreement between the two is evidence rather than tautology.
///      Each action also predicts, before calling, whether the call should succeed, and
///      records a contradiction either way. Without that the try/catch quietly absorbs a call
///      that should have worked: the ghost is not advanced either, so the two stay in
///      agreement and a registry that rejects nearly everything passes the campaign.
contract Handler is Test {
    OptOutRegistry public immutable registry;
    IvlCVX public immutable vlcvx;
    IERC20 public immutable cvx;
    address public immutable owner;

    address[] public actors;
    address[] public gauges;

    /// The two registries this campaign swaps between, and which gauges each one lists.
    /// Recorded once at construction so the prediction below never has to ask the registry
    /// under test what it is currently pointed at.
    address public immutable primaryRegistry;
    address public immutable altRegistry;
    mapping(address => bool) public listedByPrimary;
    mapping(address => bool) public listedByAlt;

    /// Ghost copies of the two owner switches, updated only by the actions that set them.
    address public activeRegistry;
    bool public pausedGhost;

    /// gauge => user => has an opt-out effective from the next epoch
    mapping(address => mapping(address => bool)) public declared;

    /// Frozen answers for settled epochs. These live here, not in the invariant contract,
    /// because Foundry discards state written by `invariant_` functions — a ghost accumulated
    /// there would re-freeze on every check and never actually compare anything.
    struct Frozen {
        address gauge;
        uint32 epoch;
        bytes32 answer;
    }

    Frozen[] internal frozenAnswers;
    mapping(bytes32 => bool) public isFrozen;

    /// Set when a call's outcome contradicted the ghost's prediction. It is recorded rather
    /// than reverted on: the campaign runs with `fail_on_revert = false`, so a revert raised
    /// here would be discarded as just another rejected call and the contradiction lost.
    /// `invariant_noUnexpectedOutcomes` is what turns it into a failure.
    bool public sawUnexpectedOutcome;
    string public unexpectedOutcome;

    function _expect(bool condition, string memory reason) internal {
        if (!condition && !sawUnexpectedOutcome) {
            sawUnexpectedOutcome = true;
            unexpectedOutcome = reason;
        }
    }

    // coverage counters, reported by afterInvariant and pinned by HandlerSanity
    uint256 public optOuts;
    uint256 public optIns;
    uint256 public forcedIns;
    uint256 public forcedOuts;
    uint256 public warps;
    uint256 public prunes;
    uint256 public pauses;
    uint256 public unpauses;
    uint256 public swapsToAlt;
    uint256 public swapsToPrimary;

    constructor(
        OptOutRegistry _registry,
        IvlCVX _vlcvx,
        IERC20 _cvx,
        address _owner,
        address[] memory _actors,
        address[] memory _gauges,
        address _primaryRegistry,
        address _altRegistry
    ) {
        registry = _registry;
        vlcvx = _vlcvx;
        cvx = _cvx;
        owner = _owner;
        actors = _actors;
        gauges = _gauges;

        primaryRegistry = _primaryRegistry;
        altRegistry = _altRegistry;
        activeRegistry = _primaryRegistry;
        for (uint256 i; i < _gauges.length; ++i) {
            listedByPrimary[_gauges[i]] = IGaugeRegistry(_primaryRegistry).isRegisteredGauge(_gauges[i]);
            listedByAlt[_gauges[i]] = IGaugeRegistry(_altRegistry).isRegisteredGauge(_gauges[i]);
        }
    }

    /// @dev Whether the gauge is listed by whichever registry the contract is pointed at.
    function _listedNow(address g) internal view returns (bool) {
        return activeRegistry == primaryRegistry ? listedByPrimary[g] : listedByAlt[g];
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function frozenCount() external view returns (uint256) {
        return frozenAnswers.length;
    }

    function frozenAt(uint256 i) external view returns (address, uint32, bytes32) {
        Frozen storage f = frozenAnswers[i];
        return (f.gauge, f.epoch, f.answer);
    }

    /// @dev Photograph the most recently settled epoch for each gauge, once. The invariant
    ///      contract re-reads these and asserts they never change.
    function _freezeSettled() internal {
        uint256 current = registry.currentEpoch();
        uint256 deployEpoch = registry.deployEpoch();
        if (current == 0 || current <= deployEpoch) return;

        uint32 e = uint32(current - 1);
        for (uint256 i; i < gauges.length; ++i) {
            bytes32 key = keccak256(abi.encode(gauges[i], e));
            if (isFrozen[key]) continue;
            isFrozen[key] = true;
            frozenAnswers.push(
                Frozen({
                    gauge: gauges[i],
                    epoch: e,
                    answer: keccak256(abi.encode(registry.optOutAtEpoch(gauges[i], e)))
                })
            );
        }
    }

    /// @dev Gauges this actor currently has declared. Without steering toward these, a random
    ///      mask almost never names a gauge the actor is actually opted out of, and `optIn`
    ///      spends the whole campaign reverting instead of exercising the close path.
    function _declaredFor(address actor) internal view returns (address[] memory out) {
        uint256 n;
        for (uint256 i; i < gauges.length; ++i) {
            if (declared[gauges[i]][actor]) n++;
        }
        out = new address[](n);
        uint256 k;
        for (uint256 i; i < gauges.length; ++i) {
            if (declared[gauges[i]][actor]) out[k++] = gauges[i];
        }
    }

    function gaugeCount() external view returns (uint256) {
        return gauges.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev A bitmask over the gauge list, so the fuzzer naturally produces singletons, batches
    ///      and the empty set without any of them being special-cased.
    function _select(uint256 mask) internal view returns (address[] memory out) {
        uint256 n;
        for (uint256 i; i < gauges.length; ++i) {
            if (mask & (1 << i) != 0) n++;
        }
        out = new address[](n);
        uint256 k;
        for (uint256 i; i < gauges.length; ++i) {
            if (mask & (1 << i) != 0) out[k++] = gauges[i];
        }
    }

    /// @dev Whether `optOut` is supposed to succeed, decided before the call. All gauges here
    ///      come from the live registry and the mask never repeats one, so the only grounds
    ///      for rejection are the balance floor and gauges the actor already holds.
    function _expectOptOutOk(address actor, address[] memory gs) internal returns (bool) {
        // Pause is checked before anything else in `optOut`, so it decides this outright.
        if (pausedGhost) return false;

        vlcvx.checkpointEpoch();
        uint256 balance = vlcvx.balanceAtEpochOf(registry.currentEpoch() + 1, actor);
        if (balance == 0 || balance < registry.minOptOutBalance()) return false;
        for (uint256 i; i < gs.length; ++i) {
            // A registry swap makes the other registry's gauges unlistable without touching
            // anything already recorded, so this has to be re-decided on every call.
            if (!_listedNow(gs[i])) return false;
            if (declared[gs[i]][actor]) return false;
        }
        return true;
    }

    function optOut(uint256 actorSeed, uint256 mask) external {
        address actor = _actor(actorSeed);
        address[] memory gs = _select(mask);
        if (gs.length == 0) return;

        bool expectOk = _expectOptOutOk(actor, gs);

        vm.prank(actor);
        try registry.optOut(gs) {
            _expect(expectOk, "optOut succeeded where the ghost expected a revert");
            for (uint256 i; i < gs.length; ++i) declared[gs[i]][actor] = true;
            optOuts++;
        } catch {
            _expect(!expectOk, "optOut reverted where the ghost expected success");
        }
        _freezeSettled();
    }

    function optIn(uint256 actorSeed, uint256 mask) external {
        address actor = _actor(actorSeed);

        // Mostly close things the actor actually holds; occasionally use the raw mask so the
        // rejection paths stay exercised too.
        address[] memory gs = mask % 8 == 0 ? _select(mask) : _declaredFor(actor);
        if (gs.length == 0) return;

        // Whatever the actor currently holds must be closable; only the raw-mask branch is
        // allowed to be rejected. Without this the catch hides an `optIn` that never works.
        bool expectOk = true;
        for (uint256 i; i < gs.length; ++i) {
            if (!declared[gs[i]][actor]) expectOk = false;
        }

        vm.prank(actor);
        try registry.optIn(gs) {
            _expect(expectOk, "optIn succeeded where the ghost expected a revert");
            for (uint256 i; i < gs.length; ++i) {
                declared[gs[i]][actor] = false;
                if (!registry.isGaugeMember(gs[i], actor)) prunes++;
            }
            optIns++;
        } catch {
            _expect(!expectOk, "optIn reverted where the ghost expected success");
        }
        _freezeSettled();
    }

    /// @dev No balance gate any more, so this lands whenever the pair is actually declared —
    ///      which is far more often than when it needed a powerless actor to exist first.
    function forceOptIn(uint256 actorSeed, uint256 gaugeSeed) external {
        address actor = _actor(actorSeed);
        address gauge = gauges[gaugeSeed % gauges.length];

        address[] memory gs = new address[](1);
        gs[0] = gauge;

        bool expectOk = declared[gauge][actor];

        vm.prank(owner);
        try registry.forceOptIn(gs, actor) {
            _expect(expectOk, "forceOptIn succeeded where the ghost expected a revert");
            declared[gauge][actor] = false;
            forcedIns++;
            if (!registry.isGaugeMember(gauge, actor)) prunes++;
        } catch {
            _expect(!expectOk, "forceOptIn reverted where the ghost expected success");
        }
        _freezeSettled();
    }

    /// @dev The owner-side add. Ignores the balance floor and the pause flag, but the registry
    ///      still gates it.
    function forceOptOut(uint256 actorSeed, uint256 gaugeSeed) external {
        address actor = _actor(actorSeed);
        address gauge = gauges[gaugeSeed % gauges.length];

        address[] memory gs = new address[](1);
        gs[0] = gauge;

        // Same registry gate as the public path, so a swap can refuse this too.
        bool expectOk = !declared[gauge][actor] && _listedNow(gauge);

        vm.prank(owner);
        try registry.forceOptOut(gs, actor) {
            _expect(expectOk, "forceOptOut succeeded where the ghost expected a revert");
            declared[gauge][actor] = true;
            forcedOuts++;
        } catch {
            _expect(!expectOk, "forceOptOut reverted where the ghost expected success");
        }
        _freezeSettled();
    }

    /// @dev Sometimes jumps far enough for every lock to age out, which is what makes
    ///      `forceOptIn` reachable at all.
    function warp(uint256 seed) external {
        uint256 weeksAhead = seed % 100 < 12 ? 18 + (seed % 4) : 1 + (seed % 3);
        vm.warp(block.timestamp + weeksAhead * 1 weeks);
        // Always checkpoint after a long jump. Left to accumulate, the catch-up append runs to
        // hundreds of epochs in a single call and runs out of gas — which is a property of the
        // locker's loop, not of this registry, and only served to lose coverage elsewhere.
        // Short jumps still leave it stale half the time, which is the case worth exercising.
        if (weeksAhead >= 18 || seed % 2 == 0) vlcvx.checkpointEpoch();
        warps++;
        _freezeSettled();
    }

    function relock(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        deal(address(cvx), actor, 1000e18);
        vm.startPrank(actor);
        cvx.approve(address(vlcvx), 1000e18);
        vlcvx.lock(actor, 1000e18, 0);
        vm.stopPrank();
    }

    /// @dev Opt out and straight back in, inside one pending window. That is the path that
    ///      discards the member entirely, and random sequencing lands on it only by chance.
    function optOutThenIn(uint256 actorSeed, uint256 gaugeSeed) external {
        address actor = _actor(actorSeed);
        address[] memory gs = new address[](1);
        gs[0] = gauges[gaugeSeed % gauges.length];

        vm.prank(actor);
        try registry.optOut(gs) {
            declared[gs[0]][actor] = true;
            optOuts++;
        } catch {
            return;
        }

        // The opt-out above just succeeded, so withdrawing it in the same window must too.
        // This is the never-effective prune path; a revert here is a real failure.
        vm.prank(actor);
        try registry.optIn(gs) {
            declared[gs[0]][actor] = false;
            optIns++;
            if (!registry.isGaugeMember(gs[0], actor)) prunes++;
        } catch {
            _expect(false, "optIn failed to withdraw an opt-out made in the same window");
        }
        _freezeSettled();
    }

    /// @dev Weighted toward unpaused: a campaign spent mostly paused would exercise the
    ///      rejection and little else. The test is `% 5 == 3` rather than `% 5 == 0` because
    ///      the fuzzer favours 0 heavily — keying the disruptive branch on zero left the
    ///      contract paused for most of every run and dropped applied opt-outs to nothing.
    function togglePause(uint256 seed) external {
        bool want = seed % 5 == 3;
        vm.prank(owner);
        registry.setOptOutsPaused(want);
        pausedGhost = want;
        if (want) pauses++;
        else unpauses++;
        _freezeSettled();
    }

    /// @dev Swaps which registry gates new opt-outs. Weighted back toward the primary for the
    ///      same reason, and keyed off a value the fuzzer does not favour, as above.
    function swapRegistry(uint256 seed) external {
        address want = seed % 5 == 2 ? altRegistry : primaryRegistry;
        vm.prank(owner);
        registry.setGaugeRegistry(want);
        activeRegistry = want;
        if (want == altRegistry) swapsToAlt++;
        else swapsToPrimary++;
        _freezeSettled();
    }

    function setFloor(uint256 v) external {
        vm.prank(owner);
        registry.setMinOptOutBalance(v % 3 == 0 ? 0 : (v % 500e18) + 1);
    }
}
