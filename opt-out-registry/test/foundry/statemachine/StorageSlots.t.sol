// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {OptOutRegistry} from "../../../contracts/OptOutRegistry.sol";
import {MockVlCVX, MockGaugeRegistry} from "./Mocks.sol";

/// Direct storage-level verification of the `_memberSlots` packing and the two swap-and-pop
/// index fixups. Reads `_gaugeMembers` / `_userGauges` / `_memberSlots` raw rather than
/// inferring them from the public views.
contract StorageSlotsTest is Test {
    OptOutRegistry reg;
    MockVlCVX vl;
    MockGaugeRegistry gr;
    address owner = address(0xA11CE);

    uint256 constant DUR = 7 days;
    uint256 constant INDEX_MASK = type(uint128).max;

    // storage slots from `forge inspect ... storage`. Re-check these whenever a state variable
    // is added or reordered: slot 4 holds `gaugeRegistry` packed with `optOutsPaused`, slots 5-7 the vote sources, and
    // anything inserted above shifts everything below. The `len view mismatch` assertions
    // below are what catches it.
    uint256 constant S_MEMBERSLOTS = 9;
    uint256 constant S_GAUGEMEMBERS = 10;
    uint256 constant S_USERGAUGES = 11;

    address[] U;
    address[] G;

    function setUp() public {
        vm.warp(1_700_000_000);
        uint32 e0 = uint32(block.timestamp - 100 * DUR);
        vl = new MockVlCVX(e0);
        gr = new MockGaugeRegistry();
        reg = new OptOutRegistry("t", owner, address(vl), address(gr), 1);
        for (uint256 i; i < 5; ++i) {
            U.push(address(uint160(0x1001 + i)));
            vl.setBal(U[i], 100e18);
        }
        for (uint256 i; i < 4; ++i) {
            G.push(address(uint160(0x2001 + i)));
        }
    }

    function _slot(address g, address u) internal view returns (uint256) {
        return uint256(vm.load(address(reg), keccak256(abi.encode(u, keccak256(abi.encode(g, S_MEMBERSLOTS))))));
    }

    function _arrLen(uint256 base, address key) internal view returns (uint256) {
        return uint256(vm.load(address(reg), keccak256(abi.encode(key, base))));
    }

    function _arrAt(uint256 base, address key, uint256 i) internal view returns (address) {
        bytes32 head = keccak256(abi.encode(key, base));
        return address(uint160(uint256(vm.load(address(reg), bytes32(uint256(keccak256(abi.encode(head))) + i)))));
    }

    function _checkSlots() internal view {
        for (uint256 gi; gi < G.length; ++gi) {
            address g = G[gi];
            uint256 n = _arrLen(S_GAUGEMEMBERS, g);
            assertEq(n, reg.gaugeMemberCount(g), "len view mismatch");
            for (uint256 i; i < n; ++i) {
                address m = _arrAt(S_GAUGEMEMBERS, g, i);
                assertTrue(m != address(0), "zero member entry");
                uint256 s = _slot(g, m);
                assertTrue(s != 0, "member with no slot");
                assertEq(s & INDEX_MASK, i + 1, "gaugeMembers index wrong");
                // high half must point at this gauge inside the member's gauge list
                uint256 j = (s >> 128) - 1;
                assertLt(j, _arrLen(S_USERGAUGES, m), "userGauges index out of range");
                assertEq(_arrAt(S_USERGAUGES, m, j), g, "userGauges index points elsewhere");
                // no duplicates
                for (uint256 k = i + 1; k < n; ++k) {
                    assertTrue(_arrAt(S_GAUGEMEMBERS, g, k) != m, "duplicate gauge member");
                }
                // history and slot must co-exist
                assertTrue(reg.membershipHistory(g, m).length != 0, "member with empty history");
            }
        }
        for (uint256 ui; ui < U.length; ++ui) {
            address u = U[ui];
            uint256 n = _arrLen(S_USERGAUGES, u);
            assertEq(n, reg.userGaugeCount(u), "len view mismatch");
            for (uint256 i; i < n; ++i) {
                address g = _arrAt(S_USERGAUGES, u, i);
                uint256 s = _slot(g, u);
                assertTrue(s != 0, "gauge with no slot");
                assertEq(s >> 128, i + 1, "userGauges index wrong");
                uint256 j = (s & INDEX_MASK) - 1;
                assertLt(j, _arrLen(S_GAUGEMEMBERS, g), "gaugeMembers index out of range");
                assertEq(_arrAt(S_GAUGEMEMBERS, g, j), u, "gaugeMembers index points elsewhere");
                for (uint256 k = i + 1; k < n; ++k) {
                    assertTrue(_arrAt(S_USERGAUGES, u, k) != g, "duplicate user gauge");
                }
            }
        }
        // reverse direction: a nonzero slot implies presence in both arrays
        for (uint256 gi; gi < G.length; ++gi) {
            for (uint256 ui; ui < U.length; ++ui) {
                uint256 s = _slot(G[gi], U[ui]);
                bool hist = reg.membershipHistory(G[gi], U[ui]).length != 0;
                assertEq(s != 0, hist, "slot/history desync");
                if (s == 0) continue;
                assertEq(_arrAt(S_GAUGEMEMBERS, G[gi], (s & INDEX_MASK) - 1), U[ui], "fwd gauge");
                assertEq(_arrAt(S_USERGAUGES, U[ui], (s >> 128) - 1), G[gi], "fwd user");
            }
        }
    }

    function testFuzz_slotIntegrity(uint256 seed) public {
        for (uint256 step; step < 60; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 kind = seed % 4;
            address u = U[(seed >> 8) % U.length];
            address g = G[(seed >> 16) % G.length];
            address[] memory arr = new address[](1);
            arr[0] = g;
            if (kind == 0) {
                vm.prank(u);
                try reg.optOut(arr) {} catch {}
            } else if (kind == 1) {
                vm.prank(u);
                try reg.optIn(arr) {} catch {}
            } else if (kind == 2) {
                // No balance condition on the owner path any more, so no need to zero it.
                vm.prank(owner);
                try reg.forceOptIn(arr, u) {} catch {}
            } else {
                if ((seed >> 24) % 3 == 0) vm.warp(block.timestamp + DUR);
            }
            _checkSlots();
        }
    }

    /// Deterministic: prune the first member of a gauge while the last is a same-window entry.
    function test_slotsAfterMiddlePrune() public {
        for (uint256 i; i < 5; ++i) {
            vm.prank(U[i]);
            reg.optOut(_all());
        }
        _checkSlots();
        // prune U[0] on G[0]: forces a swap in both arrays
        vm.prank(U[0]);
        address[] memory one = new address[](1);
        one[0] = G[0];
        reg.optIn(one);
        _checkSlots();
        // and again on a different gauge
        vm.prank(U[2]);
        one[0] = G[2];
        reg.optIn(one);
        _checkSlots();
        assertEq(reg.gaugeMemberCount(G[0]), 4);
        assertEq(reg.userGaugeCount(U[0]), 3);
    }

    function _all() internal view returns (address[] memory a) {
        a = new address[](G.length);
        for (uint256 i; i < G.length; ++i) {
            a[i] = G[i];
        }
    }
}
